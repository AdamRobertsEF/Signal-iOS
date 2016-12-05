//  Created by Michael Kirk on 11/10/16.
//  Copyright © 2016 Open Whisper Systems. All rights reserved.

import Foundation
import WebRTC

@objc(OWSCallViewController)
class CallViewController : UIViewController {

    let TAG = "[CallViewController]"
    let accountManager: AccountManager
    let messageSender: MessageSender
    var callService: CallService!
    var peerConnectionClient: PeerConnectionClient?

    var contact: Contact?
    @IBOutlet weak var contactName: UILabel!

    required init?(coder aDecoder: NSCoder) {
        accountManager = Environment.getCurrent().accountManager
        messageSender = Environment.getCurrent().messageSender
        super.init(coder: aDecoder)
    }

    override func viewDidLoad() {
        guard (contact != nil) else {
            Logger.error("\(TAG) tried to call without specifying contact.")
            return
        }

        self.contactName.text = self.contact!.fullName
        callService = CallService(contact: contact!, accountManager: self.accountManager, messageSender: self.messageSender)

        _ = callService.placeOutgoingCall(stateChangeHandler: { (newState: CallState) in
            self.updateCallStatus(newState)
        }).then { peerConnectionClient in
            self.peerConnectionClient = peerConnectionClient
        }
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
