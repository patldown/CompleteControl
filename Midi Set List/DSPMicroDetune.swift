//
//  DSPMicroDetune.swift
//  Midi Set List
//
//  Real-time DSP kernel for Micro Detune: a dual pitch-shifted delay after Eventide's
//  MicroPitch. Voice A takes the left input, shifts it up by Pitch A and delays it by
//  Delay A; voice B takes the right input, shifts it down by Pitch B and delays it by
//  Delay B. A plays on the left, B on the right (on a mono output they sum 50/50).
//  The small pitch and time differences make a source sound wide and doubled.
//  Strict real-time contract: no allocations, locks, or Swift runtime calls in process().
//
//  Signal path, per voice:
//    in ─▶ (+) ─▶ delay line ─▶ shifter (Pitch ± Mod) ─▶ Tone tilt ─▶ Low Cut ─┬─▶ × Pitch Mix × wet ─▶ out
//           ▲                                                                 │
//           └──────────────────────────── Feedback ◀──────────────────────────┘
//  Feedback goes back through the shifter, so each repeat moves further in pitch: the
//  rising / falling repeats MicroPitch is known for.
//
//  Each shifter is a rotating-tap delay: two taps sweep through a short window at a rate
//  set by the shift ratio, half a window apart, crossfaded by sin² so the jump back at the
//  end of the window is never heard. At a few cents the sweep takes seconds, so it's smooth
//  and cheap. Mod moves the shift with a sine LFO (B is a quarter cycle behind A).
//

import AVFoundation
import Synchronization

nonisolated final class MicroDetuneKernel: @unchecked Sendable {

    // MARK: - Parameters (main thread → audio thread)
    private let pitchABits   = Atomic<UInt32>(Float(9).bitPattern)     // cents
    private let pitchBBits   = Atomic<UInt32>(Float(-9).bitPattern)    // cents
    private let delayABits   = Atomic<UInt32>(Float(0).bitPattern)     // ms (tempo already resolved)
    private let delayBBits   = Atomic<UInt32>(Float(12).bitPattern)    // ms
    private let pitchMixBits = Atomic<UInt32>(Float(0.5).bitPattern)   // 0...1
    private let mixBits      = Atomic<UInt32>(Float(0.4).bitPattern)   // 0...1
    private let feedbackBits = Atomic<UInt32>(Float(0).bitPattern)     // 0...0.95
    private let toneBits     = Atomic<UInt32>(Float(0).bitPattern)     // -1...1
    private let lowCutBits   = Atomic<UInt32>(Float(20).bitPattern)    // Hz
    private let modDepthBits = Atomic<UInt32>(Float(0).bitPattern)     // 0...1
    private let modRateBits  = Atomic<UInt32>(Float(0.5).bitPattern)   // Hz

    // MARK: - Audio thread state

    /// Holds 2.7 s at 96 kHz: the 2 s max delay plus the shifter window
    private static let bufferSize = 1 << 18
    private static let mask = bufferSize - 1
    private var voiceA: Voice
    private var voiceB: Voice
    private var writeIndex = 0
    private var sampleRate: Double = 48_000
    private var windowSamples: Double = 2_400
    private var smoothCoeff: Double = 0.001
    private var lfoPhase: Double = 0
    private var dryGain: Float = 1
    private var wetGain: Float = 0
    private var gainA: Float = 1
    private var gainB: Float = 1

    init() {
        voiceA = Voice(size: Self.bufferSize)
        voiceB = Voice(size: Self.bufferSize)
        voiceB.phase = 0.25   // so the two voices never crossfade at the same moment
    }

    deinit {
        voiceA.buffer.deallocate()
        voiceB.buffer.deallocate()
    }

    // MARK: - Main thread API

    func setSampleRate(_ sr: Double) {
        guard sr > 0 else { return }
        sampleRate = sr
        windowSamples = sr * 0.050           // 50 ms shifter window
        smoothCoeff = 1 - exp(-1 / (sr * 0.050))
        writeIndex = 0
        voiceA.reset(delay: Double(Float(bitPattern: delayABits.load(ordering: .relaxed))) * sr / 1000)
        voiceB.reset(delay: Double(Float(bitPattern: delayBBits.load(ordering: .relaxed))) * sr / 1000)
    }

    /// `bpm` is the loaded song's tempo, for tempo-synced delays
    @MainActor func applyParams(_ p: MicroDetuneParams, bpm: Int?) {
        let delays = p.delays(bpm: bpm)
        pitchABits.store(p.pitchA.bitPattern, ordering: .relaxed)
        pitchBBits.store(p.pitchB.bitPattern, ordering: .relaxed)
        delayABits.store(min(MicroDetuneParams.maxDelayMs, max(0, delays.a)).bitPattern, ordering: .relaxed)
        delayBBits.store(min(MicroDetuneParams.maxDelayMs, max(0, delays.b)).bitPattern, ordering: .relaxed)
        pitchMixBits.store((p.pitchMix / 100).bitPattern, ordering: .relaxed)
        mixBits.store((p.mix / 100).bitPattern, ordering: .relaxed)
        feedbackBits.store((min(95, max(0, p.feedback)) / 100).bitPattern, ordering: .relaxed)
        toneBits.store((p.tone / 100).bitPattern, ordering: .relaxed)
        lowCutBits.store(p.lowCut.bitPattern, ordering: .relaxed)
        modDepthBits.store((p.modDepth / 100).bitPattern, ordering: .relaxed)
        modRateBits.store(p.modRate.bitPattern, ordering: .relaxed)
    }

    // MARK: - Render (audio thread only — no allocations, no runtime)

    func process(_ ioData: UnsafeMutablePointer<AudioBufferList>, frameCount: Int) {
        let ptr = UnsafeMutableAudioBufferListPointer(ioData)
        guard !ptr.isEmpty, let l = ptr[0].mData?.assumingMemoryBound(to: Float.self) else { return }
        let r = ptr.count > 1 ? ptr[1].mData?.assumingMemoryBound(to: Float.self) : nil

        let feedback = Float(bitPattern: feedbackBits.load(ordering: .relaxed))
        let mix = Float(bitPattern: mixBits.load(ordering: .relaxed))
        let pitchMix = Float(bitPattern: pitchMixBits.load(ordering: .relaxed))
        let tone = Double(Float(bitPattern: toneBits.load(ordering: .relaxed)))
        let lowCut = Double(Float(bitPattern: lowCutBits.load(ordering: .relaxed)))
        let depth = Double(Float(bitPattern: modDepthBits.load(ordering: .relaxed)))
        let rate = Double(Float(bitPattern: modRateBits.load(ordering: .relaxed)))
        let targetDelayA = Double(Float(bitPattern: delayABits.load(ordering: .relaxed))) * sampleRate / 1000
        let targetDelayB = Double(Float(bitPattern: delayBBits.load(ordering: .relaxed))) * sampleRate / 1000

        // Mod: the shift swings from 0 to 2× around its setting at full depth. Once per
        // buffer is plenty for an LFO of at most 10 Hz.
        let lfoA = sin(2 * Double.pi * lfoPhase)
        let lfoB = sin(2 * Double.pi * (lfoPhase + 0.25))
        lfoPhase += rate * Double(frameCount) / sampleRate
        lfoPhase -= lfoPhase.rounded(.down)
        let centsA = Double(Float(bitPattern: pitchABits.load(ordering: .relaxed))) * (1 + depth * lfoA)
        let centsB = Double(Float(bitPattern: pitchBBits.load(ordering: .relaxed))) * (1 + depth * lfoB)
        // Tap delays move by (1 − ratio) samples per sample: shortening = higher pitch
        let stepA = (1 - pow(2, centsA / 1200)) / windowSamples
        let stepB = (1 - pow(2, centsB / 1200)) / windowSamples

        // Up to 50%, the wet rises with the dry at full; past it the dry falls away.
        // Pitch Mix the same way between the voices.
        let targetDry = min(1, 2 * (1 - mix)), targetWet = min(1, 2 * mix)
        let targetA = min(1, 2 * (1 - pitchMix)), targetB = min(1, 2 * pitchMix)

        // Tone tilts ±6 dB around 700 Hz; Low Cut is a one-pole high-pass (20 Hz ≈ off)
        let lowGain = Float(pow(10, -6 * tone / 20)), highGain = Float(pow(10, 6 * tone / 20))
        let filters = Filters(
            tiltCoeff: Float(1 - exp(-2 * Double.pi * 700 / sampleRate)),
            lowGain: lowGain, highGain: highGain,
            hpCoeff: Float(exp(-2 * Double.pi * lowCut / sampleRate)))
        // Tone's boost would push the loop past unity at high feedback; take it back out
        let loopGain = feedback / max(lowGain, highGain)
        let window = windowSamples
        let smooth = smoothCoeff, smoothF = Float(smoothCoeff)

        // Work on locals; the class's stored state is written back once per buffer
        var voiceA = self.voiceA, voiceB = self.voiceB
        var writeIndex = self.writeIndex
        var dryGain = self.dryGain, wetGain = self.wetGain, gainA = self.gainA, gainB = self.gainB

        for i in 0..<frameCount {
            let dryL = l[i]
            let dryR = r?[i] ?? dryL

            voiceA.buffer[writeIndex] = dryL + max(-4, min(4, loopGain * voiceA.last))
            voiceB.buffer[writeIndex] = dryR + max(-4, min(4, loopGain * voiceB.last))

            voiceA.delay += (targetDelayA - voiceA.delay) * smooth
            voiceB.delay += (targetDelayB - voiceB.delay) * smooth
            dryGain += (targetDry - dryGain) * smoothF
            wetGain += (targetWet - wetGain) * smoothF
            gainA += (targetA - gainA) * smoothF
            gainB += (targetB - gainB) * smoothF

            let a = voiceA.render(at: writeIndex, window: window, step: stepA, filters: filters)
            let b = voiceB.render(at: writeIndex, window: window, step: stepB, filters: filters)
            writeIndex = (writeIndex + 1) & Self.mask

            l[i] = dryL * dryGain + a * gainA * wetGain
            r?[i] = dryR * dryGain + b * gainB * wetGain
        }
        voiceA.flushDenormals()
        voiceB.flushDenormals()
        self.voiceA = voiceA
        self.voiceB = voiceB
        self.writeIndex = writeIndex
        self.dryGain = dryGain; self.wetGain = wetGain; self.gainA = gainA; self.gainB = gainB
    }

    private struct Filters {
        let tiltCoeff: Float, lowGain: Float, highGain: Float, hpCoeff: Float
    }

    /// One shifted voice with its own delay line, so its feedback is shifted again each pass
    private struct Voice {
        let buffer: UnsafeMutablePointer<Float>
        var phase: Double = 0       // tap position through the window, 0..<1
        var delay: Double = 0       // base delay in samples, gliding to the target
        var last: Float = 0         // previous output, for feedback
        private var tiltLow: Float = 0
        private var hpX: Float = 0
        private var hpY: Float = 0

        init(size: Int) {
            buffer = .allocate(capacity: size)
            buffer.initialize(repeating: 0, count: size)
        }

        mutating func reset(delay: Double) {
            buffer.update(repeating: 0, count: MicroDetuneKernel.bufferSize)
            self.delay = delay
            last = 0; tiltLow = 0; hpX = 0; hpY = 0
        }

        @inline(__always)
        mutating func render(at writeIndex: Int, window: Double, step: Double, filters f: Filters) -> Float {
            // Two taps half a window apart, each faded by sin² so they always sum to 1
            let p2 = phase + 0.5 - (phase + 0.5).rounded(.down)
            let g1 = sin(Double.pi * phase), g2 = sin(Double.pi * p2)
            var y = read(writeIndex, delay + 1 + phase * window) * Float(g1 * g1)
                  + read(writeIndex, delay + 1 + p2 * window) * Float(g2 * g2)
            phase += step
            phase -= phase.rounded(.down)

            // Tone: split at 700 Hz, tilt the halves against each other
            tiltLow += f.tiltCoeff * (y - tiltLow)
            y = tiltLow * f.lowGain + (y - tiltLow) * f.highGain
            // Low Cut
            let hp = f.hpCoeff * (hpY + y - hpX)
            hpX = y
            hpY = hp
            last = hp
            return hp
        }

        /// Linear-interpolated read `delay` samples behind the write position
        @inline(__always)
        private func read(_ writeIndex: Int, _ delay: Double) -> Float {
            let position = Double(writeIndex) - delay + Double(MicroDetuneKernel.bufferSize)
            let index = Int(position)
            let frac = Float(position - Double(index))
            let a = buffer[index & MicroDetuneKernel.mask]
            let b = buffer[(index + 1) & MicroDetuneKernel.mask]
            return a + (b - a) * frac
        }

        mutating func flushDenormals() {
            if abs(last) < 1e-15 { last = 0 }
            if abs(tiltLow) < 1e-15 { tiltLow = 0 }
            if abs(hpY) < 1e-15 { hpY = 0 }
        }
    }
}
