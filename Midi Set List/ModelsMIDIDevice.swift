//
//  MIDIDevice.swift
//  Midi Set List
//
//  Created by Patrick Downey on 9/25/26.
//

import Foundation
import CoreMIDI

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
