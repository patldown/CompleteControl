//
//  DSPFeedbackNotch.swift
//  Midi Set List
//
//  Real-time DSP kernel for the Feedback Notch effect: a bank of up to 12 narrow
//  peaking-cut biquads (RBJ cookbook) placed by ring-out, plus a lock-free tap of
//  the processed signal that RingOutAnalyzer reads on the main thread.
//
//  Strict real-time contract: no allocations, locks, or Swift runtime calls in process().
//  Notch specs travel main→audio through a seqlock (a writer is rare: one ring-out
//  step at most every few hundred ms); audio→main samples travel through a ring buffer.
//

import AVFoundation
import Synchronization

nonisolated final class FeedbackNotchKernel: @unchecked Sendable {

    static let maxNotches = 12
    static let tapCapacity = 16_384          // power of two; ~340 ms at 48 kHz
    private static let maxChannels = 2

    // MARK: - Notch specs (main thread → audio thread, via seqlock)
    private struct Spec { var frequency: Float; var depth: Float; var q: Float }
    private let specs = UnsafeMutablePointer<Spec>.allocate(capacity: maxNotches)
    private let specScratch = UnsafeMutablePointer<Spec>.allocate(capacity: maxNotches)  // audio thread copy
    private let specSeq = Atomic<UInt32>(0)            // odd while the main thread is writing
    private let specCount = Atomic<Int>(0)

    // MARK: - Analysis tap (audio thread → main thread)
    private let tap = UnsafeMutablePointer<Float>.allocate(capacity: tapCapacity)
    private let tapWriteIndex = Atomic<Int>(0)          // total samples written (monotonic)

    // MARK: - Audio thread state (render thread only)
    private(set) var sampleRate: Double = 48_000
    private var appliedSeq: UInt32 = .max
    private var activeCount = 0
    // Per notch: b0, b1, b2, a1, a2 (normalised)
    private let coeffs = UnsafeMutablePointer<Double>.allocate(capacity: maxNotches * 5)
    // Per channel per notch: z1, z2 (transposed direct form II)
    private let state = UnsafeMutablePointer<Double>.allocate(capacity: maxChannels * maxNotches * 2)

    init() {
        specs.initialize(repeating: Spec(frequency: 1_000, depth: 0, q: 10), count: Self.maxNotches)
        specScratch.initialize(repeating: Spec(frequency: 1_000, depth: 0, q: 10), count: Self.maxNotches)
        tap.initialize(repeating: 0, count: Self.tapCapacity)
        coeffs.initialize(repeating: 0, count: Self.maxNotches * 5)
        state.initialize(repeating: 0, count: Self.maxChannels * Self.maxNotches * 2)
    }

    deinit {
        specs.deallocate(); specScratch.deallocate(); tap.deallocate(); coeffs.deallocate(); state.deallocate()
    }

    // MARK: - Main thread API

    func setSampleRate(_ sr: Double) {
        guard sr > 0 else { return }
        sampleRate = sr
        appliedSeq = .max   // recompute coefficients for the new rate
    }

    @MainActor func applyParams(_ p: FeedbackNotchParams) {
        let notches = p.notches.prefix(Self.maxNotches)
        specSeq.add(1, ordering: .acquiringAndReleasing)
        for (i, n) in notches.enumerated() {
            specs[i] = Spec(frequency: n.frequency, depth: n.depth, q: n.q)
        }
        specCount.store(notches.count, ordering: .relaxed)
        specSeq.add(1, ordering: .releasing)
    }

    /// Copies the most recent `count` processed samples (channel 0) into `out` and returns
    /// the tap position they end at. Returns nil until enough audio has passed through, or
    /// when no new audio has arrived since `previousEnd` (engine stopped).
    @MainActor func readRecentSamples(into out: UnsafeMutablePointer<Float>, count: Int,
                                      previousEnd: Int) -> Int? {
        let end = tapWriteIndex.load(ordering: .acquiring)
        guard end >= count, end != previousEnd, count <= Self.tapCapacity else { return nil }
        let mask = Self.tapCapacity - 1
        for i in 0..<count { out[i] = tap[(end - count + i) & mask] }
        return end
    }

    // MARK: - Render (audio thread only — no allocations, no runtime)

    func process(_ ioData: UnsafeMutablePointer<AudioBufferList>, frameCount: Int) {
        refreshCoefficientsIfNeeded()

        let ptr = UnsafeMutableAudioBufferListPointer(ioData)
        let channels = min(ptr.count, Self.maxChannels)
        for ch in 0..<channels {
            guard let d = ptr[ch].mData else { continue }
            let s = d.assumingMemoryBound(to: Float.self)
            let z = state + ch * Self.maxNotches * 2
            for i in 0..<frameCount {
                var x = Double(s[i])
                for n in 0..<activeCount {
                    let c = coeffs + n * 5
                    let y = c[0] * x + z[n * 2]
                    z[n * 2]     = c[1] * x - c[3] * y + z[n * 2 + 1]
                    z[n * 2 + 1] = c[2] * x - c[4] * y
                    x = y
                }
                var out = Float(x)
                if out.isNaN || out.isInfinite { out = 0 }
                s[i] = out
            }
        }

        // Tap channel 0 after the notches so the analyzer only sees what's still ringing
        guard let d0 = ptr.first?.mData else { return }
        let s0 = d0.assumingMemoryBound(to: Float.self)
        let start = tapWriteIndex.load(ordering: .relaxed)
        let mask = Self.tapCapacity - 1
        for i in 0..<frameCount { tap[(start + i) & mask] = s0[i] }
        tapWriteIndex.store(start + frameCount, ordering: .releasing)
    }

    private func refreshCoefficientsIfNeeded() {
        let seq1 = specSeq.load(ordering: .acquiring)
        guard seq1 != appliedSeq, seq1 & 1 == 0 else { return }   // unchanged, or mid-write
        let count = min(specCount.load(ordering: .relaxed), Self.maxNotches)
        for n in 0..<count { specScratch[n] = specs[n] }
        atomicMemoryFence(ordering: .acquiring)
        guard specSeq.load(ordering: .relaxed) == seq1 else { return }  // torn read: retry next block
        for n in 0..<count { computePeakingCut(specScratch[n], into: coeffs + n * 5) }
        if count > activeCount {
            // Fresh filters start from silence so they don't pop
            for ch in 0..<Self.maxChannels {
                let z = state + ch * Self.maxNotches * 2
                for n in activeCount..<count { z[n * 2] = 0; z[n * 2 + 1] = 0 }
            }
        }
        activeCount = count
        appliedSeq = seq1
    }

    /// RBJ Audio EQ Cookbook peaking filter with negative gain.
    private func computePeakingCut(_ spec: Spec, into c: UnsafeMutablePointer<Double>) {
        let nyquist = sampleRate / 2
        let f = max(20, min(Double(spec.frequency), nyquist * 0.95))
        let a = pow(10, Double(min(0, spec.depth)) / 40)
        let w0 = 2 * Double.pi * f / sampleRate
        let alpha = sin(w0) / (2 * max(0.5, Double(spec.q)))
        let cosw = cos(w0)
        let a0 = 1 + alpha / a
        c[0] = (1 + alpha * a) / a0
        c[1] = (-2 * cosw) / a0
        c[2] = (1 - alpha * a) / a0
        c[3] = (-2 * cosw) / a0
        c[4] = (1 - alpha / a) / a0
    }
}
