//
//  MIDIRemote.swift
//  Midi Set List
//
//  MIDI receive: which channel the app listens on, and which incoming messages
//  recall snapshots or move through a set list. Works with any MIDI controller —
//  USB, network or Bluetooth (e.g. a Bluetooth foot controller).
//

import Foundation
import Combine

// MARK: - Incoming message

/// One incoming channel message the app can react to.
struct MIDIRemoteMessage: Equatable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case controlChange = "CC"
        case programChange = "PC"
        case note          = "Note"

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .controlChange: return "Control Change (CC)"
            case .programChange: return "Program Change (PC)"
            case .note:          return "Note On"
            }
        }
    }

    let kind: Kind
    let channel: Int    // 1–16
    let number: Int     // CC number / program number / note number
    let value: Int      // CC value / note velocity (127 for program changes)

    var description: String {
        switch kind {
        case .controlChange: return "CC \(number) = \(value) [Ch \(channel)]"
        case .programChange: return "PC \(number) [Ch \(channel)]"
        case .note:          return "Note \(number) vel \(value) [Ch \(channel)]"
        }
    }
}

// MARK: - Binding

/// A message type + number, e.g. "CC 103". The channel comes from the receive channel.
struct MIDIRemoteBinding: Codable, Equatable {
    var kind: MIDIRemoteMessage.Kind
    var number: Int

    var label: String { "\(kind.rawValue) \(number)" }

    func matches(_ message: MIDIRemoteMessage) -> Bool {
        message.kind == kind && message.number == number
    }
}

// MARK: - Actions

enum MIDIRemoteAction: Equatable {
    case snapshot(Int)          // 0-based snapshot index
    case previousSong
    case nextSong
    case previousSnapshot
    case nextSnapshot

    var displayName: String {
        switch self {
        case .snapshot(let i):   return "Snapshot \(i + 1)"
        case .previousSong:      return "Previous Song"
        case .nextSong:          return "Next Song"
        case .previousSnapshot:  return "Previous Snapshot"
        case .nextSnapshot:      return "Next Snapshot"
        }
    }
}

/// What a "Learn" button is waiting to assign.
enum MIDIRemoteLearnTarget: String, CaseIterable, Identifiable {
    case snapshots
    case previousSong, nextSong, previousSnapshot, nextSnapshot

    var id: String { rawValue }

    var title: String {
        switch self {
        case .snapshots:         return "Snapshot 1"
        case .previousSong:      return "Previous Song"
        case .nextSong:          return "Next Song"
        case .previousSnapshot:  return "Previous Snapshot"
        case .nextSnapshot:      return "Next Snapshot"
        }
    }

    static let navigation: [MIDIRemoteLearnTarget] = [.previousSong, .nextSong, .previousSnapshot, .nextSnapshot]
}

// MARK: - Settings

/// App-wide MIDI receive settings, stored in UserDefaults.
final class MIDIRemoteSettings: ObservableObject {
    static let shared = MIDIRemoteSettings()

    private let defaults = UserDefaults.standard
    private enum Key {
        static let enabled          = "midiRemote.enabled"
        static let receiveChannel   = "midiRemote.receiveChannel"
        static let snapshotKind     = "midiRemote.snapshotKind"
        static let snapshotBase     = "midiRemote.snapshotBase"
        static let ignoreZero       = "midiRemote.ignoreZeroValues"
        static let navigation       = "midiRemote.navigation"
    }

    /// Master switch for reacting to incoming MIDI.
    @Published var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: Key.enabled) }
    }

    /// 0 = Omni (all channels), otherwise 1–16.
    @Published var receiveChannel: Int {
        didSet { defaults.set(receiveChannel, forKey: Key.receiveChannel) }
    }

    /// Snapshot N is recalled by `snapshotKind` number `snapshotBase + N - 1`,
    /// so the 12 snapshots sit on 12 consecutive numbers (e.g. CC 20–31).
    @Published var snapshotKind: MIDIRemoteMessage.Kind {
        didSet { defaults.set(snapshotKind.rawValue, forKey: Key.snapshotKind) }
    }

    @Published var snapshotBase: Int {
        didSet { defaults.set(snapshotBase, forKey: Key.snapshotBase) }
    }

    /// Momentary footswitches send 127 on press and 0 on release — ignore the release.
    @Published var ignoreZeroValues: Bool {
        didSet { defaults.set(ignoreZeroValues, forKey: Key.ignoreZero) }
    }

    /// Previous/next song and snapshot bindings, keyed by MIDIRemoteLearnTarget raw value.
    @Published private(set) var navigation: [String: MIDIRemoteBinding] {
        didSet {
            if let data = try? JSONEncoder().encode(navigation) {
                defaults.set(data, forKey: Key.navigation)
            }
        }
    }

    static let defaultNavigation: [String: MIDIRemoteBinding] = [
        MIDIRemoteLearnTarget.previousSong.rawValue:     .init(kind: .controlChange, number: 102),
        MIDIRemoteLearnTarget.nextSong.rawValue:         .init(kind: .controlChange, number: 103),
        MIDIRemoteLearnTarget.previousSnapshot.rawValue: .init(kind: .controlChange, number: 104),
        MIDIRemoteLearnTarget.nextSnapshot.rawValue:     .init(kind: .controlChange, number: 105),
    ]

    private init() {
        let defaults = UserDefaults.standard
        isEnabled        = defaults.object(forKey: Key.enabled) as? Bool ?? true
        receiveChannel   = defaults.object(forKey: Key.receiveChannel) as? Int ?? 0
        snapshotKind     = MIDIRemoteMessage.Kind(rawValue: defaults.string(forKey: Key.snapshotKind) ?? "") ?? .controlChange
        snapshotBase     = defaults.object(forKey: Key.snapshotBase) as? Int ?? 20
        ignoreZeroValues = defaults.object(forKey: Key.ignoreZero) as? Bool ?? true
        if let data = defaults.data(forKey: Key.navigation),
           let saved = try? JSONDecoder().decode([String: MIDIRemoteBinding].self, from: data) {
            navigation = saved
        } else {
            navigation = Self.defaultNavigation
        }
    }

    // MARK: Channel

    var receiveChannelLabel: String {
        receiveChannel == 0 ? "Omni" : "Ch \(receiveChannel)"
    }

    func accepts(channel: Int) -> Bool {
        receiveChannel == 0 || receiveChannel == channel
    }

    // MARK: Snapshot mapping

    /// Highest usable base so all 12 snapshots stay within 0–127.
    static let maxSnapshotBase = 127 - (Song.maxSnapshots - 1)

    /// The binding that recalls snapshot `index` (0-based), or nil if out of range.
    func snapshotBinding(for index: Int) -> MIDIRemoteBinding? {
        let number = snapshotBase + index
        guard (0...127).contains(number) else { return nil }
        return MIDIRemoteBinding(kind: snapshotKind, number: number)
    }

    var snapshotRangeLabel: String {
        let last = min(127, snapshotBase + Song.maxSnapshots - 1)
        return "\(snapshotKind.rawValue) \(snapshotBase)–\(last)"
    }

    // MARK: Navigation mapping

    func binding(for target: MIDIRemoteLearnTarget) -> MIDIRemoteBinding? {
        navigation[target.rawValue]
    }

    func setBinding(_ binding: MIDIRemoteBinding?, for target: MIDIRemoteLearnTarget) {
        if target == .snapshots {
            guard let binding else { return }
            snapshotKind = binding.kind
            snapshotBase = min(binding.number, Self.maxSnapshotBase)
            return
        }
        navigation[target.rawValue] = binding
    }

    /// Navigation bindings that collide with one of the snapshot numbers.
    var overlappingTargets: [MIDIRemoteLearnTarget] {
        MIDIRemoteLearnTarget.navigation.filter { target in
            guard let b = binding(for: target), b.kind == snapshotKind else { return false }
            return (snapshotBase..<(snapshotBase + Song.maxSnapshots)).contains(b.number)
        }
    }

    // MARK: Resolution

    /// Maps an incoming message to an action. Ignores the receive channel —
    /// callers check `accepts(channel:)` first so they can report filtered messages.
    func action(for message: MIDIRemoteMessage) -> MIDIRemoteAction? {
        if message.kind == .controlChange && ignoreZeroValues && message.value == 0 { return nil }

        // Navigation wins over a snapshot on the same number
        let navActions: [(MIDIRemoteLearnTarget, MIDIRemoteAction)] = [
            (.previousSong, .previousSong), (.nextSong, .nextSong),
            (.previousSnapshot, .previousSnapshot), (.nextSnapshot, .nextSnapshot),
        ]
        for (target, action) in navActions where binding(for: target)?.matches(message) == true {
            return action
        }

        if message.kind == snapshotKind {
            let index = message.number - snapshotBase
            if (0..<Song.maxSnapshots).contains(index) { return .snapshot(index) }
        }
        return nil
    }
}
