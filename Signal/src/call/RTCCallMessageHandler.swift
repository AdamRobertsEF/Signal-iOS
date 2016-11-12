//  Created by Michael Kirk on 12/4/16.
//  Copyright © 2016 Open Whisper Systems. All rights reserved.

import Foundation

@objc(OWSWebRTCCallMessageHandler)
class WebRTCCallMessageHandler: NSObject, OWSCallMessageHandler {

    let TAG = "[WebRTCCallMessageHandler]"

    public func receivedCallOffer(_ callMessage: OWSSignalServiceProtosCallMessage) {
        Logger.info("\(TAG) Received call offer message: \(callMessage)")
    }

}
