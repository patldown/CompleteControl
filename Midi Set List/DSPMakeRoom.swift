//
//  DSPMakeRoom.swift
//  Midi Set List
//
//  Make Room: a sidechain dynamic EQ that unmasks one or more key channels (usually the
//  singers). Two halves:
//
//  • BandAnalyzer runs in a key channel's InputPickerAudioUnit, before its effects, so a
//    channel's own carving can never feed back into what it measures. Ten band-pass
//    filters (125 Hz–9 kHz, about an octave apart) each feed a level follower (5 ms up,
//    120 ms down); the band levels go into KeyBandTable once per buffer.
//
//  • MakeRoomKernel runs on the channel that steps aside. It splits its own signal with
//    the same ten band-passes and follows its own band levels. A band dips only where a
//    key is present in it (above -45 dBFS, fully by -35) AND this channel is loud enough
//    there to mask it (within 10 dB of the key, fully at its level). The dip is scaled by
//    the key's band weight (from its Tone instrument) and capped at Amount. With several
//    keys the deepest wanted dip wins; dips never stack. Dips go in over 10 ms and let go
//    over 150 ms so nothing pumps.
//
//  The dip is made by subtracting part of each band from the signal:
//  y = x + Σ (g_b − 1)·bandpass_b(x). A band-pass is in phase at its centre, so this is a
//  cut of g_b there. No lookahead, no extra buffering: zero added latency.
//
//  All channels render in the same engine cycle, so a key's levels may be one buffer old
//  (a few ms) when read; the 10 ms dip time is longer than that.
//
//  Strict real-time contract: no allocations, locks, or Swift runtime calls in process().
//

import AVFoundation
import Synchronization

// MARK: - Bands

nonisolated enum MakeRoomBands {
    static let count = 10
    static let centres: [Double] = [125, 250, 500, 800, 1_200, 1_800, 2_700, 4_000, 6_000, 9_000]
    static let q = 1.4
    /// Display labels for the meter
    static let labels = ["125", "250", "500", "800", "1.2k", "1.8k", "2.7k", "4k", "6k", "9k"]

    /// RBJ band-pass (0 dB peak) coefficients, b0, b2 (b1 = 0), a1, a2, for each band
    static func coefficients(sampleRate sr: Double, into c: UnsafeMutablePointer<Double>) {
        for b in 0..<count {
            let f = min(centres[b], sr * 0.45)
            let w = 2 * Double.pi * f / sr, alpha = sin(w) / (2 * q), a0 = 1 + alpha
            c[b * 4 + 0] = alpha / a0
            c[b * 4 + 1] = -alpha / a0
            c[b * 4 + 2] = -2 * cos(w) / a0
            c[b * 4 + 3] = (1 - alpha) / a0
        }
    }
}

// MARK: - Shared table of key-channel band levels

/// Band levels of every channel being listened to, written by its analyzer, read by any
/// Make Room keyed to it. Fixed-size and never freed, so the audio thread can index it
/// directly. Aligned 32-bit stores don't tear, same as the routing AUs' tables.
nonisolated enum KeyBandTable {
    static let maxKeys = 32
    nonisolated(unsafe) static let levels: UnsafeMutablePointer<Float> = {
        let p = UnsafeMutablePointer<Float>.allocate(capacity: maxKeys * MakeRoomBands.count)
        p.initialize(repeating: -120, count: maxKeys * MakeRoomBands.count)
        return p
    }()

    @inline(__always) static func level(key: Int, band: Int) -> Float {
        levels[key * MakeRoomBands.count + band]
    }

    static func clear(key: Int) {
        guard key >= 0, key < maxKeys else { return }
        (levels + key * MakeRoomBands.count).update(repeating: -120, count: MakeRoomBands.count)
    }
}

// MARK: - Analyzer (in a key channel's input picker)

nonisolated final class BandAnalyzer: @unchecked Sendable {
    /// Which row of KeyBandTable to fill; -1 = nobody is listening, skip the work
    let keySlot = Atomic<Int>(-1)

    private let coeffs = UnsafeMutablePointer<Double>.allocate(capacity: MakeRoomBands.count * 4)
    private let state = UnsafeMutablePointer<Double>.allocate(capacity: MakeRoomBands.count * 2)
    private let env = UnsafeMutablePointer<Double>.allocate(capacity: MakeRoomBands.count)
    private var attack = 0.0, release = 0.0

    init() {
        coeffs.initialize(repeating: 0, count: MakeRoomBands.count * 4)
        state.initialize(repeating: 0, count: MakeRoomBands.count * 2)
        env.initialize(repeating: 0, count: MakeRoomBands.count)
        setSampleRate(48_000)
    }

    deinit { coeffs.deallocate(); state.deallocate(); env.deallocate() }

    func setSampleRate(_ sr: Double) {
        guard sr > 0 else { return }
        MakeRoomBands.coefficients(sampleRate: sr, into: coeffs)
        state.update(repeating: 0, count: MakeRoomBands.count * 2)
        env.update(repeating: 0, count: MakeRoomBands.count)
        attack = 1 - exp(-1 / (sr * 0.005))
        release = 1 - exp(-1 / (sr * 0.120))
    }

    /// Analyses one buffer (left and right summed to mono) and publishes its band levels
    func process(left: UnsafePointer<Float>, right: UnsafePointer<Float>, frames: Int) {
        let slot = keySlot.load(ordering: .relaxed)
        guard slot >= 0, slot < KeyBandTable.maxKeys else { return }
        for b in 0..<MakeRoomBands.count {
            let b0 = coeffs[b * 4], b2 = coeffs[b * 4 + 1], a1 = coeffs[b * 4 + 2], a2 = coeffs[b * 4 + 3]
            var z1 = state[b * 2], z2 = state[b * 2 + 1], e = env[b]
            for i in 0..<frames {
                // Transposed direct form II; b1 = 0 for a band-pass
                let x = 0.5 * Double(left[i] + right[i])
                let y = b0 * x + z1
                z1 = -a1 * y + z2
                z2 = b2 * x - a2 * y
                let p = y * y
                e += (p > e ? attack : release) * (p - e)
            }
            state[b * 2] = z1; state[b * 2 + 1] = z2; env[b] = e
            // Up fast, down slow: the follower rides near each cycle's peak, so this reads as
            // the band's peak level (a 0.5 sine reads about -6.5 dBFS)
            KeyBandTable.levels[slot * MakeRoomBands.count + b] = e > 1e-12 ? Float(10 * log10(e)) : -120
        }
    }
}

// MARK: - Make Room kernel (on the channel that steps aside)

nonisolated final class MakeRoomKernel: @unchecked Sendable {

    static let maxKeys = 4
    private static let maxChannels = 2
    private static let block = 32              // samples between dip decisions

    // MARK: Parameters (main thread → audio thread)
    // Plain aligned 32/64-bit words: stores don't tear, same as the routing AUs' tables
    private let maxCutBits = Atomic<UInt32>(Float(2).bitPattern)   // dB, > 0
    /// KeyBandTable row per key; -1 = unused
    private let keySlots = UnsafeMutablePointer<Int>.allocate(capacity: maxKeys)
    /// Per key, per band: how much that band matters to the key (0…1)
    private let weights = UnsafeMutablePointer<Float>.allocate(capacity: maxKeys * MakeRoomBands.count)

    // MARK: Meters (audio thread → main thread)
    private let cuts = UnsafeMutablePointer<Float>.allocate(capacity: MakeRoomBands.count)
    /// The dip in band `b` right now, dB ≥ 0
    func cutDB(band b: Int) -> Float { cuts[b] }

    // MARK: Audio thread state
    private let coeffs = UnsafeMutablePointer<Double>.allocate(capacity: MakeRoomBands.count * 4)
    private let state = UnsafeMutablePointer<Double>.allocate(capacity: maxChannels * MakeRoomBands.count * 2)
    private let env = UnsafeMutablePointer<Double>.allocate(capacity: MakeRoomBands.count)
    private let gain = UnsafeMutablePointer<Double>.allocate(capacity: MakeRoomBands.count)     // linear, 1 = no dip
    private let target = UnsafeMutablePointer<Double>.allocate(capacity: MakeRoomBands.count)
    private let power = UnsafeMutablePointer<Double>.allocate(capacity: MakeRoomBands.count)
    private var envAttack = 0.0, envRelease = 0.0, dipIn = 0.0, dipOut = 0.0
    private var blockLeft = 0

    init() {
        weights.initialize(repeating: 0, count: Self.maxKeys * MakeRoomBands.count)
        coeffs.initialize(repeating: 0, count: MakeRoomBands.count * 4)
        state.initialize(repeating: 0, count: Self.maxChannels * MakeRoomBands.count * 2)
        env.initialize(repeating: 0, count: MakeRoomBands.count)
        gain.initialize(repeating: 1, count: MakeRoomBands.count)
        target.initialize(repeating: 1, count: MakeRoomBands.count)
        power.initialize(repeating: 0, count: MakeRoomBands.count)
        keySlots.initialize(repeating: -1, count: Self.maxKeys)
        cuts.initialize(repeating: 0, count: MakeRoomBands.count)
        setSampleRate(48_000)
    }

    deinit {
        weights.deallocate(); coeffs.deallocate(); state.deallocate(); env.deallocate()
        gain.deallocate(); target.deallocate(); power.deallocate()
        keySlots.deallocate(); cuts.deallocate()
    }

    func setSampleRate(_ sr: Double) {
        guard sr > 0 else { return }
        MakeRoomBands.coefficients(sampleRate: sr, into: coeffs)
        state.update(repeating: 0, count: Self.maxChannels * MakeRoomBands.count * 2)
        env.update(repeating: 0, count: MakeRoomBands.count)
        gain.update(repeating: 1, count: MakeRoomBands.count)
        target.update(repeating: 1, count: MakeRoomBands.count)
        envAttack = 1 - exp(-1 / (sr * 0.005))
        envRelease = 1 - exp(-1 / (sr * 0.120))
        dipIn = 1 - exp(-1 / (sr * 0.010))
        dipOut = 1 - exp(-1 / (sr * 0.150))
        blockLeft = 0
    }

    /// Keys as KeyBandTable rows (-1 = unused) with their band weights; up to maxKeys
    @MainActor func apply(maxCutDB: Float, keys: [(slot: Int, weights: [Float])]) {
        maxCutBits.store(max(0, maxCutDB).bitPattern, ordering: .relaxed)
        for k in 0..<Self.maxKeys {
            let key = k < keys.count ? keys[k] : (slot: -1, weights: [])
            for b in 0..<MakeRoomBands.count {
                weights[k * MakeRoomBands.count + b] = b < key.weights.count ? max(0, min(1, key.weights[b])) : 0
            }
            keySlots[k] = key.slot
        }
    }

    /// The dip one key asks for in one band, dB ≥ 0
    @inline(__always)
    static func wantedCut(keyDB: Float, ownDB: Float, weight: Float, maxCut: Float) -> Float {
        // The key is really there (above bleed) …
        let present = max(0, min(1, (keyDB + 45) / 10))
        // … and this channel is loud enough there to cover it
        let masking = max(0, min(1, (ownDB - (keyDB - 10)) / 10))
        return maxCut * weight * present * masking
    }

    // MARK: Render (audio thread only)

    func process(_ ioData: UnsafeMutablePointer<AudioBufferList>, frameCount: Int) {
        let ptr = UnsafeMutableAudioBufferListPointer(ioData)
        let channels = min(Self.maxChannels, ptr.count)
        guard channels > 0 else { return }
        let n = MakeRoomBands.count
        let maxCut = Float(bitPattern: maxCutBits.load(ordering: .relaxed))

        for i in 0..<frameCount {
            if blockLeft == 0 {
                blockLeft = Self.block
                decide(maxCut: maxCut)
            }
            blockLeft -= 1

            // Split each channel into bands; follow the louder channel's band level
            power.update(repeating: 0, count: n)
            for ch in 0..<channels {
                guard let d = ptr[ch].mData?.assumingMemoryBound(to: Float.self) else { continue }
                let x = Double(d[i])
                var y = x
                for b in 0..<n {
                    let s = (ch * n + b) * 2
                    let out = coeffs[b * 4] * x + state[s]
                    state[s] = -coeffs[b * 4 + 2] * out + state[s + 1]
                    state[s + 1] = coeffs[b * 4 + 1] * x - coeffs[b * 4 + 3] * out
                    y += (gain[b] - 1) * out
                    power[b] = max(power[b], out * out)
                }
                d[i] = Float(y)
            }
            for b in 0..<n {
                let p = power[b]
                env[b] += (p > env[b] ? envAttack : envRelease) * (p - env[b])
                gain[b] += (target[b] < gain[b] ? dipIn : dipOut) * (target[b] - gain[b])
            }
        }
        for b in 0..<n {
            cuts[b] = Float(-20 * log10(max(1e-6, gain[b])))
        }
    }

    /// Sets each band's target gain from the keys' and our own band levels
    private func decide(maxCut: Float) {
        let n = MakeRoomBands.count
        for b in 0..<n {
            // Same follower as BandAnalyzer, so the two levels compare directly
            let ownDB: Float = env[b] > 1e-12 ? Float(10 * log10(env[b])) : -120
            var cut: Float = 0
            for k in 0..<Self.maxKeys {
                let slot = keySlots[k]
                guard slot >= 0, slot < KeyBandTable.maxKeys else { continue }
                let w = weights[k * n + b]
                guard w > 0 else { continue }
                cut = max(cut, Self.wantedCut(keyDB: KeyBandTable.level(key: slot, band: b),
                                              ownDB: ownDB, weight: w, maxCut: maxCut))
            }
            target[b] = pow(10, Double(-cut) / 20)
        }
    }
}
