//
//  ActivityLog.swift
//  Midi Set List
//
//  Shared ring-buffer log for MIDI, OSC, and system events.
//  Thread-safe: log() can be called from any thread.
//

import Foundation
import Observation

@Observable
final class ActivityLog {

    struct Entry: Identifiable {
        let id = UUID()
        let date: Date
        let direction: Direction
        let proto: Proto
        let message: String
        let midiPayload: MIDIPayload?

        init(date: Date, direction: Direction, proto: Proto, message: String,
             midiPayload: MIDIPayload? = nil) {
            self.date = date
            self.direction = direction
            self.proto = proto
            self.message = message
            self.midiPayload = midiPayload
        }

        enum Direction {
            case out       // message sent
            case `in`      // message received
            case system    // connection/status event
            case error     // failure
        }

        enum Proto {
            case midi
            case osc
            case system
        }

        /// Structured data for incoming MIDI messages that can be saved as macros.
        struct MIDIPayload {
            enum Kind { case programChange, controlChange, bankSelectMSB, bankSelectLSB }
            let kind: Kind
            let channel: Int    // 1-16
            let value1: Int     // program / CC number / bank value
            let value2: Int?    // CC value (nil for PC/bank)
        }
    }

    private(set) var entries: [Entry] = []
    private let cap = 500

    func log(_ message: String,
             direction: Entry.Direction = .system,
             proto: Entry.Proto = .system,
             midiPayload: Entry.MIDIPayload? = nil) {
        let entry = Entry(date: Date(), direction: direction, proto: proto, message: message,
                          midiPayload: midiPayload)
        if Thread.isMainThread {
            append(entry)
        } else {
            DispatchQueue.main.async { [weak self] in self?.append(entry) }
        }
    }

    func clear() {
        entries.removeAll()
    }

    private func append(_ entry: Entry) {
        entries.insert(entry, at: 0)
        if entries.count > cap { entries.removeLast() }
    }
}
