//  Created by Michael Kirk on 11/29/16.
//  Copyright © 2016 Open Whisper Systems. All rights reserved.

import Foundation
import PromiseKit
import WebRTC

// TODO move this somewhere else
struct Platform {
    static let isSimulator: Bool = {
        var isSim = false
        #if arch(i386) || arch(x86_64)
            isSim = true
        #endif
        return isSim
    }()
}


// TODO move this somewhere else
// TODO do we still need this?
protocol DeviceFinderAdaptee {
    var frontFacingCamera: AVCaptureDevice? { get }
}

class DeviceFinderAdapter {

    let adaptee: DeviceFinderAdaptee

    var frontFacingCamera: AVCaptureDevice? {
        get { return adaptee.frontFacingCamera }
    }

    init() {
        if #available(iOS 10.0, *) {
            adaptee = DeviceFinderiOS10()
        } else {
            adaptee = DeviceFinderiOS8()
        }
    }
}

class DeviceFinderiOS8: DeviceFinderAdaptee {
    var frontFacingCamera: AVCaptureDevice? {
        get {
            // FIXME TODO make something work for iOS<10
            return nil;
        }
    }
}

@available(iOS 10.0, *)
class DeviceFinderiOS10: DeviceFinderAdaptee {
    var frontFacingCamera: AVCaptureDevice? {
        get {
            return AVCaptureDeviceDiscoverySession(deviceTypes: [AVCaptureDeviceType.builtInWideAngleCamera], mediaType: AVMediaTypeVideo, position: AVCaptureDevicePosition.front).devices.first
        }
    }
}

class PeerConnectionClient: NSObject, RTCPeerConnectionDelegate {

    let TAG = "[PeerConnectionClient]"
    enum Identifiers: String {
        case mediaStream = "ARDAMS",
             videoTrack = "ARDAMSv0",
             audioTrack = "ARDAMSa0"
    }

    // Connection properties

    let peerConnection: RTCPeerConnection
    let iceServers: [RTCIceServer]
    let connectionConstraints: RTCMediaConstraints
    let configuration = RTCConfiguration()
    let factory = RTCPeerConnectionFactory()
    let mediaStream: RTCMediaStream

    // Audio properties

    var audioSender: RTCRtpSender?
    var audioConstraints: RTCMediaConstraints

    // Video properties

    var videoSender: RTCRtpSender?
    var cameraConstraints: RTCMediaConstraints

    init(iceServers someIceServers: [RTCIceServer]) {
        iceServers = someIceServers

        configuration.iceServers = iceServers
        configuration.bundlePolicy = .maxBundle
        configuration.rtcpMuxPolicy = .require

        let connectionConstraintsDict = ["DtlsSrtpKeyAgreement": "true"]
        connectionConstraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints:connectionConstraintsDict)
        peerConnection = factory.peerConnection(with: configuration, constraints: connectionConstraints, delegate: nil)

        audioConstraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints:nil)
        cameraConstraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)


        // TODO is this next line necessary? Does the stream need to be explicitly created?
        // It doesn't seem to be in the example.
        mediaStream = factory.mediaStream(withStreamId: Identifiers.mediaStream.rawValue)
        super.init()

        peerConnection.delegate = self
        audioSender = createAudioSender()        
        videoSender = createVideoSender()
    }

    // MARK: - Media Streams

    public func createDataChannel(label: String, delegate: RTCDataChannelDelegate) -> RTCDataChannel {
        let dataChannel = peerConnection.dataChannel(forLabel: label,
                                                     configuration: RTCDataChannelConfiguration())
        dataChannel.delegate = delegate
        return dataChannel
    }

    fileprivate func createVideoSender() -> RTCRtpSender? {
        guard let videoTrack = createLocalVideoTrack() else {
            Logger.warn("\(TAG) unable to create local video track")
            return nil
        }

        let sender = peerConnection.sender(withKind: kRTCMediaStreamTrackKindVideo, streamId: mediaStream.streamId)
        sender.track = videoTrack
        return sender
    }

    fileprivate func createLocalVideoTrack() -> RTCVideoTrack? {
        guard !Platform.isSimulator else {
            Logger.warn("\(TAG) Refusing to create local video track on simulator.")
            return nil
        }

        let videoSource = factory.avFoundationVideoSource(with: cameraConstraints)
        return factory.videoTrack(with: videoSource, trackId: Identifiers.videoTrack.rawValue)
    }

    fileprivate func createAudioSender() -> RTCRtpSender?  {
        guard let audioTrack = createLocalAudioTrack() else {
            Logger.warn("\(TAG) unable to create local audio track")
            return nil
        }
        let sender = peerConnection.sender(withKind: kRTCMediaStreamTrackKindAudio, streamId: mediaStream.streamId)
        sender.track = audioTrack
        return sender
    }

    fileprivate func createLocalAudioTrack() -> RTCAudioTrack? {
        let audioSource = factory.audioSource(with: self.audioConstraints)
        return factory.audioTrack(with: audioSource, trackId: Identifiers.audioTrack.rawValue)
    }

    // MARK - Session negotiation

    var defaultOfferConstraints: RTCMediaConstraints {
        get {
            let mandatoryConstraints = [
                "OfferToReceiveAudio": "true",
                "OfferToReceiveVideo" : "true"
            ]
            return RTCMediaConstraints(mandatoryConstraints:mandatoryConstraints, optionalConstraints:nil)
        }
    }

    func createOffer() -> Promise<RTCSessionDescription> {
        return Promise { fulfill, reject in
            peerConnection.offer(for: self.defaultOfferConstraints, completionHandler: { (sdp: RTCSessionDescription?, error: Error?) in
                guard error == nil else {
                    reject(error!)
                    return
                }

                guard sdp != nil else {
                    Logger.error("\(self.TAG) No session description was obtained, even though there was no error reported.")
                    let error = OWSErrorMakeUnableToProcessServerResponseError()
                    reject(error)
                    return
                }

                let secureSessionDescription = self.makeSecure(sessionDescription: sdp!)

                fulfill(secureSessionDescription)
            })
        }
    }

    func setLocalSessionDescription(_ sessionDescription: RTCSessionDescription) -> Promise<Void> {
        return Promise { fulfill, reject in
            Logger.debug("\(self.TAG) setting local session description: \(sessionDescription)")
            peerConnection.setLocalDescription(sessionDescription, completionHandler: { (error) in
                guard error == nil else {
                    reject(error!)
                    return
                }

                fulfill()
            })
        }
    }

    /**
     * Set some more secure parameters for the session description
     */
    func makeSecure(sessionDescription: RTCSessionDescription) -> RTCSessionDescription {
        let description = sessionDescription.sdp

        // Enforce Constant bit rate.
        // TODO is there a better way to configure this?
        let withoutCBR = description.replacingOccurrences(of: "(a=fmtp:111 ((?!cbr=).)*)\r?\n", with: "$1;cbr=1\r\n")

        // Strip plaintext audio-level details
        // https://tools.ietf.org/html/rfc6464
        //
        // TODO is there a better way to configure this?
        let withoutCBRNorAudioLevel = withoutCBR.replacingOccurrences(of: ".+urn:ietf:params:rtp-hdrext:ssrc-audio-level.*\r?\n", with: "")


        return RTCSessionDescription.init(type: sessionDescription.type, sdp: withoutCBRNorAudioLevel)
    }

    func terminate() {
        peerConnection.close()
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
