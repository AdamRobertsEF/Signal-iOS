/*
	Copyright (C) 2016 Apple Inc. All Rights Reserved.
	See LICENSE.txt for this sample’s licensing information
	
	Abstract:
	CallKit provider delegate class, which conforms to CXProviderDelegate protocol
*/

import Foundation
import UIKit
import CallKit
import AVFoundation

@available(iOS 10.0, *)
final class ProviderDelegate: NSObject, CXProviderDelegate {

    let TAG = "[ProviderDelegate]"
    let callManager: SpeakerboxCallManager
    let callService: CallService
    private let provider: CXProvider

    // FIXME - I might be thinking about this the wrong way.
    // It seems like the provider delegate wants to stop/start the audio recording
    // process, but the ProviderDelegate is an app singleton
    // and the audio recording process is currently controlled (I think) by
    // the PeerConnectionClient instance, which is one per call (NOT a singleton).
    // It seems like a mess to reconcile this difference in cardinality. But... here we are.
    var audioManager: CallAudioManager?


    init(callManager: SpeakerboxCallManager, callService: CallService) {
        self.callManager = callManager
        self.callService = callService
        provider = CXProvider(configuration: type(of: self).providerConfiguration)

        super.init()

        provider.setDelegate(self, queue: nil)
    }

    /// The app's provider configuration, representing its CallKit capabilities
    static var providerConfiguration: CXProviderConfiguration {
        let localizedName = NSLocalizedString("APPLICATION_NAME", comment: "Name of application")
        let providerConfiguration = CXProviderConfiguration(localizedName: localizedName)

        providerConfiguration.supportsVideo = true

        providerConfiguration.maximumCallsPerCallGroup = 1

        providerConfiguration.supportedHandleTypes = [.phoneNumber]

        if let iconMaskImage = UIImage(named: "IconMask") {
            providerConfiguration.iconTemplateImageData = UIImagePNGRepresentation(iconMaskImage)
        }

        providerConfiguration.ringtoneSound = "Ringtone.caf"

        return providerConfiguration
    }

    // MARK: Incoming Calls

    /// Use CXProvider to report the incoming call to the system
    func reportIncomingCall(_ call: SignalCall, completion: ((NSError?) -> Void)? = nil) {
        // Construct a CXCallUpdate describing the incoming call, including the caller.
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .phoneNumber, value: call.remotePhoneNumber)
        update.hasVideo = call.hasVideo

        // Report the incoming call to the system
        provider.reportNewIncomingCall(with: call.localId, update: update) { error in
            /*
                Only add incoming call to the app's list of calls if the call was allowed (i.e. there was no error)
                since calls may be "denied" for various legitimate reasons. See CXErrorCodeIncomingCallError.
             */
            if error == nil {
                self.callManager.addCall(call)
            }
            
            completion?(error as? NSError)
        }
    }

    // MARK: CXProviderDelegate

    func providerDidReset(_ provider: CXProvider) {
        Logger.debug("Provider did reset")

        stopAudio()

        /*
            End any ongoing calls if the provider resets, and remove them from the app's list of calls,
            since they are no longer valid.
         */
        for call in callManager.calls {
            // FIXME TODO forward to CallService.
//            call.endSpeakerboxCall()
        }

        // Remove all calls from the app's list of calls.
        callManager.removeAllCalls()
    }

    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        // Create & configure an instance of SpeakerboxCall, the app's model class representing the new outgoing call.
        let call = SpeakerboxCall(uuid: action.callUUID, isOutgoing: true)
        call.handle = action.handle.value

        /*
            Configure the audio session, but do not start call audio here, since it must be done once
            the audio session has been activated by the system after having its priority elevated.
         */
        configureAudioSession()

        /*
            Set callback blocks for significant events in the call's lifecycle, so that the CXProvider may be updated
            to reflect the updated state.
         */
        call.hasStartedConnectingDidChange = { [weak self] in
            self?.provider.reportOutgoingCall(with: call.uuid, startedConnectingAt: call.connectingDate)
        }
        call.hasConnectedDidChange = { [weak self] in
            self?.provider.reportOutgoingCall(with: call.uuid, connectedAt: call.connectDate)
        }

        // TODO FIXME
        // Trigger the call to be started via the underlying network service.
//        call.startSpeakerboxCall { success in
//            if success {
//                // Signal to the system that the action has been successfully performed.
//                action.fulfill()
//
//                // Add the new outgoing call to the app's list of calls.
//                self.callManager.addCall(call)
//            } else {
//                // Signal to the system that the action was unable to be performed.
//                action.fail()
//            }
//        }
    }

    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        // Retrieve the SpeakerboxCall instance corresponding to the action's call UUID
        guard let call = callManager.callWithLocalId(action.callUUID) else {
            action.fail()
            return
        }

//        /*
//            Configure the audio session, but do not start call audio here, since it must be done once
//            the audio session has been activated by the system after having its priority elevated.
//         */
//        configureAudioSession()
//
//        // Trigger the call to be answered via the underlying network service.
//        call.answerSpeakerboxCall()

        callService.handleAnswerCall(call)

        // Signal to the system that the action has been successfully performed.
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        Logger.debug("Received \(#function)")
        guard let call = callManager.callWithLocalId(action.callUUID) else {
            action.fail()
            return
        }

//        // Stop call audio whenever ending the call.
//        stopAudio()
//        // Trigger the call to be ended via the underlying network service.
//        call.endSpeakerboxCall()
        callService.handleLocalHungupCall(call)

        // Signal to the system that the action has been successfully performed.
        action.fulfill()

        // Remove the ended call from the app's list of calls.
        callManager.removeCall(call)
    }

    func provider(_ provider: CXProvider, perform action: CXSetHeldCallAction) {
        Logger.debug("Received \(#function)")
        guard let call = callManager.callWithLocalId(action.callUUID) else {
            action.fail()
            return
        }

        // TODO FIXME
//        // Update the SpeakerboxCall's underlying hold state.
//        call.isOnHold = action.isOnHold
//
//        // Stop or start audio in response to holding or unholding the call.
//        if call.isOnHold {
//            stopAudio()
//        } else {
//            startAudio()
//        }

        // Signal to the system that the action has been successfully performed.
        action.fulfill()
    }

    func provider(_ provider: CXProvider, timedOutPerforming action: CXAction) {
        Logger.debug("Timed out \(#function)")

        // React to the action timeout if necessary, such as showing an error UI.
    }

    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        Logger.debug("Received \(#function)")

        startAudio()
    }

    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        Logger.debug("Received \(#function)")

        /*
             Restart any non-call related audio now that the app's audio session has been
             de-activated after having its priority restored to normal.
         */
    }

    // MARK: - Audio

    func startAudio() {
        guard let audioManager = self.audioManager else {
            Logger.error("\(TAG) audioManager was unexpectedly nil while tryign to start audio")
            return
        }

        audioManager.startAudio()
    }

    func stopAudio() {
        guard let audioManager = self.audioManager else {
            Logger.error("\(TAG) audioManager was unexpectedly nil while tryign to stop audio")
            return
        }

        audioManager.stopAudio()
    }

    func configureAudioSession() {
        guard let audioManager = self.audioManager else {
            Logger.error("\(TAG) audioManager was unexpectedly nil while trying to: \(#function)")
            return
        }

        audioManager.configureAudioSession()
    }
}
