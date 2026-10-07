//
//  DSPLevelRider.swift
//  Midi Set List
//
//  Real-time DSP kernel for the Level Rider effect.
//  Strict real-time contract: no allocations, locks, or Swift runtime calls in process().
//  Parameters travel main→audio via atomics; meters travel audio→main the same way.
//
//  Signal path:
//    input → inputTrim → RMS envelope follower → gain rider → outputTrim → output
//
//  Gain rider uses separate attack (cut) and release (boost) time constants and
//  a ±1.5 dB deadband to avoid micro-jitter on steady signals. A noise gate freezes
//  the rider gain when the signal falls below threshold, then drifts toward unity
//  to avoid boosting room noise on re-entry.
//

import AVFoundation
import Synchronization

nonisolated final class LevelRiderKernel: @unchecked Sendable {

    // MARK: - Parameters (main thread → audio thread)
    let inputTrimBits    = Atomic<UInt32>(Float(0).bitPattern)      // dB
    let outputTrimBits   = Atomic<UInt32>(Float(0).bitPattern)      // dB
    let targetLevelBits  = Atomic<UInt32>(Float(-18).bitPattern)    // dBFS
    let maxCutBits       = Atomic<UInt32>(Float(-9).bitPattern)     // dB (≤0)
    let maxBoostBits     = Atomic<UInt32>(Float(4).bitPattern)      // dB (≥0)
    let cutSpeedBits     = Atomic<UInt32>(Float(80).bitPattern)     // ms
    let boostSpeedBits   = Atomic<UInt32>(Float(600).bitPattern)    // ms
    let gateThreshBits   = Atomic<UInt32>(Float(-50).bitPattern)    // dBFS

    // MARK: - Meters (audio thread → main thread)
    let inputPeakBits     = Atomic<UInt32>(Float(0).bitPattern)     // linear 0..1
    let outputPeakBits    = Atomic<UInt32>(Float(0).bitPattern)     // linear 0..1
    let gainReductionBits = Atomic<UInt32>(Float(0).bitPattern)     // dB (current fader)
    let clipLatch         = Atomic<Bool>(false)                      // input ≥ -0.5 dBFS
    let levelDBBits       = Atomic<UInt32>(Float(-100).bitPattern)  // dBFS RMS after input trim (Learn Voice)

    // MARK: - Audio thread state (render thread only)
    private var sampleRate: Double = 48_000
    private var envelope: Double = 0      // running mean-squared
    private var envCoeff: Double = 0      // per-sample IIR coefficient (~30 ms window)
    private var gainDB: Double = 0        // current fader position in dB
    private var cutCoeff: Double = 0
    private var boostCoeff: Double = 0
    private var lastCutSpeed: Float = -1  // sentinel to force coefficient recalc
    private var lastBoostSpeed: Float = -1

    // MARK: - Main thread API

    func setSampleRate(_ sr: Double) {
        guard sr > 0 else { return }
        sampleRate = sr
        envCoeff = 1.0 - exp(-1.0 / (sr * 0.030))  // 30 ms RMS window
        lastCutSpeed = -1
        lastBoostSpeed = -1
    }

    func applyParams(_ p: LevelRiderParams) {
        inputTrimBits.store(p.inputTrim.bitPattern, ordering: .relaxed)
        outputTrimBits.store(p.outputTrim.bitPattern, ordering: .relaxed)
        targetLevelBits.store(p.targetLevel.bitPattern, ordering: .relaxed)
        maxCutBits.store(p.maxCut.bitPattern, ordering: .relaxed)
        maxBoostBits.store(p.maxBoost.bitPattern, ordering: .relaxed)
        cutSpeedBits.store(p.cutSpeed.bitPattern, ordering: .relaxed)
        boostSpeedBits.store(p.boostSpeed.bitPattern, ordering: .relaxed)
        gateThreshBits.store(p.gateThreshold.bitPattern, ordering: .relaxed)
    }

    func resetClipLatch() { clipLatch.store(false, ordering: .relaxed) }

    func resetMeters() {
        inputPeakBits.store(Float(0).bitPattern, ordering: .relaxed)
        outputPeakBits.store(Float(0).bitPattern, ordering: .relaxed)
    }

    // MARK: - Render (audio thread only — no allocations, no runtime)

    func process(_ ioData: UnsafeMutablePointer<AudioBufferList>, frameCount: Int) {
        // Read parameters once per block
        let inputTrimDB  = Float(bitPattern: inputTrimBits.load(ordering: .relaxed))
        let outputTrimDB = Float(bitPattern: outputTrimBits.load(ordering: .relaxed))
        let targetDB     = Double(Float(bitPattern: targetLevelBits.load(ordering: .relaxed)))
        let maxCutDB     = Double(Float(bitPattern: maxCutBits.load(ordering: .relaxed)))
        let maxBoostDB   = Double(Float(bitPattern: maxBoostBits.load(ordering: .relaxed)))
        let gateThreshDB = Double(Float(bitPattern: gateThreshBits.load(ordering: .relaxed)))
        let cutMs        = Float(bitPattern: cutSpeedBits.load(ordering: .relaxed))
        let boostMs      = Float(bitPattern: boostSpeedBits.load(ordering: .relaxed))

        let inputTrimLin  = Float(pow(10.0, Double(inputTrimDB) / 20.0))
        let outputTrimLin = Float(pow(10.0, Double(outputTrimDB) / 20.0))

        // Recompute smoothing coefficients only when params change (exp() is expensive)
        if cutMs != lastCutSpeed {
            let secs = Double(max(20, cutMs)) / 1000.0
            cutCoeff = 1.0 - exp(-1.0 / (sampleRate * secs))
            lastCutSpeed = cutMs
        }
        if boostMs != lastBoostSpeed {
            let secs = Double(max(200, boostMs)) / 1000.0
            boostCoeff = 1.0 - exp(-1.0 / (sampleRate * secs))
            lastBoostSpeed = boostMs
        }

        let ptr = UnsafeMutableAudioBufferListPointer(ioData)
        guard !ptr.isEmpty, let ch0Ptr = ptr[0].mData else { return }
        let ch0 = ch0Ptr.assumingMemoryBound(to: Float.self)

        // Pass 1 — update envelope follower from channel 0, track input peak
        var inputPeak: Float = 0
        for i in 0..<frameCount {
            let x = Double(ch0[i]) * Double(inputTrimLin)
            let absX = Float(abs(x))
            if absX > inputPeak { inputPeak = absX }
            envelope += envCoeff * (x * x - envelope)
        }
        if envelope < 1.0e-20 { envelope = 0 }  // flush denormals

        // Compute desired gain from measured level
        let rms = sqrt(max(0, envelope))
        let measuredDB = rms > 1.0e-10 ? 20.0 * log10(rms) : -100.0
        levelDBBits.store(Float(measuredDB).bitPattern, ordering: .relaxed)

        if measuredDB < gateThreshDB {
            gainDB *= 0.9999   // gate: drift slowly toward 0 dB, don't boost noise
        } else {
            let errorDB   = targetDB - measuredDB
            let desiredDB = max(maxCutDB, min(maxBoostDB, errorDB))
            if abs(desiredDB - gainDB) > 1.5 {   // deadband: ignore micro-jitter
                let coeff = desiredDB < gainDB ? cutCoeff : boostCoeff
                gainDB += coeff * (desiredDB - gainDB)
            }
        }

        // Ceiling guard: clamp gain so output never exceeds -1 dBFS
        let ceilingDB   = -1.0 - measuredDB
        let effectiveDB = min(gainDB, ceilingDB)
        let riderLin    = Float(pow(10.0, effectiveDB / 20.0))
        let totalGain   = inputTrimLin * riderLin * outputTrimLin

        // Pass 2 — apply identical gain to every channel (stereo-safe)
        var outputPeak: Float = 0
        for bufIdx in 0..<ptr.count {
            guard let bPtr = ptr[bufIdx].mData else { continue }
            let samples = bPtr.assumingMemoryBound(to: Float.self)
            for i in 0..<frameCount {
                var y = samples[i] * totalGain
                if y.isNaN || y.isInfinite { y = 0 }
                if y >  1 { y =  1 } else if y < -1 { y = -1 }
                samples[i] = y
                let absY: Float = y < 0 ? -y : y
                if absY > outputPeak { outputPeak = absY }
            }
        }

        // Publish meters — accumulate max; main thread handles display decay
        let prevIn = Float(bitPattern: inputPeakBits.load(ordering: .relaxed))
        if inputPeak > prevIn { inputPeakBits.store(inputPeak.bitPattern, ordering: .relaxed) }
        let prevOut = Float(bitPattern: outputPeakBits.load(ordering: .relaxed))
        if outputPeak > prevOut { outputPeakBits.store(outputPeak.bitPattern, ordering: .relaxed) }
        gainReductionBits.store(Float(gainDB).bitPattern, ordering: .relaxed)

        if inputPeak >= 0.9441 { clipLatch.store(true, ordering: .relaxed) }  // -0.5 dBFS threshold
    }
}
