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
    case gain, eq3Band, reverb, delay, levelRider, optoComp, fetComp, feedbackNotch, pitchGuide

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
    var retuneSpeed: Float = 50         // ms, 0...400; 0 = instant (robotic)
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

    init() {}

    // Decode missing keys as defaults so slots saved by the placeholder version still load
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = PitchGuideParams()
        key = try c.decodeIfPresent(Int.self, forKey: .key) ?? d.key
        scale = (try? c.decodeIfPresent(PitchScale.self, forKey: .scale)) ?? d.scale
        retuneSpeed = try c.decodeIfPresent(Float.self, forKey: .retuneSpeed) ?? d.retuneSpeed
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
    }

    /// These params with key and scale taken from the song, when following it and it has a key
    func resolved(songKey: MusicalKey?) -> PitchGuideParams {
        guard songKeyDrive, let songKey, let pc = songKey.pitchClass else { return self }
        var p = self
        p.key = ((pc % 12) + 12) % 12
        p.scale = PitchScale(songKey.scale)
        return p
    }

    /// 12-bit mask of the pitch classes the *input* is snapped to (bit 0 = C). Offset by
    /// the transpose so that after transposing, the output lands in key + scale.
    var allowedPitchClassMask: UInt32 {
        let root = ((key - transpose) % 12 + 12) % 12
        return scale.intervals.reduce(0) { $0 | (1 << UInt32((root + $1) % 12)) }
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
    }
}

// MARK: - Channel macro (named preset for one channel)

struct ChannelMacro: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String = "Preset"
    var slots: [ChannelFXSlot] = Array(repeating: ChannelFXSlot(), count: 4)
    var outputBus: Int = 0
    var volume: Float = 1.0
    var isMuted: Bool = false
}

// MARK: - Audio channel

struct AudioChannel: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String = ""
    /// 0-based mono hardware input bus index on AVAudioEngine.inputNode
    var inputIndex: Int = 0
    /// When true, bus inputIndex+1 is also routed through this channel's FX chain (stereo pair)
    var isStereoLinked: Bool = false
    var outputBus: Int = 0
    var volume: Float = 1.0
    var isMuted: Bool = false
    var slots: [ChannelFXSlot] = Array(repeating: ChannelFXSlot(), count: 4)
    var macros: [ChannelMacro] = []

    var displayName: String { name.isEmpty ? "Input \(inputIndex + 1)" : name }
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
