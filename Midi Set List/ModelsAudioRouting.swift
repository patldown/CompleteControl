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
    case gain, eq3Band, reverb, delay, levelRider, optoComp, fetComp, pitchGuide

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

// MARK: - Pitch Guide parameters

enum PitchScale: String, Codable, CaseIterable, Identifiable {
    case chromatic, major, naturalMinor, harmonicMinor, melodicMinor
    case dorian, mixolydian, majorPentatonic, minorPentatonic, blues

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
}

struct PitchGuideParams: Codable, Equatable {
    var key: Int = 0                    // 0=C … 11=B
    var scale: PitchScale = .major
    var retuneSpeed: Float = 100        // ms, 0...400
    var tolerance: Float = 25           // cents, 0...100
    var voiceRange: VoiceRange = .mid
    var mix: Float = 100                // %, 0...100
    var songKeyDrive: Bool = false
    var songKey: Int = 0
    var songScale: PitchScale = .major
}

extension PitchGuideParams {
    static let noteNames = ["C","C#","D","D#","E","F","F#","G","G#","A","A#","B"]
    var keyName: String { PitchGuideParams.noteNames[key % 12] }
    var songKeyName: String { PitchGuideParams.noteNames[songKey % 12] }
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
