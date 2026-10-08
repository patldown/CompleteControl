//
//  DSPTone.swift
//  Midi Set List
//
//  Real-time DSP kernel for Tone: a one-button "make it sound right" for a known
//  instrument, in the spirit of the Tone button on TC-Helicon's VoiceLive. Each instrument
//  has a profile: a high-pass, four EQ moves, a compressor and (for voices) a de-esser.
//  Amount scales the whole profile from flat. No instrument = passes audio untouched.
//
//  Signal path, per channel:
//    in ─▶ HPF ─▶ EQ ×4 ─▶ de-esser (dynamic cut around 7 kHz) ─▶ compressor ─▶ out
//
//  The de-esser is a dynamic EQ: a band-pass copy of the signal is subtracted in
//  proportion to how far the band's level goes over its threshold, so only sibilance is
//  cut. Biquads are RBJ cookbook, transposed direct form II. No lookahead: zero latency.
//  Strict real-time contract: no allocations, locks, or Swift runtime calls in process().
//

import AVFoundation
import Synchronization

/// One profile, as numbers the audio thread can read without touching the model
nonisolated struct ToneProfile {
    enum Kind { case peak, lowShelf, highShelf }
    struct Band { let kind: Kind; let freq: Double; let q: Double; let db: Double }

    let highPass: Double            // Hz
    let bands: (Band, Band, Band, Band)
    let compRatio: Double           // 1 = off
    let compThreshold: Double       // dBFS
    let compAttackMs: Double
    let compReleaseMs: Double
    let deEss: Bool

    static let flat = ToneProfile(
        highPass: 20, bands: (.init(kind: .peak, freq: 1_000, q: 1, db: 0), .init(kind: .peak, freq: 1_000, q: 1, db: 0),
                              .init(kind: .peak, freq: 1_000, q: 1, db: 0), .init(kind: .peak, freq: 1_000, q: 1, db: 0)),
        compRatio: 1, compThreshold: 0, compAttackMs: 10, compReleaseMs: 100, deEss: false)
}

nonisolated final class ToneKernel: @unchecked Sendable {

    // MARK: - Parameters (main thread → audio thread)
    private let profileBits = Atomic<Int>(-1)                         // ToneInstrument raw; -1 = none
    private let amountBits  = Atomic<UInt32>(Float(0.7).bitPattern)   // 0…1

    // MARK: - Meters (audio thread → main thread)
    let gainReductionBits = Atomic<UInt32>(Float(0).bitPattern)       // compressor, dB
    let deEssBits = Atomic<UInt32>(Float(0).bitPattern)               // de-esser, dB

    // MARK: - Audio thread state
    private static let stages = 5                  // HPF + 4 bands
    private static let maxChannels = 2
    private var sampleRate: Double = 48_000
    private let coeffs = UnsafeMutablePointer<Double>.allocate(capacity: stages * 5)
    private let state = UnsafeMutablePointer<Double>.allocate(capacity: maxChannels * stages * 2)
    /// De-esser band-pass: coefficients and per-channel state
    private let essCoeffs = UnsafeMutablePointer<Double>.allocate(capacity: 5)
    private let essState = UnsafeMutablePointer<Double>.allocate(capacity: maxChannels * 2)
    private var lastProfile = -2
    private var lastAmount: Float = -1
    private var profile = ToneProfile.flat
    private var amount: Double = 0
    private var compEnvDB: Double = -120
    private var essEnvDB: Double = -120

    init() {
        coeffs.initialize(repeating: 0, count: Self.stages * 5)
        state.initialize(repeating: 0, count: Self.maxChannels * Self.stages * 2)
        essCoeffs.initialize(repeating: 0, count: 5)
        essState.initialize(repeating: 0, count: Self.maxChannels * 2)
    }

    deinit {
        coeffs.deallocate(); state.deallocate()
        essCoeffs.deallocate(); essState.deallocate()
    }

    // MARK: - Main thread API

    func setSampleRate(_ sr: Double) {
        guard sr > 0 else { return }
        sampleRate = sr
        lastProfile = -2   // recompute for the new rate
        state.update(repeating: 0, count: Self.maxChannels * Self.stages * 2)
        essState.update(repeating: 0, count: Self.maxChannels * 2)
    }

    /// `instrument` already resolved (the channel's, when the effect follows it)
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
        guard raw >= 0, let instrument = ToneInstrument(rawValue: raw) else {
            gainReductionBits.store(Float(0).bitPattern, ordering: .relaxed)
            deEssBits.store(Float(0).bitPattern, ordering: .relaxed)
            lastProfile = -1
            return
        }
        if raw != lastProfile || amt != lastAmount {
            profile = instrument.profile
            amount = Double(amt)
            updateCoefficients()
            lastProfile = raw; lastAmount = amt
        }

        let a = amount
        let ratio = 1 + (profile.compRatio - 1) * a
        let threshold = profile.compThreshold
        let knee = 6.0
        let attack = 1 - exp(-1 / (sampleRate * profile.compAttackMs / 1000))
        let release = 1 - exp(-1 / (sampleRate * profile.compReleaseMs / 1000))
        let essAttack = 1 - exp(-1 / (sampleRate * 0.001))
        let essRelease = 1 - exp(-1 / (sampleRate * 0.060))
        let essThreshold = -30.0, essMaxCut = 9.0 * a
        let deEss = profile.deEss && a > 0

        let channels = min(Self.maxChannels, ptr.count)
        let c = coeffs, z = state, ec = essCoeffs, ez = essState
        var maxGR = 0.0, maxEss = 0.0
        var comp = compEnvDB, ess = essEnvDB

        for i in 0..<frameCount {
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

            // De-esser: cut the sibilance band by how far it's over the threshold
            var essGain = 1.0
            if deEss {
                let bandDB = bandPeak > 1e-6 ? 20 * log10(bandPeak) : -120
                ess += (bandDB > ess ? essAttack : essRelease) * (bandDB - ess)
                let cut = min(essMaxCut, max(0, (ess - essThreshold) * 0.6))
                maxEss = max(maxEss, cut)
                essGain = pow(10, -cut / 20)
                filtered.0 -= band.0 * (1 - essGain)
                filtered.1 -= band.1 * (1 - essGain)
            }

            // Compressor (soft knee), keyed off the louder channel
            let inDB = peak > 1e-6 ? 20 * log10(peak) : -120
            comp += (inDB > comp ? attack : release) * (inDB - comp)
            let over = comp - threshold
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
        }
        compEnvDB = max(-120, comp)
        essEnvDB = max(-120, ess)
        gainReductionBits.store(Float(maxGR).bitPattern, ordering: .relaxed)
        deEssBits.store(Float(maxEss).bitPattern, ordering: .relaxed)
    }

    // MARK: - Coefficients (on the audio thread, only when the profile or Amount changes)

    private func updateCoefficients() {
        let sr = sampleRate, a = amount
        // Below ~20 Hz the high-pass is effectively off; Amount slides it up from there
        set(0, Self.highPass(20 + (profile.highPass - 20) * a, sr: sr))
        let b = profile.bands
        set(1, Self.biquad(b.0, db: b.0.db * a, sr: sr))
        set(2, Self.biquad(b.1, db: b.1.db * a, sr: sr))
        set(3, Self.biquad(b.2, db: b.2.db * a, sr: sr))
        set(4, Self.biquad(b.3, db: b.3.db * a, sr: sr))
        let ess = Self.bandPass(7_000, q: 1.2, sr: sr)
        essCoeffs[0] = ess.0; essCoeffs[1] = ess.1; essCoeffs[2] = ess.2; essCoeffs[3] = ess.3; essCoeffs[4] = ess.4
    }

    private func set(_ s: Int, _ v: (Double, Double, Double, Double, Double)) {
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

    /// Constant 0 dB peak gain band-pass (RBJ), so subtracting it cuts that band
    private static func bandPass(_ f: Double, q: Double, sr: Double) -> (Double, Double, Double, Double, Double) {
        let w = 2 * Double.pi * min(f, sr * 0.45) / sr, alpha = sin(w) / (2 * q), cw = cos(w), a0 = 1 + alpha
        return (alpha / a0, 0, -alpha / a0, -2 * cw / a0, (1 - alpha) / a0)
    }
}
