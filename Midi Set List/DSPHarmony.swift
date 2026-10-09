//
//  DSPHarmony.swift
//  Midi Set List
//
//  Real-time DSP kernel for Harmony: up to three key-aware harmony voices generated from
//  the singer (first input of the channel).
//
//  Detection — YIN every 256 samples, the same detector as Pitch Guide: above the gate,
//  inside the voice range, clearly periodic (threshold set by Pickiness) and steady for
//  a few frames.
//
//  Harmony — the sung pitch is snapped to the nearest note of the key/scale; each voice's
//  interval is counted in scale steps from there (a 3rd above C in C major is E, above D
//  it's F). The voice is the singer's own pitch shifted by that many semitones, so it
//  carries their vibrato, slides and timing. Scales that aren't seven notes (pentatonic,
//  blues, chromatic) use the nearest fitting interval instead of counting steps.
//  Between phrases, and on breaths and consonants, the voices fade out rather than shift
//  noise.
//
//  Shifting — PSOLA (as in Pitch Guide): one-period grains cut from the input and laid
//  back down every period ÷ ratio, so the harmonies keep the singer's tone (formants).
//  Gender reads each grain faster (+, smaller/brighter) or slower (−, bigger/deeper),
//  moving the formants without moving the pitch.
//  Latency ≈ two pitch periods (~8–17 ms) at Gender 0: about 1.7 periods at +6 and 2.4 at
//  −6, plus Humanize's delay. The lead (dry) signal passes with no added latency.
//
//  Strict real-time contract: no allocations, locks, or Swift runtime calls in process().
//

import Accelerate
import AVFoundation
import Synchronization

nonisolated final class HarmonyKernel: @unchecked Sendable {

    static let voiceCount = 3

    // MARK: - Parameters (main thread → audio thread)
    private let scaleMaskBits = Atomic<UInt32>(0xAB5)                 // C major
    private let pickinessBits = Atomic<UInt32>(Float(0.5).bitPattern)
    private let gateDBBits    = Atomic<UInt32>(Float(-45).bitPattern)
    private let minHzBits     = Atomic<UInt32>(Float(120).bitPattern)
    private let maxHzBits     = Atomic<UInt32>(Float(800).bitPattern)
    private let humanizeBits  = Atomic<UInt32>(Float(0.3).bitPattern) // 0…1
    private let leadGainBits  = Atomic<UInt32>(Float(1).bitPattern)   // linear; 0 = lead off
    private let enabled0 = Atomic<Bool>(true), enabled1 = Atomic<Bool>(false), enabled2 = Atomic<Bool>(false)
    private let interval0 = Atomic<Int>(HarmonyInterval.thirdAbove.rawValue)
    private let interval1 = Atomic<Int>(HarmonyInterval.fourthBelow.rawValue)
    private let interval2 = Atomic<Int>(HarmonyInterval.octaveBelow.rawValue)
    private let gain0 = Atomic<UInt32>(Float(1).bitPattern), gain1 = Atomic<UInt32>(Float(1).bitPattern)
    private let gain2 = Atomic<UInt32>(Float(1).bitPattern)
    private let pan0 = Atomic<UInt32>(Float(-0.4).bitPattern), pan1 = Atomic<UInt32>(Float(0.4).bitPattern)
    private let pan2 = Atomic<UInt32>(Float(0).bitPattern)
    /// Gender as a formant read rate: 2^(semitones/12); 1 = the singer's own tone
    private let formant0 = Atomic<UInt32>(Float(1).bitPattern), formant1 = Atomic<UInt32>(Float(1).bitPattern)
    private let formant2 = Atomic<UInt32>(Float(1).bitPattern)

    // MARK: - Meters (audio thread → main thread)
    /// Detected sung note as fractional MIDI; < 0 when nothing is tracked
    let detectedMidiBits = Atomic<UInt32>(Float(-1).bitPattern)
    /// Note each voice is singing (integer MIDI); < 0 when silent
    let voiceMidi0 = Atomic<UInt32>(Float(-1).bitPattern)
    let voiceMidi1 = Atomic<UInt32>(Float(-1).bitPattern)
    let voiceMidi2 = Atomic<UInt32>(Float(-1).bitPattern)
    /// Latency of the slowest sounding voice right now, ms (Humanize delay included)
    let latencyMsBits = Atomic<UInt32>(Float(0).bitPattern)
    /// Input level of the latest analysis window, dBFS RMS (Learn Voice reads this)
    let inputLevelBits = Atomic<UInt32>(Float(-120).bitPattern)
    let singingFlag = Atomic<Bool>(false)

    // MARK: - Buffers (allocated once)
    private static let ringSize = 16_384                // power of two; window + Humanize delay at 96 kHz
    private static let mask = ringSize - 1
    private static let maxLag = 2_048                   // 96 kHz / 50 Hz, rounded up
    private static let hop = 256
    private let ring = UnsafeMutablePointer<Float>.allocate(capacity: ringSize)
    private let frame = UnsafeMutablePointer<Float>.allocate(capacity: maxLag * 2 + 4)
    private let squares = UnsafeMutablePointer<Float>.allocate(capacity: maxLag * 2 + 4)
    private let corr = UnsafeMutablePointer<Float>.allocate(capacity: maxLag + 4)
    private let cmnd = UnsafeMutablePointer<Float>.allocate(capacity: maxLag + 4)

    // MARK: - Audio thread state
    private var sampleRate: Double = 48_000
    private var writeIndex = 0
    private var hopCounter = 0
    private var period: Double = 192
    private var lastMidi: Float = -1
    private var stableHops = 0
    private var lastVoicedIndex = Int.min / 2
    /// Snapped sung note while a note is held; −1 before the first one
    private var sungNote = -1
    private var voice0: Voice
    private var voice1: Voice
    private var voice2: Voice
    private var leadGain: Float = 1
    private var lfoPhase: (Double, Double, Double) = (0, 0.3, 0.6)

    init() {
        ring.initialize(repeating: 0, count: Self.ringSize)
        frame.initialize(repeating: 0, count: Self.maxLag * 2 + 4)
        squares.initialize(repeating: 0, count: Self.maxLag * 2 + 4)
        corr.initialize(repeating: 0, count: Self.maxLag + 4)
        cmnd.initialize(repeating: 0, count: Self.maxLag + 4)
        voice0 = Voice(size: Self.ringSize)
        voice1 = Voice(size: Self.ringSize)
        voice2 = Voice(size: Self.ringSize)
    }

    deinit {
        ring.deallocate(); frame.deallocate(); squares.deallocate()
        corr.deallocate(); cmnd.deallocate()
        voice0.ola.deallocate(); voice0.olaWin.deallocate()
        voice1.ola.deallocate(); voice1.olaWin.deallocate()
        voice2.ola.deallocate(); voice2.olaWin.deallocate()
    }

    // MARK: - Main thread API

    func setSampleRate(_ sr: Double) {
        guard sr > 0 else { return }
        sampleRate = sr
        period = sr / 250
        voice0.primed = false
        voice1.primed = false
        voice2.primed = false
    }

    /// `p` already resolved to the song key where it follows it
    @MainActor func applyParams(_ p: HarmonyParams) {
        scaleMaskBits.store(p.allowedPitchClassMask, ordering: .relaxed)
        pickinessBits.store((p.pickiness / 100).bitPattern, ordering: .relaxed)
        gateDBBits.store(p.gateThreshold.bitPattern, ordering: .relaxed)
        minHzBits.store(p.voiceRange.minHz.bitPattern, ordering: .relaxed)
        maxHzBits.store(p.voiceRange.maxHz.bitPattern, ordering: .relaxed)
        humanizeBits.store((p.humanize / 100).bitPattern, ordering: .relaxed)
        leadGainBits.store(p.leadGain.bitPattern, ordering: .relaxed)
        enabled0.store(p.voice1.enabled, ordering: .relaxed)
        enabled1.store(p.voice2.enabled, ordering: .relaxed)
        enabled2.store(p.voice3.enabled, ordering: .relaxed)
        interval0.store(p.voice1.interval.rawValue, ordering: .relaxed)
        interval1.store(p.voice2.interval.rawValue, ordering: .relaxed)
        interval2.store(p.voice3.interval.rawValue, ordering: .relaxed)
        gain0.store(p.voice1.gain.bitPattern, ordering: .relaxed)
        gain1.store(p.voice2.gain.bitPattern, ordering: .relaxed)
        gain2.store(p.voice3.gain.bitPattern, ordering: .relaxed)
        pan0.store((p.voice1.pan / 100).bitPattern, ordering: .relaxed)
        pan1.store((p.voice2.pan / 100).bitPattern, ordering: .relaxed)
        pan2.store((p.voice3.pan / 100).bitPattern, ordering: .relaxed)
        formant0.store(p.voice1.formantRate.bitPattern, ordering: .relaxed)
        formant1.store(p.voice2.formantRate.bitPattern, ordering: .relaxed)
        formant2.store(p.voice3.formantRate.bitPattern, ordering: .relaxed)
    }

    // MARK: - Render (audio thread only — no allocations, no runtime)

    func process(_ ioData: UnsafeMutablePointer<AudioBufferList>, frameCount: Int) {
        let ptr = UnsafeMutableAudioBufferListPointer(ioData)
        guard !ptr.isEmpty, let l = ptr[0].mData?.assumingMemoryBound(to: Float.self) else { return }
        let r = ptr.count > 1 ? ptr[1].mData?.assumingMemoryBound(to: Float.self) : nil

        let leadTarget = Float(bitPattern: leadGainBits.load(ordering: .relaxed))
        let humanize = Double(Float(bitPattern: humanizeBits.load(ordering: .relaxed)))
        let enabled = (enabled0.load(ordering: .relaxed), enabled1.load(ordering: .relaxed),
                       enabled2.load(ordering: .relaxed))
        let gains = (Float(bitPattern: gain0.load(ordering: .relaxed)),
                     Float(bitPattern: gain1.load(ordering: .relaxed)),
                     Float(bitPattern: gain2.load(ordering: .relaxed)))
        let phis = (Self.formantRate(formant0), Self.formantRate(formant1), Self.formantRate(formant2))
        // Equal-power pan
        func lr(_ atomic: borrowing Atomic<UInt32>) -> (Float, Float) {
            let p = Double(Float(bitPattern: atomic.load(ordering: .relaxed)))
            let a = (max(-1, min(1, p)) + 1) * Double.pi / 4
            return (Float(cos(a)), Float(sin(a)))
        }
        let panLR = (lr(pan0), lr(pan1), lr(pan2))

        // Humanize: voice 1 a little sharp and late, voice 2 a little flat and later, voice 3
        // slightly sharp and in between, each with its own slow drift, like real singers
        let drift = (sin(2 * Double.pi * lfoPhase.0), sin(2 * Double.pi * lfoPhase.1),
                     sin(2 * Double.pi * lfoPhase.2))
        let advance = Double(frameCount) / sampleRate
        lfoPhase.0 += 0.23 * advance; lfoPhase.0 -= lfoPhase.0.rounded(.down)
        lfoPhase.1 += 0.31 * advance; lfoPhase.1 -= lfoPhase.1.rounded(.down)
        lfoPhase.2 += 0.17 * advance; lfoPhase.2 -= lfoPhase.2.rounded(.down)
        let detune = (humanize * (6 + 3 * drift.0), -humanize * (6 + 3 * drift.1),
                      humanize * (3 + 3 * drift.2))
        let delays = (humanize * 0.020 * sampleRate, humanize * 0.032 * sampleRate,
                      humanize * 0.026 * sampleRate)

        let mix = VoiceMix(openCoeff: Float(1 - exp(-1 / (sampleRate * 0.008))),
                           closeCoeff: Float(1 - exp(-1 / (sampleRate * 0.040))),
                           glideCoeff: 1 - exp(-1 / (sampleRate * 0.012)))
        let leadCoeff = Float(1 - exp(-1 / (sampleRate * 0.020)))
        let holdSamples = Int(sampleRate * 0.06)

        // Work on locals; written back once per buffer
        var v0 = voice0, v1 = voice1, v2 = voice2
        var lead = leadGain
        for i in 0..<frameCount {
            let dryL = l[i]
            let dryR = r?[i] ?? dryL
            ring[writeIndex & Self.mask] = dryL
            writeIndex += 1

            hopCounter += 1
            if hopCounter >= Self.hop {
                hopCounter = 0
                analyze(&v0, &v1, &v2)
            }

            let voiced = writeIndex - lastVoicedIndex < holdSamples && sungNote >= 0
            let t = writeIndex - 1
            let refresh = (i & 15) == 0
            let y0 = render(&v0, on: enabled.0 && voiced, at: t, refresh: refresh,
                            detune: detune.0, delay: delays.0, phi: phis.0, mix: mix) * gains.0
            let y1 = render(&v1, on: enabled.1 && voiced, at: t, refresh: refresh,
                            detune: detune.1, delay: delays.1, phi: phis.1, mix: mix) * gains.1
            let y2 = render(&v2, on: enabled.2 && voiced, at: t, refresh: refresh,
                            detune: detune.2, delay: delays.2, phi: phis.2, mix: mix) * gains.2
            lead += leadCoeff * (leadTarget - lead)

            l[i] = dryL * lead + y0 * panLR.0.0 + y1 * panLR.1.0 + y2 * panLR.2.0
            r?[i] = dryR * lead + y0 * panLR.0.1 + y1 * panLR.1.1 + y2 * panLR.2.1
        }
        voice0 = v0
        voice1 = v1
        voice2 = v2
        leadGain = lead

        singingFlag.store(writeIndex - lastVoicedIndex < holdSamples, ordering: .relaxed)
        func sounding(_ on: Bool, _ v: Voice) -> UInt32 {
            on && v.env > 0.5 && sungNote >= 0 ? Float(sungNote + Int(v.targetSemis)).bitPattern
                                                : Float(-1).bitPattern
        }
        voiceMidi0.store(sounding(enabled.0, v0), ordering: .relaxed)
        voiceMidi1.store(sounding(enabled.1, v1), ordering: .relaxed)
        voiceMidi2.store(sounding(enabled.2, v2), ordering: .relaxed)
        // Grain latency: half the output grain plus the half-span it reads, plus the delay
        func latency(_ on: Bool, _ v: Voice, _ phi: Double, _ delay: Double) -> Double {
            guard on else { return 0 }
            let h = max(period / phi, 0.75 * period / max(0.5, min(2, v.ratio)))
            return h + h * phi + 2 + delay
        }
        let worst = max(latency(enabled.0, v0, phis.0, delays.0), latency(enabled.1, v1, phis.1, delays.1),
                        latency(enabled.2, v2, phis.2, delays.2))
        latencyMsBits.store(Float(worst / sampleRate * 1000).bitPattern, ordering: .relaxed)
    }

    @inline(__always)
    private static func formantRate(_ atomic: borrowing Atomic<UInt32>) -> Double {
        max(0.5, min(2, Double(Float(bitPattern: atomic.load(ordering: .relaxed)))))
    }

    private struct VoiceMix {
        let openCoeff: Float, closeCoeff: Float, glideCoeff: Double
    }

    /// One output sample of a harmony voice (before its level and pan)
    @inline(__always)
    private func render(_ v: inout Voice, on: Bool, at t: Int, refresh: Bool,
                        detune: Double, delay: Double, phi: Double, mix: VoiceMix) -> Float {
        let target: Float = on ? 1 : 0
        v.env += (target > v.env ? mix.openCoeff : mix.closeCoeff) * (target - v.env)
        // Faded out: stop working, and start fresh at the next phrase
        guard v.env > 1e-4 || on else {
            v.primed = false
            return 0
        }
        v.semis += mix.glideCoeff * (v.targetSemis - v.semis)
        if refresh { v.ratio = exp2((v.semis * 100 + detune) / 1200) }
        if !v.primed { v.prime(at: t, period: period, delay: delay) }
        emitGrains(&v, upTo: t, delay: delay, phi: phi)

        let idx = t & Self.mask
        var y = v.ola[idx] / max(v.olaWin[idx], 0.25)
        v.ola[idx] = 0; v.olaWin[idx] = 0
        if y.isNaN || y.isInfinite { y = 0 }
        return y * v.env
    }

    // MARK: - PSOLA

    private struct Voice {
        let ola: UnsafeMutablePointer<Float>
        let olaWin: UnsafeMutablePointer<Float>
        var primed = false
        var nextMark: Double = 0
        var lastCenter: Double = 0
        var ratio: Double = 1
        var semis: Double = 0
        var targetSemis: Double = 0
        var env: Float = 0

        init(size: Int) {
            ola = .allocate(capacity: size)
            olaWin = .allocate(capacity: size)
            ola.initialize(repeating: 0, count: size)
            olaWin.initialize(repeating: 0, count: size)
        }

        mutating func prime(at t: Int, period: Double, delay: Double) {
            ola.update(repeating: 0, count: HarmonyKernel.ringSize)
            olaWin.update(repeating: 0, count: HarmonyKernel.ringSize)
            let h = max(16, min(Double(HarmonyKernel.maxLag), period.rounded()))
            nextMark = Double(t) + h
            lastCenter = Double(t) - 2 * h - 2 - delay
            semis = targetSemis
            ratio = exp2(semis / 12)
            primed = true
        }
    }

    /// Lays down every grain of `v` whose span starts at or before output time `t`
    private func emitGrains(_ v: inout Voice, upTo t: Int, delay: Double, phi: Double) {
        while true {
            let r = max(0.5, min(2, v.ratio))
            let hop = period / r
            // Output half-length: one period re-scaled by Gender (reading a grain faster
            // squeezes its resonances up), but always long enough to reach the next grain
            let h = max(16, min(Self.maxLag, Int(max(period / phi, 0.75 * hop).rounded())))
            let span = Double(h) * phi              // input half-span the grain reads
            let mark = Int(v.nextMark.rounded())
            guard mark - h <= t else { break }

            // Cut as recently as the input (and Humanize's delay) allows, stepping from the last
            // cut by whole periods so grains line up in phase
            let target = Double(mark - h) - span - 2 - delay
            var center = v.lastCenter + ((target - v.lastCenter) / period).rounded() * period
            while center + span + 2 > Double(t) { center -= period }
            if center < target - 4 * period { center = target }   // lost sync (new phrase)
            v.lastCenter = center

            let hD = Double(h)
            for j in -h...h {
                let w = 0.5 + 0.5 * cos(Double.pi * Double(j) / hD)
                let o = (mark + j) & Self.mask
                v.ola[o] += Float(w * readAbsolute(center + Double(j) * phi))
                v.olaWin[o] += Float(w)
            }
            v.nextMark += hop
        }
    }

    /// 4-point Hermite read at absolute input time `pos`
    @inline(__always) private func readAbsolute(_ pos: Double) -> Double {
        let i = Int(pos.rounded(.down))
        let t = pos - Double(i)
        let xm1 = Double(ring[(i - 1) & Self.mask]), x0 = Double(ring[i & Self.mask])
        let x1 = Double(ring[(i + 1) & Self.mask]), x2 = Double(ring[(i + 2) & Self.mask])
        let c1 = 0.5 * (x1 - xm1)
        let c2 = xm1 - 2.5 * x0 + 2 * x1 - 0.5 * x2
        let c3 = 0.5 * (x2 - xm1) + 1.5 * (x0 - x1)
        return ((c3 * t + c2) * t + c1) * t + x0
    }

    // MARK: - Detection + harmony choice (once per hop)

    private func analyze(_ v0: inout Voice, _ v1: inout Voice, _ v2: inout Voice) {
        let sr = Float(sampleRate)
        let minHz = max(50, Float(bitPattern: minHzBits.load(ordering: .relaxed)))
        let maxHz = max(minHz * 2, Float(bitPattern: maxHzBits.load(ordering: .relaxed)))
        let tauMax = min(Self.maxLag - 2, Int(sr / minHz))
        let tauMin = max(2, Int(sr / maxHz))
        let window = tauMax
        let total = window + tauMax + 2

        let start = writeIndex - total
        for k in 0..<total { frame[k] = ring[(start + k) & Self.mask] }

        vDSP_vsq(frame, 1, squares, 1, vDSP_Length(total))
        var e0: Float = 0
        vDSP_sve(squares, 1, &e0, vDSP_Length(window))

        let levelDB = 10 * log10(max(e0 / Float(window), 1e-12))
        inputLevelBits.store(levelDB.bitPattern, ordering: .relaxed)
        let gateDB = Float(bitPattern: gateDBBits.load(ordering: .relaxed))
        let pickiness = Float(bitPattern: pickinessBits.load(ordering: .relaxed))
        let threshold = 0.25 - 0.15 * pickiness
        let requiredHops = 1 + Int(pickiness * 4)

        var foundTau = -1
        if levelDB > gateDB {
            vDSP_conv(frame, 1, frame, 1, corr, 1, vDSP_Length(tauMax + 2), vDSP_Length(window))
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

        guard foundTau > 0 else {
            stableHops = 0
            lastMidi = -1
            detectedMidiBits.store(Float(-1).bitPattern, ordering: .relaxed)
            return
        }

        let a = cmnd[foundTau - 1], b = cmnd[foundTau], c = cmnd[foundTau + 1]
        let denom = a - 2 * b + c
        let shift = denom != 0 ? max(-0.5, min(0.5, 0.5 * (a - c) / denom)) : 0
        let tauExact = Float(foundTau) + shift
        let midi = 69 + 12 * log2(sr / tauExact / 440)

        period = Double(tauExact)
        stableHops = abs(midi - lastMidi) < 0.75 ? stableHops + 1 : 1
        lastMidi = midi
        detectedMidiBits.store(midi.bitPattern, ordering: .relaxed)
        guard stableHops >= requiredHops else { return }
        lastVoicedIndex = writeIndex

        let allowed = scaleMaskBits.load(ordering: .relaxed) & 0xFFF
        let scale = allowed == 0 ? 0xFFF : allowed
        let note = Self.nearestNote(to: midi, allowed: scale)
        sungNote = note
        let i0 = HarmonyInterval(rawValue: interval0.load(ordering: .relaxed)) ?? .thirdAbove
        let i1 = HarmonyInterval(rawValue: interval1.load(ordering: .relaxed)) ?? .fourthBelow
        let i2 = HarmonyInterval(rawValue: interval2.load(ordering: .relaxed)) ?? .octaveBelow
        v0.targetSemis = Double(Self.harmonyNote(from: note, interval: i0, allowed: scale) - note)
        v1.targetSemis = Double(Self.harmonyNote(from: note, interval: i1, allowed: scale) - note)
        v2.targetSemis = Double(Self.harmonyNote(from: note, interval: i2, allowed: scale) - note)
    }

    static func nearestNote(to midi: Float, allowed: UInt32) -> Int {
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

    /// The harmony note for `note`: counted in scale steps in a seven-note scale, otherwise
    /// the first of the interval's usual sizes that lands in the scale (or the nearest note
    /// of the scale to it)
    static func harmonyNote(from note: Int, interval: HarmonyInterval, allowed: UInt32) -> Int {
        func inScale(_ n: Int) -> Bool { allowed & (1 << UInt32(((n % 12) + 12) % 12)) != 0 }
        if allowed.nonzeroBitCount == 7 {
            let direction = interval.steps > 0 ? 1 : -1
            var n = note, remaining = abs(interval.steps)
            while remaining > 0 {
                n += direction
                if inScale(n) { remaining -= 1 }
            }
            return n
        }
        let sizes = interval.semitones
        if inScale(note + sizes.0) { return note + sizes.0 }
        if let b = sizes.1, inScale(note + b) { return note + b }
        if let c = sizes.2, inScale(note + c) { return note + c }
        // None fits (e.g. no 3rd in a pentatonic scale from this note): the nearest note in
        // the key, on the same side of the singer, so the voice never leaves the key
        let base = note + sizes.0
        func fits(_ n: Int) -> Bool { inScale(n) && (n - note).signum() == sizes.0.signum() }
        for offset in 1...6 {
            if fits(base + offset) { return base + offset }
            if fits(base - offset) { return base - offset }
        }
        return base
    }
}
