//  Created by Michael Kirk on 12/7/16.
//  Copyright © 2016 Open Whisper Systems. All rights reserved.

import Foundation

class SignalCall {
    var state: CallState
    let signalingId: UInt64

    init(signalingId: UInt64, state: CallState) {
        self.signalingId = signalingId
        self.state = state
    }    
}
