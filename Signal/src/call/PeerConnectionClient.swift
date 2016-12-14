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

let AudioTrackType = kRTCMediaStreamTrackKindAudio
let VideoTrackType = kRTCMediaStreamTrackKindVideo

class PeerConnectionClient: NSObject, CallAudioManager {

    
    internal func configureAudioSession() {
        Logger.warn("TODO: \(#function)")
    }

    internal func stopAudio() {
        Logger.warn("TODO: \(#function)")
    }

    internal func startAudio() {
        guard let audioSender = self.audioSender else {
            Logger.error("\(TAG) ignoring \(#function) because audioSender was nil")
            return
        }

        Logger.warn("TODO: \(#function)")
    }

    let TAG = "[PeerConnectionClient]"
    enum Identifiers: String {
        case mediaStream = "ARDAMS",
             videoTrack = "ARDAMSv0",
             audioTrack = "ARDAMSa0",
             dataChannelSignalingLabel = "signaling"
    }

    // Connection

    private let peerConnection: RTCPeerConnection
    private let iceServers: [RTCIceServer]
    private let connectionConstraints: RTCMediaConstraints
    private let configuration: RTCConfiguration
    private let factory = RTCPeerConnectionFactory()

    // DataChannel

    // peerConnection expects to be the final owner of dataChannel. Otherwise, a crash when peerConnection deallocs
    // `dataChannel` is public because on incoming calls, we don't explicitly create the channel, rather `CallService`
    // assigns it when the channel is discovered due to the caller having created it.
    public var dataChannel: RTCDataChannel?

    // Audio

    // peerConnection expects to be the final owner of audioSender. Otherwise, a crash when peerConnection deallocs
    private weak var audioSender: RTCRtpSender?
    private var audioTrack: RTCAudioTrack?
    private var audioConstraints: RTCMediaConstraints

    // Video

    // peerConnection expects to be the final owner of videoSender. Otherwise, a crash when peerConnection deallocs
    private weak var videoSender: RTCRtpSender?
    private var videoTrack: RTCVideoTrack?
    private var cameraConstraints: RTCMediaConstraints

    init(iceServers: [RTCIceServer], peerConnectionDelegate: RTCPeerConnectionDelegate) {
        self.iceServers = iceServers

        configuration = RTCConfiguration()
        configuration.iceServers = iceServers
        configuration.bundlePolicy = .maxBundle
        configuration.rtcpMuxPolicy = .require

        let connectionConstraintsDict = ["DtlsSrtpKeyAgreement": "true"]
        connectionConstraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: connectionConstraintsDict)
        peerConnection = factory.peerConnection(with: configuration, constraints: connectionConstraints, delegate: peerConnectionDelegate)

        audioConstraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints:nil)
        cameraConstraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        super.init()

        createAudioSender()
        createVideoSender()
    }

    // MARK: - Media Streams

    public func createSignalingDataChannel(delegate: RTCDataChannelDelegate) {
        let dataChannel = peerConnection.dataChannel(forLabel: Identifiers.dataChannelSignalingLabel.rawValue,
                                                     configuration: RTCDataChannelConfiguration())
        dataChannel.delegate = delegate

        self.dataChannel = dataChannel
    }

    // MARK: Video

    fileprivate func createVideoSender() {
        guard !Platform.isSimulator else {
            Logger.warn("\(TAG) Refusing to create local video track on simulator.")
            return
        }

        let videoSource = factory.avFoundationVideoSource(with: cameraConstraints)
        let videoTrack = factory.videoTrack(with: videoSource, trackId: Identifiers.videoTrack.rawValue)
        self.videoTrack = videoTrack

        // Occasionally seeing this crash on the next line, after a *second* call:
//         -[__NSCFNumber length]: unrecognized selector sent to instance 0x1562c610
        // Seems like either videoKind or videoStreamId (both of which are Strings) is being GC'd prematurely. 
        // Not sure why, but assigned the value to local vars above in hopes of avoiding it.
//        let videoKind = kRTCMediaStreamTrackKindVideo

        let videoSender = peerConnection.sender(withKind: VideoTrackType, streamId: Identifiers.mediaStream.rawValue)
        videoSender.track = videoTrack
        self.videoSender = videoSender
    }

    // MARK: Audio

    fileprivate func createAudioSender() {
        let audioSource = factory.audioSource(with: self.audioConstraints)

        let audioTrack = factory.audioTrack(with: audioSource, trackId: Identifiers.audioTrack.rawValue)
        self.audioTrack = audioTrack

        let audioSender = peerConnection.sender(withKind: AudioTrackType, streamId: Identifiers.mediaStream.rawValue)
        audioSender.track = audioTrack
        self.audioSender = audioSender
    }

    public func setAudioEnabled(enabled: Bool) {
        guard let audioTrack = self.audioTrack else {
            let action = enabled ? "enable" : "disable"
            Logger.error("\(TAG) trying to \(action) audioTrack which doesn't exist.")
            return
        }

        audioTrack.isEnabled = enabled
    }

    // MARK: - Session negotiation

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

                let secureSessionDescription = self.hardenSecurity(sessionDescription: sdp!)

                fulfill(secureSessionDescription)
            })
        }
    }

    func setLocalSessionDescription(_ sessionDescription: RTCSessionDescription) -> Promise<Void> {
        return Promise { fulfill, reject in
            Logger.verbose("\(self.TAG) setting local session description: \(sessionDescription)")

            // TODO should we harden here too as a fallback in case of getting sent a degraded description?

            peerConnection.setLocalDescription(sessionDescription, completionHandler: { (error: Error?) in
                guard error == nil else {
                    reject(error!)
                    return
                }

                fulfill()
            })
        }
    }

    func negotiateSessionDescription(remoteDescription: RTCSessionDescription, constraints: RTCMediaConstraints) -> Promise<RTCSessionDescription> {
        return firstly {
            return self.setRemoteSessionDescription(remoteDescription)
        }.then {
            return self.negotiateAnswerSessionDescription(constraints: constraints)
        }
    }

    func setRemoteSessionDescription(_ sessionDescription: RTCSessionDescription) -> Promise<Void> {
        return Promise { fulfill, reject in
            Logger.verbose("\(self.TAG) setting remote description: \(sessionDescription)")
            peerConnection.setRemoteDescription(sessionDescription, completionHandler: { (error: Error?) in
                guard error == nil else {
                    reject(error!)
                    return
                }

                fulfill()
            })
        }
    }

    func negotiateAnswerSessionDescription(constraints: RTCMediaConstraints) -> Promise<RTCSessionDescription> {
        return Promise { fulfill, reject in
            Logger.verbose("\(self.TAG) negotating answer session.")

            peerConnection.answer(for: constraints, completionHandler: { (sessionDescription: RTCSessionDescription?, error: Error?) in
                guard error == nil else {
                    reject(error!)
                    return
                }

                guard sessionDescription != nil else {
                    Logger.error("\(self.TAG) unexpected empty session description, even though no error was reported.")
                    let error = OWSErrorMakeUnableToProcessServerResponseError()
                    reject(error)
                    return
                }

                let secureSessionDescription = self.hardenSecurity(sessionDescription: sessionDescription!)

                self.setLocalSessionDescription(secureSessionDescription).then {
                    fulfill(secureSessionDescription)
                }.catch { error in
                    reject(error)
                }
            })
        }
    }

    func addIceCandidate(_ candidate: RTCIceCandidate) {
        Logger.debug("\(TAG) adding candidate")
        self.peerConnection.add(candidate)
    }

    /**
     * Set some more secure parameters for the session description
     */
    func hardenSecurity(sessionDescription: RTCSessionDescription) -> RTCSessionDescription {
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
//        Some notes on preventing crashes while disposing of peerConnection
//        from: https://groups.google.com/forum/#!searchin/discuss-webrtc/objc$20crash$20dealloc%7Csort:relevance/discuss-webrtc/7D-vk5yLjn8/rBW2D6EW4GYJ
//        The sequence to make it work appears to be
//
//        [capturer stop]; // I had to add this as a method to RTCVideoCapturer
//        [localRenderer stop];
//        [remoteRenderer stop];
//        [peerConnection close];

        // audioTrack is a strong property because we need access to it to mute/unmute, but I was seeing it 
        // become nil when it was only a weak property. So we retain it and manually nil the reference here, because
        // we are likely to crash if we retain any peer connection properties when the peerconnection is released
        audioTrack = nil
        videoTrack = nil
        dataChannel = nil

        peerConnection.close()
    }

    // MARK: Data Channel

    func sendDataChannelMessage(data: Data) -> Bool {
        guard let dataChannel = self.dataChannel else {
            Logger.error("\(TAG) in \(#function) ignoring sending \(data) for nil dataChannel")
            return false
        }

        let buffer = RTCDataBuffer(data: data, isBinary: false)
        return dataChannel.sendData(buffer)
    }
}
