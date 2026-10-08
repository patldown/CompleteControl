//
//  AudioRouting.swift
//  Midi Set List
//
//  Pure Codable model types for the audio routing system.
//  Stored as JSON (not CoreData) — hardware configuration, not song content.
//
//  Compressors are in-house DSP (VintageCompressorKernel): AVAudioUnitDynamicsProcessor
//  is macOS-only.
//

import Foundation

// MARK: - FX type

enum BuiltInFXType: String, Codable, CaseIterable, Identifiable {
    case gain, eq3Band, reverb, delay, levelRider, optoComp, fetComp, feedbackNotch, pitchGuide, microDetune, harmony

    // reverb and delay kept in enum for JSON backward-compat but are no longer available;
    // the load() migration clears any saved slots of these types.
    static var allCases: [BuiltInFXType] {
        [.gain, .eq3Band, .levelRider, .optoComp, .fetComp, .feedbackNotch, .pitchGuide, .harmony, .microDetune]
    }

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .gain:       "Gain / Pan"
        case .eq3Band:    "3-Band EQ"
        case .reverb:     "Reverb"
        case .delay:      "Delay"
        case .levelRider: "Level Rider"
        case .optoComp:   "Opto Comp (LA-2A style)"
        case .fetComp:    "FET Comp (1176 style)"
        case .feedbackNotch: "Feedback Notch"
        case .pitchGuide: "Pitch Guide"
        case .microDetune: "Micro Detune (widener)"
        case .harmony:    "Harmony (key-aware)"
        }
    }

    var systemImage: String {
        switch self {
        case .gain:       "speaker.wave.2"
        case .eq3Band:    "slider.horizontal.3"
        case .reverb:     "waveform"
        case .delay:      "repeat"
        case .levelRider: "dial.medium"
        case .optoComp:   "lightbulb"
        case .fetComp:    "bolt"
        case .feedbackNotch: "waveform.path.badge.minus"
        case .pitchGuide: "music.note"
        case .microDetune: "arrow.left.and.right"
        case .harmony:    "music.quarternote.3"
        }
    }
}

// MARK: - FX parameters (one struct per type)

struct GainParams: Codable, Equatable {
    var volume: Float = 1.0   // 0.0 – 2.0 linear
    var pan: Float = 0.0      // -1.0 (L) – +1.0 (R)
}

struct EQ3BandParams: Codable, Equatable {
    var lowShelfGain: Float = 0            // dB, -24 – +24
    var lowShelfFrequency: Float = 80
    var midGain: Float = 0
    var midFrequency: Float = 1_000
    var midBandwidth: Float = 1.0          // octaves
    var highShelfGain: Float = 0
    var highShelfFrequency: Float = 8_000
}

struct ReverbParams: Codable, Equatable {
    /// AVAudioUnitReverbPreset rawValue. 0=smallRoom … 12=largeHall2
    var roomPreset: Int = 1
    var wetDryMix: Float = 30      // %, 0 – 100
}

struct DelayParams: Codable, Equatable {
    var delayTime: Double = 0.25      // seconds, 0 – 2
    var feedback: Float = 50          // %, -100 – 100
    var lowPassCutoff: Float = 15_000 // Hz
    var wetDryMix: Float = 30         // %, 0 – 100
}

// MARK: - Level Rider parameters

struct LevelRiderParams: Codable, Equatable {
    var inputTrim: Float = 0        // dB, -12...+12; applied before the detector
    var targetLevel: Float = -18    // dBFS, -30...-6
    var maxCut: Float = -9          // dB, -18...0
    var maxBoost: Float = 4         // dB, 0...+9
    var cutSpeed: Float = 80        // ms, 20...300  (how fast to cut)
    var boostSpeed: Float = 600     // ms, 200...2000 (how fast to boost)
    var gateThreshold: Float = -50  // dBFS, -60...-20; below this, gain freezes
    var outputTrim: Float = 0       // dB, -12...+12; applied after rider
}

// MARK: - Compressor parameters

/// LA-2A style: two knobs and a Compress/Limit switch.
struct OptoCompParams: Codable, Equatable {
    var peakReduction: Float = 40   // 0...100; higher = more compression
    var gain: Float = 6             // dB makeup, 0...40
    var limitMode: Bool = false     // false = Compress (~3:1), true = Limit (~10:1)
}

/// 1176 style: Input drives into a fixed threshold, Output sets level.
struct FETCompParams: Codable, Equatable {
    enum Ratio: Int, Codable, CaseIterable, Identifiable {
        case r4, r8, r12, r20, allButtons
        var id: Int { rawValue }
        var label: String {
            switch self {
            case .r4: "4"
            case .r8: "8"
            case .r12: "12"
            case .r20: "20"
            case .allButtons: "All"
            }
        }
    }
    var input: Float = 6            // dB, 0...48
    var output: Float = 0           // dB, -24...+12
    var ratio: Ratio = .r4
    var attack: Float = 3           // 1 (slow, 800 µs) ... 7 (fast, 20 µs)
    var release: Float = 5          // 1 (slow, 1.1 s) ... 7 (fast, 50 ms)
}

// MARK: - Feedback Notch parameters

/// One narrow cut placed by ring-out.
struct FeedbackNotch: Codable, Equatable, Identifiable {
    var id = UUID()
    var frequency: Float            // Hz
    var depth: Float                // dB, negative
    var q: Float = 10               // ~1/7 octave wide

    var label: String { Self.label(for: frequency) }

    static func label(for frequency: Float) -> String {
        frequency < 1_000 ? "\(Int(frequency.rounded())) Hz"
                          : String(format: "%.2f kHz", frequency / 1_000)
    }
}

struct FeedbackNotchParams: Codable, Equatable {
    var notches: [FeedbackNotch] = []
    var sensitivity: Float = 50     // 0...100; higher catches ringing sooner
    var maxDepth: Float = -12       // dB, -18...-6; deepest any one notch may go
}

// MARK: - Harmony parameters

/// A harmony voice's interval from the sung note, counted in steps of the key's scale
nonisolated enum HarmonyInterval: Int, Codable, CaseIterable, Identifiable {
    case octaveBelow = 0, sixthBelow, fifthBelow, fourthBelow, thirdBelow
    case thirdAbove, fourthAbove, fifthAbove, sixthAbove, octaveAbove

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .octaveBelow: "Octave Below"
        case .sixthBelow:  "6th Below"
        case .fifthBelow:  "5th Below"
        case .fourthBelow: "4th Below"
        case .thirdBelow:  "3rd Below"
        case .thirdAbove:  "3rd Above"
        case .fourthAbove: "4th Above"
        case .fifthAbove:  "5th Above"
        case .sixthAbove:  "6th Above"
        case .octaveAbove: "Octave Above"
        }
    }

    var shortLabel: String {
        switch self {
        case .octaveBelow: "−8va"
        case .sixthBelow:  "−6th"
        case .fifthBelow:  "−5th"
        case .fourthBelow: "−4th"
        case .thirdBelow:  "−3rd"
        case .thirdAbove:  "+3rd"
        case .fourthAbove: "+4th"
        case .fifthAbove:  "+5th"
        case .sixthAbove:  "+6th"
        case .octaveAbove: "+8va"
        }
    }

    /// Scale steps from the sung note in a seven-note scale (a 3rd is two steps)
    var steps: Int {
        switch self {
        case .octaveBelow: -7
        case .sixthBelow:  -5
        case .fifthBelow:  -4
        case .fourthBelow: -3
        case .thirdBelow:  -2
        case .thirdAbove:  2
        case .fourthAbove: 3
        case .fifthAbove:  4
        case .sixthAbove:  5
        case .octaveAbove: 7
        }
    }

    /// Semitone sizes to try, in order, for scales that aren't seven notes. A tuple so the
    /// audio thread never builds an array.
    var semitones: (Int, Int?, Int?) {
        switch self {
        case .octaveBelow: (-12, nil, nil)
        case .sixthBelow:  (-9, -8, nil)
        case .fifthBelow:  (-7, -8, -6)
        case .fourthBelow: (-5, -6, nil)
        case .thirdBelow:  (-3, -4, nil)
        case .thirdAbove:  (4, 3, nil)
        case .fourthAbove: (5, 6, nil)
        case .fifthAbove:  (7, 6, 8)
        case .sixthAbove:  (9, 8, nil)
        case .octaveAbove: (12, nil, nil)
        }
    }
}

struct HarmonyVoice: Codable, Equatable {
    var enabled = true
    var interval: HarmonyInterval = .thirdAbove
    var level: Float = -3           // dB, -24...+6
    var pan: Float = -40            // -100 (L) ... +100 (R)
}

/// Key-aware harmonizer: up to two voices made from the singer, in the song's key
struct HarmonyParams: Codable, Equatable {
    var voice1 = HarmonyVoice()
    var voice2 = HarmonyVoice(enabled: false, interval: .fourthBelow, level: -3, pan: 40)
    /// Use the loaded song's key and scale; `key`/`scale` are the fallback
    var songKeyDrive = true
    var key = 0                     // 0=C … 11=B
    var scale: PitchScale = .major
    var humanize: Float = 30        // %, 0...100; small detune, drift and delay per voice
    /// Keep the singer's own voice in the output; off = harmonies only
    var passLead = true
    var pickiness: Float = 50       // %, 0...100
    var gateThreshold: Float = -45  // dBFS, -70...-20
    var voiceRange: VoiceRange = .mid

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = HarmonyParams()
        voice1 = try c.decodeIfPresent(HarmonyVoice.self, forKey: .voice1) ?? d.voice1
        voice2 = try c.decodeIfPresent(HarmonyVoice.self, forKey: .voice2) ?? d.voice2
        songKeyDrive = try c.decodeIfPresent(Bool.self, forKey: .songKeyDrive) ?? d.songKeyDrive
        key = try c.decodeIfPresent(Int.self, forKey: .key) ?? d.key
        scale = (try? c.decodeIfPresent(PitchScale.self, forKey: .scale)) ?? d.scale
        humanize = try c.decodeIfPresent(Float.self, forKey: .humanize) ?? d.humanize
        passLead = try c.decodeIfPresent(Bool.self, forKey: .passLead) ?? d.passLead
        pickiness = try c.decodeIfPresent(Float.self, forKey: .pickiness) ?? d.pickiness
        gateThreshold = try c.decodeIfPresent(Float.self, forKey: .gateThreshold) ?? d.gateThreshold
        voiceRange = (try? c.decodeIfPresent(VoiceRange.self, forKey: .voiceRange)) ?? d.voiceRange
    }

    /// These params in the song's key and scale, when following it and it has a key
    func resolved(songKey: MusicalKey?) -> HarmonyParams {
        guard songKeyDrive, let songKey, let pc = songKey.pitchClass else { return self }
        var p = self
        p.key = ((pc % 12) + 12) % 12
        p.scale = PitchScale(songKey.scale)
        return p
    }

    /// 12-bit mask of the key's notes (bit 0 = C)
    var allowedPitchClassMask: UInt32 {
        scale.intervals.reduce(0) { $0 | (1 << UInt32((key + $1) % 12)) }
    }

    struct Stock: Identifiable {
        let name: String
        let voice1: HarmonyVoice
        let voice2: HarmonyVoice
        var id: String { name }
    }

    /// Ready-made voicings; choosing one sets the voices and leaves key and detection alone
    static let stock: [Stock] = [
        Stock(name: "3rd Above",
              voice1: HarmonyVoice(enabled: true, interval: .thirdAbove, level: -3, pan: -30),
              voice2: HarmonyVoice(enabled: false, interval: .fifthAbove, level: -3, pan: 30)),
        Stock(name: "3rd Below",
              voice1: HarmonyVoice(enabled: true, interval: .thirdBelow, level: -3, pan: 30),
              voice2: HarmonyVoice(enabled: false, interval: .fifthAbove, level: -3, pan: -30)),
        Stock(name: "3rd & 5th Above",
              voice1: HarmonyVoice(enabled: true, interval: .thirdAbove, level: -4, pan: -40),
              voice2: HarmonyVoice(enabled: true, interval: .fifthAbove, level: -6, pan: 40)),
        Stock(name: "Trio (3rd Up, 4th Down)",
              voice1: HarmonyVoice(enabled: true, interval: .thirdAbove, level: -4, pan: -40),
              voice2: HarmonyVoice(enabled: true, interval: .fourthBelow, level: -5, pan: 40)),
        Stock(name: "Octave Below",
              voice1: HarmonyVoice(enabled: true, interval: .octaveBelow, level: -6, pan: 0),
              voice2: HarmonyVoice(enabled: false, interval: .octaveAbove, level: -9, pan: 0)),
        Stock(name: "Octaves Up & Down",
              voice1: HarmonyVoice(enabled: true, interval: .octaveAbove, level: -9, pan: -25),
              voice2: HarmonyVoice(enabled: true, interval: .octaveBelow, level: -6, pan: 25)),
    ]
}

// MARK: - Micro Detune parameters

/// Micro-pitch dual shifted delay, after Eventide's MicroPitch: voice A shifted up (left),
/// voice B shifted down (right), each with its own delay and feedback loop.
struct MicroDetuneParams: Codable, Equatable {
    var pitchA: Float = 9           // cents, 0...50; voice A (left) shifted up
    var pitchB: Float = -9          // cents, -50...0; voice B (right) shifted down
    var delayA: Float = 0           // ms, 0...2000
    var delayB: Float = 12          // ms, 0...2000
    /// Delays follow the loaded song's tempo as note values instead of milliseconds
    var tempoSync: Bool = false
    var noteA: NoteDivision = .eighth
    var noteB: NoteDivision = .dottedEighth
    var pitchMix: Float = 50        // %, 0...100; 0 = only A, 50 = both full, 100 = only B
    var mix: Float = 40             // %, 0...100; 50 = dry and wet both full
    var feedback: Float = 0         // %, 0...95; each voice repeats through its own shifter
    var tone: Float = 0             // -100 (darker) ... +100 (brighter); 0 = flat
    var lowCut: Float = 20          // Hz, 20...600; 20 = off
    var modDepth: Float = 0         // %, 0...100; at 100 each voice's pitch swings 0 to 2× its shift
    var modRate: Float = 0.5        // Hz, 0.1...10

    init() {}

    // Missing keys decode as defaults; the first version's settings carry over
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let old = try decoder.container(keyedBy: FirstVersionKeys.self)
        let d = MicroDetuneParams()
        let oldDetune = try old.decodeIfPresent(Float.self, forKey: .detune)
        let oldDelay = try old.decodeIfPresent(Float.self, forKey: .delay)
        pitchA = try c.decodeIfPresent(Float.self, forKey: .pitchA) ?? oldDetune ?? d.pitchA
        pitchB = try c.decodeIfPresent(Float.self, forKey: .pitchB) ?? oldDetune.map { -$0 } ?? d.pitchB
        delayA = try c.decodeIfPresent(Float.self, forKey: .delayA) ?? oldDelay ?? d.delayA
        delayB = try c.decodeIfPresent(Float.self, forKey: .delayB) ?? oldDelay.map { $0 * 1.4 } ?? d.delayB
        tempoSync = try c.decodeIfPresent(Bool.self, forKey: .tempoSync) ?? d.tempoSync
        noteA = (try? c.decodeIfPresent(NoteDivision.self, forKey: .noteA)) ?? d.noteA
        noteB = (try? c.decodeIfPresent(NoteDivision.self, forKey: .noteB)) ?? d.noteB
        pitchMix = try c.decodeIfPresent(Float.self, forKey: .pitchMix) ?? d.pitchMix
        mix = try c.decodeIfPresent(Float.self, forKey: .mix) ?? d.mix
        feedback = try c.decodeIfPresent(Float.self, forKey: .feedback) ?? d.feedback
        tone = try c.decodeIfPresent(Float.self, forKey: .tone) ?? d.tone
        lowCut = try c.decodeIfPresent(Float.self, forKey: .lowCut) ?? d.lowCut
        modDepth = try c.decodeIfPresent(Float.self, forKey: .modDepth) ?? d.modDepth
        modRate = try c.decodeIfPresent(Float.self, forKey: .modRate) ?? d.modRate
    }

    private enum FirstVersionKeys: String, CodingKey { case detune, delay }

    static let maxDelayMs: Float = 2_000

    /// Delay times in ms: the fixed times, or the note values at the song's tempo
    func delays(bpm: Int?) -> (a: Float, b: Float) {
        guard tempoSync, let bpm, bpm > 0 else { return (delayA, delayB) }
        let beat = 60_000 / Float(bpm)
        return (min(Self.maxDelayMs, noteA.beats * beat), min(Self.maxDelayMs, noteB.beats * beat))
    }
}

/// A delay time as a note value, in beats (quarter notes)
enum NoteDivision: String, Codable, CaseIterable, Identifiable {
    case thirtySecond, sixteenthTriplet, sixteenth, eighthTriplet, dottedSixteenth
    case eighth, quarterTriplet, dottedEighth, quarter, dottedQuarter, half

    var id: String { rawValue }

    var beats: Float {
        switch self {
        case .thirtySecond:     0.125
        case .sixteenthTriplet: 1.0 / 6
        case .sixteenth:        0.25
        case .eighthTriplet:    1.0 / 3
        case .dottedSixteenth:  0.375
        case .eighth:           0.5
        case .quarterTriplet:   2.0 / 3
        case .dottedEighth:     0.75
        case .quarter:          1
        case .dottedQuarter:    1.5
        case .half:             2
        }
    }

    var label: String {
        switch self {
        case .thirtySecond:     "1/32"
        case .sixteenthTriplet: "1/16T"
        case .sixteenth:        "1/16"
        case .eighthTriplet:    "1/8T"
        case .dottedSixteenth:  "1/16."
        case .eighth:           "1/8"
        case .quarterTriplet:   "1/4T"
        case .dottedEighth:     "1/8."
        case .quarter:          "1/4"
        case .dottedQuarter:    "1/4."
        case .half:             "1/2"
        }
    }
}

extension MicroDetuneParams {
    struct Stock: Identifiable {
        let name: String
        let params: MicroDetuneParams
        var id: String { name }
        init(_ name: String, _ params: MicroDetuneParams) { self.name = name; self.params = params }
    }

    /// Ready-made settings offered in the editor
    static let stock: [Stock] = [
        Stock("Classic Micro Pitch", .make(a: 9, b: -9, delayA: 0, delayB: 12, mix: 40)),
        Stock("Subtle Widen", .make(a: 6, b: -6, delayA: 8, delayB: 12, mix: 30, lowCut: 150)),
        Stock("Thick Double", .make(a: 12, b: -12, delayA: 18, delayB: 32, mix: 45, lowCut: 120,
                               modDepth: 15, modRate: 0.4)),
        Stock("Wide Chorus", .make(a: 7, b: -7, delayA: 10, delayB: 14, mix: 50, tone: 20,
                              modDepth: 50, modRate: 0.8)),
        Stock("Pitch Slap", .make(a: 15, b: -15, delayA: 110, delayB: 160, mix: 35, feedback: 20,
                             tone: -20, lowCut: 150)),
        Stock("Rising Repeats", .make(a: 25, b: 0, delayA: 375, delayB: 500, mix: 30, feedback: 60,
                                 pitchMix: 0, lowCut: 200, tempoSync: true,
                                 noteA: .dottedEighth, noteB: .quarter)),
    ]

    private static func make(a: Float, b: Float, delayA: Float, delayB: Float, mix: Float,
                             feedback: Float = 0, pitchMix: Float = 50, tone: Float = 0,
                             lowCut: Float = 20, modDepth: Float = 0, modRate: Float = 0.5,
                             tempoSync: Bool = false, noteA: NoteDivision = .eighth,
                             noteB: NoteDivision = .dottedEighth) -> MicroDetuneParams {
        var p = MicroDetuneParams()
        p.pitchA = a; p.pitchB = b; p.delayA = delayA; p.delayB = delayB; p.mix = mix
        p.feedback = feedback; p.pitchMix = pitchMix; p.tone = tone; p.lowCut = lowCut
        p.modDepth = modDepth; p.modRate = modRate
        p.tempoSync = tempoSync; p.noteA = noteA; p.noteB = noteB
        return p
    }
}

// MARK: - Pitch Guide parameters

enum PitchScale: String, Codable, CaseIterable, Identifiable {
    case chromatic, major, naturalMinor, harmonicMinor, melodicMinor
    case dorian, mixolydian, majorPentatonic, minorPentatonic, blues
    case phrygian, lydian, locrian

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .chromatic:       "Chromatic"
        case .major:           "Major"
        case .naturalMinor:    "Natural Minor"
        case .harmonicMinor:   "Harmonic Minor"
        case .melodicMinor:    "Melodic Minor"
        case .dorian:          "Dorian"
        case .mixolydian:      "Mixolydian"
        case .majorPentatonic: "Major Pentatonic"
        case .minorPentatonic: "Minor Pentatonic"
        case .blues:           "Blues"
        case .phrygian:        "Phrygian"
        case .lydian:          "Lydian"
        case .locrian:         "Locrian"
        }
    }

    /// The pitch scale matching a song's key scale
    init(_ scale: MusicalScale) {
        switch scale {
        case .major:           self = .major
        case .minor:           self = .naturalMinor
        case .harmonicMinor:   self = .harmonicMinor
        case .melodicMinor:    self = .melodicMinor
        case .majorPentatonic: self = .majorPentatonic
        case .minorPentatonic: self = .minorPentatonic
        case .blues:           self = .blues
        case .dorian:          self = .dorian
        case .phrygian:        self = .phrygian
        case .lydian:          self = .lydian
        case .mixolydian:      self = .mixolydian
        case .locrian:         self = .locrian
        }
    }
}

enum VoiceRange: String, Codable, CaseIterable, Identifiable {
    case low, mid, high

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .low:  "Low (70–400 Hz)"
        case .mid:  "Mid (120–800 Hz)"
        case .high: "High (180–1200 Hz)"
        }
    }

    var minHz: Float {
        switch self { case .low: 70; case .mid: 120; case .high: 180 }
    }

    var maxHz: Float {
        switch self { case .low: 400; case .mid: 800; case .high: 1200 }
    }
}

extension PitchScale {
    /// Semitones above the key that belong to the scale
    var intervals: [Int] {
        switch self {
        case .chromatic:       Array(0..<12)
        case .major:           [0, 2, 4, 5, 7, 9, 11]
        case .naturalMinor:    [0, 2, 3, 5, 7, 8, 10]
        case .harmonicMinor:   [0, 2, 3, 5, 7, 8, 11]
        case .melodicMinor:    [0, 2, 3, 5, 7, 9, 11]
        case .dorian:          [0, 2, 3, 5, 7, 9, 10]
        case .mixolydian:      [0, 2, 4, 5, 7, 9, 10]
        case .majorPentatonic: [0, 2, 4, 7, 9]
        case .minorPentatonic: [0, 3, 5, 7, 10]
        case .blues:           [0, 3, 5, 6, 7, 10]
        case .phrygian:        [0, 1, 3, 5, 7, 8, 10]
        case .lydian:          [0, 2, 4, 6, 7, 9, 11]
        case .locrian:         [0, 1, 3, 5, 6, 8, 10]
        }
    }
}

struct PitchGuideParams: Codable, Equatable {
    var key: Int = 0                    // 0=C … 11=B
    var scale: PitchScale = .major
    var retuneSpeed: Float = 50         // ms to land on the note, 0...400; 0 = instant (robotic)
    var tolerance: Float = 10           // cents, 0...50; deviations this small are left alone
    var amount: Float = 100             // %, 0...100; how much of the error is removed
    var humanize: Float = 0             // %, 0...100; slows retune on held notes
    var pickiness: Float = 50           // %, 0...100; higher = only clear, steady notes
    var gateThreshold: Float = -45      // dBFS, -70...-20; quieter input (bleed) is ignored
    var voiceRange: VoiceRange = .mid
    /// Use the loaded song's key and scale; `key`/`scale` are the fallback when it has none
    var songKeyDrive: Bool = true
    /// PSOLA shifting keeps the voice's character; costs one extra pitch period of latency
    var preserveFormants: Bool = true
    /// Fixed shift on top of the correction, through the same shifter (no extra latency)
    var transpose: Int = 0              // semitones, -12...12
    /// Moves the voice's resonances: + smaller/brighter, − bigger/darker. On top of the
    /// automatic preservation, or on top of the pitch shift when that's off.
    var formantShift: Float = 0         // semitones, -6...6
    /// Transpose and Formant switch off between phrases, so bleed in the gaps isn't shifted
    var shiftOnlyWhileSinging: Bool = true
    /// How far to turn the mic down between phrases; 0 = off
    var bleedDuck: Float = 0            // dB, -20...0
    /// Balance between processed and dry signal; 100 = fully processed, 0 = bypass
    var wetMix: Float = 100             // %, 0...100
    /// Saved after Retune Speed came to mean time to land (like Auto-Tune) rather than the
    /// glide's time constant. Missing on older saves, whose speeds are scaled to match.
    var retuneSpeedLands: Bool = true

    init() {}

    // Decode missing keys as defaults so slots saved by the placeholder version still load
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = PitchGuideParams()
        key = try c.decodeIfPresent(Int.self, forKey: .key) ?? d.key
        scale = (try? c.decodeIfPresent(PitchScale.self, forKey: .scale)) ?? d.scale
        retuneSpeed = try c.decodeIfPresent(Float.self, forKey: .retuneSpeed) ?? d.retuneSpeed
        // Older saves stored the time constant; landing takes about 3× that, so keep their sound
        if try c.decodeIfPresent(Bool.self, forKey: .retuneSpeedLands) != true,
           c.contains(.retuneSpeed) {
            retuneSpeed = min(400, retuneSpeed * 3)
        }
        tolerance = try min(50, c.decodeIfPresent(Float.self, forKey: .tolerance) ?? d.tolerance)
        amount = try c.decodeIfPresent(Float.self, forKey: .amount) ?? d.amount
        humanize = try c.decodeIfPresent(Float.self, forKey: .humanize) ?? d.humanize
        pickiness = try c.decodeIfPresent(Float.self, forKey: .pickiness) ?? d.pickiness
        gateThreshold = try c.decodeIfPresent(Float.self, forKey: .gateThreshold) ?? d.gateThreshold
        voiceRange = (try? c.decodeIfPresent(VoiceRange.self, forKey: .voiceRange)) ?? d.voiceRange
        songKeyDrive = try c.decodeIfPresent(Bool.self, forKey: .songKeyDrive) ?? d.songKeyDrive
        preserveFormants = try c.decodeIfPresent(Bool.self, forKey: .preserveFormants) ?? d.preserveFormants
        transpose = try c.decodeIfPresent(Int.self, forKey: .transpose) ?? d.transpose
        formantShift = try c.decodeIfPresent(Float.self, forKey: .formantShift) ?? d.formantShift
        shiftOnlyWhileSinging = try c.decodeIfPresent(Bool.self, forKey: .shiftOnlyWhileSinging) ?? d.shiftOnlyWhileSinging
        bleedDuck = try c.decodeIfPresent(Float.self, forKey: .bleedDuck) ?? d.bleedDuck
        wetMix = try c.decodeIfPresent(Float.self, forKey: .wetMix) ?? d.wetMix
    }

    /// These params with the correction's key and scale taken from the song, when following
    /// it and it has a key. Only the correction follows the song; Transpose is untouched.
    func resolved(songKey: MusicalKey?) -> PitchGuideParams {
        guard songKeyDrive, let songKey, let pc = songKey.pitchClass else { return self }
        var p = self
        p.key = ((pc % 12) + 12) % 12
        p.scale = PitchScale(songKey.scale)
        return p
    }

    /// 12-bit mask of the pitch classes the singer is snapped to (bit 0 = C). `key` is the
    /// key they sing in; Transpose then moves the corrected voice (sung in D, +2 → heard in E).
    var allowedPitchClassMask: UInt32 {
        scale.intervals.reduce(0) { $0 | (1 << UInt32((key + $1) % 12)) }
    }
}

extension PitchGuideParams {
    static let noteNames = ["C","C#","D","D#","E","F","F#","G","G#","A","A#","B"]
    var keyName: String { PitchGuideParams.noteNames[key % 12] }
}

// MARK: - FX slot

struct ChannelFXSlot: Codable, Equatable {
    var type: BuiltInFXType? = nil
    var isBypassed: Bool = false
    var gain: GainParams = .init()
    var eq: EQ3BandParams = .init()
    var reverb: ReverbParams = .init()
    var delay: DelayParams = .init()
    var levelRider: LevelRiderParams = .init()
    var optoComp: OptoCompParams = .init()
    var fetComp: FETCompParams = .init()
    var feedbackNotch: FeedbackNotchParams = .init()
    var pitchGuide: PitchGuideParams = .init()
    var microDetune: MicroDetuneParams = .init()
    var harmony: HarmonyParams = .init()

    init() {}

    // Decode missing keys as defaults so channels saved before a new effect existed still load
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try? c.decodeIfPresent(BuiltInFXType.self, forKey: .type)
        isBypassed = try c.decodeIfPresent(Bool.self, forKey: .isBypassed) ?? false
        gain = try c.decodeIfPresent(GainParams.self, forKey: .gain) ?? .init()
        eq = try c.decodeIfPresent(EQ3BandParams.self, forKey: .eq) ?? .init()
        reverb = try c.decodeIfPresent(ReverbParams.self, forKey: .reverb) ?? .init()
        delay = try c.decodeIfPresent(DelayParams.self, forKey: .delay) ?? .init()
        levelRider = try c.decodeIfPresent(LevelRiderParams.self, forKey: .levelRider) ?? .init()
        optoComp = try c.decodeIfPresent(OptoCompParams.self, forKey: .optoComp) ?? .init()
        fetComp = try c.decodeIfPresent(FETCompParams.self, forKey: .fetComp) ?? .init()
        feedbackNotch = try c.decodeIfPresent(FeedbackNotchParams.self, forKey: .feedbackNotch) ?? .init()
        pitchGuide = try c.decodeIfPresent(PitchGuideParams.self, forKey: .pitchGuide) ?? .init()
        microDetune = try c.decodeIfPresent(MicroDetuneParams.self, forKey: .microDetune) ?? .init()
        harmony = try c.decodeIfPresent(HarmonyParams.self, forKey: .harmony) ?? .init()
    }
}

// MARK: - Output route

/// Where a channel's signal leaves the interface: one hardware output (mono — the channel is
/// summed to mono) or a pair starting at `channel` (stereo — left on `channel`, right on the next).
struct OutputRoute: Codable, Hashable {
    var channel: Int = 0        // 0-based hardware output
    var stereo: Bool = true

    var label: String { stereo ? "Out \(channel + 1)–\(channel + 2)" : "Out \(channel + 1)" }
}

// MARK: - Channel macro (named preset for one channel)

struct ChannelMacro: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String = "Preset"
    var slots: [ChannelFXSlot] = Array(repeating: ChannelFXSlot(), count: 6)
    var output: OutputRoute = .init()
    var volume: Float = 1.0
    var isMuted: Bool = false
}

// MARK: - Audio channel

struct AudioChannel: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String = ""
    /// 0-based hardware input channel on the interface
    var inputIndex: Int = 0
    /// When true, input inputIndex+1 is also routed through this channel's FX chain (stereo pair)
    var isStereoLinked: Bool = false
    var output: OutputRoute = .init()
    var volume: Float = 1.0
    var isMuted: Bool = false
    var slots: [ChannelFXSlot] = Array(repeating: ChannelFXSlot(), count: 6)
    var macros: [ChannelMacro] = []

    var displayName: String { name.isEmpty ? "Input \(inputIndex + 1)" : name }
}

// Saves from before mono outputs stored `outputBus` (a stereo pair index); read it as that
// pair. Kept in extensions so the memberwise initialisers stay available.
private enum LegacyOutputKeys: String, CodingKey { case outputBus }

private func decodeOutput<K: CodingKey>(_ c: KeyedDecodingContainer<K>, key: K,
                                         decoder: Decoder) throws -> OutputRoute {
    if let route = try c.decodeIfPresent(OutputRoute.self, forKey: key) { return route }
    let legacy = try decoder.container(keyedBy: LegacyOutputKeys.self)
    let pair = try legacy.decodeIfPresent(Int.self, forKey: .outputBus) ?? 0
    return OutputRoute(channel: pair * 2, stereo: true)
}

extension ChannelMacro {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Preset"
        slots = try c.decodeIfPresent([ChannelFXSlot].self, forKey: .slots) ?? Array(repeating: ChannelFXSlot(), count: 6)
        output = try decodeOutput(c, key: .output, decoder: decoder)
        volume = try c.decodeIfPresent(Float.self, forKey: .volume) ?? 1
        isMuted = try c.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false
    }
}

extension AudioChannel {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        inputIndex = try c.decodeIfPresent(Int.self, forKey: .inputIndex) ?? 0
        isStereoLinked = try c.decodeIfPresent(Bool.self, forKey: .isStereoLinked) ?? false
        output = try decodeOutput(c, key: .output, decoder: decoder)
        volume = try c.decodeIfPresent(Float.self, forKey: .volume) ?? 1
        isMuted = try c.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false
        slots = try c.decodeIfPresent([ChannelFXSlot].self, forKey: .slots) ?? Array(repeating: ChannelFXSlot(), count: 6)
        macros = try c.decodeIfPresent([ChannelMacro].self, forKey: .macros) ?? []
    }
}

// MARK: - Reverb preset names (matches AVAudioUnitReverbPreset rawValues 0-12)

extension ReverbParams {
    static let presetNames = [
        "Small Room", "Medium Room", "Large Room",
        "Medium Hall", "Large Hall", "Plate",
        "Medium Chamber", "Large Chamber", "Cathedral",
        "Large Room 2", "Medium Hall 2", "Medium Hall 3", "Large Hall 2"
    ]

    var presetName: String {
        ReverbParams.presetNames.indices.contains(roomPreset)
            ? ReverbParams.presetNames[roomPreset] : "Unknown"
    }
}
