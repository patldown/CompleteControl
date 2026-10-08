//
//  AppOSC.swift
//  Midi Set List
//
//  The app's own effects as an OSC destination. Any OSC macro or song command whose
//  address starts with /app/ is handled inside the app (see AppOSCRouter) instead of
//  being sent to the network, so the existing macro system can drive every parameter.
//
//  This table is the single source of truth: the router, the macro editor's App Effect
//  picker, the in-app AI macro assistant and docs/app-osc-reference.md all follow it.
//  Keep the doc in step when you add or change a parameter.
//
//  Address forms (values are the OSC float argument):
//    /app/<channel>/volume                0…1
//    /app/<channel>/mute                  0 = on, 1 = muted
//    /app/<channel>/output                first hardware output, 1-based (3 = Out 3 / Out 3–4)
//    /app/<channel>/stereoOut             1 = stereo pair from that output, 0 = mono
//    /app/<channel>/<fx>/bypass           0 = active, 1 = bypassed
//    /app/<channel>/<fx>/<param>          see the parameter table
//    /app/engine/run                      1 = start, 0 = stop
//  <channel> is the channel's name (case, spaces, "-" and "_" ignored) or ch1, ch2… by
//  position. <fx> is the effect's short name; add 2, 3… for a second instance on the
//  same channel (pitch, pitch2).
//

import Foundation

struct AppFXParam: Identifiable {
    enum Kind {
        case number
        case toggle                     // ≥ 0.5 = on
        case choice([String])           // value = index
        case action                     // value ignored
    }

    let key: String
    let name: String
    let range: ClosedRange<Double>
    let unit: String
    let kind: Kind
    let detail: String
    let get: (ChannelFXSlot) -> Double
    let set: (inout ChannelFXSlot, Double) -> Void

    var id: String { key }

    /// Clamps (and rounds, for whole-number parameters) an incoming value
    func normalized(_ value: Double) -> Double {
        let v = min(range.upperBound, max(range.lowerBound, value))
        switch kind {
        case .toggle:            return v >= 0.5 ? 1 : 0
        case .choice, .action:   return v.rounded()
        case .number:            return isWholeNumber ? v.rounded() : v
        }
    }

    /// Parameters that only take whole numbers (transpose, FET attack/release, …)
    var isWholeNumber = false

    var rangeDescription: String {
        switch kind {
        case .toggle: return "0 or 1"
        case .action: return "any value"
        case .choice(let options):
            return options.enumerated().map { "\($0.offset) = \($0.element)" }.joined(separator: ", ")
        case .number:
            let fmt: (Double) -> String = { $0 == $0.rounded() ? String(Int($0)) : String(format: "%g", $0) }
            return "\(fmt(range.lowerBound)) to \(fmt(range.upperBound))\(unit.isEmpty ? "" : " \(unit)")"
        }
    }
}

private func num(_ key: String, _ name: String, _ range: ClosedRange<Double>, _ unit: String,
                 _ detail: String, whole: Bool = false,
                 get: @escaping (ChannelFXSlot) -> Double,
                 set: @escaping (inout ChannelFXSlot, Double) -> Void) -> AppFXParam {
    var p = AppFXParam(key: key, name: name, range: range, unit: unit, kind: .number,
                       detail: detail, get: get, set: set)
    p.isWholeNumber = whole
    return p
}

private func toggle(_ key: String, _ name: String, _ detail: String,
                    get: @escaping (ChannelFXSlot) -> Bool,
                    set: @escaping (inout ChannelFXSlot, Bool) -> Void) -> AppFXParam {
    AppFXParam(key: key, name: name, range: 0...1, unit: "", kind: .toggle, detail: detail,
               get: { get($0) ? 1 : 0 }, set: { set(&$0, $1 >= 0.5) })
}

private func choice(_ key: String, _ name: String, _ options: [String], _ detail: String,
                    get: @escaping (ChannelFXSlot) -> Int,
                    set: @escaping (inout ChannelFXSlot, Int) -> Void) -> AppFXParam {
    AppFXParam(key: key, name: name, range: 0...Double(options.count - 1), unit: "",
               kind: .choice(options), detail: detail,
               get: { Double(get($0)) }, set: { set(&$0, Int($1)) })
}

/// One harmony voice's parameters: voice1, interval1, level1, pan1, gender1, …
private func harmonyVoiceParams(_ n: Int, _ voice: WritableKeyPath<HarmonyParams, HarmonyVoice>) -> [AppFXParam] {
    let slotVoice = (\ChannelFXSlot.harmony).appending(path: voice)
    return [
        toggle("voice\(n)", "Voice \(n)", "On, or off to mute it (its settings are kept).",
               get: { $0[keyPath: slotVoice].enabled }, set: { $0[keyPath: slotVoice].enabled = $1 }),
        choice("interval\(n)", "Voice \(n) Interval", HarmonyInterval.allCases.map(\.label), "In the song's key.",
               get: { $0[keyPath: slotVoice].interval.rawValue },
               set: { $0[keyPath: slotVoice].interval = HarmonyInterval(rawValue: $1) ?? .thirdAbove }),
        num("level\(n)", "Voice \(n) Level", -24...6, "dB", "",
            get: { Double($0[keyPath: slotVoice].level) }, set: { $0[keyPath: slotVoice].level = Float($1) }),
        num("pan\(n)", "Voice \(n) Pan", -100...100, "", "-100 = left, 100 = right.",
            get: { Double($0[keyPath: slotVoice].pan) }, set: { $0[keyPath: slotVoice].pan = Float($1) }),
        num("gender\(n)", "Voice \(n) Gender", -6...6, "semitones", "+ smaller/brighter, − bigger/deeper. Pitch stays.",
            get: { Double($0[keyPath: slotVoice].gender) }, set: { $0[keyPath: slotVoice].gender = Float($1) }),
    ]
}

extension BuiltInFXType {
    /// Short name used in /app/ addresses
    var oscName: String {
        switch self {
        case .gain:          "gain"
        case .eq3Band:       "eq"
        case .reverb:        "reverb"
        case .delay:         "delay"
        case .levelRider:    "rider"
        case .optoComp:      "opto"
        case .fetComp:       "fet"
        case .feedbackNotch: "notch"
        case .pitchGuide:    "pitch"
        case .microDetune:   "detune"
        case .harmony:       "harmony"
        case .piezoBody:     "body"
        case .tone:          "tone"
        }
    }

    init?(oscName: String) {
        guard let match = Self.allCases.first(where: { $0.oscName == oscName }) else { return nil }
        self = match
    }

    /// Every parameter reachable over /app/ OSC (bypass is common to all and handled separately)
    var oscParams: [AppFXParam] {
        switch self {
        case .gain: [
            num("volume", "Volume", 0...2, "× (1 = unity)", "Linear gain.",
                get: { Double($0.gain.volume) }, set: { $0.gain.volume = Float($1) }),
            num("pan", "Pan", -1...1, "", "-1 = left, 0 = centre, 1 = right.",
                get: { Double($0.gain.pan) }, set: { $0.gain.pan = Float($1) }),
        ]
        case .eq3Band: [
            num("lowGain", "Low Shelf Gain", -24...24, "dB", "",
                get: { Double($0.eq.lowShelfGain) }, set: { $0.eq.lowShelfGain = Float($1) }),
            num("lowFreq", "Low Shelf Freq", 20...500, "Hz", "",
                get: { Double($0.eq.lowShelfFrequency) }, set: { $0.eq.lowShelfFrequency = Float($1) }),
            num("midGain", "Mid Gain", -24...24, "dB", "",
                get: { Double($0.eq.midGain) }, set: { $0.eq.midGain = Float($1) }),
            num("midFreq", "Mid Freq", 100...8_000, "Hz", "",
                get: { Double($0.eq.midFrequency) }, set: { $0.eq.midFrequency = Float($1) }),
            num("midWidth", "Mid Width", 0.05...5, "octaves", "",
                get: { Double($0.eq.midBandwidth) }, set: { $0.eq.midBandwidth = Float($1) }),
            num("highGain", "High Shelf Gain", -24...24, "dB", "",
                get: { Double($0.eq.highShelfGain) }, set: { $0.eq.highShelfGain = Float($1) }),
            num("highFreq", "High Shelf Freq", 1_000...20_000, "Hz", "",
                get: { Double($0.eq.highShelfFrequency) }, set: { $0.eq.highShelfFrequency = Float($1) }),
        ]
        case .reverb: [
            choice("room", "Room", ReverbParams.presetNames, "Reverb type.",
                   get: { $0.reverb.roomPreset }, set: { $0.reverb.roomPreset = $1 }),
            num("mix", "Wet/Dry", 0...100, "%", "",
                get: { Double($0.reverb.wetDryMix) }, set: { $0.reverb.wetDryMix = Float($1) }),
        ]
        case .delay: [
            num("time", "Time", 0...2, "s", "Delay time in seconds. Tip: 60 ÷ BPM = one beat.",
                get: { $0.delay.delayTime }, set: { $0.delay.delayTime = $1 }),
            num("feedback", "Feedback", -100...100, "%", "",
                get: { Double($0.delay.feedback) }, set: { $0.delay.feedback = Float($1) }),
            num("cutoff", "Low-Pass Cutoff", 10...22_050, "Hz", "Darkens the repeats.",
                get: { Double($0.delay.lowPassCutoff) }, set: { $0.delay.lowPassCutoff = Float($1) }),
            num("mix", "Wet/Dry", 0...100, "%", "",
                get: { Double($0.delay.wetDryMix) }, set: { $0.delay.wetDryMix = Float($1) }),
        ]
        case .levelRider: [
            num("inputTrim", "Input Trim", -12...12, "dB", "",
                get: { Double($0.levelRider.inputTrim) }, set: { $0.levelRider.inputTrim = Float($1) }),
            num("target", "Target Level", -30...(-6), "dBFS", "Level the rider aims for.",
                get: { Double($0.levelRider.targetLevel) }, set: { $0.levelRider.targetLevel = Float($1) }),
            num("maxCut", "Max Cut", -18...0, "dB", "",
                get: { Double($0.levelRider.maxCut) }, set: { $0.levelRider.maxCut = Float($1) }),
            num("maxBoost", "Max Boost", 0...9, "dB", "",
                get: { Double($0.levelRider.maxBoost) }, set: { $0.levelRider.maxBoost = Float($1) }),
            num("cutSpeed", "Cut Speed", 20...300, "ms", "",
                get: { Double($0.levelRider.cutSpeed) }, set: { $0.levelRider.cutSpeed = Float($1) }),
            num("boostSpeed", "Boost Speed", 200...2_000, "ms", "",
                get: { Double($0.levelRider.boostSpeed) }, set: { $0.levelRider.boostSpeed = Float($1) }),
            num("gate", "Gate", -60...(-20), "dBFS", "Below this the rider holds still.",
                get: { Double($0.levelRider.gateThreshold) }, set: { $0.levelRider.gateThreshold = Float($1) }),
            num("outputTrim", "Output Trim", -12...12, "dB", "",
                get: { Double($0.levelRider.outputTrim) }, set: { $0.levelRider.outputTrim = Float($1) }),
        ]
        case .optoComp: [
            num("peakReduction", "Peak Reduction", 0...100, "", "More = more compression.",
                get: { Double($0.optoComp.peakReduction) }, set: { $0.optoComp.peakReduction = Float($1) }),
            num("gain", "Gain", 0...40, "dB", "Makeup gain.",
                get: { Double($0.optoComp.gain) }, set: { $0.optoComp.gain = Float($1) }),
            toggle("limit", "Limit Mode", "0 = Compress (~3:1), 1 = Limit (~10:1).",
                   get: { $0.optoComp.limitMode }, set: { $0.optoComp.limitMode = $1 }),
        ]
        case .fetComp: [
            num("input", "Input", 0...48, "dB", "Drives into the fixed threshold: more = more compression.",
                get: { Double($0.fetComp.input) }, set: { $0.fetComp.input = Float($1) }),
            num("output", "Output", -24...12, "dB", "",
                get: { Double($0.fetComp.output) }, set: { $0.fetComp.output = Float($1) }),
            choice("ratio", "Ratio", FETCompParams.Ratio.allCases.map { $0.label }, "",
                   get: { $0.fetComp.ratio.rawValue },
                   set: { $0.fetComp.ratio = FETCompParams.Ratio(rawValue: $1) ?? .r4 }),
            num("attack", "Attack", 1...7, "", "7 = fastest (20 µs), 1 = slowest (800 µs).", whole: true,
                get: { Double($0.fetComp.attack) }, set: { $0.fetComp.attack = Float($1) }),
            num("release", "Release", 1...7, "", "7 = fastest (50 ms), 1 = slowest (1.1 s).", whole: true,
                get: { Double($0.fetComp.release) }, set: { $0.fetComp.release = Float($1) }),
        ]
        case .feedbackNotch: [
            num("sensitivity", "Sensitivity", 0...100, "", "Ring-out detection sensitivity.",
                get: { Double($0.feedbackNotch.sensitivity) }, set: { $0.feedbackNotch.sensitivity = Float($1) }),
            num("maxDepth", "Max Depth", -18...(-6), "dB", "Deepest any notch may go.", whole: true,
                get: { Double($0.feedbackNotch.maxDepth) }, set: { $0.feedbackNotch.maxDepth = Float($1) }),
            AppFXParam(key: "clear", name: "Clear Notches", range: 0...1, unit: "", kind: .action,
                       detail: "Removes every ring-out notch.",
                       get: { _ in 0 }, set: { slot, _ in slot.feedbackNotch.notches.removeAll() }),
        ]
        case .pitchGuide: [
            num("retuneSpeed", "Retune Speed", 0...400, "ms", "Time to land on the note, like Auto-Tune. 0 = instant (robotic), 10–25 = tight, 50–150 = natural.",
                get: { Double($0.pitchGuide.retuneSpeed) }, set: { $0.pitchGuide.retuneSpeed = Float($1) }),
            num("amount", "Amount", 0...100, "%", "How far toward the note it pulls. 0 = transpose only.",
                get: { Double($0.pitchGuide.amount) }, set: { $0.pitchGuide.amount = Float($1) }),
            num("humanize", "Humanize", 0...100, "%", "Loosens the retune on long held notes.",
                get: { Double($0.pitchGuide.humanize) }, set: { $0.pitchGuide.humanize = Float($1) }),
            num("tolerance", "Tolerance", 0...50, "cents", "Notes within this are left alone.",
                get: { Double($0.pitchGuide.tolerance) }, set: { $0.pitchGuide.tolerance = Float($1) }),
            num("pickiness", "Pickiness", 0...100, "%", "Higher = only clear, steady notes.",
                get: { Double($0.pitchGuide.pickiness) }, set: { $0.pitchGuide.pickiness = Float($1) }),
            num("gate", "Gate", -70...(-20), "dBFS", "Quieter input (bleed) is ignored.",
                get: { Double($0.pitchGuide.gateThreshold) }, set: { $0.pitchGuide.gateThreshold = Float($1) }),
            choice("key", "Key", PitchGuideParams.noteNames,
                   "Key the singer sings in (fallback when following the song key).",
                   get: { $0.pitchGuide.key }, set: { $0.pitchGuide.key = $1 }),
            choice("scale", "Scale", PitchScale.allCases.map(\.displayName), "",
                   get: { PitchScale.allCases.firstIndex(of: $0.pitchGuide.scale) ?? 0 },
                   set: { $0.pitchGuide.scale = PitchScale.allCases[$1] }),
            choice("voiceRange", "Voice Range", VoiceRange.allCases.map(\.displayName), "",
                   get: { VoiceRange.allCases.firstIndex(of: $0.pitchGuide.voiceRange) ?? 0 },
                   set: { $0.pitchGuide.voiceRange = VoiceRange.allCases[$1] }),
            toggle("followSongKey", "Follow Song Key", "Correct in the key of the song loaded in Perform.",
                   get: { $0.pitchGuide.songKeyDrive }, set: { $0.pitchGuide.songKeyDrive = $1 }),
            num("transpose", "Transpose", -12...12, "semitones", "Shifts the corrected voice.", whole: true,
                get: { Double($0.pitchGuide.transpose) }, set: { $0.pitchGuide.transpose = Int($1) }),
            toggle("autoFormant", "Auto Formant Correction", "Keeps the singer's natural tone when shifting.",
                   get: { $0.pitchGuide.preserveFormants }, set: { $0.pitchGuide.preserveFormants = $1 }),
            num("formant", "Formant", -6...6, "semitones", "+ smaller/brighter, − bigger/darker.",
                get: { Double($0.pitchGuide.formantShift) }, set: { $0.pitchGuide.formantShift = Float($1) }),
            toggle("shiftOnlyWhileSinging", "Shift Only While Singing",
                   "Transpose/Formant switch off between phrases.",
                   get: { $0.pitchGuide.shiftOnlyWhileSinging }, set: { $0.pitchGuide.shiftOnlyWhileSinging = $1 }),
            num("bleedDuck", "Bleed Duck", -20...0, "dB", "Turns the mic down between phrases. 0 = off.",
                get: { Double($0.pitchGuide.bleedDuck) }, set: { $0.pitchGuide.bleedDuck = Float($1) }),
        ]
        case .tone: [
            num("amount", "Amount", 0...100, "%", "How much of the instrument's tone profile. 0 = flat.",
                get: { Double($0.tone.amount) }, set: { $0.tone.amount = Float($1) }),
            choice("instrument", "Instrument", ["None"] + ToneInstrument.allCases.map(\.displayName),
                   "Picks the profile and stops following the channel's icon. 0 = none (Tone does nothing).",
                   get: { ($0.tone.instrument?.rawValue ?? -1) + 1 },
                   set: { $0.tone.instrument = ToneInstrument(rawValue: $1 - 1); $0.tone.followChannel = false }),
        ]
        case .piezoBody: [
            num("amount", "Amount", 0...100, "%", "Body back in, quack and spikiness out. 0 = flat.",
                get: { Double($0.piezoBody.amount) }, set: { $0.piezoBody.amount = Float($1) }),
            choice("size", "Body Size", GuitarBodySize.allCases.map(\.displayName), "Where the body resonances sit.",
                   get: { GuitarBodySize.allCases.firstIndex(of: $0.piezoBody.bodySize) ?? 1 },
                   set: { $0.piezoBody.bodySize = GuitarBodySize.allCases[$1] }),
            toggle("phase", "Phase Invert", "Flip polarity; try it when the low end feeds back.",
                   get: { $0.piezoBody.phaseInvert }, set: { $0.piezoBody.phaseInvert = $1 }),
            toggle("mute", "Mute", "Silence the guitar (e.g. to tune).",
                   get: { $0.piezoBody.mute }, set: { $0.piezoBody.mute = $1 }),
            num("level", "Level", -12...6, "dB", "Output level.",
                get: { Double($0.piezoBody.level) }, set: { $0.piezoBody.level = Float($1) }),
        ]
        case .harmony:
            harmonyVoiceParams(1, \.voice1) + harmonyVoiceParams(2, \.voice2) + harmonyVoiceParams(3, \.voice3) + [
            num("leadLevel", "Lead Level", -60...6, "dB", "The singer's own voice. -60 = off (harmonies only).",
                get: { Double($0.harmony.leadLevel) }, set: { $0.harmony.leadLevel = Float($1) }),
            num("humanize", "Humanize", 0...100, "%", "Small detune, drift and delay so the voices sound like singers.",
                get: { Double($0.harmony.humanize) }, set: { $0.harmony.humanize = Float($1) }),
            toggle("followSongKey", "Follow Song Key", "Harmonize in the key of the song loaded in Perform.",
                   get: { $0.harmony.songKeyDrive }, set: { $0.harmony.songKeyDrive = $1 }),
            choice("key", "Key", PitchGuideParams.noteNames, "Fallback when following the song key.",
                   get: { $0.harmony.key }, set: { $0.harmony.key = $1 }),
            choice("scale", "Scale", PitchScale.allCases.map(\.displayName), "",
                   get: { PitchScale.allCases.firstIndex(of: $0.harmony.scale) ?? 0 },
                   set: { $0.harmony.scale = PitchScale.allCases[$1] }),
            num("pickiness", "Pickiness", 0...100, "%", "Higher = only clear, steady notes get harmonies.",
                get: { Double($0.harmony.pickiness) }, set: { $0.harmony.pickiness = Float($1) }),
            num("gate", "Gate", -70...(-20), "dBFS", "Quieter input (bleed) gets no harmonies.",
                get: { Double($0.harmony.gateThreshold) }, set: { $0.harmony.gateThreshold = Float($1) }),
        ]
        case .microDetune: [
            num("pitchA", "Pitch A", 0...50, "cents", "Voice A (left) shifted up. 9 = classic.",
                get: { Double($0.microDetune.pitchA) }, set: { $0.microDetune.pitchA = Float($1) }),
            num("pitchB", "Pitch B", -50...0, "cents", "Voice B (right) shifted down. -9 = classic.",
                get: { Double($0.microDetune.pitchB) }, set: { $0.microDetune.pitchB = Float($1) }),
            num("delayA", "Delay A", 0...2_000, "ms", "Voice A delay (when not tempo-synced). The shifter adds ~25 ms on top.",
                get: { Double($0.microDetune.delayA) }, set: { $0.microDetune.delayA = Float($1) }),
            num("delayB", "Delay B", 0...2_000, "ms", "Voice B delay (when not tempo-synced). The shifter adds ~25 ms on top.",
                get: { Double($0.microDetune.delayB) }, set: { $0.microDetune.delayB = Float($1) }),
            toggle("tempoSync", "Tempo Sync", "Delays follow the loaded song's tempo as note values.",
                   get: { $0.microDetune.tempoSync }, set: { $0.microDetune.tempoSync = $1 }),
            choice("noteA", "Note A", NoteDivision.allCases.map(\.label), "Voice A delay when tempo-synced.",
                   get: { NoteDivision.allCases.firstIndex(of: $0.microDetune.noteA) ?? 0 },
                   set: { $0.microDetune.noteA = NoteDivision.allCases[$1] }),
            choice("noteB", "Note B", NoteDivision.allCases.map(\.label), "Voice B delay when tempo-synced.",
                   get: { NoteDivision.allCases.firstIndex(of: $0.microDetune.noteB) ?? 0 },
                   set: { $0.microDetune.noteB = NoteDivision.allCases[$1] }),
            num("pitchMix", "Pitch Mix", 0...100, "%", "0 = only A, 50 = both, 100 = only B.",
                get: { Double($0.microDetune.pitchMix) }, set: { $0.microDetune.pitchMix = Float($1) }),
            num("mix", "Mix", 0...100, "%", "50 = dry and wet both full; above that the dry fades.",
                get: { Double($0.microDetune.mix) }, set: { $0.microDetune.mix = Float($1) }),
            num("feedback", "Feedback", 0...95, "%", "Repeats shift further each time: rising/falling repeats.",
                get: { Double($0.microDetune.feedback) }, set: { $0.microDetune.feedback = Float($1) }),
            num("tone", "Tone", -100...100, "", "- darker, 0 flat, + brighter (voices only).",
                get: { Double($0.microDetune.tone) }, set: { $0.microDetune.tone = Float($1) }),
            num("lowCut", "Low Cut", 20...600, "Hz", "Keeps the low end out of the voices. 20 = off.",
                get: { Double($0.microDetune.lowCut) }, set: { $0.microDetune.lowCut = Float($1) }),
            num("modDepth", "Mod Depth", 0...100, "%", "Chorus: at 100 each voice swings from 0 to 2× its shift.",
                get: { Double($0.microDetune.modDepth) }, set: { $0.microDetune.modDepth = Float($1) }),
            num("modRate", "Mod Rate", 0.1...10, "Hz", "Speed of the chorus.",
                get: { Double($0.microDetune.modRate) }, set: { $0.microDetune.modRate = Float($1) }),
        ]
        }
    }
}

// MARK: - Addressing helpers

/// One effect on a channel as addressed over OSC: "pitch", "pitch2", …
struct AppFXInstance: Hashable {
    let slotIndex: Int
    let type: BuiltInFXType
    let segment: String
}

enum AppOSC {
    static let prefix = "/app/"

    static func isAppAddress(_ address: String) -> Bool { address.hasPrefix(prefix) }

    /// Channel-name form used in addresses and matching: lowercased, no spaces, "-" or "_"
    static func normalize(_ name: String) -> String {
        name.lowercased().filter { !" -_".contains($0) }
    }

    /// Names a channel can't take: they'd be read as a position (ch2) or the engine address
    static func isReservedName(_ name: String) -> Bool {
        let n = normalize(name)
        if n == "engine" || n == "mix" { return true }
        return n.hasPrefix("ch") && n.count > 2 && n.dropFirst(2).allSatisfy(\.isNumber)
    }

    /// The address segment for a channel: its name, or ch<n> when it has none
    static func channelSegment(_ channel: AudioChannel, index: Int) -> String {
        channel.name.trimmingCharacters(in: .whitespaces).isEmpty ? "ch\(index + 1)" : channel.name
    }

    /// The <fx> segment for each used slot of a channel: pitch, pitch2, …
    static func fxSegments(for channel: AudioChannel) -> [AppFXInstance] {
        var counts: [BuiltInFXType: Int] = [:]
        return channel.slots.enumerated().compactMap { i, slot in
            guard let type = slot.type else { return nil }
            let n = (counts[type] ?? 0) + 1
            counts[type] = n
            return AppFXInstance(slotIndex: i, type: type, segment: n == 1 ? type.oscName : "\(type.oscName)\(n)")
        }
    }

    static func address(channel: AudioChannel, index: Int, fxSegment: String, param: String) -> String {
        "\(prefix)\(channelSegment(channel, index: index))/\(fxSegment)/\(param)"
    }
}

// MARK: - Reference text (in-app AI assistant, Share OSC Reference)

extension AppOSC {
    /// Markdown reference generated from the parameter table, with the user's actual
    /// channels. `compact` drops descriptions to fit an on-device model's context.
    static func referenceMarkdown(channels: [AudioChannel], compact: Bool = false) -> String {
        var md = """
        # Complete Control app OSC reference

        OSC messages whose address starts with `/app/` control this app's own effects. They \
        never leave the device. Send them from any OSC macro or song command; the float value \
        is the setting. Values outside a range are clamped; changes apply instantly and are saved.

        ## Address forms
        - `/app/<channel>/volume` 0 to 1
        - `/app/<channel>/mute` 1 = muted, 0 = unmuted
        - `/app/<channel>/output` first hardware output, 1-based (3 = Out 3, or Out 3–4 in stereo)
        - `/app/<channel>/stereoOut` 1 = stereo pair starting at that output, 0 = mono to that one output
        - `/app/<channel>/<fx>/bypass` 1 = bypassed, 0 = active
        - `/app/<channel>/<fx>/<param>` see tables below
        - `/app/engine/run` 1 = start the routing engine, 0 = stop
        - `/app/mix/<preset>` recall a mix preset (any value); `/app/mix/<preset>/<channel>` just that channel's part
        - `/app/<channel>/preset/<name>` recall one of the channel's own presets

        `<channel>` is the routing channel's name (case, spaces, `-` and `_` ignored) or `ch1`, \
        `ch2`… by position. `<fx>` is the effect's short name; a second instance of the same \
        effect on one channel is `<fx>2` (e.g. `pitch2`). Toggles: 1 = on, 0 = off. Choices: \
        send the option's number.

        """

        md += "\n## Channels right now\n"
        if channels.isEmpty {
            md += "- (none yet — add channels in the Routing tab)\n"
        }
        for (i, ch) in channels.enumerated() {
            let fx = fxSegments(for: ch).map { "`\($0.segment)` (\($0.type.displayName))" }
            md += "- `\(channelSegment(ch, index: i))`: \(fx.isEmpty ? "no effects" : fx.joined(separator: ", "))\n"
        }

        md += "\n## Effects and parameters\n"
        for type in BuiltInFXType.allCases {
            md += "\n### `\(type.oscName)` — \(type.displayName)\n"
            for p in type.oscParams {
                let detail = compact || p.detail.isEmpty ? "" : " — \(p.detail)"
                md += "- `\(p.key)`: \(p.rangeDescription)\(detail)\n"
            }
        }

        if !compact {
            md += """

            ## Examples
            - Lead vocal retune speed to 25 ms: `/app/Lead Vox/pitch/retuneSpeed` 25
            - Transpose the second pitch effect on BGV up 2: `/app/BGV/pitch2/transpose` 2
            - Bypass the FET compressor on channel 1: `/app/ch1/fet/bypass` 1
            - Correct in A minor: `/app/Lead Vox/pitch/key` 9 and `/app/Lead Vox/pitch/scale` 2

            """
        }
        return md
    }
}
