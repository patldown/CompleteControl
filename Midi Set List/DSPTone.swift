//
//  DSPTone.swift
//  Midi Set List
//
//  Real-time DSP kernel for Tone: an adaptive "make it sound right" for a known instrument,
//  in the spirit of the Tone button on TC-Helicon's VoiceLive (their algorithm isn't
//  published; this is our own take on the idea).
//
//  It listens before it corrects. While the instrument is playing, the input's balance is
//  measured in seven octave bands (125 Hz … 8 kHz, smoothed over ~1.5 s) and compared with
//  the instrument's target balance. Each of the profile's four EQ moves is applied only as
//  far as the sound is actually off — a boomy voice gets its mud cut, a thin one doesn't —
//  and never more than the profile's fixed amount. The compressor and de-esser set their
//  thresholds from the running average level, so they act the same at any input gain.
//  Amount scales all of it; no instrument = audio passes untouched.
//
//  Signal path, per channel:
//    in ─▶ HPF ─▶ EQ ×4 (adaptive) ─▶ de-esser (dynamic cut ~7 kHz) ─▶ compressor ─▶ out
//    in ─▶ (mono) analysis: 7 octave band-passes + broadband level ──┘ (sets the above)
//
//  Biquads are RBJ cookbook, transposed direct form II. No lookahead: zero latency.
//  Strict real-time contract: no allocations, locks, or Swift runtime calls in process().
//

import AVFoundation
import Synchronization

/// One profile, as numbers the audio thread can read without touching the model
nonisolated struct ToneProfile {
    enum Kind { case peak, lowShelf, highShelf }
    struct Band { let kind: Kind; let freq: Double; let q: Double; let db: Double }

    let highPass: Double            // Hz
    /// The most each move may do (dB at full Amount); its sign says cut or boost
    let bands: (Band, Band, Band, Band)
    let compRatio: Double           // 1 = off
    /// Used until the running average level is known
    let compThreshold: Double       // dBFS
    let compAttackMs: Double
    let compReleaseMs: Double
    let deEss: Bool
}

nonisolated final class ToneKernel: @unchecked Sendable {

    // MARK: - Parameters (main thread → audio thread)
    private let profileBits = Atomic<Int>(-1)                         // ToneInstrument raw; -1 = none
    private let amountBits  = Atomic<UInt32>(Float(0.7).bitPattern)   // 0…1

    // MARK: - Meters (audio thread → main thread)
    let gainReductionBits = Atomic<UInt32>(Float(0).bitPattern)       // compressor, dB
    let deEssBits = Atomic<UInt32>(Float(0).bitPattern)               // de-esser, dB
    /// The EQ moves being applied right now, dB (the profile's bands, in order)
    let band0Bits = Atomic<UInt32>(Float(0).bitPattern)
    let band1Bits = Atomic<UInt32>(Float(0).bitPattern)
    let band2Bits = Atomic<UInt32>(Float(0).bitPattern)
    let band3Bits = Atomic<UInt32>(Float(0).bitPattern)
    /// 0…1: how much it has heard so far (corrections ramp in as this fills)
    let confidenceBits = Atomic<UInt32>(Float(0).bitPattern)

    // MARK: - Audio thread state
    private static let stages = 5                  // HPF + 4 bands
    private static let maxChannels = 2
    private static let analysisBands = 7           // octaves at 125 Hz … 8 kHz
    private static let analysisCentres: [Double] = [125, 250, 500, 1_000, 2_000, 4_000, 8_000]
    private static let updateInterval = 1_024      // samples between correction updates

    private var sampleRate: Double = 48_000
    private let coeffs = UnsafeMutablePointer<Double>.allocate(capacity: stages * 5)
    private let state = UnsafeMutablePointer<Double>.allocate(capacity: maxChannels * stages * 2)
    private let essCoeffs = UnsafeMutablePointer<Double>.allocate(capacity: 5)
    private let essState = UnsafeMutablePointer<Double>.allocate(capacity: maxChannels * 2)
    // Analysis
    private let anaCoeffs = UnsafeMutablePointer<Double>.allocate(capacity: analysisBands * 5)
    private let anaState = UnsafeMutablePointer<Double>.allocate(capacity: analysisBands * 2)
    private let anaPower = UnsafeMutablePointer<Double>.allocate(capacity: analysisBands)
    private let anaAccum = UnsafeMutablePointer<Double>.allocate(capacity: analysisBands)
    /// The EQ moves applied now, dB, gliding toward what the analysis asks for
    private let applied = UnsafeMutablePointer<Double>.allocate(capacity: 4)
    private let lastBuilt = UnsafeMutablePointer<Double>.allocate(capacity: 4)

    private var lastProfile = -2
    private var lastAmount: Float = -1
    private var profile: ToneProfile?
    private var instrument: ToneInstrument?
    private var amount: Double = 0
    private var compEnvDB: Double = -120
    private var essEnvDB: Double = -120
    private var fastPower: Double = 0               // ~50 ms, decides "playing"
    private var averagePower: Double = 0            // gated, ~1.5 s: the running level
    private var broadAccum: Double = 0
    private var accumCount = 0
    private var heardSeconds: Double = 0
    private var sinceUpdate = 0

    init() {
        coeffs.initialize(repeating: 0, count: Self.stages * 5)
        state.initialize(repeating: 0, count: Self.maxChannels * Self.stages * 2)
        essCoeffs.initialize(repeating: 0, count: 5)
        essState.initialize(repeating: 0, count: Self.maxChannels * 2)
        anaCoeffs.initialize(repeating: 0, count: Self.analysisBands * 5)
        anaState.initialize(repeating: 0, count: Self.analysisBands * 2)
        anaPower.initialize(repeating: 0, count: Self.analysisBands)
        anaAccum.initialize(repeating: 0, count: Self.analysisBands)
        applied.initialize(repeating: 0, count: 4)
        lastBuilt.initialize(repeating: .nan, count: 4)
    }

    deinit {
        coeffs.deallocate(); state.deallocate()
        essCoeffs.deallocate(); essState.deallocate()
        anaCoeffs.deallocate(); anaState.deallocate(); anaPower.deallocate(); anaAccum.deallocate()
        applied.deallocate(); lastBuilt.deallocate()
    }

    // MARK: - Main thread API

    func setSampleRate(_ sr: Double) {
        guard sr > 0 else { return }
        sampleRate = sr
        for b in 0..<Self.analysisBands {
            let c = Self.bandPass(Self.analysisCentres[b], q: 1.41, sr: sr)   // one octave wide
            anaCoeffs[b * 5] = c.0; anaCoeffs[b * 5 + 1] = c.1; anaCoeffs[b * 5 + 2] = c.2
            anaCoeffs[b * 5 + 3] = c.3; anaCoeffs[b * 5 + 4] = c.4
        }
        lastProfile = -2
        resetAnalysis()
        state.update(repeating: 0, count: Self.maxChannels * Self.stages * 2)
        essState.update(repeating: 0, count: Self.maxChannels * 2)
    }

    @MainActor func applyParams(instrument: ToneInstrument?, amount: Float) {
        profileBits.store(instrument?.rawValue ?? -1, ordering: .relaxed)
        amountBits.store((max(0, min(100, amount)) / 100).bitPattern, ordering: .relaxed)
    }

    // MARK: - Render (audio thread only — no allocations, no runtime)

    func process(_ ioData: UnsafeMutablePointer<AudioBufferList>, frameCount: Int) {
        let ptr = UnsafeMutableAudioBufferListPointer(ioData)
        guard !ptr.isEmpty else { return }

        let raw = profileBits.load(ordering: .relaxed)
        let amt = Float(bitPattern: amountBits.load(ordering: .relaxed))
        // No instrument: Tone does nothing
        guard raw >= 0, let inst = ToneInstrument(rawValue: raw) else {
            lastProfile = -1
            profile = nil
            storeMeters(gr: 0, ess: 0)
            return
        }
        if raw != lastProfile {
            // A new instrument starts listening afresh
            instrument = inst
            profile = inst.profile
            resetAnalysis()
            lastProfile = raw
        }
        guard let profile else { return }
        if amt != lastAmount {
            amount = Double(amt)
            lastAmount = amt
            buildFixedCoefficients(profile)
        }

        let a = amount
        let ratio = 1 + (profile.compRatio - 1) * a
        let knee = 6.0
        let attack = 1 - exp(-1 / (sampleRate * profile.compAttackMs / 1000))
        let release = 1 - exp(-1 / (sampleRate * profile.compReleaseMs / 1000))
        let essAttack = 1 - exp(-1 / (sampleRate * 0.001))
        let essRelease = 1 - exp(-1 / (sampleRate * 0.060))
        let fastCoeff = 1 - exp(-1 / (sampleRate * 0.050))
        let slowCoeff = 1 - exp(-1 / (sampleRate * 1.5))
        let deEss = profile.deEss && a > 0

        // Thresholds follow the running level once it's known
        let haveLevel = heardSeconds > 0.5 && averagePower > 1e-12
        let averageDB = haveLevel ? 10 * log10(averagePower) : -120
        let compThreshold = haveLevel ? averageDB + instrument!.compOverAverageDB : profile.compThreshold
        let essThreshold = haveLevel ? averageDB - 8 : -30
        let essMaxCut = 9.0 * a

        let channels = min(Self.maxChannels, ptr.count)
        let c = coeffs, z = state, ec = essCoeffs, ez = essState, ac = anaCoeffs, az = anaState
        var maxGR = 0.0, maxEss = 0.0
        var comp = compEnvDB, ess = essEnvDB
        var fast = fastPower

        for i in 0..<frameCount {
            // --- Analysis on the dry input (mono) ---
            var mono = 0.0
            for ch in 0..<channels {
                if let d = ptr[ch].mData?.assumingMemoryBound(to: Float.self) { mono += Double(d[i]) }
            }
            mono /= Double(max(1, channels))
            let p = mono * mono
            fast += fastCoeff * (p - fast)
            // Only learn while it's playing: well above silence and not far under its own level
            let playing = fast > 1e-6 && (averagePower < 1e-12 || fast > averagePower * 0.01)
            if playing {
                averagePower += slowCoeff * (p - averagePower)
                broadAccum += p
                for b in 0..<Self.analysisBands {
                    let k = b * 5, zi = b * 2
                    let y = ac[k] * mono + az[zi]
                    az[zi] = ac[k + 1] * mono - ac[k + 3] * y + az[zi + 1]
                    az[zi + 1] = ac[k + 2] * mono - ac[k + 4] * y
                    anaAccum[b] += y * y
                }
                accumCount += 1
            }

            // --- Processing ---
            var filtered = (0.0, 0.0)
            var band = (0.0, 0.0)
            var peak = 0.0, bandPeak = 0.0
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
                var b = 0.0
                if deEss {
                    let zi = ch * 2
                    b = ec[0] * x + ez[zi]
                    ez[zi] = ec[1] * x - ec[3] * b + ez[zi + 1]
                    ez[zi + 1] = ec[2] * x - ec[4] * b
                }
                if ch == 0 { filtered.0 = x; band.0 = b } else { filtered.1 = x; band.1 = b }
                peak = max(peak, abs(x))
                bandPeak = max(bandPeak, abs(b))
            }

            if deEss {
                let bandDB = bandPeak > 1e-6 ? 20 * log10(bandPeak) : -120
                ess += (bandDB > ess ? essAttack : essRelease) * (bandDB - ess)
                let cut = min(essMaxCut, max(0, (ess - essThreshold) * 0.6))
                maxEss = max(maxEss, cut)
                let essGain = pow(10, -cut / 20)
                filtered.0 -= band.0 * (1 - essGain)
                filtered.1 -= band.1 * (1 - essGain)
            }

            let inDB = peak > 1e-6 ? 20 * log10(peak) : -120
            comp += (inDB > comp ? attack : release) * (inDB - comp)
            let over = comp - compThreshold
            var reduction = 0.0
            if ratio > 1.001 {
                if over >= knee / 2 {
                    reduction = (1 - 1 / ratio) * over
                } else if over > -knee / 2 {
                    let k = over + knee / 2
                    reduction = (1 - 1 / ratio) * k * k / (2 * knee)
                }
            }
            maxGR = max(maxGR, reduction)
            let g = Float(pow(10, -reduction / 20))

            if let d0 = ptr[0].mData?.assumingMemoryBound(to: Float.self) { d0[i] = Float(filtered.0) * g }
            if channels > 1, let d1 = ptr[1].mData?.assumingMemoryBound(to: Float.self) {
                d1[i] = Float(filtered.1) * g
            }

            sinceUpdate += 1
            if sinceUpdate >= Self.updateInterval {
                sinceUpdate = 0
                adapt(profile)
            }
        }
        fastPower = fast
        compEnvDB = max(-120, comp)
        essEnvDB = max(-120, ess)
        storeMeters(gr: maxGR, ess: maxEss)
    }

    // MARK: - Adaptation (every ~20 ms, audio thread)

    /// Folds the latest playing samples into the band levels, works out how far each of the
    /// profile's moves is needed, and glides the EQ there
    private func adapt(_ profile: ToneProfile) {
        if accumCount > 0 {
            let seconds = Double(accumCount) / sampleRate
            heardSeconds += seconds
            // Band powers: ~1.5 s exponential average of each block's mean power
            let w = 1 - exp(-seconds / 1.5)
            for b in 0..<Self.analysisBands {
                anaPower[b] += w * (anaAccum[b] / Double(accumCount) - anaPower[b])
                anaAccum[b] = 0
            }
            broadAccum = 0
            accumCount = 0
        }
        guard let instrument else { return }

        // Measured shape and target shape, each relative to its own mean (only shape matters)
        var measured = (0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0)
        var sum = 0.0
        for b in 0..<Self.analysisBands {
            let db = 10 * log10(max(anaPower[b], 1e-14))
            setTuple(&measured, b, db)
            sum += db
        }
        let mMean = sum / Double(Self.analysisBands)
        let t = instrument.balance
        let tMean = (t.0 + t.1 + t.2 + t.3 + t.4 + t.5 + t.6) / 7
        // Corrections ramp in over the first ~3 s of playing
        let confidence = min(1, heardSeconds / 3)
        confidenceBits.store(Float(confidence).bitPattern, ordering: .relaxed)

        let bands = profile.bands
        let wanted0 = wanted(bands.0, measured: measured, mMean: mMean, target: t, tMean: tMean) * confidence
        let wanted1 = wanted(bands.1, measured: measured, mMean: mMean, target: t, tMean: tMean) * confidence
        let wanted2 = wanted(bands.2, measured: measured, mMean: mMean, target: t, tMean: tMean) * confidence
        let wanted3 = wanted(bands.3, measured: measured, mMean: mMean, target: t, tMean: tMean) * confidence

        // Glide (~0.4 s) so the EQ never jumps
        let glide = 0.05
        applied[0] += glide * (wanted0 * amount - applied[0])
        applied[1] += glide * (wanted1 * amount - applied[1])
        applied[2] += glide * (wanted2 * amount - applied[2])
        applied[3] += glide * (wanted3 * amount - applied[3])

        let sr = sampleRate
        if abs(applied[0] - lastBuilt[0]) > 0.05 || lastBuilt[0].isNaN {
            setStage(1, Self.biquad(bands.0, db: applied[0], sr: sr)); lastBuilt[0] = applied[0]
        }
        if abs(applied[1] - lastBuilt[1]) > 0.05 || lastBuilt[1].isNaN {
            setStage(2, Self.biquad(bands.1, db: applied[1], sr: sr)); lastBuilt[1] = applied[1]
        }
        if abs(applied[2] - lastBuilt[2]) > 0.05 || lastBuilt[2].isNaN {
            setStage(3, Self.biquad(bands.2, db: applied[2], sr: sr)); lastBuilt[2] = applied[2]
        }
        if abs(applied[3] - lastBuilt[3]) > 0.05 || lastBuilt[3].isNaN {
            setStage(4, Self.biquad(bands.3, db: applied[3], sr: sr)); lastBuilt[3] = applied[3]
        }
    }

    /// How much of a move is needed (dB at full Amount, before confidence): a cut only as far
    /// as there's too much energy there, a boost only as far as there's too little, each
    /// capped at the profile's amount. Differences under 0.5 dB are left alone; past that the
    /// gap is scaled ×1.5, because an octave-wide measurement shows only about half of a
    /// narrower problem (a +6 dB bump reads as ~+3 dB).
    private func wanted(_ band: ToneProfile.Band, measured: (Double, Double, Double, Double, Double, Double, Double),
                        mMean: Double, target: (Double, Double, Double, Double, Double, Double, Double),
                        tMean: Double) -> Double {
        guard band.db != 0 else { return 0 }
        let excess = (interpolate(measured, at: band.freq) - mMean) - (interpolate(target, at: band.freq) - tMean)
        let gap = 1.5 * (excess < 0 ? -1 : 1) * max(0, abs(excess) - 0.5)
        return band.db < 0 ? -min(-band.db, max(0, gap)) : min(band.db, max(0, -gap))
    }

    /// Value at `freq` between the octave points (log-frequency), held at the ends
    private func interpolate(_ v: (Double, Double, Double, Double, Double, Double, Double), at freq: Double) -> Double {
        let pos = max(0, min(6, log2(freq / 125)))
        let i = min(5, Int(pos))
        let frac = pos - Double(i)
        return tuple(v, i) * (1 - frac) + tuple(v, i + 1) * frac
    }

    private func tuple(_ v: (Double, Double, Double, Double, Double, Double, Double), _ i: Int) -> Double {
        switch i {
        case 0: v.0
        case 1: v.1
        case 2: v.2
        case 3: v.3
        case 4: v.4
        case 5: v.5
        default: v.6
        }
    }

    private func setTuple(_ v: inout (Double, Double, Double, Double, Double, Double, Double), _ i: Int, _ x: Double) {
        switch i {
        case 0: v.0 = x
        case 1: v.1 = x
        case 2: v.2 = x
        case 3: v.3 = x
        case 4: v.4 = x
        case 5: v.5 = x
        default: v.6 = x
        }
    }

    private func resetAnalysis() {
        anaState.update(repeating: 0, count: Self.analysisBands * 2)
        anaPower.update(repeating: 0, count: Self.analysisBands)
        anaAccum.update(repeating: 0, count: Self.analysisBands)
        applied.update(repeating: 0, count: 4)
        lastBuilt.update(repeating: .nan, count: 4)
        fastPower = 0; averagePower = 0; broadAccum = 0
        accumCount = 0; heardSeconds = 0; sinceUpdate = 0
        lastAmount = -1
        confidenceBits.store(Float(0).bitPattern, ordering: .relaxed)
    }

    private func storeMeters(gr: Double, ess: Double) {
        gainReductionBits.store(Float(gr).bitPattern, ordering: .relaxed)
        deEssBits.store(Float(ess).bitPattern, ordering: .relaxed)
        band0Bits.store(Float(applied[0]).bitPattern, ordering: .relaxed)
        band1Bits.store(Float(applied[1]).bitPattern, ordering: .relaxed)
        band2Bits.store(Float(applied[2]).bitPattern, ordering: .relaxed)
        band3Bits.store(Float(applied[3]).bitPattern, ordering: .relaxed)
    }

    // MARK: - Coefficients

    /// The parts that don't adapt: high-pass and de-esser band (EQ moves are rebuilt by adapt)
    private func buildFixedCoefficients(_ profile: ToneProfile) {
        let sr = sampleRate
        setStage(0, Self.highPass(20 + (profile.highPass - 20) * amount, sr: sr))
        let ess = Self.bandPass(7_000, q: 1.2, sr: sr)
        essCoeffs[0] = ess.0; essCoeffs[1] = ess.1; essCoeffs[2] = ess.2; essCoeffs[3] = ess.3; essCoeffs[4] = ess.4
        let b = profile.bands
        setStage(1, Self.biquad(b.0, db: applied[0], sr: sr))
        setStage(2, Self.biquad(b.1, db: applied[1], sr: sr))
        setStage(3, Self.biquad(b.2, db: applied[2], sr: sr))
        setStage(4, Self.biquad(b.3, db: applied[3], sr: sr))
    }

    private func setStage(_ s: Int, _ v: (Double, Double, Double, Double, Double)) {
        coeffs[s * 5] = v.0; coeffs[s * 5 + 1] = v.1; coeffs[s * 5 + 2] = v.2
        coeffs[s * 5 + 3] = v.3; coeffs[s * 5 + 4] = v.4
    }

    private static func biquad(_ band: ToneProfile.Band, db: Double, sr: Double)
        -> (Double, Double, Double, Double, Double) {
        let A = pow(10, db / 40), w = 2 * Double.pi * min(band.freq, sr * 0.45) / sr
        let cw = cos(w), sw = sin(w)
        switch band.kind {
        case .peak:
            let alpha = sw / (2 * band.q), a0 = 1 + alpha / A
            return ((1 + alpha * A) / a0, -2 * cw / a0, (1 - alpha * A) / a0, -2 * cw / a0, (1 - alpha / A) / a0)
        case .lowShelf, .highShelf:
            let alpha = sw / 2 * sqrt(2), sq = 2 * sqrt(A) * alpha
            if band.kind == .lowShelf {
                let a0 = (A + 1) + (A - 1) * cw + sq
                return (A * ((A + 1) - (A - 1) * cw + sq) / a0,
                        2 * A * ((A - 1) - (A + 1) * cw) / a0,
                        A * ((A + 1) - (A - 1) * cw - sq) / a0,
                        -2 * ((A - 1) + (A + 1) * cw) / a0,
                        ((A + 1) + (A - 1) * cw - sq) / a0)
            }
            let a0 = (A + 1) - (A - 1) * cw + sq
            return (A * ((A + 1) + (A - 1) * cw + sq) / a0,
                    -2 * A * ((A - 1) + (A + 1) * cw) / a0,
                    A * ((A + 1) + (A - 1) * cw - sq) / a0,
                    2 * ((A - 1) - (A + 1) * cw) / a0,
                    ((A + 1) - (A - 1) * cw - sq) / a0)
        }
    }

    private static func highPass(_ f: Double, sr: Double) -> (Double, Double, Double, Double, Double) {
        let w = 2 * Double.pi * f / sr, alpha = sin(w) / (2 * 0.7071), cw = cos(w), a0 = 1 + alpha
        return ((1 + cw) / 2 / a0, -(1 + cw) / a0, (1 + cw) / 2 / a0, -2 * cw / a0, (1 - alpha) / a0)
    }

    /// Constant 0 dB peak gain band-pass (RBJ)
    private static func bandPass(_ f: Double, q: Double, sr: Double) -> (Double, Double, Double, Double, Double) {
        let w = 2 * Double.pi * min(f, sr * 0.45) / sr, alpha = sin(w) / (2 * q), cw = cos(w), a0 = 1 + alpha
        return (alpha / a0, 0, -alpha / a0, -2 * cw / a0, (1 - alpha) / a0)
    }
}
