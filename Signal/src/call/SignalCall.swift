//  Created by Michael Kirk on 12/7/16.
//  Copyright © 2016 Open Whisper Systems. All rights reserved.

import Foundation

class SignalCall {
    var state: CallState
    let signalingId: UInt64
    var remotePhoneNumber: String

    init(signalingId: UInt64, state: CallState, remotePhoneNumber: String) {
        self.signalingId = signalingId
        self.state = state
        self.remotePhoneNumber = remotePhoneNumber
    }    
}
