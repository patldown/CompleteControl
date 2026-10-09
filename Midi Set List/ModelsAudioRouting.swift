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
    case gain, eq3Band, reverb, delay, levelRider, optoComp, fetComp, feedbackNotch, pitchGuide, microDetune, harmony,
         piezoBody, tone, warmth, air, punch, smartGate, makeRoom

    // reverb and delay kept in enum for JSON backward-compat but are no longer available;
    // the load() migration clears any saved slots of these types.
    static var allCases: [BuiltInFXType] {
        [.tone, .gain, .eq3Band, .makeRoom, .smartGate, .levelRider, .optoComp, .fetComp, .punch, .warmth, .air,
         .feedbackNotch, .pitchGuide, .harmony, .microDetune, .piezoBody]
    }

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .gain:       "Gain / Pan"
        case .eq3Band:    "3-Band EQ"
        case .reverb:     "Reverb"
        case .delay:      "Delay"
        case .levelRider: "Level Rider"
        case .optoComp:   "Compressor – Smooth (LA-2A style)"
        case .fetComp:    "Compressor – Punchy (1176 style)"
        case .feedbackNotch: "Feedback Notch"
        case .pitchGuide: "Pitch Guide"
        case .microDetune: "Micro Detune (widener)"
        case .harmony:    "Harmony (key-aware)"
        case .piezoBody:  "Piezo Body (acoustic pickup)"
        case .tone:       "Tone (instrument)"
        case .warmth:     "Warmth (tape / tube)"
        case .air:        "Air (exciter)"
        case .punch:      "Punch (transient shaper)"
        case .smartGate:  "Smart Gate"
        case .makeRoom:   "Make Room (unmask)"
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
        case .piezoBody:  "guitars"
        case .tone:       "wand.and.rays"
        case .warmth:     "flame"
        case .air:        "wind"
        case .punch:      "burst"
        case .smartGate:  "door.left.hand.closed"
        case .makeRoom:   "rectangle.split.2x1"
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
    // Defaults are the Steady style
    var maxCut: Float = -9          // dB, -18...0
    var maxBoost: Float = 4         // dB, 0...+9
    var cutSpeed: Float = 80        // ms, 20...300  (how fast to cut)
    var boostSpeed: Float = 600     // ms, 200...2000 (how fast to boost)
    var gateThreshold: Float = -50  // dBFS, -60...-20; below this, gain freezes
    var outputTrim: Float = 0       // dB, -12...+12; applied after rider
    /// Show every slider instead of the Style choice
    var custom: Bool = false

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = LevelRiderParams()
        inputTrim = try c.decodeIfPresent(Float.self, forKey: .inputTrim) ?? d.inputTrim
        targetLevel = try c.decodeIfPresent(Float.self, forKey: .targetLevel) ?? d.targetLevel
        maxCut = try c.decodeIfPresent(Float.self, forKey: .maxCut) ?? d.maxCut
        maxBoost = try c.decodeIfPresent(Float.self, forKey: .maxBoost) ?? d.maxBoost
        cutSpeed = try c.decodeIfPresent(Float.self, forKey: .cutSpeed) ?? d.cutSpeed
        boostSpeed = try c.decodeIfPresent(Float.self, forKey: .boostSpeed) ?? d.boostSpeed
        gateThreshold = try c.decodeIfPresent(Float.self, forKey: .gateThreshold) ?? d.gateThreshold
        outputTrim = try c.decodeIfPresent(Float.self, forKey: .outputTrim) ?? d.outputTrim
        // Saved before the styles: hand-set values stay exact, shown as sliders
        custom = try c.decodeIfPresent(Bool.self, forKey: .custom) ?? !matchesStyle
    }

    /// How hard it rides the level
    enum Style: CaseIterable, Identifiable {
        case gentle, steady, firm
        var id: Self { self }

        var name: String {
            switch self { case .gentle: "Gentle"; case .steady: "Steady"; case .firm: "Firm" }
        }

        var sound: String {
            switch self {
            case .gentle: "Evens out big jumps only. You'll barely notice it."
            case .steady: "Keeps the voice at an even level, line to line."
            case .firm:   "Always right up front. Quiet words come up fast."
            }
        }

        var maxCut: Float { switch self { case .gentle: -6; case .steady: -9; case .firm: -12 } }
        var maxBoost: Float { switch self { case .gentle: 3; case .steady: 4; case .firm: 6 } }
        var cutSpeed: Float { switch self { case .gentle: 150; case .steady: 80; case .firm: 40 } }
        var boostSpeed: Float { switch self { case .gentle: 1200; case .steady: 600; case .firm: 400 } }
    }

    /// The style these values match, or nil
    var style: Style? {
        get {
            Style.allCases.first {
                $0.maxCut == maxCut && $0.maxBoost == maxBoost
                    && $0.cutSpeed == cutSpeed && $0.boostSpeed == boostSpeed
            }
        }
        set {
            guard let newValue else { return }
            maxCut = newValue.maxCut; maxBoost = newValue.maxBoost
            cutSpeed = newValue.cutSpeed; boostSpeed = newValue.boostSpeed
        }
    }

    /// The style describes everything not shown beside it (Target and Gate are shown)
    var matchesStyle: Bool { style != nil && inputTrim == 0 && outputTrim == 0 }

    /// Moves to the nearest style, trims back to 0 (leaving Custom)
    mutating func snapToStyle() {
        let nearest = Style.allCases.min {
            abs($0.cutSpeed - cutSpeed) / 110 + abs($0.maxCut - maxCut) / 6
                < abs($1.cutSpeed - cutSpeed) / 110 + abs($1.maxCut - maxCut) / 6
        }
        style = nearest
        inputTrim = 0; outputTrim = 0
        custom = false
    }
}

// MARK: - Compressor parameters

/// LA-2A style: two knobs and a Compress/Limit switch.
struct OptoCompParams: Codable, Equatable {
    // Defaults are Medium
    var peakReduction: Float = 68   // 0...100; higher = more compression
    var gain: Float = 5             // dB makeup, 0...40
    var limitMode: Bool = false     // false = Compress (~3:1), true = Limit (~10:1)
    /// Show the knobs instead of the Amount choice
    var custom: Bool = false

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        peakReduction = try c.decodeIfPresent(Float.self, forKey: .peakReduction) ?? 40
        gain = try c.decodeIfPresent(Float.self, forKey: .gain) ?? 6
        limitMode = try c.decodeIfPresent(Bool.self, forKey: .limitMode) ?? false
        // Saved before the choices: keep the exact values, shown as knobs unless they match one
        custom = try c.decodeIfPresent(Bool.self, forKey: .custom) ?? (amount == nil)
    }

    var amount: CompressionAmount? {
        get {
            CompressionAmount.allCases.first {
                let o = $0.opto
                return o.peakReduction == peakReduction && o.gain == gain && o.limit == limitMode
            }
        }
        set {
            guard let o = newValue?.opto else { return }
            peakReduction = o.peakReduction; gain = o.gain; limitMode = o.limit
        }
    }

    mutating func snapToAmount() {
        amount = CompressionAmount.allCases.min {
            abs($0.opto.peakReduction - peakReduction) < abs($1.opto.peakReduction - peakReduction)
        }
        custom = false
    }
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
    // Defaults are Medium
    var input: Float = 6            // dB, 0...48
    var output: Float = 2           // dB, -24...+12
    var ratio: Ratio = .r8
    var attack: Float = 3           // 1 (slow, 800 µs) ... 7 (fast, 20 µs)
    var release: Float = 5          // 1 (slow, 1.1 s) ... 7 (fast, 50 ms)
    /// Show the knobs instead of the Amount choice
    var custom: Bool = false

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        input = try c.decodeIfPresent(Float.self, forKey: .input) ?? 6
        output = try c.decodeIfPresent(Float.self, forKey: .output) ?? 0
        ratio = (try? c.decodeIfPresent(Ratio.self, forKey: .ratio)) ?? .r4
        attack = try c.decodeIfPresent(Float.self, forKey: .attack) ?? 3
        release = try c.decodeIfPresent(Float.self, forKey: .release) ?? 5
        custom = try c.decodeIfPresent(Bool.self, forKey: .custom) ?? (amount == nil)
    }

    var amount: CompressionAmount? {
        get {
            CompressionAmount.allCases.first {
                let f = $0.fet
                return f.input == input && f.output == output && f.ratio == ratio
                    && f.attack == attack && f.release == release
            }
        }
        set {
            guard let f = newValue?.fet else { return }
            input = f.input; output = f.output; ratio = f.ratio; attack = f.attack; release = f.release
        }
    }

    mutating func snapToAmount() {
        amount = CompressionAmount.allCases.min { abs($0.fet.input - input) < abs($1.fet.input - input) }
        custom = false
    }
}

/// A compressor following other channels instead of its own: this channel is turned down
/// when they play (kick → bass, vocals → backing track). Off by default; under Custom Values.
struct SidechainParams: Codable, Equatable {
    var enabled = false
    var keyChannels: [UUID] = []
    /// Read the keys after their effects and fader (true) or as they come in (false)
    var post = false

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        keyChannels = try c.decodeIfPresent([UUID].self, forKey: .keyChannels) ?? []
        post = try c.decodeIfPresent(Bool.self, forKey: .post) ?? false
    }
}

/// The Compressor's Amount choice. Each sets its own make-up gain so the level stays
/// roughly where it was (for a voice around -18 dBFS).
enum CompressionAmount: CaseIterable, Identifiable {
    case light, medium, heavy
    var id: Self { self }

    var name: String {
        switch self { case .light: "Light"; case .medium: "Medium"; case .heavy: "Heavy" }
    }

    var sound: String {
        switch self {
        case .light:  "Just takes the edge off the loudest moments."
        case .medium: "Holds it together: a solid, even sound."
        case .heavy:  "Squashed and in your face. Every word the same level."
        }
    }

    var opto: (peakReduction: Float, gain: Float, limit: Bool) {
        switch self {
        case .light:  (56, 3, false)
        case .medium: (68, 5, false)
        case .heavy:  (83, 8, true)
        }
    }

    var fet: (input: Float, output: Float, ratio: FETCompParams.Ratio, attack: Float, release: Float) {
        switch self {
        case .light:  (0, 3, .r4, 3, 5)
        case .medium: (6, 2, .r8, 3, 5)
        case .heavy:  (12, 1, .r12, 4, 6)
        }
    }
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

// MARK: - One-knob effects

struct WarmthParams: Codable, Equatable {
    enum Character: String, Codable, CaseIterable, Identifiable {
        case tape, tube
        var id: String { rawValue }
        var displayName: String { self == .tape ? "Tape" : "Tube" }
    }
    var drive: Float = 40           // %, 0...100
    var character: Character = .tape

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        drive = try c.decodeIfPresent(Float.self, forKey: .drive) ?? 40
        character = (try? c.decodeIfPresent(Character.self, forKey: .character)) ?? .tape
    }
}

struct AirParams: Codable, Equatable {
    enum Focus: String, Codable, CaseIterable, Identifiable {
        case presence, air
        var id: String { rawValue }
        var displayName: String { self == .presence ? "Presence (3 kHz up)" : "Air (6 kHz up)" }
    }
    var amount: Float = 40          // %, 0...100
    var focus: Focus = .presence

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        amount = try c.decodeIfPresent(Float.self, forKey: .amount) ?? 40
        focus = (try? c.decodeIfPresent(Focus.self, forKey: .focus)) ?? .presence
    }
}

struct PunchParams: Codable, Equatable {
    var amount: Float = 0           // -100 (softer attack, more sustain) ... +100 (more attack)

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        amount = try c.decodeIfPresent(Float.self, forKey: .amount) ?? 0
    }
}

struct SmartGateParams: Codable, Equatable {
    var sensitivity: Float = 50     // %, 0...100; higher gates more
    var depth: Float = 40           // dB the gate turns down when closed, 0...80
    /// "Opens For: Singing": only open for singing, so loud bleed between phrases stays down.
    /// Named for the Pitch Guide setting it replaced.
    var bleedDuck: Bool = false

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sensitivity = try c.decodeIfPresent(Float.self, forKey: .sensitivity) ?? 50
        depth = try c.decodeIfPresent(Float.self, forKey: .depth) ?? 40
        bleedDuck = try c.decodeIfPresent(Bool.self, forKey: .bleedDuck) ?? false
    }
}

// MARK: - Make Room (sidechain unmasking)

/// Steps this channel aside, gently and only while they play, in the bands where the
/// chosen channels (usually the singers) need to be heard
struct MakeRoomParams: Codable, Equatable {
    /// The channels to make room for
    var keyChannels: [UUID] = []
    var amount: Amount = .subtle

    enum Amount: String, Codable, CaseIterable, Identifiable {
        case subtle, clear
        var id: Self { self }
        var name: String { self == .subtle ? "Subtle" : "Clear" }
        var sound: String {
            self == .subtle
                ? "A gentle step aside. You'll hear the singer more than the change."
                : "A clear gap for the singer in a busy mix."
        }
        /// Deepest dip in any band, dB
        var maxCutDB: Float { self == .subtle ? 2 : 4 }
    }

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        keyChannels = try c.decodeIfPresent([UUID].self, forKey: .keyChannels) ?? []
        amount = (try? c.decodeIfPresent(Amount.self, forKey: .amount)) ?? .subtle
    }

    /// How much each Make Room band (125 Hz … 8 kHz, octaves) matters to a key, from its
    /// Tone instrument; nil = no instrument set, so a general voice-and-instrument middle
    static func bandWeights(for instrument: ToneInstrument?) -> [Float] {
        //                     125  250  500   1k   2k   4k   8k
        guard let instrument else { return [0.2, 0.5, 0.7, 0.8, 0.8, 0.7, 0.4] }
        switch instrument {
        case .leadVocal:      return [0.0, 0.2, 0.5, 0.9, 1.0, 1.0, 0.5]
        case .backingVocal:   return [0.0, 0.2, 0.4, 0.7, 0.8, 0.7, 0.4]
        case .acousticGuitar: return [0.2, 0.6, 0.8, 0.8, 0.7, 0.6, 0.3]
        case .electricGuitar: return [0.1, 0.5, 0.8, 1.0, 0.8, 0.5, 0.2]
        case .bass:           return [1.0, 0.8, 0.5, 0.3, 0.1, 0.0, 0.0]
        case .keys:           return [0.3, 0.6, 0.8, 0.8, 0.6, 0.4, 0.2]
        case .synth:          return [0.4, 0.6, 0.7, 0.7, 0.6, 0.5, 0.4]
        case .kick:           return [1.0, 0.6, 0.2, 0.0, 0.0, 0.4, 0.0]
        case .snare:          return [0.0, 0.6, 0.5, 0.2, 0.3, 0.6, 0.4]
        case .drumKit:        return [0.8, 0.5, 0.3, 0.2, 0.3, 0.5, 0.5]
        }
    }
}

extension AudioChannel {
    /// Its first active Tone: Make Room listens to the channel through it
    var listeningToneIndex: Int? {
        slots.firstIndex { $0.type == .tone && !$0.isBypassed }
    }

    /// The instrument that Tone is set to, if any
    var toneInstrument: ToneInstrument? {
        listeningToneIndex.flatMap { slots[$0].tone.instrument }
    }
}

// MARK: - Tone (instrument-aware one-button sound)

/// What a Tone effect shapes the sound for
nonisolated enum ToneInstrument: Int, Codable, CaseIterable, Identifiable {
    case leadVocal = 0, backingVocal, acousticGuitar, electricGuitar, bass, keys, synth, kick, snare, drumKit

    var id: Int { rawValue }

    var displayName: String {
        switch self {
        case .leadVocal:      "Lead Vocal"
        case .backingVocal:   "Backing Vocal"
        case .acousticGuitar: "Acoustic Guitar"
        case .electricGuitar: "Electric Guitar"
        case .bass:           "Bass"
        case .keys:           "Keys / Piano"
        case .synth:          "Synth"
        case .kick:           "Kick"
        case .snare:          "Snare"
        case .drumKit:        "Drum Kit / Overheads"
        }
    }

    var shortName: String {
        switch self {
        case .leadVocal:      "Lead"
        case .backingVocal:   "BGV"
        case .acousticGuitar: "Acoustic"
        case .electricGuitar: "Electric"
        case .bass:           "Bass"
        case .keys:           "Keys"
        case .synth:          "Synth"
        case .kick:           "Kick"
        case .snare:          "Snare"
        case .drumKit:        "Kit"
        }
    }

    var icon: String {
        switch self {
        case .leadVocal:      "🎤"
        case .backingVocal:   "🎙️"
        case .acousticGuitar, .electricGuitar, .bass: "🎸"
        case .keys:           "🎹"
        case .synth:          "🎛️"
        case .kick, .snare, .drumKit: "🥁"
        }
    }

    /// What Tone does for it, in words (shown in the editor)
    var toneDescription: String {
        switch self {
        case .leadVocal:      "Cuts rumble and mud, adds presence and air, smooths level and tames sibilance."
        case .backingVocal:   "Thinner and further back than a lead: more low cut, less presence, firmer level, de-essed."
        case .acousticGuitar: "Cuts boom and boxiness, adds sparkle, gently evens out strumming."
        case .electricGuitar: "Cuts mud and fizz, pushes the mids that cut through a band."
        case .bass:           "Firms the lows, clears mud, adds growl for definition, steadies level."
        case .keys:           "Clears low-mid clutter and adds a little clarity."
        case .synth:          "Light clean-up: tidies the low mids and opens the top."
        case .kick:           "Adds thump and beater click, scoops the cardboard mids, tight compression."
        case .snare:          "Adds body and crack, cuts the boxy ring."
        case .drumKit:        "Cuts low thud and boxiness from overheads, adds cymbal shimmer."
        }
    }

    /// Target tonal balance in octave bands at 125, 250, 500, 1k, 2k, 4k and 8k Hz, in dB
    /// relative to pink noise (only the shape matters). Adaptive Tone corrects toward it.
    var balance: (Double, Double, Double, Double, Double, Double, Double) {
        switch self {
        case .leadVocal:      (-8, -1, 2, 2, 1, -1, -6)
        case .backingVocal:   (-10, -3, 1, 2, 2, 0, -5)
        case .acousticGuitar: (-4, -1, 0, 1, 1, 0, -3)
        case .electricGuitar: (-6, -1, 2, 3, 1, -3, -10)
        case .bass:           (6, 3, 0, -3, -6, -10, -16)
        case .keys:           (-2, 0, 1, 0, -1, -2, -5)
        case .synth:          (0, 0, 0, 0, -1, -2, -4)
        case .kick:           (8, 2, -6, -6, -3, -2, -8)
        case .snare:          (-6, 2, 0, -1, 0, 0, -3)
        case .drumKit:        (-6, -3, -2, -1, 0, 1, 1)
        }
    }

    /// Compressor threshold above the running average level, dB: lower = more leveling
    var compOverAverageDB: Double {
        switch self {
        case .leadVocal:      6
        case .backingVocal:   4
        case .acousticGuitar, .electricGuitar: 8
        case .bass:           6
        case .keys, .synth:   10
        case .kick, .snare:   8
        case .drumKit:        10
        }
    }

    /// Full-Amount settings: the most each EQ move may do (adaptive Tone applies only what's needed)
    var profile: ToneProfile {
        typealias B = ToneProfile.Band
        switch self {
        case .leadVocal:
            return ToneProfile(highPass: 90, bands: (B(kind: .peak, freq: 250, q: 1.0, db: -3),
                                                    B(kind: .peak, freq: 1_000, q: 1.5, db: -1),
                                                    B(kind: .peak, freq: 3_200, q: 1.0, db: 3),
                                                    B(kind: .highShelf, freq: 10_000, q: 0.7, db: 2.5)),
                               compRatio: 3, compThreshold: -22, compAttackMs: 5, compReleaseMs: 120, deEss: true)
        case .backingVocal:
            return ToneProfile(highPass: 130, bands: (B(kind: .peak, freq: 250, q: 1.0, db: -4),
                                                     B(kind: .peak, freq: 1_000, q: 1.5, db: -1),
                                                     B(kind: .peak, freq: 3_200, q: 1.0, db: 2),
                                                     B(kind: .highShelf, freq: 10_000, q: 0.7, db: 2)),
                               compRatio: 4, compThreshold: -24, compAttackMs: 5, compReleaseMs: 120, deEss: true)
        case .acousticGuitar:
            return ToneProfile(highPass: 80, bands: (B(kind: .peak, freq: 220, q: 1.2, db: -3),
                                                    B(kind: .peak, freq: 1_200, q: 1.5, db: -1.5),
                                                    B(kind: .peak, freq: 5_000, q: 1.0, db: 2.5),
                                                    B(kind: .highShelf, freq: 12_000, q: 0.7, db: 2)),
                               compRatio: 2.5, compThreshold: -20, compAttackMs: 10, compReleaseMs: 150, deEss: false)
        case .electricGuitar:
            return ToneProfile(highPass: 90, bands: (B(kind: .peak, freq: 300, q: 1.0, db: -2),
                                                    B(kind: .peak, freq: 800, q: 1.0, db: 1),
                                                    B(kind: .peak, freq: 2_500, q: 1.2, db: 2),
                                                    B(kind: .highShelf, freq: 7_000, q: 0.7, db: -3)),
                               compRatio: 2, compThreshold: -18, compAttackMs: 15, compReleaseMs: 150, deEss: false)
        case .bass:
            return ToneProfile(highPass: 35, bands: (B(kind: .lowShelf, freq: 100, q: 0.7, db: 2.5),
                                                    B(kind: .peak, freq: 250, q: 1.0, db: -3),
                                                    B(kind: .peak, freq: 800, q: 1.2, db: 2),
                                                    B(kind: .highShelf, freq: 5_000, q: 0.7, db: -2)),
                               compRatio: 4, compThreshold: -20, compAttackMs: 10, compReleaseMs: 200, deEss: false)
        case .keys:
            return ToneProfile(highPass: 60, bands: (B(kind: .peak, freq: 300, q: 1.0, db: -2),
                                                    B(kind: .peak, freq: 1_000, q: 1.0, db: 0),
                                                    B(kind: .peak, freq: 4_000, q: 1.0, db: 1.5),
                                                    B(kind: .highShelf, freq: 10_000, q: 0.7, db: 1.5)),
                               compRatio: 2, compThreshold: -18, compAttackMs: 15, compReleaseMs: 200, deEss: false)
        case .synth:
            return ToneProfile(highPass: 40, bands: (B(kind: .peak, freq: 250, q: 1.0, db: -1.5),
                                                    B(kind: .peak, freq: 2_000, q: 1.0, db: 0),
                                                    B(kind: .peak, freq: 5_000, q: 1.0, db: 1),
                                                    B(kind: .highShelf, freq: 12_000, q: 0.7, db: 1.5)),
                               compRatio: 1.5, compThreshold: -16, compAttackMs: 20, compReleaseMs: 200, deEss: false)
        case .kick:
            return ToneProfile(highPass: 30, bands: (B(kind: .peak, freq: 60, q: 1.2, db: 3),
                                                    B(kind: .peak, freq: 350, q: 1.0, db: -5),
                                                    B(kind: .peak, freq: 4_000, q: 1.2, db: 3),
                                                    B(kind: .highShelf, freq: 10_000, q: 0.7, db: -2)),
                               compRatio: 4, compThreshold: -18, compAttackMs: 3, compReleaseMs: 80, deEss: false)
        case .snare:
            return ToneProfile(highPass: 80, bands: (B(kind: .peak, freq: 200, q: 1.2, db: 2),
                                                    B(kind: .peak, freq: 500, q: 1.2, db: -3),
                                                    B(kind: .peak, freq: 5_000, q: 1.0, db: 2.5),
                                                    B(kind: .highShelf, freq: 10_000, q: 0.7, db: 1)),
                               compRatio: 3, compThreshold: -18, compAttackMs: 3, compReleaseMs: 100, deEss: false)
        case .drumKit:
            return ToneProfile(highPass: 120, bands: (B(kind: .peak, freq: 400, q: 1.0, db: -2.5),
                                                     B(kind: .peak, freq: 2_500, q: 1.5, db: -1),
                                                     B(kind: .peak, freq: 6_000, q: 1.0, db: 0),
                                                     B(kind: .highShelf, freq: 10_000, q: 0.7, db: 2)),
                               compRatio: 2, compThreshold: -16, compAttackMs: 5, compReleaseMs: 150, deEss: false)
        }
    }
}

struct ToneParams: Codable, Equatable {
    /// The instrument it shapes the sound for; nil = Tone does nothing
    var instrument: ToneInstrument?
    var amount: Float = 70          // %, 0...100

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ToneParams()
        instrument = try? c.decodeIfPresent(ToneInstrument.self, forKey: .instrument)
        amount = try c.decodeIfPresent(Float.self, forKey: .amount) ?? d.amount
    }
}

// MARK: - Piezo Body parameters

/// Where the guitar's body resonances sit
enum GuitarBodySize: String, Codable, CaseIterable, Identifiable {
    case parlor, dreadnought, jumbo

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .parlor:      "Parlor"
        case .dreadnought: "Dreadnought"
        case .jumbo:       "Jumbo"
        }
    }
    /// Air and top resonances, Hz
    var resonances: (Float, Float) {
        switch self {
        case .parlor:      (130, 260)
        case .dreadnought: (100, 210)
        case .jumbo:       (85, 180)
        }
    }
}

/// Acoustic pickup enhancer: body resonance back in, quack and spikiness out, one knob
struct PiezoBodyParams: Codable, Equatable {
    var amount: Float = 60          // %, 0...100
    var bodySize: GuitarBodySize = .dreadnought
    var phaseInvert = false
    var mute = false
    var level: Float = 0            // dB, -12...+6

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = PiezoBodyParams()
        amount = try c.decodeIfPresent(Float.self, forKey: .amount) ?? d.amount
        bodySize = (try? c.decodeIfPresent(GuitarBodySize.self, forKey: .bodySize)) ?? d.bodySize
        phaseInvert = try c.decodeIfPresent(Bool.self, forKey: .phaseInvert) ?? d.phaseInvert
        mute = try c.decodeIfPresent(Bool.self, forKey: .mute) ?? d.mute
        level = try c.decodeIfPresent(Float.self, forKey: .level) ?? d.level
    }
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
    /// False = muted (settings kept)
    var enabled = true
    var interval: HarmonyInterval = .thirdAbove
    var level: Float = -3           // dB, -24...+6
    var pan: Float = -40            // -100 (L) ... +100 (R)
    /// Formant shift: + smaller/brighter, − bigger/deeper; the pitch doesn't move
    var gender: Float = 0           // semitones, -6...+6

    init(enabled: Bool = true, interval: HarmonyInterval = .thirdAbove, level: Float = -3,
         pan: Float = -40, gender: Float = 0) {
        self.enabled = enabled; self.interval = interval; self.level = level
        self.pan = pan; self.gender = gender
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = HarmonyVoice()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        interval = (try? c.decodeIfPresent(HarmonyInterval.self, forKey: .interval)) ?? d.interval
        level = try c.decodeIfPresent(Float.self, forKey: .level) ?? d.level
        pan = try c.decodeIfPresent(Float.self, forKey: .pan) ?? d.pan
        gender = try c.decodeIfPresent(Float.self, forKey: .gender) ?? d.gender
    }

    var gain: Float { powf(10, level / 20) }
    /// Rate grains are read at: 2^(gender/12)
    var formantRate: Float { powf(2, max(-6, min(6, gender)) / 12) }
}

/// Key-aware harmonizer: up to three voices made from the singer, in the song's key
struct HarmonyParams: Codable, Equatable {
    var voice1 = HarmonyVoice()
    var voice2 = HarmonyVoice(enabled: false, interval: .fourthBelow, level: -3, pan: 40)
    var voice3 = HarmonyVoice(enabled: false, interval: .octaveBelow, level: -6, pan: 0)
    /// Use the loaded song's key and scale; `key`/`scale` are the fallback
    var songKeyDrive = true
    var key = 0                     // 0=C … 11=B
    var scale: PitchScale = .major
    var humanize: Float = 30        // %, 0...100; small detune, drift and delay per voice
    /// The singer's own voice in the output; at the bottom (-60) it's off = harmonies only
    var leadLevel: Float = 0        // dB, -60...+6
    var pickiness: Float = 50       // %, 0...100
    var gateThreshold: Float = -45  // dBFS, -70...-20
    var voiceRange: VoiceRange = .mid
    /// Take key and detection (the fields in `syncKeyAndDetection`) from the channel's
    /// Pitch Guide, so they're set once. Only applies when the channel has one.
    var usePitchGuide = true

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = HarmonyParams()
        voice1 = try c.decodeIfPresent(HarmonyVoice.self, forKey: .voice1) ?? d.voice1
        voice2 = try c.decodeIfPresent(HarmonyVoice.self, forKey: .voice2) ?? d.voice2
        voice3 = try c.decodeIfPresent(HarmonyVoice.self, forKey: .voice3) ?? d.voice3
        songKeyDrive = try c.decodeIfPresent(Bool.self, forKey: .songKeyDrive) ?? d.songKeyDrive
        key = try c.decodeIfPresent(Int.self, forKey: .key) ?? d.key
        scale = (try? c.decodeIfPresent(PitchScale.self, forKey: .scale)) ?? d.scale
        humanize = try c.decodeIfPresent(Float.self, forKey: .humanize) ?? d.humanize
        // The first version had an on/off Lead switch
        let oldLead = try decoder.container(keyedBy: FirstVersionKeys.self)
            .decodeIfPresent(Bool.self, forKey: .passLead)
        leadLevel = try c.decodeIfPresent(Float.self, forKey: .leadLevel)
            ?? oldLead.map { $0 ? 0 : Self.leadOff } ?? d.leadLevel
        pickiness = try c.decodeIfPresent(Float.self, forKey: .pickiness) ?? d.pickiness
        gateThreshold = try c.decodeIfPresent(Float.self, forKey: .gateThreshold) ?? d.gateThreshold
        voiceRange = (try? c.decodeIfPresent(VoiceRange.self, forKey: .voiceRange)) ?? d.voiceRange
        // Saved before the link: only link if key and detection were never changed, so a
        // hand-set Harmony keeps its own
        usePitchGuide = try c.decodeIfPresent(Bool.self, forKey: .usePitchGuide)
            ?? (songKeyDrive == d.songKeyDrive && pickiness == d.pickiness
                && gateThreshold == d.gateThreshold && voiceRange == d.voiceRange)
    }

    private enum FirstVersionKeys: String, CodingKey { case passLead }

    /// Lead Level at or below this is off
    static let leadOff: Float = -60

    /// Copies key and detection from a Pitch Guide; true if anything changed
    mutating func syncKeyAndDetection(from p: PitchGuideParams) -> Bool {
        let before = self
        songKeyDrive = p.songKeyDrive; key = p.key; scale = p.scale
        voiceRange = p.voiceRange; pickiness = p.pickiness; gateThreshold = p.gateThreshold
        return self != before
    }

    /// How much the voices drift from each other, like real singers
    enum Feel: CaseIterable, Identifiable {
        case tight, natural, loose
        var id: Self { self }
        var name: String {
            switch self { case .tight: "Tight"; case .natural: "Natural"; case .loose: "Loose" }
        }
        var sound: String {
            switch self {
            case .tight:   "Locked to the singer, like a studio double."
            case .natural: "Like real backing singers."
            case .loose:   "A loose group: each voice drifts and lags a little."
            }
        }
        var humanize: Float { switch self { case .tight: 10; case .natural: 30; case .loose: 65 } }
    }

    var feel: Feel? {
        get { Feel.allCases.first { $0.humanize == humanize } }
        set { if let newValue { humanize = newValue.humanize } }
    }

    var leadGain: Float { leadLevel <= Self.leadOff ? 0 : powf(10, leadLevel / 20) }

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
        let voice3: HarmonyVoice
        var id: String { name }

        init(_ name: String, _ voice1: HarmonyVoice,
             _ voice2: HarmonyVoice = HarmonyVoice(enabled: false, interval: .fourthBelow, level: -3, pan: 40),
             _ voice3: HarmonyVoice = HarmonyVoice(enabled: false, interval: .octaveBelow, level: -6, pan: 0)) {
            self.name = name; self.voice1 = voice1; self.voice2 = voice2; self.voice3 = voice3
        }
    }

    /// Ready-made voicings; choosing one sets the voices and leaves key, lead and detection alone
    static let stock: [Stock] = [
        Stock("3rd Above", HarmonyVoice(interval: .thirdAbove, level: -3, pan: -30)),
        Stock("3rd Below", HarmonyVoice(interval: .thirdBelow, level: -3, pan: 30)),
        Stock("3rd & 5th Above",
              HarmonyVoice(interval: .thirdAbove, level: -4, pan: -40),
              HarmonyVoice(interval: .fifthAbove, level: -6, pan: 40)),
        Stock("Trio (3rd Up, 4th Down)",
              HarmonyVoice(interval: .thirdAbove, level: -4, pan: -40),
              HarmonyVoice(interval: .fourthBelow, level: -5, pan: 40)),
        Stock("Full Stack (3rd, 5th, Octave Down)",
              HarmonyVoice(interval: .thirdAbove, level: -5, pan: -45),
              HarmonyVoice(interval: .fifthAbove, level: -7, pan: 45),
              HarmonyVoice(interval: .octaveBelow, level: -8, pan: 0, gender: -2)),
        Stock("Octave Below",
              HarmonyVoice(interval: .octaveBelow, level: -6, pan: 0)),
        Stock("Deep Octave Below",
              HarmonyVoice(interval: .octaveBelow, level: -6, pan: 0, gender: -4)),
        Stock("Octaves Up & Down",
              HarmonyVoice(interval: .octaveAbove, level: -9, pan: -25, gender: 2),
              HarmonyVoice(interval: .octaveBelow, level: -6, pan: 25, gender: -2)),
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
    // Defaults are Natural – Tight, A Little, All the Way
    var retuneSpeed: Float = 60         // ms to land on the note, 0...400; 0 = instant (robotic)
    var tolerance: Float = 10           // cents, 0...50; deviations this small are left alone
    var amount: Float = 100             // %, 0...100; how much of the error is removed
    var humanize: Float = 20            // %, 0...100; slows retune on held notes
    /// Show the four correction sliders instead of the Speed / Flex / Amount choices
    var customCorrection: Bool = false
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
    /// How far to turn the mic down between phrases; 0 = off. Superseded by Smart Gate's
    /// Bleed Duck: loading moves it there (see `moveBleedDuckToSmartGate`). Still honoured
    /// when it can't move (no free slot), and shown in the editor only then.
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
        if let custom = try c.decodeIfPresent(Bool.self, forKey: .customCorrection) {
            customCorrection = custom
        } else if retuneSpeed == 50 && tolerance == 10 && amount == 100 && humanize == 0 {
            // Saved before the choices, on the old defaults: move to the nearest choices
            snapToChoices()
        } else {
            // Hand-set before the choices: keep the exact values, shown as sliders
            customCorrection = !matchesChoices
        }
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

// MARK: - Pitch Guide: correction by description

/// How fast the voice lands on the note
enum TuneSpeed: CaseIterable, Identifiable {
    case off, naturalLoose, naturalTight, hard, exact
    var id: Self { self }

    var name: String {
        switch self {
        case .off:          "Off"
        case .naturalLoose: "Natural – Loose"
        case .naturalTight: "Natural – Tight"
        case .hard:         "Hard"
        case .exact:        "Exact"
        }
    }

    var sound: String {
        switch self {
        case .off:          "The voice as sung. No tuning."
        case .naturalLoose: "A good singer on a good night. Tuning you won't notice."
        case .naturalTight: "A polished studio vocal."
        case .hard:         "Modern pop: clearly tuned, still musical."
        case .exact:        "The robot effect. Jumps straight to each note."
        }
    }

    /// Retune Speed, ms; nil for Off
    var retuneMs: Float? {
        switch self {
        case .off:          nil
        case .naturalLoose: 150
        case .naturalTight: 60
        case .hard:         20
        case .exact:        0
        }
    }
}

/// How much of the singer's own movement (drift, vibrato, scoops) is kept
enum TuneFlex: CaseIterable, Identifiable {
    case locked, aLittle, expressive, free
    var id: Self { self }

    var name: String {
        switch self {
        case .locked:     "Locked"
        case .aLittle:    "A Little"
        case .expressive: "Expressive"
        case .free:       "Free"
        }
    }

    var sound: String {
        switch self {
        case .locked:     "Every note pinned. No wobble."
        case .aLittle:    "Small drift cleaned up; phrasing kept."
        case .expressive: "Vibrato, scoops and bends come through."
        case .free:       "Only clearly wrong notes are fixed."
        }
    }

    var tolerance: Float {
        switch self { case .locked: 0; case .aLittle: 10; case .expressive: 25; case .free: 40 }
    }

    var humanize: Float {
        switch self { case .locked: 0; case .aLittle: 20; case .expressive: 50; case .free: 80 }
    }
}

/// How far toward the note the voice is pulled
enum TuneAmount: CaseIterable, Identifiable {
    case nudge, mostly, allTheWay
    var id: Self { self }

    var name: String {
        switch self { case .nudge: "Nudge"; case .mostly: "Mostly"; case .allTheWay: "All the Way" }
    }

    var sound: String {
        switch self {
        case .nudge:     "Still clearly the singer, just safer."
        case .mostly:    "In tune, with a little character left."
        case .allTheWay: "Right on the note."
        }
    }

    var amount: Float {
        switch self { case .nudge: 40; case .mostly: 75; case .allTheWay: 100 }
    }
}

extension PitchGuideParams {
    /// The Speed choice these values match, or nil when they match none
    var tuneSpeed: TuneSpeed? {
        get {
            if amount == 0 { return .off }
            return TuneSpeed.allCases.first { $0.retuneMs == retuneSpeed }
        }
        set {
            guard let newValue else { return }
            switch newValue {
            case .off:
                amount = 0
            case .exact:
                // The robot sound needs every note pinned, all the way
                retuneSpeed = 0
                tuneFlex = .locked
                tuneAmount = .allTheWay
            default:
                retuneSpeed = newValue.retuneMs ?? retuneSpeed
                if amount == 0 { amount = TuneAmount.allTheWay.amount }
            }
        }
    }

    var tuneFlex: TuneFlex? {
        get { TuneFlex.allCases.first { $0.tolerance == tolerance && $0.humanize == humanize } }
        set {
            guard let newValue else { return }
            tolerance = newValue.tolerance
            humanize = newValue.humanize
        }
    }

    var tuneAmount: TuneAmount? {
        get { TuneAmount.allCases.first { $0.amount == amount } }
        set { if let newValue { amount = newValue.amount } }
    }

    /// Whether the choices describe these values exactly (Flex and Amount don't matter when Off)
    var matchesChoices: Bool {
        switch tuneSpeed {
        case .none:      false
        case .some(.off): true
        case .some:      tuneFlex != nil && tuneAmount != nil
        }
    }

    /// Moves each value to the nearest choice (leaving Custom)
    mutating func snapToChoices() {
        if amount > 0 {
            let speeds = TuneSpeed.allCases.filter { $0 != .off }
            let speed = speeds.min { abs(($0.retuneMs ?? 0) - retuneSpeed) < abs(($1.retuneMs ?? 0) - retuneSpeed) }
            let flex = TuneFlex.allCases.min {
                abs($0.tolerance - tolerance) / 40 + abs($0.humanize - humanize) / 80
                    < abs($1.tolerance - tolerance) / 40 + abs($1.humanize - humanize) / 80
            }
            let pull = TuneAmount.allCases.min { abs($0.amount - amount) < abs($1.amount - amount) }
            tuneFlex = flex
            tuneAmount = pull
            tuneSpeed = speed
        }
        customCorrection = false
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
    var piezoBody: PiezoBodyParams = .init()
    var tone: ToneParams = .init()
    var warmth: WarmthParams = .init()
    var air: AirParams = .init()
    var punch: PunchParams = .init()
    var smartGate: SmartGateParams = .init()
    var makeRoom: MakeRoomParams = .init()
    /// Compressor (either character) sidechain
    var sidechain: SidechainParams = .init()

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
        piezoBody = try c.decodeIfPresent(PiezoBodyParams.self, forKey: .piezoBody) ?? .init()
        tone = try c.decodeIfPresent(ToneParams.self, forKey: .tone) ?? .init()
        warmth = try c.decodeIfPresent(WarmthParams.self, forKey: .warmth) ?? .init()
        air = try c.decodeIfPresent(AirParams.self, forKey: .air) ?? .init()
        punch = try c.decodeIfPresent(PunchParams.self, forKey: .punch) ?? .init()
        smartGate = try c.decodeIfPresent(SmartGateParams.self, forKey: .smartGate) ?? .init()
        makeRoom = try c.decodeIfPresent(MakeRoomParams.self, forKey: .makeRoom) ?? .init()
        sidechain = try c.decodeIfPresent(SidechainParams.self, forKey: .sidechain) ?? .init()
    }
}

// MARK: - Harmony follows Pitch Guide

extension Array where Element == ChannelFXSlot {
    /// Each Harmony set to use the Pitch Guide's settings gets the channel's first Pitch
    /// Guide's key and detection. True if anything changed.
    @discardableResult
    mutating func syncHarmonyWithPitchGuide() -> Bool {
        guard let guide = first(where: { $0.type == .pitchGuide })?.pitchGuide else { return false }
        var changed = false
        for i in indices where self[i].type == .harmony && self[i].harmony.usePitchGuide {
            if self[i].harmony.syncKeyAndDetection(from: guide) { changed = true }
        }
        return changed
    }

    var hasPitchGuide: Bool { contains { $0.type == .pitchGuide } }
}

// MARK: - Bleed Duck migration

extension Array where Element == ChannelFXSlot {
    /// Bleed Duck used to be a Pitch Guide setting; it's now Smart Gate's "Opens For: Singing".
    /// Moves each Pitch Guide's duck to a Smart Gate: the channel's existing one if it has
    /// one, otherwise a new one right after the Pitch Guide, where the duck acted (effects
    /// shift along into a free slot, before or after). A duck with no free slot to move
    /// into stays on the Pitch Guide.
    ///
    /// Returns where each original slot now sits (old index → new index) and which slots
    /// were added, or nil when nothing changed.
    mutating func moveBleedDuckToSmartGate() -> (newIndex: [Int: Int], added: [Int])? {
        var position = Dictionary(uniqueKeysWithValues: indices.map { ($0, $0) })
        var changed = false
        while let pg = firstIndex(where: { $0.type == .pitchGuide && $0.pitchGuide.bleedDuck < 0 }) {
            let duckDB = self[pg].pitchGuide.bleedDuck
            self[pg].pitchGuide.bleedDuck = 0
            if let gate = firstIndex(where: { $0.type == .smartGate }) {
                self[gate].smartGate.bleedDuck = true
                changed = true
                continue
            }
            var gate = ChannelFXSlot()
            gate.type = .smartGate
            gate.isBypassed = self[pg].isBypassed
            gate.smartGate.bleedDuck = true
            gate.smartGate.depth = -duckDB
            // The voice check does the sorting, so the level only needs to clear the floor
            gate.smartGate.sensitivity = 25
            if let free = indices.first(where: { $0 > pg && self[$0].type == nil }) {
                position = position.filter { $0.value != free }   // the free slot is used up
                // Effects after the Pitch Guide move down one; the gate lands right after it
                for j in stride(from: free, to: pg + 1, by: -1) { self[j] = self[j - 1] }
                for (old, now) in position where now > pg && now < free { position[old] = now + 1 }
                self[pg + 1] = gate
            } else if let free = indices.last(where: { $0 < pg && self[$0].type == nil }) {
                position = position.filter { $0.value != free }
                // Effects from the free slot up to the Pitch Guide move up one; the gate lands right after it
                for j in free..<pg { self[j] = self[j + 1] }
                for (old, now) in position where now > free && now <= pg { position[old] = now - 1 }
                self[pg] = gate
            } else {
                // Chain is full: keep the duck where it was (and stop; nothing else can move either)
                self[pg].pitchGuide.bleedDuck = duckDB
                break
            }
            changed = true
        }
        guard changed else { return nil }
        let kept = Set(position.values)
        let added = indices.filter { !kept.contains($0) && self[$0].type == .smartGate }
        return (position, added)
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
    /// 1-based channel on the linked mixer; nil = same as the interface input
    var mixerChannel: Int? = nil

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
        mixerChannel = try c.decodeIfPresent(Int.self, forKey: .mixerChannel)
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
