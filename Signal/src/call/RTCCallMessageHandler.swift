//  Created by Michael Kirk on 12/4/16.
//  Copyright © 2016 Open Whisper Systems. All rights reserved.

import Foundation

@objc(OWSWebRTCCallMessageHandler)
class WebRTCCallMessageHandler: NSObject, OWSCallMessageHandler {

    let TAG = "[WebRTCCallMessageHandler]"

    public func receivedOffer(_ offer: OWSSignalServiceProtosCallMessageOffer) {
        Logger.verbose("\(TAG) handling offer")
    }

    public func receivedAnswer(_ answer: OWSSignalServiceProtosCallMessageAnswer) {
        Logger.verbose("\(TAG) handling answer")
    }

    public func receivedIceUpdates(_ iceUpdates: [OWSSignalServiceProtosCallMessageIceUpdate]) {
        Logger.verbose("\(TAG) handling iceUpdates")
    }

    public func receivedHangup(_ hangup: OWSSignalServiceProtosCallMessageHangup) {
        Logger.verbose("\(TAG) handling hangup")
    }
}
