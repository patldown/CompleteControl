//
//  DSPMicroDetune.swift
//  Midi Set List
//
//  Real-time DSP kernel for Micro Detune: the classic micro-pitch widener (the Eventide
//  H3000 / MicroPitch trick). Two copies of the voice, one nudged up a few cents and the
//  other down, each slightly delayed and panned apart, are added back to the dry signal.
//  The small pitch and time differences make a mono source sound wide and doubled.
//  Strict real-time contract: no allocations, locks, or Swift runtime calls in process().
//
//  Signal path:
//    in (L+R)/2 ─▶ delay line ─┬▶ voice L: +Detune cents, Delay ms      ─▶ low cut ─┐
//                    ▲         └▶ voice R: −Detune cents, Delay × 1.4 ms ─▶ low cut ─┤
//                    └──────────── Feedback ◀─────────────────────────────────────────┤
//    out = dry × dryGain + voices panned by Width × wetGain ◀─────────────────────────┘
//
//  Each voice is a rotating-tap shifter: two taps sweep through a short window at a
//  rate set by the shift ratio, half a window apart, and crossfade so the jump back
//  at the end of the window is never heard. At a few cents the sweep is very slow
//  (about 10 s per window at 9 cents), so it's smooth and costs almost nothing.
//

import AVFoundation
import Synchronization

nonisolated final class MicroDetuneKernel: @unchecked Sendable {

    // MARK: - Parameters (main thread → audio thread)
    private let detuneBits   = Atomic<UInt32>(Float(9).bitPattern)     // cents, 0...50
    private let delayBits    = Atomic<UInt32>(Float(12).bitPattern)    // ms, 0...100
    private let widthBits    = Atomic<UInt32>(Float(1).bitPattern)     // 0...1
    private let mixBits      = Atomic<UInt32>(Float(0.35).bitPattern)  // 0...1
    private let feedbackBits = Atomic<UInt32>(Float(0).bitPattern)     // 0...0.7
    private let lowCutBits   = Atomic<UInt32>(Float(150).bitPattern)   // Hz, 20...600

    // MARK: - Audio thread state

    /// Holds over a second at 96 kHz: max delay (140 ms on the right voice) plus the window
    private static let bufferSize = 1 << 17
    private static let mask = bufferSize - 1
    private let buffer: UnsafeMutablePointer<Float>
    private var writeIndex = 0
    private var sampleRate: Double = 48_000

    /// Sweep window of each shifter, in samples
    private var windowSamples: Double = 2_400
    /// Tap phase of each voice (0..<1 through the window)
    private var phaseL: Double = 0
    private var phaseR: Double = 0.25   // offset so the two voices never crossfade together
    /// Base delays and gains glide to new settings so knob moves don't click
    private var delayL: Double = 0
    private var delayR: Double = 0
    private var dryGain: Float = 1
    private var wetGain: Float = 0
    private var smoothCoeff: Double = 0.001
    /// One-pole high-pass on each voice
    private var hpL = HighPass()
    private var hpR = HighPass()
    private var lastWetL: Float = 0
    private var lastWetR: Float = 0

    init() {
        buffer = .allocate(capacity: Self.bufferSize)
        buffer.initialize(repeating: 0, count: Self.bufferSize)
    }

    deinit { buffer.deallocate() }

    // MARK: - Main thread API

    func setSampleRate(_ sr: Double) {
        guard sr > 0 else { return }
        sampleRate = sr
        windowSamples = sr * 0.050           // 50 ms window
        smoothCoeff = 1 - exp(-1 / (sr * 0.030))
        buffer.update(repeating: 0, count: Self.bufferSize)
        writeIndex = 0
        let p = currentDelayMs()
        delayL = p * sr / 1000
        delayR = p * 1.4 * sr / 1000
        lastWetL = 0
        lastWetR = 0
    }

    func applyParams(_ p: MicroDetuneParams) {
        detuneBits.store(p.detune.bitPattern, ordering: .relaxed)
        delayBits.store(p.delay.bitPattern, ordering: .relaxed)
        widthBits.store((p.width / 100).bitPattern, ordering: .relaxed)
        mixBits.store((p.mix / 100).bitPattern, ordering: .relaxed)
        feedbackBits.store((min(70, max(0, p.feedback)) / 100).bitPattern, ordering: .relaxed)
        lowCutBits.store(p.lowCut.bitPattern, ordering: .relaxed)
    }

    private func currentDelayMs() -> Double {
        Double(Float(bitPattern: delayBits.load(ordering: .relaxed)))
    }

    // MARK: - Render (audio thread only — no allocations, no runtime)

    func process(_ ioData: UnsafeMutablePointer<AudioBufferList>, frameCount: Int) {
        let ptr = UnsafeMutableAudioBufferListPointer(ioData)
        guard !ptr.isEmpty, let l = ptr[0].mData?.assumingMemoryBound(to: Float.self) else { return }
        let r = ptr.count > 1 ? ptr[1].mData?.assumingMemoryBound(to: Float.self) : nil

        let cents = Double(Float(bitPattern: detuneBits.load(ordering: .relaxed)))
        let width = Float(bitPattern: widthBits.load(ordering: .relaxed))
        let mix = Float(bitPattern: mixBits.load(ordering: .relaxed))
        let feedback = Float(bitPattern: feedbackBits.load(ordering: .relaxed))
        let lowCut = Double(Float(bitPattern: lowCutBits.load(ordering: .relaxed)))
        let targetDelayL = currentDelayMs() * sampleRate / 1000
        let targetDelayR = targetDelayL * 1.4

        // Up to 50%, the wet rises with the dry at full; past it the dry falls away
        let targetDry = min(1, 2 * (1 - mix))
        let targetWet = min(1, 2 * mix)
        // Width pans each voice: 1 = hard left/right, 0 = both centre
        let near = (1 + width) / 2, far = (1 - width) / 2

        // Tap delays move by (1 − ratio) samples per sample: shorter = higher pitch
        let stepUp = (1 - pow(2, cents / 1200)) / windowSamples
        let stepDown = (1 - pow(2, -cents / 1200)) / windowSamples
        let hpCoeff = Float(exp(-2 * Double.pi * lowCut / sampleRate))
        let window = windowSamples

        for i in 0..<frameCount {
            let dryL = l[i]
            let dryR = r?[i] ?? dryL
            let input = (dryL + dryR) * 0.5

            buffer[writeIndex] = input + feedback * (lastWetL + lastWetR) * 0.5

            delayL += (targetDelayL - delayL) * smoothCoeff
            delayR += (targetDelayR - delayR) * smoothCoeff
            dryGain += (targetDry - dryGain) * Float(smoothCoeff)
            wetGain += (targetWet - wetGain) * Float(smoothCoeff)

            let voiceL = hpL.process(shifted(phase: phaseL, base: delayL, window: window), coeff: hpCoeff)
            let voiceR = hpR.process(shifted(phase: phaseR, base: delayR, window: window), coeff: hpCoeff)
            lastWetL = voiceL
            lastWetR = voiceR

            phaseL = wrap(phaseL + stepUp)
            phaseR = wrap(phaseR + stepDown)
            writeIndex = (writeIndex + 1) & Self.mask

            l[i] = dryL * dryGain + (voiceL * near + voiceR * far) * wetGain
            r?[i] = dryR * dryGain + (voiceR * near + voiceL * far) * wetGain
        }
        // Keep silence from decaying into denormals
        if abs(lastWetL) < 1e-15 { lastWetL = 0 }
        if abs(lastWetR) < 1e-15 { lastWetR = 0 }
    }

    /// One shifted voice: two taps half a window apart, each faded by sin² so they sum to 1
    @inline(__always)
    private func shifted(phase: Double, base: Double, window: Double) -> Float {
        let p2 = wrap(phase + 0.5)
        let g1 = sin(Double.pi * phase), g2 = sin(Double.pi * p2)
        return read(base + 1 + phase * window) * Float(g1 * g1)
             + read(base + 1 + p2 * window) * Float(g2 * g2)
    }

    /// Linear-interpolated read `delay` samples behind the write position
    @inline(__always)
    private func read(_ delay: Double) -> Float {
        let position = Double(writeIndex) - delay + Double(Self.bufferSize)
        let index = Int(position)
        let frac = Float(position - Double(index))
        let a = buffer[index & Self.mask], b = buffer[(index + 1) & Self.mask]
        return a + (b - a) * frac
    }

    @inline(__always)
    private func wrap(_ x: Double) -> Double { x - x.rounded(.down) }

    private struct HighPass {
        private var x1: Float = 0
        private var y1: Float = 0
        mutating func process(_ x: Float, coeff: Float) -> Float {
            let y = coeff * (y1 + x - x1)
            x1 = x
            y1 = abs(y) < 1e-15 ? 0 : y
            return y
        }
    }
}
