//
//  DSPPitchGuide.swift
//  Midi Set List
//
//  Real-time DSP kernel for Pitch Guide: mono pitch correction.
//
//  Detection — YIN every 256 samples on the dry input. The autocorrelation runs through
//  vDSP_conv (vectorised, no allocation). A frame only counts as a sung note when it is
//  above the gate, inside the voice range, clearly periodic (YIN aperiodicity under a
//  threshold set by Pickiness), and has held the same pitch for a few frames. Anything
//  else — bleed, breaths, consonants, chords — is left untouched.
//
//  Decision — the nearest note in the key/scale is the target. Within ±Tolerance cents
//  nothing happens; past it, correction engages and pulls Amount% of the way to the note,
//  gliding at Retune Speed. It lets go when the singer comes back within half the
//  tolerance, changes note, or stops singing. Humanize slows the retune on held notes.
//
//  Shifting — two crossfading delay-line taps kept exactly one detected period apart
//  (pitch-synchronous), so they stay in phase and don't comb. When idle the output
//  settles on one tap: latency is one pitch period (~4–8 ms for most voices).
//
//  Strict real-time contract: no allocations, locks, or Swift runtime calls in process().
//

import Accelerate
import AVFoundation
import Synchronization

nonisolated final class PitchGuideKernel: @unchecked Sendable {

    // MARK: - Parameters (main thread → audio thread)
    private let scaleMaskBits  = Atomic<UInt32>(0xFFF)               // bit n = pitch class n allowed
    private let retuneMsBits   = Atomic<UInt32>(Float(50).bitPattern)
    private let toleranceBits  = Atomic<UInt32>(Float(10).bitPattern) // cents
    private let amountBits     = Atomic<UInt32>(Float(1).bitPattern)  // 0…1
    private let humanizeBits   = Atomic<UInt32>(Float(0).bitPattern)  // 0…1
    private let pickinessBits  = Atomic<UInt32>(Float(0.5).bitPattern) // 0…1
    private let gateDBBits     = Atomic<UInt32>(Float(-45).bitPattern)
    private let minHzBits      = Atomic<UInt32>(Float(120).bitPattern)
    private let maxHzBits      = Atomic<UInt32>(Float(800).bitPattern)

    // MARK: - Meters (audio thread → main thread)
    /// Detected input note as fractional MIDI number; < 0 when nothing is being tracked
    let detectedMidiBits   = Atomic<UInt32>(Float(-1).bitPattern)
    /// Target note (integer MIDI); < 0 when not correcting
    let targetMidiBits     = Atomic<UInt32>(Float(-1).bitPattern)
    /// Correction being applied right now, in cents
    let correctionBits     = Atomic<UInt32>(Float(0).bitPattern)

    // MARK: - Buffers (allocated once)
    private static let ringSize = 8_192                 // power of two; > 2 × max period at 96 kHz
    private static let maxLag = 2_048                   // 96 kHz / 50 Hz, rounded up
    private static let hop = 256
    private let ring = UnsafeMutablePointer<Float>.allocate(capacity: ringSize)
    private let frame = UnsafeMutablePointer<Float>.allocate(capacity: maxLag * 2 + 4)
    private let squares = UnsafeMutablePointer<Float>.allocate(capacity: maxLag * 2 + 4)
    private let corr = UnsafeMutablePointer<Float>.allocate(capacity: maxLag + 4)
    private let cmnd = UnsafeMutablePointer<Float>.allocate(capacity: maxLag + 4)

    // MARK: - Audio thread state
    private(set) var sampleRate: Double = 48_000
    private var writeIndex = 0
    private var hopCounter = 0

    // Detection / decision
    private var lastMidi: Float = -1
    private var stableHops = 0
    private var engaged = false
    private var targetNote = -1
    private var noteHops = 0
    private var desiredCents: Float = 0
    private var smoothCoeff: Float = 1

    // Shifter
    private var period: Double = 300        // samples; last detected
    private var correction: Float = 0       // cents, smoothed
    private var ratio: Double = 1
    private var dA: Double = 300, wA: Double = 600
    private var dB: Double = 0,   wB: Double = 600

    init() {
        ring.initialize(repeating: 0, count: Self.ringSize)
        frame.initialize(repeating: 0, count: Self.maxLag * 2 + 4)
        squares.initialize(repeating: 0, count: Self.maxLag * 2 + 4)
        corr.initialize(repeating: 0, count: Self.maxLag + 4)
        cmnd.initialize(repeating: 0, count: Self.maxLag + 4)
    }

    deinit {
        ring.deallocate(); frame.deallocate(); squares.deallocate()
        corr.deallocate(); cmnd.deallocate()
    }

    // MARK: - Main thread API

    func setSampleRate(_ sr: Double) {
        guard sr > 0 else { return }
        sampleRate = sr
        period = sr / 250
        wA = 2 * period; wB = wA
        dA = period; dB = 0
    }

    @MainActor func applyParams(_ p: PitchGuideParams) {
        scaleMaskBits.store(p.allowedPitchClassMask, ordering: .relaxed)
        retuneMsBits.store(p.retuneSpeed.bitPattern, ordering: .relaxed)
        toleranceBits.store(p.tolerance.bitPattern, ordering: .relaxed)
        amountBits.store((p.amount / 100).bitPattern, ordering: .relaxed)
        humanizeBits.store((p.humanize / 100).bitPattern, ordering: .relaxed)
        pickinessBits.store((p.pickiness / 100).bitPattern, ordering: .relaxed)
        gateDBBits.store(p.gateThreshold.bitPattern, ordering: .relaxed)
        minHzBits.store(p.voiceRange.minHz.bitPattern, ordering: .relaxed)
        maxHzBits.store(p.voiceRange.maxHz.bitPattern, ordering: .relaxed)
    }

    // MARK: - Render (audio thread only — no allocations, no runtime)

    func process(_ ioData: UnsafeMutablePointer<AudioBufferList>, frameCount: Int) {
        let ptr = UnsafeMutableAudioBufferListPointer(ioData)
        guard !ptr.isEmpty, let d0 = ptr[0].mData else { return }
        let io = d0.assumingMemoryBound(to: Float.self)
        let mask = Self.ringSize - 1

        for i in 0..<frameCount {
            ring[writeIndex & mask] = io[i]
            writeIndex += 1

            hopCounter += 1
            if hopCounter >= Self.hop {
                hopCounter = 0
                analyze()
            }

            // Glide toward the desired correction (Retune Speed)
            correction += smoothCoeff * (desiredCents - correction)
            if (i & 15) == 0 { ratio = exp2(Double(correction) / 1200) }

            var r = ratio
            if desiredCents == 0 && abs(correction) < 0.1 {
                // Idle: drift (≤ ~2 cents, inaudible) until one tap sits mid-span at full gain
                let leadIsA = gain(dA, wA) >= gain(dB, wB)
                let d = leadIsA ? dA : dB, w = leadIsA ? wA : wB
                r = 1 - max(-0.001, min(0.001, 0.004 * (w / 2 - d) / w))
            }

            // Both taps move at (1 - r) samples per sample: r > 1 shrinks the delay = higher pitch
            let step = 1 - r
            dA += step; dB += step
            // A tap that runs off its span is silent there; re-seat it one period from the other
            if dA < 0 || dA > wA { wA = 2 * period; dA = clampDelay(dA < 0 ? dB + period : dB - period, wA) }
            if dB < 0 || dB > wB { wB = 2 * period; dB = clampDelay(dB < 0 ? dA + period : dA - period, wB) }

            let gA = gain(dA, wA), gB = gain(dB, wB)
            let norm = 1 / max(1e-6, gA + gB)
            var y = Float((gA * read(dA) + gB * read(dB)) * norm)
            if y.isNaN || y.isInfinite { y = 0 }
            io[i] = y
        }

        // Mono effect: every output channel gets the corrected signal
        for ch in 1..<max(1, ptr.count) {
            guard let d = ptr[ch].mData else { continue }
            d.assumingMemoryBound(to: Float.self).update(from: io, count: frameCount)
        }

        correctionBits.store(correction.bitPattern, ordering: .relaxed)
    }

    // MARK: - Shifter helpers

    /// Hann-shaped crossfade: silent at both ends of the span, full at the middle
    @inline(__always) private func gain(_ d: Double, _ w: Double) -> Double {
        let s = sin(Double.pi * max(0, min(1, d / w)))
        return s * s
    }

    @inline(__always) private func clampDelay(_ d: Double, _ w: Double) -> Double {
        max(0, min(w, d))
    }

    /// 4-point Hermite read `d` samples behind the newest sample (+2 so all 4 points exist)
    @inline(__always) private func read(_ d: Double) -> Double {
        let mask = Self.ringSize - 1
        let pos = Double(writeIndex - 1) - (d + 2)
        let i = Int(pos.rounded(.down))
        let t = pos - Double(i)
        let xm1 = Double(ring[(i - 1) & mask]), x0 = Double(ring[i & mask])
        let x1 = Double(ring[(i + 1) & mask]), x2 = Double(ring[(i + 2) & mask])
        let c1 = 0.5 * (x1 - xm1)
        let c2 = xm1 - 2.5 * x0 + 2 * x1 - 0.5 * x2
        let c3 = 0.5 * (x2 - xm1) + 1.5 * (x0 - x1)
        return ((c3 * t + c2) * t + c1) * t + x0
    }

    // MARK: - Detection + decision (once per hop)

    private func analyze() {
        let sr = Float(sampleRate)
        let minHz = max(50, Float(bitPattern: minHzBits.load(ordering: .relaxed)))
        let maxHz = max(minHz * 2, Float(bitPattern: maxHzBits.load(ordering: .relaxed)))
        let tauMax = min(Self.maxLag - 2, Int(sr / minHz))
        let tauMin = max(2, Int(sr / maxHz))
        let window = tauMax
        let total = window + tauMax + 2

        // Latest `total` samples, oldest first
        let mask = Self.ringSize - 1
        let start = writeIndex - total
        for k in 0..<total { frame[k] = ring[(start + k) & mask] }

        vDSP_vsq(frame, 1, squares, 1, vDSP_Length(total))
        var e0: Float = 0
        vDSP_sve(squares, 1, &e0, vDSP_Length(window))

        let levelDB = 10 * log10(max(e0 / Float(window), 1e-12))
        let gateDB = Float(bitPattern: gateDBBits.load(ordering: .relaxed))
        let pickiness = Float(bitPattern: pickinessBits.load(ordering: .relaxed))
        let threshold = 0.25 - 0.15 * pickiness            // lenient 0.25 … strict 0.10
        let requiredHops = 1 + Int(pickiness * 4)          // ~5 ms … ~27 ms of steady pitch

        var foundTau = -1
        if levelDB > gateDB {
            // r(τ) = Σ x[p]·x[p+τ] for τ = 0…tauMax+1 — skipped below the gate to save CPU
            vDSP_conv(frame, 1, frame, 1, corr, 1, vDSP_Length(tauMax + 2), vDSP_Length(window))
            // YIN cumulative-mean-normalised difference
            var eTau = e0, running: Float = 0
            cmnd[0] = 1
            for tau in 1...tauMax + 1 {
                eTau += squares[tau + window - 1] - squares[tau - 1]
                let d = max(0, e0 + eTau - 2 * corr[tau])
                running += d
                cmnd[tau] = running > 0 ? d * Float(tau) / running : 1
            }
            var tau = tauMin
            while tau <= tauMax {
                if cmnd[tau] < threshold {
                    while tau + 1 <= tauMax && cmnd[tau + 1] < cmnd[tau] { tau += 1 }
                    foundTau = tau
                    break
                }
                tau += 1
            }
        }

        guard foundTau > 0 else { release(); return }

        // Parabolic interpolation for sub-sample period
        let a = cmnd[foundTau - 1], b = cmnd[foundTau], c = cmnd[foundTau + 1]
        let denom = a - 2 * b + c
        let shift = denom != 0 ? max(-0.5, min(0.5, 0.5 * (a - c) / denom)) : 0
        let tauExact = Float(foundTau) + shift
        let hz = sr / tauExact
        let midi = 69 + 12 * log2(hz / 440)

        period = Double(tauExact)
        stableHops = abs(midi - lastMidi) < 0.75 ? stableHops + 1 : 1
        lastMidi = midi
        detectedMidiBits.store(midi.bitPattern, ordering: .relaxed)
        guard stableHops >= requiredHops else { return }

        // Nearest allowed note
        let allowed = scaleMaskBits.load(ordering: .relaxed) & 0xFFF
        let note = nearestNote(to: midi, allowed: allowed == 0 ? 0xFFF : allowed)
        let errorCents = (Float(note) - midi) * 100
        let tolerance = Float(bitPattern: toleranceBits.load(ordering: .relaxed))

        if note != targetNote {
            targetNote = note
            noteHops = 0
            engaged = abs(errorCents) > tolerance
        } else {
            noteHops += 1
            if engaged {
                if abs(errorCents) < tolerance * 0.5 { engaged = false }   // back in tune: let go
            } else if abs(errorCents) > tolerance {
                engaged = true
            }
        }

        let amount = Float(bitPattern: amountBits.load(ordering: .relaxed))
        desiredCents = engaged ? errorCents * amount : 0
        targetMidiBits.store(Float(engaged ? note : -1).bitPattern, ordering: .relaxed)

        // Retune Speed, slowed on held notes by Humanize (fast on short notes, looser on long ones)
        var retuneMs = Float(bitPattern: retuneMsBits.load(ordering: .relaxed))
        let heldSeconds = Float(noteHops * Self.hop) / sr
        if heldSeconds > 0.15 {
            retuneMs *= 1 + 3 * Float(bitPattern: humanizeBits.load(ordering: .relaxed))
        }
        smoothCoeff = retuneMs < 1 ? 1 : 1 - exp(-1 / (sr * retuneMs / 1000))
    }

    /// Nothing sung (or not confidently): glide back to no correction
    private func release() {
        stableHops = 0
        lastMidi = -1
        engaged = false
        targetNote = -1
        desiredCents = 0
        smoothCoeff = 1 - exp(-1 / (Float(sampleRate) * 0.03))
        detectedMidiBits.store(Float(-1).bitPattern, ordering: .relaxed)
        targetMidiBits.store(Float(-1).bitPattern, ordering: .relaxed)
    }

    private func nearestNote(to midi: Float, allowed: UInt32) -> Int {
        let base = Int(midi.rounded())
        var best = base, bestDist = Float.greatestFiniteMagnitude
        for offset in -6...6 {
            let n = base + offset
            guard allowed & (1 << UInt32(((n % 12) + 12) % 12)) != 0 else { continue }
            let dist = abs(Float(n) - midi)
            if dist < bestDist { best = n; bestDist = dist }
        }
        return best
    }
}
