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

protocol CallUIAdaptee {
    func startOutgoingCall(_ call: SignalCall);
    func reportIncomingCall(_ call: SignalCall, audioManager: CallAudioManager) -> Promise<Void>;
}

class CallUIiOS8Adaptee: CallUIAdaptee {
    func startOutgoingCall(_ call: SignalCall) {}
    func reportIncomingCall(_ call: SignalCall, audioManager: CallAudioManager) -> Promise<Void> {
        return Promise { _ in
            // TODO
        }
    }
}

@available(iOS 10.0, *)
class CallUICallKitAdaptee: CallUIAdaptee {
    let providerDelegate: ProviderDelegate

    init(callService: CallService) {
        self.providerDelegate = ProviderDelegate(callManager: SpeakerboxCallManager(), callService: callService)
    }

    func startOutgoingCall(_ call: SignalCall) {
        // TODO initiate video call
        providerDelegate.callManager.startCall(handle: call.remotePhoneNumber, video: call.hasVideo)
    }

    func reportIncomingCall(_ call: SignalCall, audioManager: CallAudioManager) -> Promise<Void> {
        return PromiseKit.wrap {
            // FIXME weird to pass the audio manager in here.
            // Crux is, the peerconnectionclient is what controls the audio channel.
            // But a peerconnectionclient is per call.
            // While this providerDelegate is an app singleton.
            providerDelegate.audioManager = audioManager
            providerDelegate.reportIncomingCall(call, completion: $0)
        }
    }
}

/**
 * I actually don't yet understand the role of these CallAudioManager methods as 
 * called in the speakerbox example. Are they redundant with what the RTC setup
 * already does for us?
 *
 * Here's the AVSessionConfig for the ARDRTC Example app, which maybe belongs 
 * in the coonfigureAudio session. and maybe the adding audio tracks is sufficient for startAudio's implenetation?
 *
 *
 187   RTCAudioSessionConfiguration *configuration =
 188       [[RTCAudioSessionConfiguration alloc] init];
 189   configuration.category = AVAudioSessionCategoryAmbient;
 190   configuration.categoryOptions = AVAudioSessionCategoryOptionDuckOthers;
 191   configuration.mode = AVAudioSessionModeDefault;
 192
 193   RTCAudioSession *session = [RTCAudioSession sharedInstance];
 194   [session lockForConfiguration];
 195   BOOL hasSucceeded = NO;
 196   NSError *error = nil;
 197   if (session.isActive) {
 198     hasSucceeded = [session setConfiguration:configuration error:&error];
 199   } else {
 200     hasSucceeded = [session setConfiguration:configuration
 201                                       active:YES
 202                                        error:&error];
 203   }
 204   if (!hasSucceeded) {
 205     RTCLogError(@"Error setting configuration: %@", error.localizedDescription);
 206   }
 207   [session unlockForConfiguration];
 */
protocol CallAudioManager {
    func startAudio();
    func stopAudio();
    func configureAudioSession();
}

class CallManagerAdapter {

    let TAG = "[CallManagerAdapter]"
    let adaptee: CallUIAdaptee

    init(callService: CallService) {
        if #available(iOS 10.0, *) {
            adaptee = CallUICallKitAdaptee(callService: callService)
        } else {
            adaptee = CallUIiOS8Adaptee()
        }
    }

    func reportIncomingCall(_ call: SignalCall, thread: TSContactThread, audioManager: CallAudioManager) {
        adaptee.reportIncomingCall(call, audioManager: audioManager).then {
            Logger.info("\(self.TAG) successfully reported incoming call")
        }.catch { error in
            // TODO UI
            Logger.error("\(self.TAG) reporting incoming call failed with error \(error)")
        }
    }

    func addOutgoingCall(_ call: SignalCall, thread: TSContactThread) {
        adaptee.startOutgoingCall(call)
    }

}

class CallError: Error {
    let description: String

    init(description: String) {
        self.description = description
    }
}

class ClientFailure: CallError {

}

@objc class CallService: NSObject, RTCDataChannelDelegate, RTCPeerConnectionDelegate {

    // MARK: - Properties

    let TAG = "[CallService]"

    // MARK: Dependencies

    let accountManager: AccountManager
    let messageSender: MessageSender
    var callManagerAdapter: CallManagerAdapter!

    // MARK: Class

    static let DataChannelLabel = "signaling"
    static let fallbackIceServer = RTCIceServer(urlStrings: ["stun:stun1.l.google.com:19302"])

    // MARK: Ivars

    var peerConnectionClient: PeerConnectionClient?
    // TODO move thread into SignalCall
    var thread: TSContactThread?
    var call: SignalCall?
    var pendingIceUpdateMessages: [OWSCallIceUpdateMessage]?

    required init(accountManager: AccountManager, messageSender: MessageSender) {
        self.accountManager = accountManager
        self.messageSender = messageSender
        super.init()
        self.callManagerAdapter = CallManagerAdapter(callService: self)
    }

    // MARK: - Class Methods

    // Wrapping this class constant in a method to make it accessible to objc
    class func callServiceActiveCallNotificationName() -> String {
        return  "CallServiceActiveCallNotification"
    }

    // MARK: - Service Actions

    func handleOutgoingCall(thread: TSContactThread) -> SignalCall {
        self.thread = thread
        Logger.verbose("\(TAG) handling outgoing call to thread:\(thread)")

        let newCall = SignalCall(signalingId: UInt64.ows_random(), state: .dialing, remotePhoneNumber: thread.contactIdentifier())
        call = newCall
        pendingIceUpdateMessages = []

        let callRecord = TSCall(timestamp: NSDate.ows_millisecondTimeStamp(), withCallNumber: newCall.remotePhoneNumber, callType: RPRecentCallTypeOutgoing, in: thread)
        callRecord.save()

        _ = getIceServers().then { iceServers -> Promise<RTCSessionDescription> in
            Logger.debug("\(self.TAG) got ice servers:\(iceServers)")
            let peerConnectionClient =  PeerConnectionClient(iceServers: iceServers, peerConnectionDelegate: self)
            self.peerConnectionClient = peerConnectionClient

            self.peerConnectionClient!.createDataChannel(label: CallService.DataChannelLabel, delegate: self)

            return self.peerConnectionClient!.createOffer()
        }.then { sessionDescription -> Promise<Void> in
            return self.peerConnectionClient!.setLocalSessionDescription(sessionDescription).then {
                let offerMessage = OWSCallOfferMessage(callId: newCall.signalingId, sessionDescription: sessionDescription.sdp)
                let callMessage = OWSOutgoingCallMessage(thread: thread, offerMessage: offerMessage)
                return self.sendMessage(callMessage)
            }
        }.catch { error in
            Logger.error("\(self.TAG) placing call failed with error: \(error)")
        }

        return newCall
    }

    func handleReceivedAnswer(thread: TSContactThread, callId: UInt64, sessionDescription: String) {
        Logger.debug("\(TAG) received call answer for call: \(callId) thread: \(thread)")
        Logger.error("FIXME TODO")

        if let pendingIceUpdateMessages = self.pendingIceUpdateMessages {
            let callMessage = OWSOutgoingCallMessage(thread: thread, iceUpdateMessages: pendingIceUpdateMessages)
            _ = sendMessage(callMessage).catch { error in
                Logger.error("\(self.TAG) failed to send ice updates in \(#function) with error: \(error)")
            }
        }

        guard let peerConnectionClient = self.peerConnectionClient else {
            failCall(error: ClientFailure(description: "peerConnectionClient was unexpectedly nil in \(#function)"))
            return
        }

        let sessionDescription = RTCSessionDescription(type: .answer, sdp: sessionDescription)
        _ = peerConnectionClient.setRemoteSessionDescription(sessionDescription).then {
            Logger.debug("\(self.TAG) successfully set remote description")
        }.catch { error in
            Logger.error("\(self.TAG) failed to set remote description with error: \(error)")
        }
    }

    func handleBusyCall(thread aThread: TSContactThread, callId: UInt64) {
        Logger.debug("\(TAG) received 'busy' for call: \(callId) thread: \(thread)")
        Logger.error("FIXME TODO")
        // TODO
//        let busyMessage = OWSCallBusyMessage(callId: callId)
//        let callMessage = OWSOutgoingCallMessage(thread: thread, busyMessage: busyMessage)
//        sendMessage(callMessage)
//        insertMissedCall(thread: thread)
    }

    func isBusy() -> Bool {
        // TODO CallManager adapter?
        return false;
    }

    func handleReceivedOffer(thread aThread: TSContactThread, callId: UInt64, sessionDescription sdpString: String) {
        thread = aThread
        Logger.verbose("\(TAG) receivedCallOffer for thread:\(thread)")

        guard call == nil else {
            if (isBusy()) {
                handleBusyCall(thread: aThread, callId: callId)
            } else {
                Logger.error("\(TAG) refusing to answer call because their is an unexpected existing call, yet phone is not busy.")
            }
            return
        }

        let newCall = SignalCall(signalingId: callId, state: .answering, remotePhoneNumber: aThread.contactIdentifier())
        call = newCall

        _ = getIceServers().then { (iceServers: [RTCIceServer]) -> Promise<RTCSessionDescription> in
            // FIXME for first time call recipients I think we'll see mic/camera permission requests here,
            // even though, from the users perspective, no incoming call is yet visible.
            self.peerConnectionClient = PeerConnectionClient(iceServers: iceServers, peerConnectionDelegate: self)

            let sessionDescription = RTCSessionDescription(type: .offer, sdp: sdpString)
            let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)

            // Find a sessionDescription compatible with my constraints and the remote sessionDescription
            return self.peerConnectionClient!.negotiateSessionDescription(remoteDescription: sessionDescription, constraints: constraints)
        }.then { (negotiatedSessionDescription: RTCSessionDescription) in
            // TODO? WebRtcCallService.this.lockManager.updatePhoneState(LockManager.PhoneState.PROCESSING);
            Logger.debug("\(self.TAG) set the remote description")

            let answerMessage = OWSCallAnswerMessage(callId: newCall.signalingId, sessionDescription: negotiatedSessionDescription.sdp)
            let callAnswerMessage = OWSOutgoingCallMessage(thread: aThread, answerMessage: answerMessage)

            return self.sendMessage(callAnswerMessage)
        }.then { () in
            Logger.debug("\(self.TAG) successfully sent callAnswerMessage")
        }
    }

    public func handleRemoteAddedIceCandidate(thread: TSContactThread, callId: UInt64, sdp: String, lineIndex: Int32, mid: String) {

        Logger.debug("\(TAG) received ice update")
        guard self.thread != nil else {
            // CallService.thread should have already been set at this point.
            Logger.error("\(TAG) ignoring remote ice update for thread: \(thread) since there is no current thread. \(self.thread)")
            return
        }

        guard thread.contactIdentifier() == self.thread!.contactIdentifier() else {
            Logger.error("\(TAG) ignoring remote ice update for thread: \(thread) since the current call is for thread: \(self.thread)")
            return
        }

        guard let call = self.call else {
            Logger.error("\(TAG) ignoring remote ice update for callId: \(callId), since there is no current call.")
            return
        }

        guard call.signalingId == callId else {
            Logger.error("\(TAG) ignoring remote ice update for call: \(callId) since the current call is: \(call.signalingId)")
            return
        }

        guard self.peerConnectionClient != nil else {
            Logger.error("\(TAG) ignoring remote ice update for thread: \(thread) since the current call hasn't initialized it's peerConnectionClient")
            return
        }

        peerConnectionClient!.addIceCandidate(RTCIceCandidate(sdp: sdp, sdpMLineIndex: lineIndex, sdpMid: mid))
    }

    public func handleLocalAddedIceCandidate(_ iceCandidate: RTCIceCandidate) {
        guard let call = self.call else {
            Logger.warn("\(TAG) ignoring local ice candidate, since there is no current call.")
            return
        }

        guard call.state != .idle else {
            Logger.warn("\(TAG) ignoring local ice candidate, since call is now idle.")
            return
        }

        guard let thread = self.thread else {
            Logger.warn("\(TAG) ignoring local ice candidate, because there was no current TSContactThread.")
            return
        }

        let iceUpdateMessage = OWSCallIceUpdateMessage(callId: call.signalingId, sdp: iceCandidate.sdp, sdpMLineIndex: iceCandidate.sdpMLineIndex, sdpMid: iceCandidate.sdpMid)
        if var pendingIceUpdateMessages = self.pendingIceUpdateMessages {
            // For outgoing messages, we wait to send ice updates until we're sure client received our call message.
            // e.g. if the client has blocked our message due to an identity change, we'd otherwise
            // bombard them with a bunch *more* undecipherable messages.
            Logger.debug("\(TAG) enqueuing iceUpdate until we receive call answer")
            pendingIceUpdateMessages.append(iceUpdateMessage)
            return
        }

        let callMessage = OWSOutgoingCallMessage(thread: thread, iceUpdateMessage: iceUpdateMessage)
        _ = sendMessage(callMessage).then {
            Logger.debug("\(self.TAG) successfully sent single ice update message.")
        }
        // TODO catch and display server failure?
    }

    func handleIceConnected() {

        guard let call = self.call else {
            Logger.warn("\(TAG) ignoring \(#function) since there is no current call.")
            return
        }

        guard let thread = self.thread else {
            Logger.warn("\(TAG) ignoring \(#function) since there is no current thread.")
            return
        }

        guard let peerConnectionClient = self.peerConnectionClient else {
            Logger.warn("\(TAG) ignoring \(#function) since there is no current peerConnectionClient.")
            return
        }

        switch (call.state) {
        case .answering:
            call.state = .localRinging
            self.callManagerAdapter.reportIncomingCall(call, thread: thread, audioManager: peerConnectionClient)
        case .dialing:
            call.state = .remoteRinging
            self.callManagerAdapter.addOutgoingCall(call, thread: thread)
        default:
            Logger.debug("\(TAG) unexpected call state for handleIceConnected: \(call.state)")
        }
    }

    func handleRemoteHangup() {
        Logger.debug("\(TAG) in \(#function)")
        Logger.error("\(TAG) TODO")
    }

    func handleAnswerCall(_ call: SignalCall) {
        Logger.debug("\(TAG) in \(#function)")

        guard self.call != nil else {
            Logger.error("\(TAG) ignoring \(#function) since there is no current call")
            return
        }

        guard call == self.call! else {
            Logger.error("\(TAG) ignoring \(#function) for call other than current call")
            return
        }

        guard let thread = self.thread else {
            Logger.error("\(TAG) ignoring \(#function) for call other than current call")
            return
        }

        guard let peerConnectionClient = self.peerConnectionClient else {
            Logger.error("\(TAG) missing peerconnection client in \(#function)")
            return
        }

        let callRecord = TSCall(timestamp: NSDate.ows_millisecondTimeStamp(), withCallNumber: call.remotePhoneNumber, callType: RPRecentCallTypeIncoming, in: thread)
        callRecord.save()

        let callNotificationName = type(of: self).callServiceActiveCallNotificationName()
        NotificationCenter.default.post(name: NSNotification.Name(rawValue: callNotificationName), object: call)

//        incomingRinger.stop();

        //FIXME TODO
//        peerConnectionClient.audioEnabled = true
//        peerConnectionClient.videoEnabled = true

        let message = DataChannelMessage.forConnected(callId: call.signalingId)
        if peerConnectionClient.sendDataChannelMessage(data: message.asData()) {
            Logger.debug("\(TAG) sendDataChannelMessage returned true")
        } else {
            Logger.warn("\(TAG) sendDataChannelMessage returned false")
        }

        handleConnectedCall(call);
    }

    func handleConnectedCall(_ call: SignalCall) {
        Logger.debug("\(TAG) in \(#function)")
        // Anything to do here?
    }

    func handleLocalHungupCall(_ call: SignalCall) {
        guard self.call != nil else {
            Logger.error("\(TAG) ignoring \(#function) since there is no current call")
            return
        }

        guard call == self.call! else {
            Logger.error("\(TAG) ignoring \(#function) for call other than current call")
            return
        }

        guard let peerConnectionClient = self.peerConnectionClient else {
            Logger.error("\(TAG) missing peerconnection client in \(#function)")
            return
        }

        guard let thread = self.thread else {
            Logger.error("\(TAG) missing thread in \(#function)")
            return
        }

        // TODO something like this lifted from Signal-Android.
        //        this.accountManager.cancelInFlightRequests();
        //        this.messageSender.cancelInFlightRequests();

        // If the call is going, we can send the hangup via the data channel.
        let message = DataChannelMessage.forHangup(callId: call.signalingId)
        if peerConnectionClient.sendDataChannelMessage(data: message.asData()) {
            Logger.debug("\(TAG) sendDataChannelMessage returned true")
        } else {
            Logger.warn("\(TAG) sendDataChannelMessage returned false")
        }

        // If the call hasn't started yet, we don't have a data channel to communicate the hang up. Use Signal Service Message.
        let hangupMessage = OWSCallHangupMessage(callId: call.signalingId)
        let callMessage = OWSOutgoingCallMessage(thread: thread, hangupMessage: hangupMessage)
        _  = sendMessage(callMessage).then {
            Logger.debug("\(self.TAG) successfully sent hangup call message to \(thread)")
        }.catch { error in
            Logger.error("\(self.TAG) failed to send hangup call message to \(thread) with error: \(error)")
        }

        terminateCall()
    }

    func handleToggledMute(isMuted: Bool) {
        guard let peerConnectionClient = self.peerConnectionClient else {
            Logger.error("\(TAG) peerConnectionClient unexpectedly nil in \(#function)")
            return
        }
        peerConnectionClient.setAudioEnabled(enabled: !isMuted)
    }

    // MARK: Helpers

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

    private func failCall(error: Error) {
        Logger.error("\(TAG) call failed with error: \(error)")
        Logger.error("TODO: show some UI for \(#function)")
    }

    private func terminateCall() {
//        lockManager.updatePhoneState(LockManager.PhoneState.PROCESSING);
//        NotificationBarManager.setCallEnded(this);
//
//        incomingRinger.stop();
//        outgoingRinger.stop();
//        outgoingRinger.playDisconnected();
//
//        if (peerConnection != null) {
//            peerConnection.dispose();
//            peerConnection = null;
//        }
//
//        if (eglBase != null && localRenderer != null && remoteRenderer != null) {
//            localRenderer.release();
//            remoteRenderer.release();
//            eglBase.release();
//        }
//
//        shutdownAudio();
//
//        this.callState         = CallState.STATE_IDLE;
//        this.recipient         = null;
//        this.callId            = null;
//        this.audioEnabled      = false;
//        this.videoEnabled      = false;
//        this.pendingIceUpdates = null;
//        lockManager.updatePhoneState(LockManager.PhoneState.IDLE);
        peerConnectionClient?.terminate()
        peerConnectionClient = nil
        call = nil
        thread = nil
        pendingIceUpdateMessages = nil
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
        switch(newState) {
        case .connected, .completed:
            handleIceConnected()
        case .failed:
            handleRemoteHangup()
        default:
            Logger.debug("\(TAG) ignoring change IceConnectionState:\(newState.rawValue)")
        }
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

        guard let peerConnectionClient = self.peerConnectionClient else {
            Logger.error("\(TAG) surprised to find no peerConnectionCLient in \(#function)")
            return
        }

        peerConnectionClient.dataChannel = dataChannel
    }

}

fileprivate extension UInt64 {
    static func ows_random() -> UInt64 {
        var random : UInt64 = 0
        arc4random_buf(&random, MemoryLayout.size(ofValue: random))
        return random
    }
}
