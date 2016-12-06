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

    // MARK: - Properties

    // MARK: Dependencies
    let accountManager: AccountManager
    let messageSender: MessageSender
    var peerConnectionClient: PeerConnectionClient?

    // MARK: Class
    let TAG = "[CallService]"
    static let DataChannelLabel = "signaling"
    static let fallbackIceServer = RTCIceServer(urlStrings: ["stun:stun1.l.google.com:19302"])

    // MARK: Ivars
    var dataChannel: RTCDataChannel?
    let thread: TSContactThread

    required init(thread aThread: TSContactThread, accountManager anAccountManager: AccountManager, messageSender aMessageSender: MessageSender) {
        thread = aThread
        accountManager = anAccountManager
        messageSender = aMessageSender
    }

    // MARK: - Call Lifecyle

    func placeOutgoingCall(stateChangeHandler: (CallState) -> ()) -> Promise<Void> {
        let call = Call(uniqueId: UInt64.ows_random())
        stateChangeHandler(call.state);

        return getIceServers().then { iceServers -> Promise<RTCSessionDescription> in
            Logger.debug("\(self.TAG) got ice servers:\(iceServers)")
            self.peerConnectionClient = PeerConnectionClient(iceServers: iceServers)

            // TODO Would dataChannel be better created within PeerConnectionClient class? Seems like it's only created on outgoing.
            self.dataChannel = self.peerConnectionClient!.createDataChannel(label: CallService.DataChannelLabel, delegate: self)

            return self.peerConnectionClient!.createOffer()
        }.then { sessionDescription -> Promise<Void> in
            return self.peerConnectionClient!.setLocalSessionDescription(sessionDescription).then {
                let offerMessage = OWSCallOfferMessage(callId: call.uniqueId, sessionDescription: sessionDescription.sdp)
                let callMessage = OWSOutgoingCallMessage(offerMessage: offerMessage, thread: self.thread)
                return self.sendMessage(callMessage)
            }
        }.then {
            Logger.debug("\(self.TAG) sent CallOffer message in \(self.thread)")
        }.catch { error in
            Logger.error("\(self.TAG) placing call failed with error: \(error)")
        }
    }

    func handleReceivedOffer(callId: UInt64, sessionDescription sdpString: String) -> Promise<Void> {
        Logger.verbose("\(TAG) receivedCallOffer")

        // TODO call kit inegration + ios9 adapter.
//        guard (callState == CallState.STATE_IDLE) else {
//            Logger.error("\(TAG) expected call state to be idle, but found: \(callState.rawValue)")
//            // TODO throw new IllegalStateException("Incoming on non-idle");
//        }
//
//        final String offer = intent.getStringExtra(EXTRA_REMOTE_DESCRIPTION);
//
//        this.callState = CallState.STATE_ANSWERING;
//        this.callId    = intent.getLongExtra(EXTRA_CALL_ID, -1);
//        this.recipient = getRemoteRecipient(intent);
//
//        initializeVideo();
//        retrieveTurnServers().addListener(new SuccessOnlyListener<List<PeerConnection.IceServer>>(this.callState, this.callId) {
//        public void onSuccessContinue(List<PeerConnection.IceServer> result) {
//            try {
//            WebRtcCallService.this.peerConnection = new PeerConnectionWrapper(WebRtcCallService.this, peerConnectionFactory, WebRtcCallService.this, localRenderer, result);
//            WebRtcCallService.this.peerConnection.setRemoteDescription(new SessionDescription(SessionDescription.Type.OFFER, offer));
//            WebRtcCallService.this.lockManager.updatePhoneState(LockManager.PhoneState.PROCESSING);
//
//            SessionDescription sdp = WebRtcCallService.this.peerConnection.createAnswer(new MediaConstraints());
//            Log.w(TAG, "Answer SDP: " + sdp.description);
//            WebRtcCallService.this.peerConnection.setLocalDescription(sdp);
//
//            ListenableFutureTask<Boolean> listenableFutureTask = sendMessage(recipient, SignalServiceCallMessage.forAnswer(new AnswerMessage(WebRtcCallService.this.callId, sdp.description)));
//
//            listenableFutureTask.addListener(new FailureListener<Boolean>(WebRtcCallService.this.callState, WebRtcCallService.this.callId) {
//            @Override
//            public void onFailureContinue(Throwable error) {
//            Log.w(TAG, error);
//            terminate();
//            }
//            });
//            } catch (PeerConnectionException e) {
//            Log.w(TAG, e);
//            terminate();
//            }

        let call = Call(uniqueId: callId)
        return getIceServers().then { iceServers -> Promise<RTCSessionDescription> in
            self.peerConnectionClient = PeerConnectionClient(iceServers: iceServers)

            let sessionDescription = RTCSessionDescription(type: .offer, sdp: sdpString)
            let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)

            // Find a sessionDescription compatible with my constraints and the remote sessionDescription
            return self.peerConnectionClient!.negotiateSessionDescription(remoteDescription: sessionDescription, constraints: constraints)
        }.then { (negotiatedSessionDescription: RTCSessionDescription) in
            // TODO? WebRtcCallService.this.lockManager.updatePhoneState(LockManager.PhoneState.PROCESSING);
            Logger.debug("\(self.TAG) set the remote description")

            let answerMessage = OWSCallAnswerMessage(callId: call.uniqueId, sessionDescription: negotiatedSessionDescription.sdp)
            let callMessage = OWSOutgoingCallMessage(answerMessage: answerMessage, thread: self.thread)

            return self.sendMessage(callMessage)
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

    fileprivate func sendMessage(_ message: OWSOutgoingCallMessage) -> Promise<Void> {
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
