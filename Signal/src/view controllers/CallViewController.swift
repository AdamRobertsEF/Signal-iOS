//  Created by Michael Kirk on 11/10/16.
//  Copyright © 2016 Open Whisper Systems. All rights reserved.

import Foundation
import WebRTC
import PromiseKit

@objc(OWSCallViewController)
class CallViewController : UIViewController {

    enum CallDirection {
        case unspecified, outgoing, incoming;
    }

    let TAG = "[CallViewController]"

    // Dependencies

    let callService: CallService
    let contactsManager: OWSContactsManager

    // MARK: Properties
    
    var peerConnectionClient: PeerConnectionClient?
    var callDirection: CallDirection = .unspecified
    var thread: TSContactThread!
    var call: SignalCall!

    @IBOutlet weak var contactNameLabel: UILabel!
    @IBOutlet weak var contactAvatarView: AvatarImageView!
    @IBOutlet weak var callStatusLabel: UILabel!

    @IBOutlet weak var muteButton: UIButton!
    @IBOutlet weak var speakerPhoneButton: UIButton!

    // MARK: Initializers

    required init?(coder aDecoder: NSCoder) {
        contactsManager = Environment.getCurrent().contactsManager
        callService = Environment.getCurrent().callService
        super.init(coder: aDecoder)
    }

    required init() {
        contactsManager = Environment.getCurrent().contactsManager
        callService = Environment.getCurrent().callService
        super.init(nibName: nil, bundle: nil)
    }

    override func viewDidLoad() {

        guard thread != nil else {
            Logger.error("\(TAG) tried to show call call without specifying thread.")
            showCallFailed(error: OWSErrorMakeAssertionError())
            return
        }

        contactNameLabel.text = contactsManager.displayName(forPhoneIdentifier: thread.contactIdentifier());
        contactAvatarView.image = OWSAvatarBuilder.buildImage(for: thread, contactsManager: contactsManager)

        switch(callDirection) {
        case .unspecified:
            Logger.error("\(TAG) must set call direction before call starts.")
            showCallFailed(error: OWSErrorMakeAssertionError())
        case .outgoing:
            self.call = callService.handleOutgoingCall(thread: thread)
        case .incoming:
            Logger.error("\(TAG) handling Incoming call")
            // No-op, since call service is already set up at this point, the result of which was presenting this viewController.
        }

        call.stateDidChange = updateCallStatus
        updateCallStatus(call.state)

    }

    // objc accessible way to set our swift enum.
    func setOutgoingCallDirection() {
        callDirection = .outgoing
    }

    // objc accessible way to set our swift enum.
    func setIncomingCallDirection() {
        callDirection = .incoming
    }

    func showCallFailed(error: Error) {
        // TODO Show something in UI.
        Logger.error("\(TAG) call failed with error: \(error)")
    }

    func updateCallStatus(_ newState: CallState) {
        let textForState = { ()-> String in
            switch(newState) {
            case .idle, .remoteHangup, .localHangup:
                return NSLocalizedString("IN_CALL_TERMINATED", comment: "Call setup status label")
            case .dialing:
                return NSLocalizedString("IN_CALL_CONNECTING", comment: "Call setup status label")
            case .remoteRinging, .localRinging:
                return NSLocalizedString("IN_CALL_RINGING", comment: "Call setup status label")
            case .answering:
                return NSLocalizedString("IN_CALL_SECURING", comment: "Call setup status label")
            case .connected:
                return NSLocalizedString("IN_CALL_TALKING", comment: "Call setup status label")
            }
        }()

        Logger.info("\(TAG) new call status: \(newState) with text: \(textForState)")
        DispatchQueue.main.async {
            self.callStatusLabel.text = textForState
        }
    }

    @IBAction func didPressHangup(sender: UIButton) {
        Logger.debug("\(TAG) called \(#function)")
        if call != nil {
            CallService.signalingQueue.async {
                callService.handleLocalHungupCall(call!)
            }
        }

        self.dismiss(animated: true)
    }

    @IBAction func didPressMute(sender: UIButton) {
        Logger.debug("\(TAG) called \(#function)")
        sender.isSelected = !sender.isSelected
        CallService.signalingQueue.async {
            self.callService.handleToggledMute(isMuted: sender.isSelected)
        }
    }

    @IBAction func didPressSpeakerphone(sender: UIButton) {
        Logger.debug("\(TAG) called \(#function)")
        Logger.error("TODO \(#function)")
//        callService.handleLocalSpeakerPhone(isSpeakerphone: true)
    }
}
