//  Created by Michael Kirk on 11/10/16.
//  Copyright © 2016 Open Whisper Systems. All rights reserved.

import Foundation
import WebRTC

@objc(OWSCallViewController)
class CallViewController : UIViewController {

    enum CallDirection {
        case unspecified, outgoing, incoming;
    }

    let TAG = "[CallViewController]"

    // Dependencies
    let accountManager: AccountManager
    let messageSender: MessageSender
    let contactsManager: OWSContactsManager

    // MARK: Properties

    var callService: CallService!
    var peerConnectionClient: PeerConnectionClient?
    var callDirection: CallDirection = .unspecified
    var thread: TSContactThread!
    @IBOutlet weak var contactName: UILabel!

    // MARK: Initializers

    required init?(coder aDecoder: NSCoder) {
        accountManager = Environment.getCurrent().accountManager
        messageSender = Environment.getCurrent().messageSender
        contactsManager = Environment.getCurrent().contactsManager

        super.init(coder: aDecoder)
    }

    required init() {
        accountManager = Environment.getCurrent().accountManager
        messageSender = Environment.getCurrent().messageSender
        contactsManager = Environment.getCurrent().contactsManager

        super.init(nibName: nil, bundle: nil)
    }

    override func viewDidLoad() {

        guard (thread != nil) else {
            Logger.error("\(TAG) tried to call without specifying thread.")
            showCallFailed(error: OWSErrorMakeAssertionError())
            return
        }

        switch(callDirection) {
        case .unspecified:
            Logger.error("\(TAG) must set call direction before call starts.")
            showCallFailed(error: OWSErrorMakeAssertionError())
        case .outgoing:
            self.contactName.text = self.contactsManager.displayName(forPhoneIdentifier: thread.contactIdentifier());
            callService = CallService(accountManager: self.accountManager, messageSender: self.messageSender)
            _ = callService.handleOutgoingCall(thread: thread)
        case .incoming:
            guard callService != nil else {
                Logger.error("\(TAG) expected call service to already be set for incoming call")
                showCallFailed(error: OWSErrorMakeAssertionError())
                return
            }
        }
    }

    /**
     * objc accessible way to set our swift enum.
     */
    func setOutgoingCallDirection() {
        callDirection = .outgoing
    }

    func showCallFailed(error: Error) {
        // TODO Show something in UI.
        Logger.error("\(TAG) call failed with error: \(error)")
    }

    func updateCallStatus(_ newState: CallState) {
        // TODO update UI
        Logger.info("\(TAG) new call status: \(newState)")
    }

    @IBAction func didPressHangup() {
        callService.terminateCall()
        self.dismiss(animated: true)
    }
}
