//
//  DSPVintageCompressor.swift
//  Midi Set List
//
//  Real-time DSP kernel for the two vintage-style compressors:
//
//    • Opto (LA-2A style) — RMS-ish detector, soft knee, fixed ~10 ms attack and a
//      two-stage program-dependent release: short peaks recover in ~60 ms, sustained
//      compression "charges" a slow stage that lets go over 1–2 s, like an optical cell.
//    • FET (1176 style) — peak detector, fixed threshold driven by the Input knob,
//      20–800 µs attack, 50 ms–1.1 s release, 4/8/12/20:1 and "all buttons" mode.
//
//  Strict real-time contract: no allocations, locks, or Swift runtime calls in process().
//  Parameters travel main→audio via atomics, same as LevelRiderKernel.
//

import AVFoundation
import Synchronization

nonisolated enum VintageCompressorModel {
    case opto, fet
}

nonisolated final class VintageCompressorKernel: @unchecked Sendable {

    let model: VintageCompressorModel

    // MARK: - Parameters (main thread → audio thread)
    // Opto: a = peak reduction (0–100), b = gain (dB), c = limit mode (0/1)
    // FET:  a = input (dB), b = output (dB), c = ratio index (0–4), d = attack (1–7), e = release (1–7)
    let aBits = Atomic<UInt32>(Float(0).bitPattern)
    let bBits = Atomic<UInt32>(Float(0).bitPattern)
    let cBits = Atomic<UInt32>(Float(0).bitPattern)
    let dBits = Atomic<UInt32>(Float(4).bitPattern)
    let eBits = Atomic<UInt32>(Float(4).bitPattern)

    // MARK: - Meters (audio thread → main thread)
    let gainReductionBits = Atomic<UInt32>(Float(0).bitPattern)   // dB, ≥ 0

    // MARK: - Audio thread state (render thread only)
    private var sampleRate: Double = 48_000
    private var detector: Double = 0      // opto: mean-square; FET: peak envelope
    private var detCoeff: Double = 0
    private var grFast: Double = 0        // dB of gain reduction
    private var grSlow: Double = 0        // opto only: slow "light memory" stage
    private var attackCoeff: Double = 0
    private var releaseCoeff: Double = 0
    private var slowAttackCoeff: Double = 0
    private var slowReleaseCoeff: Double = 0
    private var lastTimingKey: Float = -1  // sentinel to force coefficient recalc

    init(model: VintageCompressorModel) {
        self.model = model
        setSampleRate(48_000)
    }

    // MARK: - Main thread API

    func setSampleRate(_ sr: Double) {
        guard sr > 0 else { return }
        sampleRate = sr
        // Opto cell responds to average level; FET detector decays quickly between peaks
        detCoeff = Self.coeff(seconds: model == .opto ? 0.005 : 0.002, sampleRate: sr)
        slowAttackCoeff = Self.coeff(seconds: 0.8, sampleRate: sr)
        slowReleaseCoeff = Self.coeff(seconds: 1.5, sampleRate: sr)
        lastTimingKey = -1
    }

    @MainActor func applyParams(_ p: OptoCompParams) {
        aBits.store(p.peakReduction.bitPattern, ordering: .relaxed)
        bBits.store(p.gain.bitPattern, ordering: .relaxed)
        cBits.store(Float(p.limitMode ? 1 : 0).bitPattern, ordering: .relaxed)
    }

    @MainActor func applyParams(_ p: FETCompParams) {
        aBits.store(p.input.bitPattern, ordering: .relaxed)
        bBits.store(p.output.bitPattern, ordering: .relaxed)
        cBits.store(Float(p.ratio.rawValue).bitPattern, ordering: .relaxed)
        dBits.store(p.attack.bitPattern, ordering: .relaxed)
        eBits.store(p.release.bitPattern, ordering: .relaxed)
    }

    // MARK: - Render (audio thread only — no allocations, no runtime)

    func process(_ ioData: UnsafeMutablePointer<AudioBufferList>, frameCount: Int) {
        let a = Double(Float(bitPattern: aBits.load(ordering: .relaxed)))
        let b = Double(Float(bitPattern: bBits.load(ordering: .relaxed)))
        let c = Float(bitPattern: cBits.load(ordering: .relaxed))

        // Static curve + timing for this block
        var thresholdDB: Double, ratio: Double, kneeDB: Double
        var preGain: Double, postGainDB: Double, grScale: Double = 1, drive: Float = 1
        switch model {
        case .opto:
            let limit = c >= 0.5
            thresholdDB = -0.4 * max(0, min(100, a))       // Peak Reduction 0–100 → 0 … -40 dBFS
            ratio = limit ? 10 : 3
            kneeDB = limit ? 6 : 10
            preGain = 1
            postGainDB = b
            setTiming(attackSeconds: 0.010, releaseSeconds: 0.060, key: 0)
        case .fet:
            let ratioIndex = Int(c.rounded())
            let allButtons = ratioIndex >= 4
            thresholdDB = allButtons ? -28 : -24
            switch ratioIndex {                             // no array literal: it would allocate
            case ...0: ratio = 4
            case 1:    ratio = 8
            case 2:    ratio = 12
            default:   ratio = 20
            }
            kneeDB = allButtons ? 10 : (ratioIndex == 0 ? 6 : 3)
            preGain = pow(10, a / 20)
            postGainDB = b
            if allButtons { grScale = 1.25; drive = 1.6 }  // over-compression + extra grit
            // Knobs run 1 (slowest) … 7 (fastest), like the hardware
            let atk = Double(Float(bitPattern: dBits.load(ordering: .relaxed)))
            let rel = Double(Float(bitPattern: eBits.load(ordering: .relaxed)))
            let atkSecs = 800e-6 * pow(20.0 / 800.0, (max(1, min(7, atk)) - 1) / 6)
            let relSecs = 1.1 * pow(0.05 / 1.1, (max(1, min(7, rel)) - 1) / 6)
            setTiming(attackSeconds: atkSecs, releaseSeconds: relSecs, key: Float(atk * 10 + rel))
        }
        let postGain = Float(pow(10, postGainDB / 20))

        let ptr = UnsafeMutableAudioBufferListPointer(ioData)
        let channelCount = ptr.count
        guard channelCount > 0 else { return }

        var maxGR: Double = 0
        for i in 0..<frameCount {
            // Stereo-linked detector: loudest channel drives both
            var peak: Double = 0
            for ch in 0..<channelCount {
                guard let d = ptr[ch].mData else { continue }
                let x = abs(Double(d.assumingMemoryBound(to: Float.self)[i])) * preGain
                if x > peak { peak = x }
            }

            let levelDB: Double
            if model == .opto {
                detector += detCoeff * (peak * peak - detector)
                levelDB = detector > 1e-12 ? 10 * log10(detector) : -120
            } else {
                detector = peak > detector ? peak : detector + detCoeff * (peak - detector)
                levelDB = detector > 1e-6 ? 20 * log10(detector) : -120
            }

            // Soft-knee gain computer → desired gain reduction (dB, positive)
            let over = levelDB - thresholdDB
            var target: Double
            if 2 * over < -kneeDB {
                target = 0
            } else if 2 * abs(over) <= kneeDB {
                let k = over + kneeDB / 2
                target = (1 - 1 / ratio) * k * k / (2 * kneeDB)
            } else {
                target = (1 - 1 / ratio) * over
            }
            target *= grScale

            // Ballistics
            grFast += (target > grFast ? attackCoeff : releaseCoeff) * (target - grFast)
            var gr = grFast
            if model == .opto {
                // Slow stage only builds up under sustained compression, then holds the
                // release back — the "program dependent" opto behaviour.
                grSlow += (target > grSlow ? slowAttackCoeff : slowReleaseCoeff) * (target - grSlow)
                if grSlow > gr { gr = grSlow }
            }
            if gr > maxGR { maxGR = gr }

            let gain = Float(preGain * pow(10, -gr / 20)) * postGain
            for ch in 0..<channelCount {
                guard let d = ptr[ch].mData else { continue }
                let s = d.assumingMemoryBound(to: Float.self)
                var y = s[i] * gain
                // Gentle tanh saturation doubles as the output safety clip
                y = tanhf(y * drive) / drive
                if y.isNaN || y.isInfinite { y = 0 }
                s[i] = y
            }
        }
        if grFast < 1e-9 { grFast = 0 }
        if grSlow < 1e-9 { grSlow = 0 }
        if detector < 1e-20 { detector = 0 }

        gainReductionBits.store(Float(maxGR).bitPattern, ordering: .relaxed)
    }

    // MARK: - Helpers

    /// Recomputes attack/release coefficients only when the knob positions change.
    private func setTiming(attackSeconds: Double, releaseSeconds: Double, key: Float) {
        guard key != lastTimingKey else { return }
        attackCoeff = Self.coeff(seconds: attackSeconds, sampleRate: sampleRate)
        releaseCoeff = Self.coeff(seconds: releaseSeconds, sampleRate: sampleRate)
        lastTimingKey = key
    }

    private static func coeff(seconds: Double, sampleRate: Double) -> Double {
        1 - exp(-1 / (sampleRate * max(1e-6, seconds)))
    }
}
