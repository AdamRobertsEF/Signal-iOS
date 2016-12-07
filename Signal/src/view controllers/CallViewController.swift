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
    var callPromise: Promise<Void>?

    @IBOutlet weak var contactName: UILabel!

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
            self.callPromise = callService.handleOutgoingCall(thread: thread)
        case .incoming:
            Logger.error("\(TAG) TODO incoming call handling not implemented")
            // TODO for ios8 maybe? do we need our own UI for callkit?
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
