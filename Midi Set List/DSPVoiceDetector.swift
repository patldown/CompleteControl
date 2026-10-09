//
//  DSPVoiceDetector.swift
//  Midi Set List
//
//  Tells singing from bleed for Smart Gate's Bleed Duck mode. Every 256 samples it runs
//  YIN (the same pitch test Pitch Guide uses) on the latest input: a frame counts as voice
//  when it is clearly pitched inside the singing range (80 Hz–1 kHz). Drums, cymbals,
//  breath and hiss aren't pitched, so they never count. Pitched bleed (a guitar under the
//  mic) can, which is why Smart Gate still also needs the level to clear its threshold.
//
//  Strict real-time contract: no allocations, locks, or Swift runtime calls in push().
//

import Accelerate

nonisolated final class VoiceDetector {

    private static let ringSize = 4_096                 // power of two; > window + maxLag
    private static let maxLag = 1_300                   // 96 kHz / 80 Hz, rounded up
    private static let hop = 256
    private static let minHz: Float = 80
    private static let maxHz: Float = 1_000
    /// YIN aperiodicity under this counts as pitched (Pitch Guide's default Pickiness)
    private static let threshold: Float = 0.175

    private let ring = UnsafeMutablePointer<Float>.allocate(capacity: ringSize)
    private let frame = UnsafeMutablePointer<Float>.allocate(capacity: maxLag * 2 + 4)
    private let squares = UnsafeMutablePointer<Float>.allocate(capacity: maxLag * 2 + 4)
    private let corr = UnsafeMutablePointer<Float>.allocate(capacity: maxLag + 4)

    private var sampleRate: Float = 48_000
    private var writeIndex = 0
    private var hopCounter = 0
    /// Whether the latest analysed frame was pitched voice
    private(set) var isVoiced = false

    init() {
        ring.initialize(repeating: 0, count: Self.ringSize)
        frame.initialize(repeating: 0, count: Self.maxLag * 2 + 4)
        squares.initialize(repeating: 0, count: Self.maxLag * 2 + 4)
        corr.initialize(repeating: 0, count: Self.maxLag + 4)
    }

    deinit {
        ring.deallocate(); frame.deallocate(); squares.deallocate(); corr.deallocate()
    }

    func reset(sampleRate sr: Double) {
        sampleRate = Float(sr)
        ring.update(repeating: 0, count: Self.ringSize)
        writeIndex = 0
        hopCounter = 0
        isVoiced = false
    }

    /// Feeds one sample. `worthChecking` false skips the analysis (input too quiet to matter)
    /// and reports no voice, which saves the CPU while the gate is idle.
    /// Returns true on samples where a new analysis just ran.
    @inline(__always) @discardableResult
    func push(_ x: Float, worthChecking: Bool) -> Bool {
        ring[writeIndex & (Self.ringSize - 1)] = x
        writeIndex += 1
        hopCounter += 1
        guard hopCounter >= Self.hop else { return false }
        hopCounter = 0
        isVoiced = worthChecking && analyze()
        return true
    }

    private func analyze() -> Bool {
        let tauMax = min(Self.maxLag - 2, Int(sampleRate / Self.minHz))
        let tauMin = max(2, Int(sampleRate / Self.maxHz))
        let window = tauMax
        let total = window + tauMax + 2
        guard writeIndex >= total else { return false }

        // Latest `total` samples, oldest first
        let mask = Self.ringSize - 1
        let start = writeIndex - total
        for k in 0..<total { frame[k] = ring[(start + k) & mask] }

        vDSP_vsq(frame, 1, squares, 1, vDSP_Length(total))
        var e0: Float = 0
        vDSP_sve(squares, 1, &e0, vDSP_Length(window))
        guard e0 > 1e-9 else { return false }

        // r(τ) = Σ x[p]·x[p+τ], then YIN's cumulative-mean-normalised difference
        vDSP_conv(frame, 1, frame, 1, corr, 1, vDSP_Length(tauMax + 2), vDSP_Length(window))
        var eTau = e0, running: Float = 0
        for tau in 1...tauMax {
            eTau += squares[tau + window - 1] - squares[tau - 1]
            let d = max(0, e0 + eTau - 2 * corr[tau])
            running += d
            let cmnd = running > 0 ? d * Float(tau) / running : 1
            if tau >= tauMin && cmnd < Self.threshold { return true }
        }
        return false
    }
}
