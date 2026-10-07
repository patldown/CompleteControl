//
//  RingOutAnalyzer.swift
//  Midi Set List
//
//  Ring-out mode for the Feedback Notch effect. Every 25 ms it reads the latest
//  4096 processed samples from the kernel's tap, runs an FFT, and looks for a
//  feedback signature: one narrow spike, well above its neighbours, holding the
//  same pitch for several frames without dying away. When it finds one it adds a
//  notch there (or deepens the existing one) and waits briefly for the room to settle.
//
//  Runs on the main thread; one 4096-point FFT costs a few microseconds.
//

import Accelerate
import Foundation
import Observation

@Observable
final class RingOutAnalyzer {
    private(set) var isRunning = false
    /// Loudest ringing candidate right now, for display
    private(set) var candidateFrequency: Float?
    private(set) var lastAction: String?

    // Internal state below changes every tick and isn't shown, so keep it out of observation
    @ObservationIgnored private let kernel: FeedbackNotchKernel
    @ObservationIgnored private var getParams: () -> FeedbackNotchParams = { .init() }
    @ObservationIgnored private var setParams: (FeedbackNotchParams) -> Void = { _ in }
    @ObservationIgnored private var timer: Timer?

    // FFT
    private static let size = 4096
    private static let log2Size = vDSP_Length(12)
    @ObservationIgnored private let fft = FFTResource(log2n: log2Size)
    @ObservationIgnored private var window = [Float](repeating: 0, count: size)
    @ObservationIgnored private var samples = [Float](repeating: 0, count: size)
    @ObservationIgnored private var windowed = [Float](repeating: 0, count: size)
    @ObservationIgnored private var real = [Float](repeating: 0, count: size / 2)
    @ObservationIgnored private var imag = [Float](repeating: 0, count: size / 2)
    @ObservationIgnored private var power = [Float](repeating: 0, count: size / 2)
    @ObservationIgnored private var lastTapEnd = -1

    // Detection state
    @ObservationIgnored private var candidateBin: Int?
    @ObservationIgnored private var candidateFrames = 0
    @ObservationIgnored private var candidateStartDB: Float = 0
    @ObservationIgnored private var cooldownUntil = Date.distantPast

    init(kernel: FeedbackNotchKernel) {
        self.kernel = kernel
        vDSP_hann_window(&window, vDSP_Length(Self.size), Int32(vDSP_HANN_DENORM))
    }

    func start(get: @escaping () -> FeedbackNotchParams, set: @escaping (FeedbackNotchParams) -> Void) {
        getParams = get
        setParams = set
        resetCandidate()
        lastAction = nil
        isRunning = true
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.025, repeats: true) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self else { t.invalidate(); return }
                self.tick()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        isRunning = false
        candidateFrequency = nil
    }

    // MARK: - Analysis

    private func tick() {
        let n = Self.size
        guard let end = samples.withUnsafeMutableBufferPointer({
            kernel.readRecentSamples(into: $0.baseAddress!, count: n, previousEnd: lastTapEnd)
        }) else { return }
        lastTapEnd = end

        vDSP_vmul(samples, 1, window, 1, &windowed, 1, vDSP_Length(n))
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                windowed.withUnsafeBytes { raw in
                    vDSP_ctoz(raw.bindMemory(to: DSPComplex.self).baseAddress!, 2,
                              &split, 1, vDSP_Length(n / 2))
                }
                vDSP_fft_zrip(fft.setup, &split, 1, Self.log2Size, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(n / 2))
            }
        }

        // Power → dBFS for a sine (zrip output is 2× the DFT; Hann halves the peak)
        let normDB = 20 * log10(Float(n) / 2)
        let sr = Float(kernel.sampleRate)
        let binHz = sr / Float(n)
        let lo = max(16, Int(80 / binHz))
        let hi = min(n / 2 - 16, Int(12_000 / binHz))
        guard lo < hi else { return }

        var peakBin = lo
        for k in lo...hi where power[k] > power[peakBin] { peakBin = k }
        func db(_ k: Int) -> Float { 10 * log10(max(power[k], 1e-20)) - normDB }
        let peakDB = db(peakBin)

        // Feedback is loud and narrow: compare against the bins either side of the main lobe
        var neighbourSum: Float = 0
        for off in 4...12 { neighbourSum += db(peakBin - off) + db(peakBin + off) }
        let prominence = peakDB - neighbourSum / 18

        let params = getParams()
        let sensitivity = max(0, min(100, params.sensitivity))
        let requiredProminence = 30 - 0.2 * sensitivity          // 30 dB … 10 dB
        let requiredFrames = max(3, Int(10 - sensitivity / 15))  // ~250 … ~75 ms after the window fills

        guard peakDB > -50, prominence >= requiredProminence else {
            resetCandidate()
            return
        }

        // Parabolic interpolation on the dB values for sub-bin frequency accuracy
        let a = db(peakBin - 1), b = peakDB, c = db(peakBin + 1)
        let denom = a - 2 * b + c
        let offset = denom != 0 ? max(-0.5, min(0.5, 0.5 * (a - c) / denom)) : 0
        let frequency = (Float(peakBin) + offset) * binHz
        candidateFrequency = frequency

        guard Date() >= cooldownUntil else { return }

        if let bin = candidateBin, abs(bin - peakBin) <= 2 {
            candidateFrames += 1
        } else {
            candidateBin = peakBin
            candidateFrames = 1
            candidateStartDB = peakDB
            return
        }

        // Sustained at the same pitch and not dying away → feedback
        if candidateFrames >= requiredFrames && peakDB >= candidateStartDB - 6 {
            notch(at: frequency, params: params)
        }
    }

    private func notch(at frequency: Float, params: FeedbackNotchParams) {
        var p = params
        let label = FeedbackNotch.label(for: frequency)
        if let i = p.notches.firstIndex(where: { abs(log2($0.frequency / frequency)) < 1.0 / 12 }) {
            if p.notches[i].depth > p.maxDepth + 0.01 {
                p.notches[i].depth = max(p.maxDepth, p.notches[i].depth - 3)
                lastAction = "Deepened \(label) to \(Int(p.notches[i].depth)) dB"
            } else {
                lastAction = "\(label) is at max depth — back the gain off"
            }
        } else if p.notches.count < FeedbackNotchKernel.maxNotches {
            p.notches.append(FeedbackNotch(frequency: frequency, depth: max(p.maxDepth, -6)))
            p.notches.sort { $0.frequency < $1.frequency }
            lastAction = "Notched \(label)"
        } else {
            lastAction = "All \(FeedbackNotchKernel.maxNotches) notches used — back the gain off"
        }
        if p != params {
            setParams(p)
            kernel.applyParams(p)
        }
        cooldownUntil = Date().addingTimeInterval(0.4)
        resetCandidate()
    }

    private func resetCandidate() {
        candidateBin = nil
        candidateFrames = 0
        candidateFrequency = nil
    }
}

/// Owns the vDSP FFT setup so it's destroyed with the analyzer.
nonisolated private final class FFTResource {
    let setup: FFTSetup
    init(log2n: vDSP_Length) { setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))! }
    deinit { vDSP_destroy_fftsetup(setup) }
}
