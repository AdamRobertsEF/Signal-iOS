//  Created by Michael Kirk on 12/13/16.
//  Copyright © 2016 Open Whisper Systems. All rights reserved.

import Foundation
import PromiseKit
import CallKit

protocol CallUIAdaptee {
    func startOutgoingCall(_ call: SignalCall)
    func reportIncomingCall(_ call: SignalCall, audioManager: CallAudioManager) -> Promise<Void>
    func endCall(_ call: SignalCall)
}

/**
 * Manage call related UI in a pre-CallKit world.
 */
class CallUIiOS8Adaptee: CallUIAdaptee {

    let TAG = "[CallUIiOS8Adaptee]"

    func startOutgoingCall(_ call: SignalCall) {
        Logger.error("\(TAG) TODO \(#function)")
    }

    func reportIncomingCall(_ call: SignalCall, audioManager: CallAudioManager) -> Promise<Void> {
        Logger.error("\(TAG) TODO \(#function)")
        return Promise { _ in
            // TODO
        }
    }

    func endCall(_ call: SignalCall) {
        Logger.error("\(TAG) TODO \(#function)")
    }

}

// This is duplicating CallKit reasons, but usable from pre iOS10.
// Are we using this?
enum OWSCallEndedReason {
    case failed // An error occurred while trying to service the call

    case remoteEnded // The remote party explicitly ended the call

    case unanswered // The call never started connecting and was never explicitly ended (e.g. outgoing/incoming call timeout)

    case answeredElsewhere // The call was answered on another device

    case declinedElsewhere // The call was declined on another device
}

@available(iOS 10.0, *)
class CallUICallKitAdaptee: CallUIAdaptee {

    let providerDelegate: ProviderDelegate
    let callManager: SpeakerboxCallManager

    init(callService: CallService) {
        callManager = SpeakerboxCallManager()
        providerDelegate = ProviderDelegate(callManager: callManager, callService: callService)
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

    func endCall(_ call: SignalCall) {

//        let cxReason = { (reason: OWSCallEndedReason) -> CXCallEndedReason in
//            switch owsReason {
//
//            case .failed:
//                return CXCallEndedReason.failed
//
//            case .remoteEnded:
//                return CXCallEndedReason.remoteEnded
//
//            case .unanswered:
//                return CXCallEndedReason.unanswered
//
//            case .answeredElsewhere:
//                return CXCallEndedReason.answeredElsewhere
//
//            case .declinedElsewhere:
//                return CXCallEndedReason.declinedElsewhere
//            }
//        }(owsReason)

        callManager.end(call: call)
    }
}

class CallUIAdapter {

    let TAG = "[CallUIAdapter]"
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

    func startOutgoingCall(_ call: SignalCall, thread: TSContactThread) {
        adaptee.startOutgoingCall(call)
    }

    func endCall(_ call: SignalCall) {
        adaptee.endCall(call)
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
