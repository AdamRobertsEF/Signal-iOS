//  Created by Michael Kirk on 11/11/16.
//  Copyright © 2016 Open Whisper Systems. All rights reserved.

import Foundation
import PromiseKit
import WebRTC

enum CallState {
    case Idle
    case Dialing
    case Answering
    case RemoteRinging
    case LocalRinging
    case Connected
}

class Call {
    var state: CallState
    var uniqueId: UInt64

    init(uniqueId: UInt64) {
        self.state = CallState.Idle
        self.uniqueId = uniqueId
    }
}

class CallService: NSObject, RTCDataChannelDelegate {

    let TAG = "[CallService]"
    let contact: Contact
    let accountManager: AccountManager
    let messageSender: MessageSender
    var peerConnectionClient: PeerConnectionClient?
    static let fallbackIceServer = RTCIceServer(urlStrings: ["stun:stun1.l.google.com:19302"])
    var dataChannel: RTCDataChannel?

    static let DataChannelLabel = "signaling"

    required init(contact aContact: Contact, accountManager anAccountManager: AccountManager, messageSender aMessageSender: MessageSender) {
        contact = aContact
        accountManager = anAccountManager
        messageSender = aMessageSender
    }

    // Mark Call Lifecyle
    func placeOutgoingCall(stateChangeHandler: (CallState) -> ()) -> Promise<PeerConnectionClient> {
        let call = Call(uniqueId: UInt64.ows_random())
        stateChangeHandler(call.state);

        return getIceServers().then { iceServers -> Promise<RTCSessionDescription> in
            Logger.debug("\(self.TAG) got ice servers:\(iceServers)")
            let peerConnectionClient = PeerConnectionClient(iceServers: iceServers)

            // TODO Would dataChannel be better created within PeerConnectionClient class? Seems like it's only created on outgoing.
            self.dataChannel = peerConnectionClient.createDataChannel(label: CallService.DataChannelLabel, delegate: self)
            self.peerConnectionClient = peerConnectionClient

            return peerConnectionClient.createOffer()
        }.then { sessionDescription -> Promise<Void> in
            return self.peerConnectionClient!.setLocalSessionDescription(sessionDescription).then {
                let offerMessage = OWSCallOfferMessage(callId: call.uniqueId, sessionDescription: sessionDescription.sdp)
                let callMessage = OWSOutgoingCallMessage(offerMessage: offerMessage)
                return self.sendMessage(callMessage, to: self.contact)
            }
        }.then {
            return self.peerConnectionClient!
        }
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

    fileprivate func sendMessage(_ message: OWSOutgoingCallMessage, to contact: Contact) -> Promise<Void> {
        return Promise { fulfill, reject in
            self.messageSender.send(message, success: fulfill, failure: reject)
        }
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
            // TODO can't this throw an exception? Is it just being lost in the Objc->Swift?
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
}

fileprivate extension UInt64 {
    static func ows_random() -> UInt64 {
        var random : UInt64 = 0
        arc4random_buf(&random, MemoryLayout.size(ofValue: random))
        return random
    }
}
