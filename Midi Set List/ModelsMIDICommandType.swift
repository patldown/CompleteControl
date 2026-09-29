//
//  MIDICommandType.swift
//  Midi Set List
//
//  Created by Patrick Downey on 9/25/26.
//

import Foundation

enum MIDICommandType: String, Codable, CaseIterable {
    case programChange = "Program Change"
    case controlChange = "Control Change"
    case bankSelectMSB = "Bank Select MSB"
    case bankSelectLSB = "Bank Select LSB"
    case oscMessage = "OSC Message"

    var description: String { rawValue }

    var shortCode: String {
        switch self {
        case .programChange:  return "PC"
        case .controlChange:  return "CC"
        case .bankSelectMSB:  return "Bank MSB"
        case .bankSelectLSB:  return "Bank LSB"
        case .oscMessage:     return "OSC"
        }
    }

    /// Returns true if this command type requires two values (e.g. CC number + value)
    var requiresTwoValues: Bool {
        switch self {
        case .controlChange:                                    return true
        case .programChange, .bankSelectMSB, .bankSelectLSB,
             .oscMessage:                                       return false
        }
    }

    var isMIDI: Bool { self != .oscMessage }

    /// MIDI CC number for bank select commands
    var ccNumber: Int? {
        switch self {
        case .bankSelectMSB:                                    return 0
        case .bankSelectLSB:                                    return 32
        case .programChange, .controlChange, .oscMessage:      return nil
        }
    }
}
