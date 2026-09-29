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
struct MIDIRemoteBinding: Codable, Hashable {
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
enum MIDIRemoteLearnTarget: Hashable, Identifiable {
    /// Where the counted-up snapshot numbers start (Snapshot 1)
    case snapshots
    /// One snapshot's own trigger, replacing its counted-up number (0-based)
    case snapshot(Int)
    case previousSong, nextSong, previousSnapshot, nextSnapshot

    var id: String { key }

    /// Storage key for navigation bindings
    var key: String {
        switch self {
        case .snapshots:           return "snapshots"
        case .snapshot(let i):     return "snapshot\(i)"
        case .previousSong:        return "previousSong"
        case .nextSong:            return "nextSong"
        case .previousSnapshot:    return "previousSnapshot"
        case .nextSnapshot:        return "nextSnapshot"
        }
    }

    var title: String {
        switch self {
        case .snapshots:           return "Snapshot Numbering"
        case .snapshot(let i):     return "Snapshot \(i + 1)"
        case .previousSong:        return "Previous Song"
        case .nextSong:            return "Next Song"
        case .previousSnapshot:    return "Previous Snapshot"
        case .nextSnapshot:        return "Next Snapshot"
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
        static let overrides        = "midiRemote.snapshotOverrides"
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

    /// Previous/next song and snapshot bindings, keyed by MIDIRemoteLearnTarget key.
    @Published private(set) var navigation: [String: MIDIRemoteBinding] {
        didSet {
            if let data = try? JSONEncoder().encode(navigation) {
                defaults.set(data, forKey: Key.navigation)
            }
        }
    }

    /// Snapshots given their own trigger instead of the counted-up number,
    /// keyed by 0-based snapshot index as a string.
    @Published private(set) var snapshotOverrides: [String: MIDIRemoteBinding] {
        didSet {
            if let data = try? JSONEncoder().encode(snapshotOverrides) {
                defaults.set(data, forKey: Key.overrides)
            }
        }
    }

    static let defaultNavigation: [String: MIDIRemoteBinding] = [
        MIDIRemoteLearnTarget.previousSong.key:     .init(kind: .controlChange, number: 102),
        MIDIRemoteLearnTarget.nextSong.key:         .init(kind: .controlChange, number: 103),
        MIDIRemoteLearnTarget.previousSnapshot.key: .init(kind: .controlChange, number: 104),
        MIDIRemoteLearnTarget.nextSnapshot.key:     .init(kind: .controlChange, number: 105),
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
        if let data = defaults.data(forKey: Key.overrides),
           let saved = try? JSONDecoder().decode([String: MIDIRemoteBinding].self, from: data) {
            snapshotOverrides = saved
        } else {
            snapshotOverrides = [:]
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

    /// The binding that recalls snapshot `index` (0-based): its own trigger if it
    /// has one, otherwise the counted-up number. Nil if that falls outside 0–127.
    func snapshotBinding(for index: Int) -> MIDIRemoteBinding? {
        if let custom = snapshotOverrides[String(index)] { return custom }
        return countedBinding(for: index)
    }

    /// True when snapshot `index` has its own trigger rather than the counted-up number.
    func hasOverride(forSnapshot index: Int) -> Bool {
        snapshotOverrides[String(index)] != nil
    }

    var hasAnyOverride: Bool { !snapshotOverrides.isEmpty }

    /// Puts every snapshot back on the counted-up numbers.
    func clearSnapshotOverrides() {
        snapshotOverrides = [:]
    }

    private func countedBinding(for index: Int) -> MIDIRemoteBinding? {
        let number = snapshotBase + index
        guard (0...127).contains(number) else { return nil }
        return MIDIRemoteBinding(kind: snapshotKind, number: number)
    }

    var snapshotRangeLabel: String {
        let last = min(127, snapshotBase + Song.maxSnapshots - 1)
        let range = "\(snapshotKind.rawValue) \(snapshotBase)–\(last)"
        return hasAnyOverride ? "\(range) (some custom)" : range
    }

    // MARK: Navigation mapping

    func binding(for target: MIDIRemoteLearnTarget) -> MIDIRemoteBinding? {
        if case .snapshot(let index) = target { return snapshotBinding(for: index) }
        return navigation[target.key]
    }

    /// Assigns a trigger. For `.snapshot`, nil puts it back on its counted-up number.
    func setBinding(_ binding: MIDIRemoteBinding?, for target: MIDIRemoteLearnTarget) {
        switch target {
        case .snapshots:
            guard let binding else { return }
            snapshotKind = binding.kind
            snapshotBase = min(binding.number, Self.maxSnapshotBase)
        case .snapshot(let index):
            // Learning the number it already counts to is the same as no override
            if let binding, binding == countedBinding(for: index) {
                snapshotOverrides[String(index)] = nil
            } else {
                snapshotOverrides[String(index)] = binding
            }
        default:
            navigation[target.key] = binding
        }
    }

    /// Pairs of triggers sharing one message, in priority order: the first of
    /// each pair is the one that responds. Navigation beats a snapshot's own
    /// trigger, which beats a counted-up number.
    var conflicts: [(winner: MIDIRemoteLearnTarget, loser: MIDIRemoteLearnTarget, binding: MIDIRemoteBinding)] {
        var ranked: [(MIDIRemoteLearnTarget, MIDIRemoteBinding)] = []
        for target in MIDIRemoteLearnTarget.navigation {
            if let b = navigation[target.key] { ranked.append((target, b)) }
        }
        let indices = Array(0..<Song.maxSnapshots)
        for i in indices where hasOverride(forSnapshot: i) {
            if let b = snapshotBinding(for: i) { ranked.append((.snapshot(i), b)) }
        }
        for i in indices where !hasOverride(forSnapshot: i) {
            if let b = countedBinding(for: i) { ranked.append((.snapshot(i), b)) }
        }
        var owner: [MIDIRemoteBinding: MIDIRemoteLearnTarget] = [:]
        var result: [(winner: MIDIRemoteLearnTarget, loser: MIDIRemoteLearnTarget, binding: MIDIRemoteBinding)] = []
        for (target, b) in ranked {
            if let winner = owner[b] {
                result.append((winner, target, b))
            } else {
                owner[b] = target
            }
        }
        return result
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
        for (target, action) in navActions where navigation[target.key]?.matches(message) == true {
            return action
        }

        // Then a snapshot's own trigger…
        for index in 0..<Song.maxSnapshots where snapshotOverrides[String(index)]?.matches(message) == true {
            return .snapshot(index)
        }

        // …then the counted-up numbers, skipping snapshots that have their own
        if message.kind == snapshotKind {
            let index = message.number - snapshotBase
            if (0..<Song.maxSnapshots).contains(index) && !hasOverride(forSnapshot: index) {
                return .snapshot(index)
            }
        }
        return nil
    }
}
