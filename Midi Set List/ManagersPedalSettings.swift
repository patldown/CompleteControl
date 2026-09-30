//
//  PedalSettings.swift
//  Midi Set List
//
//  Bluetooth page-turner pedals (AirTurn, PageFlip, Donner, M-VAVE…) connect as a
//  keyboard and send keys such as arrows or Page Up / Page Down. This maps those keys
//  to Perform actions. Works out of the box with the common pedal modes, and any key
//  can be learned from Settings.
//

import Combine
import UIKit

enum PedalAction: String, CaseIterable, Identifiable {
    case pageDown, pageUp
    case nextSong, previousSong
    case nextSnapshot, previousSnapshot
    case toggleAutoScroll, toggleFullView

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pageDown: "Scroll Down a Page"
        case .pageUp: "Scroll Up a Page"
        case .nextSong: "Next Song"
        case .previousSong: "Previous Song"
        case .nextSnapshot: "Next Snapshot"
        case .previousSnapshot: "Previous Snapshot"
        case .toggleAutoScroll: "Start / Pause Auto-Scroll"
        case .toggleFullView: "Full View On / Off"
        }
    }

    var systemImage: String {
        switch self {
        case .pageDown: "arrow.down.to.line"
        case .pageUp: "arrow.up.to.line"
        case .nextSong: "forward.fill"
        case .previousSong: "backward.fill"
        case .nextSnapshot: "chevron.right.square"
        case .previousSnapshot: "chevron.left.square"
        case .toggleAutoScroll: "playpause.fill"
        case .toggleFullView: "arrow.up.left.and.arrow.down.right"
        }
    }
}

/// A hardware key, identified by its HID usage code
struct PedalKey: Hashable, Codable {
    var code: Int

    init(code: Int) { self.code = code }
    init(_ usage: UIKeyboardHIDUsage) { code = usage.rawValue }

    var name: String {
        guard let usage = UIKeyboardHIDUsage(rawValue: code) else { return "Key \(code)" }
        switch usage {
        case .keyboardDownArrow: "↓ Down Arrow"
        case .keyboardUpArrow: "↑ Up Arrow"
        case .keyboardLeftArrow: "← Left Arrow"
        case .keyboardRightArrow: "→ Right Arrow"
        case .keyboardPageDown: "Page Down"
        case .keyboardPageUp: "Page Up"
        case .keyboardSpacebar: "Space"
        case .keyboardReturnOrEnter, .keypadEnter: "Return"
        case .keyboardTab: "Tab"
        case .keyboardHome: "Home"
        case .keyboardEnd: "End"
        case .keyboardEscape: "Escape"
        case .keyboardDeleteOrBackspace: "Delete"
        default: Self.characterName(code) ?? "Key \(code)"
        }
    }

    /// Letters and digits by their character
    private static func characterName(_ code: Int) -> String? {
        let a = UIKeyboardHIDUsage.keyboardA.rawValue, z = UIKeyboardHIDUsage.keyboardZ.rawValue
        if (a...z).contains(code), let scalar = UnicodeScalar(UInt32(65 + code - a)) {
            return String(Character(scalar))
        }
        let one = UIKeyboardHIDUsage.keyboard1.rawValue, nine = UIKeyboardHIDUsage.keyboard9.rawValue
        if (one...nine).contains(code) { return "\(code - one + 1)" }
        if code == UIKeyboardHIDUsage.keyboard0.rawValue { return "0" }
        return nil
    }
}

final class PedalSettings: ObservableObject {
    static let shared = PedalSettings()

    private enum Key {
        static let enabled = "pedalsEnabled"
        static let bindings = "pedalBindings"
    }

    /// Covers the usual page-turner modes: up/down arrows, page up/down, left/right arrows
    static let defaultBindings: [PedalKey: PedalAction] = [
        PedalKey(.keyboardDownArrow): .pageDown,
        PedalKey(.keyboardPageDown): .pageDown,
        PedalKey(.keyboardRightArrow): .pageDown,
        PedalKey(.keyboardUpArrow): .pageUp,
        PedalKey(.keyboardPageUp): .pageUp,
        PedalKey(.keyboardLeftArrow): .pageUp,
    ]

    @Published var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Key.enabled) }
    }
    @Published private(set) var bindings: [PedalKey: PedalAction] {
        didSet { saveBindings() }
    }
    /// Set while Settings is waiting for a pedal press to assign
    @Published var learning: PedalAction?

    private init() {
        isEnabled = UserDefaults.standard.object(forKey: Key.enabled) as? Bool ?? true
        if let data = UserDefaults.standard.data(forKey: Key.bindings),
           let stored = try? JSONDecoder().decode([Int: String].self, from: data) {
            bindings = stored.reduce(into: [:]) { result, pair in
                if let action = PedalAction(rawValue: pair.value) { result[PedalKey(code: pair.key)] = action }
            }
        } else {
            bindings = Self.defaultBindings
        }
    }

    func action(for key: PedalKey) -> PedalAction? {
        isEnabled ? bindings[key] : nil
    }

    func keys(for action: PedalAction) -> [PedalKey] {
        bindings.filter { $0.value == action }.map(\.key).sorted { $0.code < $1.code }
    }

    /// Assigns a key to an action. A key does one thing, so it's taken off any other action.
    func assign(_ key: PedalKey, to action: PedalAction) {
        bindings[key] = action
    }

    func remove(_ key: PedalKey) {
        bindings[key] = nil
    }

    func resetToDefaults() {
        bindings = Self.defaultBindings
    }

    private func saveBindings() {
        let raw = bindings.reduce(into: [Int: String]()) { $0[$1.key.code] = $1.value.rawValue }
        if let data = try? JSONEncoder().encode(raw) {
            UserDefaults.standard.set(data, forKey: Key.bindings)
        }
    }
}
