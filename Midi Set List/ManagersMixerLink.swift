//
//  ManagersMixerLink.swift
//  Midi Set List
//
//  Links routing channels to channels on an OSC mixer (XR18, X32, …): a preamp gain knob
//  and a fader on each strip that send OSC, Auto Gain, and the mixer half of mix presets.
//
//  Addresses are templates with a channel token, filled in per channel:
//    {ch}        the channel's mixer number as is            → 1, 2, … 16
//    {ch:02}     zero-padded to 2 digits                     → 01, 02, … 16
//    {ch:03-1}   zero-padded to 3 digits, minus 1 (0-based)  → 000, 001, …
//  So the XR18's gain is /headamp/{ch:02}/gain and its fader /ch/{ch:02}/mix/fader.
//
//  Values go out as the 0…1 float these mixers use: gain linear across its dB range,
//  the fader on the Behringer X fader law (0.75 = 0 dB, 1 = +10 dB) or linear in dB.
//  Sending an address with no value asks Behringer mixers for the current value, which
//  comes back to the OSC connection and moves the knob/fader to match.
//

import Foundation
import Observation

// MARK: - Settings

/// How a fader's dB maps onto the 0…1 float sent
enum FaderLaw: String, Codable, CaseIterable, Identifiable {
    /// Behringer X32 / X Air: four linear segments, 0.75 = 0 dB, 1.0 = +10 dB, 0 = −∞
    case behringer
    /// Linear in dB across the range below
    case linear

    var id: String { rawValue }
    var displayName: String { self == .behringer ? "Behringer X (XR18, X32)" : "Linear dB" }
}

struct MixerLinkSettings: Codable, Equatable {
    var showGain = false
    var gainPath = "/headamp/{ch:02}/gain"
    var gainMinDB: Float = -12
    var gainMaxDB: Float = 60

    var showFader = false
    var faderPath = "/ch/{ch:02}/mix/fader"
    var faderLaw: FaderLaw = .behringer
    /// Only used by the linear law (the Behringer law is fixed at −∞…+10 dB)
    var faderMinDB: Float = -90
    var faderMaxDB: Float = 10

    /// Auto Gain listens for this long and sets the loudest part to `autoGainTargetDB`
    var autoGainSeconds: Double = 6
    var autoGainTargetDB: Float = -18

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = MixerLinkSettings()
        showGain = try c.decodeIfPresent(Bool.self, forKey: .showGain) ?? d.showGain
        gainPath = try c.decodeIfPresent(String.self, forKey: .gainPath) ?? d.gainPath
        gainMinDB = try c.decodeIfPresent(Float.self, forKey: .gainMinDB) ?? d.gainMinDB
        gainMaxDB = try c.decodeIfPresent(Float.self, forKey: .gainMaxDB) ?? d.gainMaxDB
        showFader = try c.decodeIfPresent(Bool.self, forKey: .showFader) ?? d.showFader
        faderPath = try c.decodeIfPresent(String.self, forKey: .faderPath) ?? d.faderPath
        faderLaw = (try? c.decodeIfPresent(FaderLaw.self, forKey: .faderLaw)) ?? d.faderLaw
        faderMinDB = try c.decodeIfPresent(Float.self, forKey: .faderMinDB) ?? d.faderMinDB
        faderMaxDB = try c.decodeIfPresent(Float.self, forKey: .faderMaxDB) ?? d.faderMaxDB
        autoGainSeconds = try c.decodeIfPresent(Double.self, forKey: .autoGainSeconds) ?? d.autoGainSeconds
        autoGainTargetDB = try c.decodeIfPresent(Float.self, forKey: .autoGainTargetDB) ?? d.autoGainTargetDB
    }

    /// Ready-made address sets
    struct Template: Identifiable {
        let name: String
        let gainPath: String
        let faderPath: String
        let law: FaderLaw
        var id: String { name }
    }

    static let templates: [Template] = [
        Template(name: "Behringer XR18 / X Air", gainPath: "/headamp/{ch:02}/gain",
                 faderPath: "/ch/{ch:02}/mix/fader", law: .behringer),
        Template(name: "Behringer X32 / M32 (local inputs)", gainPath: "/headamp/{ch:03-1}/gain",
                 faderPath: "/ch/{ch:02}/mix/fader", law: .behringer),
    ]
}

// MARK: - Address templates

enum OSCPathTemplate {
    /// Fills every {ch…} token with `channel` (1-based mixer channel)
    static func resolve(_ template: String, channel: Int) -> String {
        var out = ""
        var rest = Substring(template)
        while let open = rest.firstIndex(of: "{") {
            out += rest[..<open]
            guard let close = rest[open...].firstIndex(of: "}") else { out += rest[open...]; return out }
            let token = rest[rest.index(after: open)..<close]
            out += format(token, channel: channel) ?? "{\(token)}"
            rest = rest[rest.index(after: close)...]
        }
        return out + rest
    }

    /// "ch", "ch:02", "ch:03-1", "ch+16" → the formatted number; nil if not a channel token
    private static func format(_ token: Substring, channel: Int) -> String? {
        guard token.lowercased().hasPrefix("ch") else { return nil }
        var spec = token.dropFirst(2)
        var width = 0
        if spec.first == ":" {
            spec = spec.dropFirst()
            let digits = spec.prefix { $0.isNumber }
            width = Int(digits) ?? 0
            spec = spec.dropFirst(digits.count)
        }
        var offset = 0
        if let sign = spec.first, sign == "+" || sign == "-" {
            guard let n = Int(spec.dropFirst()) else { return nil }
            offset = sign == "+" ? n : -n
            spec = spec.dropFirst(spec.count)
        }
        guard spec.isEmpty else { return nil }
        let n = String(max(0, channel + offset))
        return width > n.count ? String(repeating: "0", count: width - n.count) + n : n
    }

    /// The channel number a concrete address was made from, if it fits the template
    static func channel(in address: String, template: String, candidates: [Int]) -> Int? {
        candidates.first { resolve(template, channel: $0) == address }
    }
}

// MARK: - Value laws

extension MixerLinkSettings {
    func gainFloat(_ db: Float) -> Float {
        let span = max(1, gainMaxDB - gainMinDB)
        return min(1, max(0, (db - gainMinDB) / span))
    }

    func gainDB(_ value: Float) -> Float {
        gainMinDB + min(1, max(0, value)) * (gainMaxDB - gainMinDB)
    }

    /// Lowest fader position, shown as −∞
    var faderFloorDB: Float { faderLaw == .behringer ? -90 : faderMinDB }
    var faderCeilingDB: Float { faderLaw == .behringer ? 10 : faderMaxDB }

    func faderFloat(_ db: Float) -> Float {
        switch faderLaw {
        case .behringer:
            if db <= -90 { return 0 }
            if db < -60 { return (db + 90) / 480 }
            if db < -30 { return (db + 70) / 160 }
            if db < -10 { return (db + 50) / 80 }
            return min(1, (db + 30) / 40)
        case .linear:
            let span = max(1, faderMaxDB - faderMinDB)
            return min(1, max(0, (db - faderMinDB) / span))
        }
    }

    func faderDB(_ value: Float) -> Float {
        let f = min(1, max(0, value))
        switch faderLaw {
        case .behringer:
            if f >= 0.5 { return f * 40 - 30 }
            if f >= 0.25 { return f * 80 - 50 }
            if f >= 0.0625 { return f * 160 - 70 }
            return f * 480 - 90
        case .linear:
            return faderMinDB + f * (faderMaxDB - faderMinDB)
        }
    }

    static func faderLabel(_ db: Float, floor: Float) -> String {
        db <= floor + 0.05 ? "−∞" : String(format: "%+.1f dB", db)
    }
}

// MARK: - Auto Gain Presets

struct AutoGainPreset: Identifiable {
    let name: String
    let targetDB: Float
    let description: String
    var id: String { name }
}

extension MixerLinkSettings {
    static let autoGainPresets: [AutoGainPreset] = [
        AutoGainPreset(name: "Vocals",      targetDB: -18, description: "Lead/backing vocals — headroom for dynamics and mix bus processing"),
        AutoGainPreset(name: "Instrument",  targetDB: -12, description: "Acoustic guitar, keys, horns — punchy but clean"),
        AutoGainPreset(name: "Percussion",  targetDB: -6,  description: "Kick, snare, loud sources — hot gain for transient punch"),
    ]
}

// MARK: - Link

@Observable
@MainActor
final class MixerLink {
    static let shared = MixerLink()

    var settings = MixerLinkSettings() {
        didSet { if settings != oldValue { saveSettings() } }
    }
    /// Last known mixer values per routing channel (sent by us or read back from the mixer)
    private(set) var gainDB: [UUID: Float] = [:]
    private(set) var faderDB: [UUID: Float] = [:]

    @ObservationIgnored weak var oscManager: OSCManager?
    @ObservationIgnored private let store = AudioRoutingStore.shared
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    private static let settingsKey = "mixerLink.settings"
    private static let valuesKey = "mixerLink.values"

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.settingsKey),
           let s = try? JSONDecoder().decode(MixerLinkSettings.self, from: data) {
            settings = s
        }
        if let data = UserDefaults.standard.data(forKey: Self.valuesKey),
           let v = try? JSONDecoder().decode(StoredValues.self, from: data) {
            gainDB = v.gain
            faderDB = v.fader
        }
    }

    var isConnected: Bool { !(oscManager?.connectedTargets.isEmpty ?? true) }

    /// 1-based mixer channel for a routing channel: its own setting, else its interface input
    func mixerChannel(for channel: AudioChannel) -> Int {
        channel.mixerChannel ?? channel.inputIndex + 1
    }

    func gainAddress(for channel: AudioChannel) -> String {
        OSCPathTemplate.resolve(settings.gainPath, channel: mixerChannel(for: channel))
    }

    func faderAddress(for channel: AudioChannel) -> String {
        OSCPathTemplate.resolve(settings.faderPath, channel: mixerChannel(for: channel))
    }

    // MARK: Sending

    func setGain(_ db: Float, for channel: AudioChannel) {
        let clamped = min(settings.gainMaxDB, max(settings.gainMinDB, db))
        gainDB[channel.id] = clamped
        oscManager?.send(address: gainAddress(for: channel), floatArg: Double(settings.gainFloat(clamped)))
        scheduleSave()
    }

    func setFader(_ db: Float, for channel: AudioChannel) {
        let clamped = min(settings.faderCeilingDB, max(settings.faderFloorDB, db))
        faderDB[channel.id] = clamped
        oscManager?.send(address: faderAddress(for: channel), floatArg: Double(settings.faderFloat(clamped)))
        scheduleSave()
    }

    /// Asks the mixer for every linked channel's gain and fader; replies move the controls
    func requestCurrentValues() {
        guard let oscManager else { return }
        for channel in store.channels {
            if settings.showGain { oscManager.send(address: gainAddress(for: channel), floatArg: nil) }
            if settings.showFader { oscManager.send(address: faderAddress(for: channel), floatArg: nil) }
        }
    }

    // MARK: Receiving

    /// A message came back from a mixer: if it's a linked gain or fader, show its value
    func received(address: String, value: Float?) {
        guard let value else { return }
        for channel in store.channels {
            if settings.showGain, address == gainAddress(for: channel) {
                gainDB[channel.id] = settings.gainDB(value)
                scheduleSave()
            }
            if settings.showFader, address == faderAddress(for: channel) {
                faderDB[channel.id] = settings.faderDB(value)
                scheduleSave()
            }
        }
    }

    // MARK: Auto Gain

    enum AutoGainState: Equatable {
        case listening(secondsLeft: Int)
        case done(String)
        case failed(String)
    }

    private(set) var autoGain: [UUID: AutoGainState] = [:]

    /// Listens to the channel for the set time and moves the preamp gain so its loudest
    /// peaks land at the target. Needs the routing engine running (it measures what reaches
    /// the iPad) and a known starting gain (read from the mixer, or the knob).
    func runAutoGain(for channelID: UUID) async {
        let engine = AudioRoutingEngine.shared
        guard engine.isRunning else {
            autoGain[channelID] = .failed("Turn Audio on first")
            return
        }
        guard let start = store.channels.first(where: { $0.id == channelID }) else { return }

        // Ask the mixer where the gain is now; a reply updates gainDB within a few ms
        oscManager?.send(address: gainAddress(for: start), floatArg: nil)
        autoGain[channelID] = .listening(secondsLeft: Int(settings.autoGainSeconds.rounded(.up)))
        try? await Task.sleep(for: .milliseconds(300))

        var peaks: [Float] = []
        let interval = 0.05
        let total = Int(settings.autoGainSeconds / interval)
        for i in 0..<total {
            guard case .listening = autoGain[channelID] else { return }   // cancelled
            peaks.append(engine.channelInputLevel(id: channelID))
            let left = Int((Double(total - i) * interval).rounded(.up))
            autoGain[channelID] = .listening(secondsLeft: left)
            try? await Task.sleep(for: .milliseconds(Int(interval * 1000)))
        }

        guard let channel = store.channels.first(where: { $0.id == channelID }) else { return }
        guard let current = gainDB[channelID] else {
            autoGain[channelID] = .failed("Unknown starting gain. Read Values from Mixer, or set the knob to match.")
            return
        }
        let heard = peaks.filter { $0 > -80 }.sorted()
        guard let loudest = heard.last, loudest > -60, heard.count >= 10 else {
            autoGain[channelID] = .failed("Didn't hear anything. Check the input and try again.")
            return
        }
        // The loudest 5% sets it, so one stray spike doesn't
        let p95 = heard[min(heard.count - 1, Int(Double(heard.count) * 0.95))]
        let clipped = heard.filter { $0 > -0.5 }.count > 2
        // Clipping hides how loud it really was: take a bigger step down and ask for a re-run
        let change = clipped ? min(-6, settings.autoGainTargetDB - p95 - 6) : settings.autoGainTargetDB - p95
        let newGain = min(settings.gainMaxDB, max(settings.gainMinDB, (current + change).rounded()))
        setGain(newGain, for: channel)

        var message = String(format: "%+.0f dB → %+.0f dB", newGain - current, newGain)
        if clipped { message += ". It was clipping: run again to fine-tune" }
        else if newGain >= settings.gainMaxDB && change > 0 { message += ". At maximum gain" }
        autoGain[channelID] = .done(message)
    }

    func cancelAutoGain(for channelID: UUID) {
        autoGain[channelID] = nil
    }

    func clearAutoGainMessage(for channelID: UUID) {
        if case .listening = autoGain[channelID] { return }
        autoGain[channelID] = nil
    }

    // MARK: Persistence

    private struct StoredValues: Codable {
        var gain: [UUID: Float]
        var fader: [UUID: Float]
    }

    private func saveSettings() {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: Self.settingsKey)
        }
    }

    /// Knob drags change values many times a second; write once they settle
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self else { return }
            if let data = try? JSONEncoder().encode(StoredValues(gain: self.gainDB, fader: self.faderDB)) {
                UserDefaults.standard.set(data, forKey: Self.valuesKey)
            }
        }
    }
}
