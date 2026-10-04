//
//  MIDITypes.swift
//  Midi Set List
//

import CoreMIDI
import Foundation

// MARK: - MIDICommandType

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

// MARK: - MIDIDevice

/// Represents a discovered MIDI device
struct MIDIDevice: Identifiable, Hashable {
    let id: MIDIUniqueID
    let name: String
    let displayName: String
    let manufacturer: String?
    let isOnline: Bool
    let endpoint: MIDIEndpointRef

    init(
        id: MIDIUniqueID,
        name: String,
        displayName: String? = nil,
        manufacturer: String? = nil,
        isOnline: Bool = true,
        endpoint: MIDIEndpointRef
    ) {
        self.id = id
        self.name = name
        self.displayName = displayName ?? name
        self.manufacturer = manufacturer
        self.isOnline = isOnline
        self.endpoint = endpoint
    }

    var fullDescription: String {
        if let manufacturer = manufacturer {
            return "\(displayName) (\(manufacturer))"
        }
        return displayName
    }
}
