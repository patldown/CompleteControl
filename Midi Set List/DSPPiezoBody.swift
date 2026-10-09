//
//  DSPPiezoBody.swift
//  Midi Set List
//
//  Real-time DSP kernel for Piezo Body: an acoustic pickup enhancer in the spirit of
//  TC Electronic's BodyRez, tuned by ear. Under-saddle (piezo) pickups sound thin, quacky
//  and spiky; this puts back the body resonance a mic would hear, softens the quack and
//  the brittle top, and evens out pick attack — all from one Amount knob.
//
//  Signal path, per channel:
//    in ─▶ HPF 40 Hz ─▶ body peak 1 ─▶ body peak 2 ─▶ quack cut ─▶ top shelf ─▶ compressor ─▶ phase/level/mute ─▶ out
//
//  At full Amount: body peaks +6 dB and +3.5 dB (Body Size sets where: parlor ~130/260 Hz,
//  dreadnought ~100/210 Hz, jumbo ~85/180 Hz), quack −5 dB around 1.6 kHz, top −3 dB above
//  7 kHz, and a fast 3:1 compressor from −18 dBFS. Amount scales all of it from flat.
//
//  Biquads are RBJ cookbook, transposed direct form II. No lookahead: zero latency.
//  Strict real-time contract: no allocations, locks, or Swift runtime calls in process().
//

import AVFoundation
import Synchronization

nonisolated final class PiezoBodyKernel: @unchecked Sendable {

    // MARK: - Parameters (main thread → audio thread)
    private let amountBits = Atomic<UInt32>(Float(0.6).bitPattern)    // 0…1
    private let body1Bits  = Atomic<UInt32>(Float(100).bitPattern)    // Hz
    private let body2Bits  = Atomic<UInt32>(Float(210).bitPattern)    // Hz
    private let levelBits  = Atomic<UInt32>(Float(1).bitPattern)      // linear
    private let invertBits = Atomic<Bool>(false)
    private let muteBits   = Atomic<Bool>(false)

    // MARK: - Meter (audio thread → main thread)
    /// Compressor gain reduction right now, dB (≥ 0)
    let gainReductionBits = Atomic<UInt32>(Float(0).bitPattern)

    // MARK: - Audio thread state
    private static let stages = 5
    private var sampleRate: Double = 48_000
    /// Per stage: b0, b1, b2, a1, a2 (allocated once)
    private let coeffs = UnsafeMutablePointer<Double>.allocate(capacity: stages * 5)
    /// Per channel per stage: z1, z2
    private let state = UnsafeMutablePointer<Double>.allocate(capacity: 2 * stages * 2)
    private var lastAmount: Float = -1, lastBody1: Float = -1, lastBody2: Float = -1
    private var envelopeDB: Double = -120
    private var outGain: Float = 1

    init() {
        coeffs.initialize(repeating: 0, count: Self.stages * 5)
        coeffs[0] = 1   // stage 0 passes until the first coefficients are computed
        state.initialize(repeating: 0, count: 2 * Self.stages * 2)
    }

    deinit {
        coeffs.deallocate()
        state.deallocate()
    }

    // MARK: - Main thread API

    func setSampleRate(_ sr: Double) {
        guard sr > 0 else { return }
        sampleRate = sr
        lastAmount = -1   // recompute coefficients for the new rate
        state.update(repeating: 0, count: 2 * Self.stages * 2)
    }

    @MainActor func applyParams(_ p: PiezoBodyParams) {
        amountBits.store((max(0, min(100, p.amount)) / 100).bitPattern, ordering: .relaxed)
        body1Bits.store(p.bodySize.resonances.0.bitPattern, ordering: .relaxed)
        body2Bits.store(p.bodySize.resonances.1.bitPattern, ordering: .relaxed)
        levelBits.store(powf(10, p.level / 20).bitPattern, ordering: .relaxed)
        invertBits.store(p.phaseInvert, ordering: .relaxed)
        muteBits.store(p.mute, ordering: .relaxed)
    }

    // MARK: - Render (audio thread only — no allocations, no runtime)

    func process(_ ioData: UnsafeMutablePointer<AudioBufferList>, frameCount: Int) {
        let ptr = UnsafeMutableAudioBufferListPointer(ioData)
        guard !ptr.isEmpty else { return }

        let amount = Float(bitPattern: amountBits.load(ordering: .relaxed))
        let body1 = Float(bitPattern: body1Bits.load(ordering: .relaxed))
        let body2 = Float(bitPattern: body2Bits.load(ordering: .relaxed))
        if amount != lastAmount || body1 != lastBody1 || body2 != lastBody2 {
            updateCoefficients(amount: Double(amount), body1: Double(body1), body2: Double(body2))
            lastAmount = amount; lastBody1 = body1; lastBody2 = body2
        }

        // Fast, gentle compressor on the louder channel: 1:1 at Amount 0, 3:1 at full
        let ratio = 1 + 2 * Double(amount)
        let threshold = -18.0, knee = 6.0
        let attack = 1 - exp(-1 / (sampleRate * 0.002))
        let release = 1 - exp(-1 / (sampleRate * 0.080))
        let smooth = Float(1 - exp(-1 / (sampleRate * 0.010)))
        let level = Float(bitPattern: levelBits.load(ordering: .relaxed))
        let target = muteBits.load(ordering: .relaxed) ? 0
                   : (invertBits.load(ordering: .relaxed) ? -level : level)

        let channels = min(2, ptr.count)
        var maxReduction: Double = 0
        var gain = outGain
        var env = envelopeDB
        let c = coeffs, z = state
        for i in 0..<frameCount {
            // Filters, and the peak that drives the compressor
            var peak: Double = 0
            var filtered = (0.0, 0.0)
            for ch in 0..<channels {
                guard let data = ptr[ch].mData?.assumingMemoryBound(to: Float.self) else { continue }
                var x = Double(data[i])
                for s in 0..<Self.stages {
                    let k = s * 5, zi = (ch * Self.stages + s) * 2
                    let y = c[k] * x + z[zi]
                    z[zi] = c[k + 1] * x - c[k + 3] * y + z[zi + 1]
                    z[zi + 1] = c[k + 2] * x - c[k + 4] * y
                    x = y
                }
                if ch == 0 { filtered.0 = x } else { filtered.1 = x }
                peak = max(peak, abs(x))
            }

            let inDB = peak > 1e-6 ? 20 * log10(peak) : -120
            env += (inDB > env ? attack : release) * (inDB - env)
            let over = env - threshold
            let reduction: Double
            if over <= -knee / 2 {
                reduction = 0
            } else if over < knee / 2 {
                let k = over + knee / 2
                reduction = (1 - 1 / ratio) * k * k / (2 * knee)
            } else {
                reduction = (1 - 1 / ratio) * over
            }
            maxReduction = max(maxReduction, reduction)
            let compGain = pow(10, -reduction / 20)

            gain += smooth * (target - gain)
            let g = Float(compGain) * gain
            if let d0 = ptr[0].mData?.assumingMemoryBound(to: Float.self) {
                d0[i] = Float(filtered.0) * g
            }
            if channels > 1, let d1 = ptr[1].mData?.assumingMemoryBound(to: Float.self) {
                d1[i] = Float(filtered.1) * g
            }
        }
        outGain = gain
        envelopeDB = max(-120, env)
        gainReductionBits.store(Float(maxReduction).bitPattern, ordering: .relaxed)
    }

    // MARK: - Coefficients (on the audio thread, only when a setting changed)

    private func updateCoefficients(amount a: Double, body1: Double, body2: Double) {
        let sr = sampleRate
        setStage(0, Self.highPass(40, q: 0.7071, sr: sr))
        setStage(1, Self.peaking(body1, q: 2.0, db: 6.0 * a, sr: sr))
        setStage(2, Self.peaking(body2, q: 1.5, db: 3.5 * a, sr: sr))
        setStage(3, Self.peaking(1_600, q: 0.9, db: -5.0 * a, sr: sr))
        setStage(4, Self.highShelf(7_000, db: -3.0 * a, sr: sr))
    }

    private func setStage(_ s: Int, _ c: (Double, Double, Double, Double, Double)) {
        coeffs[s * 5] = c.0; coeffs[s * 5 + 1] = c.1; coeffs[s * 5 + 2] = c.2
        coeffs[s * 5 + 3] = c.3; coeffs[s * 5 + 4] = c.4
    }

    /// RBJ peaking EQ, normalised (b0, b1, b2, a1, a2)
    private static func peaking(_ f: Double, q: Double, db: Double, sr: Double)
        -> (Double, Double, Double, Double, Double) {
        let A = pow(10, db / 40), w = 2 * Double.pi * f / sr
        let alpha = sin(w) / (2 * q), cw = cos(w)
        let a0 = 1 + alpha / A
        return ((1 + alpha * A) / a0, -2 * cw / a0, (1 - alpha * A) / a0, -2 * cw / a0, (1 - alpha / A) / a0)
    }

    /// RBJ high shelf, slope 1
    private static func highShelf(_ f: Double, db: Double, sr: Double)
        -> (Double, Double, Double, Double, Double) {
        let A = pow(10, db / 40), w = 2 * Double.pi * f / sr
        let cw = cos(w), alpha = sin(w) / 2 * sqrt(2)
        let sq = 2 * sqrt(A) * alpha
        let a0 = (A + 1) - (A - 1) * cw + sq
        return (A * ((A + 1) + (A - 1) * cw + sq) / a0,
                -2 * A * ((A - 1) + (A + 1) * cw) / a0,
                A * ((A + 1) + (A - 1) * cw - sq) / a0,
                2 * ((A - 1) - (A + 1) * cw) / a0,
                ((A + 1) - (A - 1) * cw - sq) / a0)
    }

    /// RBJ high-pass
    private static func highPass(_ f: Double, q: Double, sr: Double)
        -> (Double, Double, Double, Double, Double) {
        let w = 2 * Double.pi * f / sr
        let alpha = sin(w) / (2 * q), cw = cos(w)
        let a0 = 1 + alpha
        return ((1 + cw) / 2 / a0, -(1 + cw) / a0, (1 + cw) / 2 / a0, -2 * cw / a0, (1 - alpha) / a0)
    }
}
