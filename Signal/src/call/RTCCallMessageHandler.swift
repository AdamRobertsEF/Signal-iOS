//  Created by Michael Kirk on 12/4/16.
//  Copyright © 2016 Open Whisper Systems. All rights reserved.

import Foundation

@objc(OWSWebRTCCallMessageHandler)
class WebRTCCallMessageHandler: NSObject, OWSCallMessageHandler {

    // MARK - Properties

    // MARK: Dependencies

    let accountManager: AccountManager
    let contactsManager: OWSContactsManager
    let messageSender: MessageSender

    // MARK: Class

    let TAG = "[WebRTCCallMessageHandler]"

    // MARK: Initializers

    required init(accountManager anAccountManager: AccountManager, contactsManager aContactsManager: OWSContactsManager, messageSender aMessageSender: MessageSender) {
        accountManager = anAccountManager
        contactsManager = aContactsManager
        messageSender = aMessageSender
    }

    // MARK: - Call Handlers

    public func receivedOffer(_ offer: OWSSignalServiceProtosCallMessageOffer, from callerId: String) {
        Logger.verbose("\(TAG) handling offer from caller:\(callerId)")

        let thread = TSContactThread.getOrCreateThread(withContactId: callerId)
        let callService = CallService(thread: thread, accountManager: accountManager, messageSender: messageSender)
        callService.handleReceivedOffer(callId: offer.id, sessionDescription: offer.sessionDescription).then {
            Logger.info("received call offer")
        }
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
