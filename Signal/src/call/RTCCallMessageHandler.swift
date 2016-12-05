//  Created by Michael Kirk on 12/4/16.
//  Copyright © 2016 Open Whisper Systems. All rights reserved.

import Foundation

@objc(OWSWebRTCCallMessageHandler)
class WebRTCCallMessageHandler: NSObject, OWSCallMessageHandler {

    let TAG = "[WebRTCCallMessageHandler]"

    let accountManager: AccountManager
    let contactsManager: OWSContactsManager
    let messageSender: MessageSender

    required init(accountManager anAccountManager: AccountManager, contactsManager aContactsManager: OWSContactsManager, messageSender aMessageSender: MessageSender) {
        accountManager = anAccountManager
        contactsManager = aContactsManager
        messageSender = aMessageSender
    }

    public func receivedOffer(_ offer: OWSSignalServiceProtosCallMessageOffer, from callerId: String) {
        Logger.verbose("\(TAG) handling offer from caller:\(callerId)")

        // FIXME TODO unknown caller
        let contact = contactsManager.contact(forPhoneIdentifier: callerId)!


        let callService = CallService(contact: contact, accountManager: accountManager, messageSender: messageSender)
        callService.handleReceivedOffer(callId: offer.id, contact: contact, sessionDescription: offer.sessionDescription)
    }

    public func receivedAnswer(_ answer: OWSSignalServiceProtosCallMessageAnswer, from callerId: String) {
        Logger.verbose("\(TAG) handling answer from caller:\(callerId)")
    }

    public func receivedIceUpdates(_ iceUpdates: [OWSSignalServiceProtosCallMessageIceUpdate], from callerId: String) {
        Logger.verbose("\(TAG) handling iceUpdates from caller:\(callerId)")
    }

    public func receivedHangup(_ hangup: OWSSignalServiceProtosCallMessageHangup, from callerId: String) {
        Logger.verbose("\(TAG) handling hangup from caller:\(callerId)")
    }
}
