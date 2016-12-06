//  Created by Michael Kirk on 11/11/16.
//  Copyright © 2016 Open Whisper Systems. All rights reserved.

import Foundation
import PromiseKit
import WebRTC

enum CallState: String {
    case idle
    case dialing
    case answering
    case remoteRinging
    case localRinging
    case connected
}

class Call {
    var state: CallState
    var uniqueId: UInt64

    init(uniqueId: UInt64) {
        self.state = .idle
        self.uniqueId = uniqueId
    }
}

enum CallErrors: Error {
    case AlreadyInCall
    case NoCurrentContactThread
}

class CallService: NSObject, RTCDataChannelDelegate, RTCPeerConnectionDelegate {

    // MARK: - Properties

    let TAG = "[CallService]"

    // MARK: Dependencies

    let accountManager: AccountManager
    let messageSender: MessageSender
    var peerConnectionClient: PeerConnectionClient?

    // MARK: Class

    static let DataChannelLabel = "signaling"
    static let fallbackIceServer = RTCIceServer(urlStrings: ["stun:stun1.l.google.com:19302"])

    // MARK: Ivars

    var dataChannel: RTCDataChannel?
    var thread: TSContactThread!
    var call: Call?
    var pendingIceUpdates: [OWSOutgoingCallMessage]?

//    var iceUpdatesPromise: Promise<Void>

    required init(accountManager anAccountManager: AccountManager, messageSender aMessageSender: MessageSender) {
        accountManager = anAccountManager
        messageSender = aMessageSender
    }

    // MARK: - Call Lifecyle

    func handleOutgoingCall(thread aThread: TSContactThread) -> Promise<Void> {
        thread = aThread
        Logger.verbose("\(TAG) receivedCallOffer for thread:\(thread)")

        call = Call(uniqueId: UInt64.ows_random())
        pendingIceUpdates = []

        return getIceServers().then { iceServers -> Promise<RTCSessionDescription> in
            Logger.debug("\(self.TAG) got ice servers:\(iceServers)")
            self.peerConnectionClient = PeerConnectionClient(iceServers: iceServers, peerConnectionDelegate: self)

            // TODO Would dataChannel be better created within PeerConnectionClient class? Seems like it's only created on outgoing.
            self.dataChannel = self.peerConnectionClient!.createDataChannel(label: CallService.DataChannelLabel, delegate: self)

            return self.peerConnectionClient!.createOffer()
        }.then { sessionDescription -> Promise<Void> in
            return self.peerConnectionClient!.setLocalSessionDescription(sessionDescription).then {
                let offerMessage = OWSCallOfferMessage(callId: self.call!.uniqueId, sessionDescription: sessionDescription.sdp)
                let callMessage = OWSOutgoingCallMessage(thread: self.thread, offerMessage: offerMessage)
                return self.sendMessage(callMessage)
            }
        }.then {
            Logger.debug("\(self.TAG) sent CallOffer message in \(self.thread)")
        }.catch { error in
            Logger.error("\(self.TAG) placing call failed with error: \(error)")
        }
    }

    func handleReceivedAnswer(thread: TSContactThread, callId: UInt64, sessionDescription: String) {
        // TODO 
        //SEND pendingIceUpdates
        // etc.
    }

    func handleReceivedOffer(thread aThread: TSContactThread, callId: UInt64, sessionDescription sdpString: String) -> Promise<Void> {
        thread = aThread
        Logger.verbose("\(TAG) receivedCallOffer for thread:\(thread)")

        guard call == nil else {
            Logger.error("\(TAG) refusing to receiveOffer, since there is an existing call: \(call)")
            return Promise { fulfill, reject in
                reject(CallErrors.AlreadyInCall)
            }
        }

        call = Call(uniqueId: callId)
        return getIceServers().then { (iceServers: [RTCIceServer]) -> Promise<RTCSessionDescription> in
            self.peerConnectionClient = PeerConnectionClient(iceServers: iceServers, peerConnectionDelegate: self)

            let sessionDescription = RTCSessionDescription(type: .offer, sdp: sdpString)
            let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)

            // Find a sessionDescription compatible with my constraints and the remote sessionDescription
            return self.peerConnectionClient!.negotiateSessionDescription(remoteDescription: sessionDescription, constraints: constraints)
        }.then { (negotiatedSessionDescription: RTCSessionDescription) in
            // TODO? WebRtcCallService.this.lockManager.updatePhoneState(LockManager.PhoneState.PROCESSING);
            Logger.debug("\(self.TAG) set the remote description")

            let answerMessage = OWSCallAnswerMessage(callId: self.call!.uniqueId, sessionDescription: negotiatedSessionDescription.sdp)
            let callAnswerMessage = OWSOutgoingCallMessage(thread: self.thread, answerMessage: answerMessage)

            return self.sendMessage(callAnswerMessage)
        }.then { () in
            return self.waitForIceUpdates()
        }.then { () in
            Logger.debug("\(self.TAG) received ICE updates")
        }
    }

    fileprivate func waitForIceUpdates() -> Promise<Void> {
        return Promise { fulfill, reject in
            // TODO, how to get handler to resolve this?
        }
    }

    public func handleRemoteAddedIceCandidate(thread aThread: TSContactThread, callId aCallId: UInt64, sdp: String, lineIndex: Int32, mid: String) {
        Logger.debug("\(TAG) received ice update")
        guard thread == aThread else {
            Logger.error("\(TAG) ignoring remote ice update for thread: \(aThread) since the current call is for thread: \(thread)")
            return
        }

        guard let currentCall = call else {
            Logger.error("\(TAG) ignoring remote ice update for callId: \(aCallId), since there is no current call.")
            return
        }

        guard currentCall.uniqueId == aCallId else {
            Logger.error("\(TAG) ignoring remote ice update for call: \(aCallId) since the current call is: \(currentCall.uniqueId)")
            return
        }

        guard peerConnectionClient != nil else {
            Logger.error("\(TAG) ignoring remote ice update for thread: \(aThread) since the current call hasn't initialized it's peerConnectionClient")
            return
        }

        peerConnectionClient!.addIceCandidate(RTCIceCandidate(sdp: sdp, sdpMLineIndex: lineIndex, sdpMid: mid))
    }

    public func handleLocalAddedIceCandidate(_ iceCandidate: RTCIceCandidate) {
        guard let currentCall = call else {
            Logger.warn("\(TAG) ignoring local ice candidate, since there is no current call.")
            return
        }

        guard currentCall.state != .idle else {
            Logger.warn("\(TAG) ignoring local ice candidate, since call is now idle.")
            return
        }

        guard let currentThread = thread else {
            Logger.warn("\(TAG) ignoring local ice candidate, because there was no currentThread.")
            return
        }

        let iceUpdateMessage = OWSCallIceUpdateMessage(callId: currentCall.uniqueId, sdp: iceCandidate.sdp, sdpMLineIndex: iceCandidate.sdpMLineIndex, sdpMid: iceCandidate.sdpMid)
        let callMessage = OWSOutgoingCallMessage(thread: self.thread, iceUpdateMessage: iceUpdateMessage)

        if pendingIceUpdates != nil {
            // For outgoing messages, we wait to send ice updates until we're sure client received our call message.
            // e.g. if the client has blocked our message due to an identity change, we'd otherwise
            // bombard them with a bunch *more* undecipherable messages.
            pendingIceUpdates!.append(callMessage)
            return
        }

        _ = sendMessage(callMessage).then {
            Logger.debug("\(self.TAG) successfully sent single ice update message.")
        }
        // TODO catch and display server failure?
    }

    fileprivate func getIceServers() -> Promise<[RTCIceServer]> {
        return accountManager.getTurnServerInfo().then { turnServerInfo -> [RTCIceServer] in
            Logger.debug("\(self.TAG) got turn server info \(turnServerInfo)")

            return turnServerInfo.urls.map { url in
                if url.hasPrefix("turn") {
                    // only pass credentials for "turn:" servers.
                    return RTCIceServer(urlStrings: [url], username: turnServerInfo.username, credential: turnServerInfo.password)
                } else {
                    return RTCIceServer(urlStrings: [url])
                }
            } + [CallService.fallbackIceServer]
        }
    }

    fileprivate func sendMessage(_ message: OWSOutgoingCallMessage) -> Promise<Void> {
        return Promise { fulfill, reject in
            self.messageSender.send(message, success: fulfill, failure: reject)
        }
    }

    fileprivate func waitForIceUpdates() {

    }

    public func terminateCall() {
        peerConnectionClient?.terminate()
    }

    // MARK: - RTCDataChannelDelegate

    /** The data channel state changed. */
    public func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        Logger.debug("\(TAG) dataChannelDidChangeState: \(dataChannel)")
    }

    /** The data channel successfully received a data buffer. */
    public func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        Logger.debug("\(TAG) dataChannel didReceiveMessageWith buffer:\(buffer)")

        guard let dataMessage = OWSWebRTCProtosData.parse(from:buffer.data) else {
            // TODO can't proto parsings throw an exception? Is it just being lost in the Objc->Swift?
            Logger.error("\(TAG) failed to parse dataProto")
            return
        }

        if dataMessage.hasConnected() {
            Logger.debug("\(TAG) has connected")
            // TODO: translate from java
            //   Intent intent = new Intent(this, WebRtcCallService.class);
            //   intent.setAction(ACTION_CALL_CONNECTED);
            //   intent.putExtra(EXTRA_CALL_ID, dataMessage.getConnected().getId());
            //   startService(intent);

        } else if dataMessage.hasHangup() {
            Logger.debug("\(TAG) has hangup")
            // TODO: translate from java
            //   Intent intent = new Intent(this, WebRtcCallService.class);
            //   intent.setAction(ACTION_REMOTE_HANGUP);
            //   intent.putExtra(EXTRA_CALL_ID, dataMessage.getHangup().getId());
            //   startService(intent);

        } else if dataMessage.hasVideoStreamingStatus() {
            Logger.debug("\(TAG) has video streaming status")
            // TODO: translate from java
            //   Intent intent = new Intent(this, WebRtcCallService.class);
            //   intent.setAction(ACTION_REMOTE_VIDEO_MUTE);
            //   intent.putExtra(EXTRA_CALL_ID, dataMessage.getVideoStreamingStatus().getId());
            //   intent.putExtra(EXTRA_MUTE, !dataMessage.getVideoStreamingStatus().getEnabled());
            //   startService(intent);
        }
    }

    /** The data channel's |bufferedAmount| changed. */
    public func dataChannel(_ dataChannel: RTCDataChannel, didChangeBufferedAmount amount: UInt64) {
        Logger.debug("\(TAG) didChangeBufferedAmount: \(amount)")
    }

    // MARK: - RTCPeerConnectionDelegate

    /** Called when the SignalingState changed. */
    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {
        Logger.debug("\(TAG) didChange signalingState:\(stateChanged)")
    }

    /** Called when media is received on a new stream from remote peer. */
    public func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        Logger.debug("\(TAG) didAdd stream:\(stream)")
    }

    /** Called when a remote peer closes a stream. */
    public func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {
        Logger.debug("\(TAG) didRemove Stream:\(stream)")
    }

    /** Called when negotiation is needed, for example ICE has restarted. */
    public func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {
        Logger.debug("\(TAG) shouldNegotiate")
    }

    /** Called any time the IceConnectionState changes. */
    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        Logger.debug("\(TAG) didChange IceConnectionState:\(newState)")
    }

    /** Called any time the IceGatheringState changes. */
    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        Logger.debug("\(TAG) didChange IceGatheringState:\(newState)")
    }

    /** New ice candidate has been found. */
    public func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        Logger.debug("\(TAG) didGenerate IceCandidate:\(candidate)")
        self.handleLocalAddedIceCandidate(candidate)
    }

    /** Called when a group of local Ice candidates have been removed. */
    public func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {
        Logger.debug("\(TAG) didRemove IceCandidates:\(candidates)")
    }

    /** New data channel has been opened. */
    public func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        Logger.debug("\(TAG) didOpen dataChannel:\(dataChannel)")
    }

}

fileprivate extension UInt64 {
    static func ows_random() -> UInt64 {
        var random : UInt64 = 0
        arc4random_buf(&random, MemoryLayout.size(ofValue: random))
        return random
    }
}
