//  Created by Michael Kirk on 12/7/16.
//  Copyright © 2016 Open Whisper Systems. All rights reserved.

import Foundation

enum CallState: String {
    case idle
    case dialing
    case answering
    case remoteRinging
    case localRinging
    case connected
    case localHangup
    case remoteHangup
}

/**
 * Data model representing a WebRTC backed call, signaled through the TextSecure service.
 * This deprecates the existing Redphone call.
 */
@objc(OWSSignalCall)
class SignalCall: NSObject {

    let TAG = "[SignalCall]"

    var state: CallState {
        didSet {
            Logger.debug("\(TAG) state changed to:\(state)")
            stateDidChange?(state)
        }
    }

    let signalingId: UInt64
    let remotePhoneNumber: String
    let localId: UUID
    let hasVideo = false

    var stateDidChange: ((_ newState: CallState) -> Void)?

    init(signalingId: UInt64, state: CallState, remotePhoneNumber: String) {
        self.signalingId = signalingId
        self.state = state
        self.remotePhoneNumber = remotePhoneNumber
        self.localId = UUID()
    }

    // MARK: Equatable 
    
    static func ==(lhs: SignalCall, rhs: SignalCall) -> Bool {
        return lhs.localId == rhs.localId
    }

}
