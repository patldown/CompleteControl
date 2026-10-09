//
//  DSPOneKnob.swift
//  Midi Set List
//
//  Real-time DSP kernel for the one-knob effects. One kernel, four modes (the AU's
//  component subtype picks which):
//
//  • Warmth — tape / tube saturation. The signal is run at twice the sample rate through
//    a soft clipper (tanh; tube adds a bias for even harmonics) and filtered back down, so
//    it stays clean of aliasing. Quiet signals pass at unity; loud ones round off. Tape
//    also softens the very top a little as Drive goes up.
//  • Air — harmonic exciter. The highs (above 3 kHz, or 6 kHz for Air focus) are split
//    off, driven through a saturator at a steady level (so the harmonic mix doesn't depend
//    on how loud it is) to make new upper harmonics, high-passed again and blended back in.
//    Adds clarity rather than just treble.
//  • Punch — transient shaper. A fast and a slow level follower; their ratio rises at each
//    hit. Gain follows that ratio to a power set by the knob: right = more attack, left =
//    softer attack and relatively more sustain. Steady sounds stay at their level.
//  • Smart Gate — finds its own threshold. It tracks the noise floor (the quiet between
//    notes) and the playing level, and opens between the two: Sensitivity moves the
//    threshold toward the playing level. Hysteresis, 1 ms attack, 80 ms hold, 150 ms
//    release (both linear in dB); closed = turned down by Depth. Bleed Duck mode also
//    listens for singing (VoiceDetector): it opens only for pitched voice, so loud
//    unpitched bleed (drums, cymbals) between phrases is turned down too. 300 ms hold, as
//    syllables have unpitched consonants; opening waits for the first pitched frame (~10 ms).
//
//  No lookahead: zero latency. Strict real-time contract: no allocations, locks, or Swift
//  runtime calls in process().
//

import AVFoundation
import Synchronization

nonisolated enum OneKnobMode { case warmth, air, punch, gate }

nonisolated final class OneKnobKernel: @unchecked Sendable {

    let mode: OneKnobMode

    // MARK: - Parameters (main thread → audio thread)
    private let p1Bits = Atomic<UInt32>(Float(0.4).bitPattern)   // main knob (0…1, Punch −1…1)
    private let p2Bits = Atomic<UInt32>(Float(40).bitPattern)    // Gate depth, dB
    private let choiceBits = Atomic<Int>(0)                      // Warmth: 0 tape, 1 tube; Air: 0 presence, 1 air
    private let bleedDuckBits = Atomic<Bool>(false)              // Gate: only open for singing

    // MARK: - Meters (audio thread → main thread)
    let gateOpenFlag = Atomic<Bool>(false)
    let gateThresholdBits = Atomic<UInt32>(Float(-120).bitPattern)  // dBFS
    let floorBits = Atomic<UInt32>(Float(-120).bitPattern)          // dBFS
    /// Gate, Bleed Duck mode: singing heard within the hold
    let voiceFlag = Atomic<Bool>(false)
    let punchGainBits = Atomic<UInt32>(Float(0).bitPattern)         // dB, latest

    // MARK: - Audio thread state
    private static let maxChannels = 2
    private var sampleRate: Double = 48_000
    // Per channel: filter states (generous; each mode uses what it needs)
    private let z = UnsafeMutablePointer<Double>.allocate(capacity: maxChannels * 16)
    private let prev = UnsafeMutablePointer<Double>.allocate(capacity: maxChannels)
    // Coefficients, recomputed on rate/choice change
    private var lp2x = (0.0, 0.0, 0.0, 0.0, 0.0)    // Warmth: anti-alias low-pass at 2× rate
    private var hp = (0.0, 0.0, 0.0, 0.0, 0.0)      // Air: split
    private var lastChoice = -1
    // Dynamics state (shared across channels: keyed off the louder one)
    private var fastEnv = 0.0, slowEnv = 0.0
    private var punchGain = 1.0
    private var levelEnv = 0.0                       // Gate: ~10 ms RMS-ish power
    private var floorDB = -90.0, signalDB = -40.0
    private var floorKnown = false
    private var windowMinDB = 0.0
    private var windowSamples = 0
    /// Samples left before the level meter has settled after a reset
    private var warmup = 0
    private var gateGain = 0.0                      // dB
    private var gateOpen = false
    private var holdSamples = 0
    private let voice = VoiceDetector()
    private var voiceHoldLeft = 0

    init(mode: OneKnobMode) {
        self.mode = mode
        z.initialize(repeating: 0, count: Self.maxChannels * 16)
        prev.initialize(repeating: 0, count: Self.maxChannels)
    }

    deinit {
        z.deallocate()
        prev.deallocate()
    }

    // MARK: - Main thread API

    func setSampleRate(_ sr: Double) {
        guard sr > 0 else { return }
        sampleRate = sr
        lastChoice = -1
        floorKnown = false
        windowSamples = 0
        warmup = Int(sr * 0.05)
        voice.reset(sampleRate: sr)
        voiceHoldLeft = 0
        z.update(repeating: 0, count: Self.maxChannels * 16)
        prev.update(repeating: 0, count: Self.maxChannels)
    }

    @MainActor func applyParams(_ p: WarmthParams) {
        p1Bits.store((max(0, min(100, p.drive)) / 100).bitPattern, ordering: .relaxed)
        choiceBits.store(p.character == .tube ? 1 : 0, ordering: .relaxed)
    }

    @MainActor func applyParams(_ p: AirParams) {
        p1Bits.store((max(0, min(100, p.amount)) / 100).bitPattern, ordering: .relaxed)
        choiceBits.store(p.focus == .air ? 1 : 0, ordering: .relaxed)
    }

    @MainActor func applyParams(_ p: PunchParams) {
        p1Bits.store((max(-100, min(100, p.amount)) / 100).bitPattern, ordering: .relaxed)
    }

    @MainActor func applyParams(_ p: SmartGateParams) {
        p1Bits.store((max(0, min(100, p.sensitivity)) / 100).bitPattern, ordering: .relaxed)
        p2Bits.store(max(0, min(80, p.depth)).bitPattern, ordering: .relaxed)
        bleedDuckBits.store(p.bleedDuck, ordering: .relaxed)
    }

    // MARK: - Render (audio thread only — no allocations, no runtime)

    func process(_ ioData: UnsafeMutablePointer<AudioBufferList>, frameCount: Int) {
        let ptr = UnsafeMutableAudioBufferListPointer(ioData)
        guard !ptr.isEmpty else { return }
        let channels = min(Self.maxChannels, ptr.count)
        let knob = Double(Float(bitPattern: p1Bits.load(ordering: .relaxed)))
        let choice = choiceBits.load(ordering: .relaxed)
        if choice != lastChoice { updateCoefficients(choice: choice); lastChoice = choice }

        switch mode {
        case .warmth: warmth(ptr, channels: channels, frames: frameCount, drive: knob, tube: choice == 1)
        case .air:    air(ptr, channels: channels, frames: frameCount, amount: knob)
        case .punch:  punch(ptr, channels: channels, frames: frameCount, amount: knob)
        case .gate:
            gate(ptr, channels: channels, frames: frameCount, sensitivity: knob,
                 depthDB: Double(Float(bitPattern: p2Bits.load(ordering: .relaxed))))
        }
    }

    // MARK: Warmth

    private func warmth(_ ptr: UnsafeMutableAudioBufferListPointer, channels: Int, frames: Int,
                        drive d: Double, tube: Bool) {
        guard d > 0.001 else { return }
        let g = 1 + 9 * d * d                       // up to +20 dB into the clipper
        let bias = tube ? 0.25 * d : 0
        let biasOut = tanh(g * bias)
        // The bias moves the clipper off its steepest point; scale back so quiet signals stay at unity
        let unity = 1 / max(0.1, 1 - biasOut * biasOut)
        // Tape rounds off the very top as it's pushed (one-pole at 18 kHz → ~11 kHz)
        let topHz = tube ? 20_000.0 : 18_000 - 7_000 * d
        let topCoeff = 1 - exp(-2 * Double.pi * min(topHz, sampleRate * 0.45) / sampleRate)
        let c = lp2x
        for ch in 0..<channels {
            guard let data = ptr[ch].mData?.assumingMemoryBound(to: Float.self) else { continue }
            let s = ch * 16
            var last = prev[ch]
            for i in 0..<frames {
                let x = Double(data[i])
                // Two samples at 2× rate (linear interpolation), each shaped and low-passed
                var out = 0.0
                for half in 0..<2 {
                    let u = half == 0 ? 0.5 * (last + x) : x
                    let shaped = (tanh(g * (u + bias)) - biasOut) / g * unity
                    let y = c.0 * shaped + z[s]
                    z[s] = c.1 * shaped - c.3 * y + z[s + 1]
                    z[s + 1] = c.2 * shaped - c.4 * y
                    out = y   // keep the second (on-grid) sample
                }
                last = x
                z[s + 2] += topCoeff * (out - z[s + 2])
                data[i] = Float(z[s + 2])
            }
            prev[ch] = last
        }
    }

    // MARK: Air

    private func air(_ ptr: UnsafeMutableAudioBufferListPointer, channels: Int, frames: Int, amount a: Double) {
        guard a > 0.001 else { return }
        let c = hp
        let blend = 0.6 * a
        let envCoeff = 1 - exp(-1 / (sampleRate * 0.010))
        for ch in 0..<channels {
            guard let data = ptr[ch].mData?.assumingMemoryBound(to: Float.self) else { continue }
            let s = ch * 16
            for i in 0..<frames {
                let x = Double(data[i])
                // Split off the highs
                var h = c.0 * x + z[s]
                z[s] = c.1 * x - c.3 * h + z[s + 1]
                z[s + 1] = c.2 * x - c.4 * h
                // New harmonics at a steady ratio whatever the level: normalise by the band's
                // envelope, shape (odd from the soft clip, even from the square), scale back
                z[s + 4] += envCoeff * (abs(h) - z[s + 4])
                let env = z[s + 4] + 1e-6
                let u = h / env
                let n = env * (tanh(2 * u) / 2 + 0.25 * u * u)
                // Keep only the new highs (removes the low intermodulation)
                h = c.0 * n + z[s + 2]
                z[s + 2] = c.1 * n - c.3 * h + z[s + 3]
                z[s + 3] = c.2 * n - c.4 * h
                data[i] = Float(x + blend * h)
            }
        }
    }

    // MARK: Punch

    private func punch(_ ptr: UnsafeMutableAudioBufferListPointer, channels: Int, frames: Int, amount k: Double) {
        guard abs(k) > 0.005 else {
            punchGainBits.store(Float(0).bitPattern, ordering: .relaxed)
            return
        }
        let fastA = 1 - exp(-1 / (sampleRate * 0.0005)), fastR = 1 - exp(-1 / (sampleRate * 0.050))
        let slowA = 1 - exp(-1 / (sampleRate * 0.020)), slowR = 1 - exp(-1 / (sampleRate * 0.050))
        let smooth = 1 - exp(-1 / (sampleRate * 0.001))
        let exponent = 1.5 * k
        var fast = fastEnv, slow = slowEnv, gain = punchGain
        for i in 0..<frames {
            var peak = 0.0
            for ch in 0..<channels {
                if let d = ptr[ch].mData?.assumingMemoryBound(to: Float.self) { peak = max(peak, abs(Double(d[i]))) }
            }
            fast += (peak > fast ? fastA : fastR) * (peak - fast)
            slow += (peak > slow ? slowA : slowR) * (peak - slow)
            // Rises above 1 at each hit; ~1 on steady sound
            let ratio = slow > 1e-6 ? max(0.25, min(4, fast / slow)) : 1
            let target = max(0.25, min(4, pow(ratio, exponent)))   // ±12 dB at most
            gain += smooth * (target - gain)
            let g = Float(gain)
            for ch in 0..<channels {
                if let d = ptr[ch].mData?.assumingMemoryBound(to: Float.self) { d[i] *= g }
            }
        }
        fastEnv = fast; slowEnv = slow; punchGain = gain
        punchGainBits.store(Float(20 * log10(max(gain, 1e-6))).bitPattern, ordering: .relaxed)
    }

    // MARK: Smart Gate

    private func gate(_ ptr: UnsafeMutableAudioBufferListPointer, channels: Int, frames: Int,
                      sensitivity s: Double, depthDB: Double) {
        let levelCoeff = 1 - exp(-1 / (sampleRate * 0.020))
        // The floor is the quietest moment of each half-second window, averaged: it drops
        // quickly to a quieter window (a gap between notes) and rises slowly (~3 s) when
        // the windows get louder. The playing level follows loud passages and decays slowly.
        let window = Int(sampleRate * 0.5)
        let signalRise = 1 - exp(-1 / (sampleRate * 0.200))
        let signalFall = 3.0 / sampleRate
        // Opens over 1 ms and closes over 150 ms, both evenly in dB (as gates are heard)
        let openStep = max(1, depthDB) / (sampleRate * 0.001)
        let closeStep = max(1, depthDB) / (sampleRate * 0.150)
        let hold = Int(sampleRate * 0.080)
        let duck = bleedDuckBits.load(ordering: .relaxed)
        let voiceHold = Int(sampleRate * 0.3)
        var voiceLeft = voiceHoldLeft
        var level = levelEnv, floor = floorDB, signal = signalDB
        var windowMin = windowMinDB, windowCount = windowSamples, known = floorKnown
        var settle = warmup
        var gain = gateGain, open = gateOpen, holdLeft = holdSamples
        var effective = open
        var threshold = -120.0

        for i in 0..<frames {
            var p = 0.0, sum: Float = 0
            for ch in 0..<channels {
                if let d = ptr[ch].mData?.assumingMemoryBound(to: Float.self) {
                    let v = Double(d[i]); p = max(p, v * v); sum += d[i]
                }
            }
            level += levelCoeff * (p - level)
            let db = level > 1e-12 ? 10 * log10(level) : -120

            // Skip the meter's own rise from zero, or it would read as the floor
            if settle > 0 { settle -= 1 } else {
                windowMin = windowCount == 0 ? db : min(windowMin, db)
                windowCount += 1
            }
            if windowCount >= window {
                if !known { floor = windowMin; known = true }
                else { floor += (windowMin < floor ? 0.6 : 0.15) * (windowMin - floor) }
                windowCount = 0
            }
            floor = min(floor, signal - 12)
            signal += db > signal ? signalRise * (db - signal) : -signalFall
            signal = max(signal, floor + 12)

            // Opens between the floor and the playing level; Sensitivity moves it up
            threshold = floor + 3 + (0.15 + 0.7 * s) * max(0, signal - floor - 3)
            if db > threshold + 2 {
                open = true; holdLeft = hold
            } else if db < threshold - 2 {
                if holdLeft > 0 { holdLeft -= 1 } else { open = false }
            }
            effective = open
            if duck {
                // Only listen while the level could open the gate; quieter input isn't singing
                if voice.push(sum / Float(channels), worthChecking: db > threshold - 2),
                   voice.isVoiced {
                    voiceLeft = voiceHold
                } else if voiceLeft > 0 {
                    voiceLeft -= 1
                }
                effective = open && voiceLeft > 0
            }
            // gain holds dB here: 0 = open, −depth = closed
            gain = effective ? min(0, gain + openStep) : max(-depthDB, gain - closeStep)
            let g = Float(pow(10, gain / 20))
            for ch in 0..<channels {
                if let d = ptr[ch].mData?.assumingMemoryBound(to: Float.self) { d[i] *= g }
            }
        }
        levelEnv = level; floorDB = floor; signalDB = signal
        windowMinDB = windowMin; windowSamples = windowCount; floorKnown = known; warmup = settle
        gateGain = gain; gateOpen = open; holdSamples = holdLeft; voiceHoldLeft = voiceLeft
        gateOpenFlag.store(effective, ordering: .relaxed)
        voiceFlag.store(duck && voiceLeft > 0, ordering: .relaxed)
        gateThresholdBits.store(Float(threshold).bitPattern, ordering: .relaxed)
        floorBits.store(Float(floor).bitPattern, ordering: .relaxed)
    }

    // MARK: - Coefficients

    private func updateCoefficients(choice: Int) {
        // Warmth: 2nd-order Butterworth low-pass at 20 kHz, running at 2× the rate
        lp2x = Self.lowPass(min(20_000, sampleRate * 0.45), q: 0.7071, sr: sampleRate * 2)
        // Air: split at 3 kHz (presence) or 6 kHz (air)
        hp = Self.highPass(choice == 1 ? 6_000 : 3_000, q: 0.7071, sr: sampleRate)
    }

    private static func lowPass(_ f: Double, q: Double, sr: Double) -> (Double, Double, Double, Double, Double) {
        let w = 2 * Double.pi * f / sr, alpha = sin(w) / (2 * q), cw = cos(w), a0 = 1 + alpha
        return ((1 - cw) / 2 / a0, (1 - cw) / a0, (1 - cw) / 2 / a0, -2 * cw / a0, (1 - alpha) / a0)
    }

    private static func highPass(_ f: Double, q: Double, sr: Double) -> (Double, Double, Double, Double, Double) {
        let w = 2 * Double.pi * f / sr, alpha = sin(w) / (2 * q), cw = cos(w), a0 = 1 + alpha
        return ((1 + cw) / 2 / a0, -(1 + cw) / a0, (1 + cw) / 2 / a0, -2 * cw / a0, (1 - alpha) / a0)
    }
}
