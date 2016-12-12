//  Created by Michael Kirk on 12/4/16.
//  Copyright © 2016 Open Whisper Systems. All rights reserved.

import Foundation

@objc(OWSWebRTCCallMessageHandler)
class WebRTCCallMessageHandler: NSObject, OWSCallMessageHandler {

    // MARK - Properties

    let TAG = "[WebRTCCallMessageHandler]"

    // MARK: Dependencies

    let accountManager: AccountManager
    let contactsManager: OWSContactsManager
    let messageSender: MessageSender
    let callService: CallService

    // MARK: Initializers

    required init(accountManager: AccountManager, contactsManager: OWSContactsManager, messageSender: MessageSender, callService: CallService) {
        self.accountManager = accountManager
        self.contactsManager = contactsManager
        self.messageSender = messageSender
        self.callService = callService
    }

    // MARK: - Call Handlers

    public func receivedOffer(_ offer: OWSSignalServiceProtosCallMessageOffer, from callerId: String) {
        Logger.verbose("\(TAG) handling offer from caller:\(callerId)")

        let thread = TSContactThread.getOrCreateThread(withContactId: callerId)
        CallService.signalingQueue.async {
            _ = self.callService.handleReceivedOffer(thread: thread, callId: offer.id, sessionDescription: offer.sessionDescription)
        }
    }

    public func receivedAnswer(_ answer: OWSSignalServiceProtosCallMessageAnswer, from callerId: String) {
        Logger.verbose("\(TAG) handling answer from caller:\(callerId)")

        let thread = TSContactThread.getOrCreateThread(withContactId: callerId)
        CallService.signalingQueue.async {
            self.callService.handleReceivedAnswer(thread: thread, callId: answer.id, sessionDescription: answer.sessionDescription)
        }
    }

    public func receivedIceUpdate(_ iceUpdate: OWSSignalServiceProtosCallMessageIceUpdate, from callerId: String) {
        Logger.verbose("\(TAG) handling iceUpdates from caller:\(callerId)")

        let thread = TSContactThread.getOrCreateThread(withContactId: callerId)

        // Discrepency between our protobuf's sdpMlineIndex, which is unsigned, 
        // while the RTC iOS API requires a signed int.
        let lineIndex = Int32(iceUpdate.sdpMlineIndex)

        CallService.signalingQueue.async {
            self.callService.handleRemoteAddedIceCandidate(thread: thread, callId: iceUpdate.id, sdp: iceUpdate.sdp, lineIndex: lineIndex, mid: iceUpdate.sdpMid)
        }
    }

    public func receivedHangup(_ hangup: OWSSignalServiceProtosCallMessageHangup, from callerId: String) {
        Logger.verbose("\(TAG) handling 'hangup' from caller:\(callerId)")
        Logger.error("TODO")
    }

    public func receivedBusy(_ busy: OWSSignalServiceProtosCallMessageBusy, from callerId: String) {
        Logger.verbose("\(TAG) handling 'busy' from caller:\(callerId)")
        Logger.error("TODO")
    }

}
