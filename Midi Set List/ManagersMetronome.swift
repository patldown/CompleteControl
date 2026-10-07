//
//  Metronome.swift
//  Midi Set List
//
//  A click track for Perform. Clicks are synthesised sample by sample in the audio render
//  callback, and each sample works out where it falls in the bar from the system's host
//  clock — the same clock MIDI clock pulses are stamped with. So clicks land exactly on
//  the beat, stay locked to MIDI clock for as long as both run, and never drift.
//
//  Meant for a wired output (headphone jack, USB or Lightning interface). The output's
//  own delay is allowed for; wireless (Bluetooth, AirPlay) adds far more, so it's flagged.
//

import AVFoundation
import Foundation
import Observation
import Synchronization

@Observable
final class Metronome {
    static let shared = Metronome()

    private(set) var isRunning = false
    private(set) var bpm = 120
    private(set) var beatsPerBar = 4
    /// Host time of beat 1 of the first bar; the beat display counts from here
    private(set) var startHostTime: UInt64 = 0
    private(set) var beatTicks: UInt64 = HostTime.beatTicks(bpm: 120)
    /// Playing a one-bar count-in that stops by itself
    private(set) var isCountIn = false
    /// Set when the click is going somewhere wireless, where it will sound late
    private(set) var routeWarning: String?
    private(set) var lastError: String?

    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private let render = MetronomeRender()
    @ObservationIgnored private var countInTask: Task<Void, Never>?
    @ObservationIgnored private let prefs = UserPreferences.shared

    private init() {}

    /// Starts clicking at `bpm`, beat 1 at `startAt` (host time; nil = a moment from now).
    /// `countIn` plays one bar and stops.
    func start(bpm: Int, beatsPerBar: Int, startAt: UInt64? = nil, countIn: Bool = false) {
        stop()
        guard bpm > 0 else { return }
        self.bpm = bpm
        self.beatsPerBar = max(1, beatsPerBar)
        beatTicks = HostTime.beatTicks(bpm: bpm)
        startHostTime = startAt ?? (mach_absolute_time() + HostTime.ticks(seconds: Self.leadIn))
        isCountIn = countIn
        lastError = nil

        // Sound off: the beat display still runs from the same timeline
        if prefs.metronomeSound {
            do {
                try startAudio()
            } catch {
                lastError = "Couldn't start the click: \(error.localizedDescription)"
            }
        }
        isRunning = true

        if countIn {
            let bar = HostTime.seconds(ticks: Double(beatTicks) * Double(self.beatsPerBar))
            let untilStart = HostTime.seconds(ticks: Double(startHostTime) - Double(mach_absolute_time()))
            countInTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(max(0, untilStart) + bar))
                guard !Task.isCancelled else { return }
                self?.stop()
            }
        }
    }

    func stop() {
        countInTask?.cancel()
        countInTask = nil
        render.active.store(false, ordering: .relaxed)
        engine?.stop()
        engine = nil
        isRunning = false
        isCountIn = false
    }

    /// Volume changes apply while it's playing
    func applyVolume() {
        render.volumeBits.store(Float(prefs.metronomeVolume).bitPattern, ordering: .relaxed)
    }

    /// Moves the click to the output chosen in preferences — instantly, even mid-song
    func applyOutput() {
        let route = prefs.metronomeOutput
        render.outputChannel.store(route.channel, ordering: .relaxed)
        render.outputStereo.store(route.stereo, ordering: .relaxed)
    }

    /// Time from pressing start to the first click: long enough for the audio to get going
    static let leadIn: Double = 0.12

    /// Number of output channels on the current audio route (2 without an interface)
    static var currentOutputChannelCount: Int {
        max(2, AVAudioSession.sharedInstance().maximumOutputNumberOfChannels)
    }

    /// Number of stereo output channel pairs available on the current audio route.
    /// 1 = standard stereo; 2+ = multi-channel interface (Ch 1-2, Ch 3-4, …).
    static var currentOutputBusPairCount: Int {
        let n = AVAudioSession.sharedInstance().maximumOutputNumberOfChannels
        return n > 0 ? max(1, n / 2) : 1
    }

    // MARK: Audio

    private func startAudio() throws {
        let session = AVAudioSession.sharedInstance()
        // While the routing engine runs, leave its session exactly as it set it: changing the
        // category or its options re-routes the hardware and would interrupt live audio.
        // Otherwise playback is sufficient for the click output.
        if !AudioRoutingEngine.shared.isRunning {
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers, .defaultToSpeaker])
        }
        try session.setActive(true)
        routeWarning = Self.wirelessWarning(for: session.currentRoute)

        // Every output channel the interface has, so the click can move to any of them live
        try? session.setPreferredOutputNumberOfChannels(session.maximumOutputNumberOfChannels)
        let engine = AVAudioEngine()
        let sampleRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        let channels = engine.outputNode.outputFormat(forBus: 0).channelCount
        // More than two channels needs an explicit layout: discrete, in hardware order
        let outputFormat: AVAudioFormat? = channels <= 2
            ? AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: max(1, channels))
            : AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | channels)
                .map { AVAudioFormat(standardFormatWithSampleRate: sampleRate, channelLayout: $0) }
        guard sampleRate > 0, let outputFormat else { throw MetronomeError.noOutput }

        render.configure(startHostTime: startHostTime, beatTicks: beatTicks, beatsPerBar: beatsPerBar,
                         maxBeats: isCountIn ? beatsPerBar : nil,
                         volume: Float(prefs.metronomeVolume),
                         outputLatency: session.outputLatency, sampleRate: sampleRate)
        applyOutput()
        // The source renders every hardware output channel and writes the click only on the
        // chosen one(s), so moving the click is an atomic switch — no channel map, no restart
        let source = Self.makeSourceNode(render: render, format: outputFormat)
        engine.attach(source)
        engine.connect(source, to: engine.outputNode, format: outputFormat)

        engine.prepare()
        try engine.start()
        self.engine = engine
    }

    /// Built outside the main actor: the render block runs on the real-time audio thread
    private nonisolated static func makeSourceNode(render: MetronomeRender, format: AVAudioFormat) -> AVAudioSourceNode {
        AVAudioSourceNode(format: format) { isSilence, timeStamp, frameCount, bufferList in
            render.fill(timeStamp: timeStamp.pointee, frames: Int(frameCount),
                        buffers: UnsafeMutableAudioBufferListPointer(bufferList), isSilence: isSilence)
            return noErr
        }
    }

    private static func wirelessWarning(for route: AVAudioSessionRouteDescription) -> String? {
        let wireless: Set<AVAudioSession.Port> = [.bluetoothA2DP, .bluetoothLE, .bluetoothHFP, .airPlay]
        guard let output = route.outputs.first(where: { wireless.contains($0.portType) }) else { return nil }
        return "The click is playing on \(output.portName). Wireless adds a noticeable delay — use a wired connection."
    }

    enum MetronomeError: LocalizedError {
        case noOutput
        var errorDescription: String? { "No audio output is available." }
    }
}

// MARK: - Render

/// Everything the audio thread needs. Settings arrive through atomics; the synth state
/// is touched only by the audio thread.
nonisolated final class MetronomeRender: @unchecked Sendable {
    let active = Atomic<Bool>(false)
    let volumeBits = Atomic<UInt32>(Float(0.8).bitPattern)
    /// First output channel (0-based) and whether the click also goes on the next one
    let outputChannel = Atomic<Int>(0)
    let outputStereo = Atomic<Bool>(true)

    // Written before the engine starts, then read only on the audio thread
    private var startHostTime: Double = 0
    private var beatTicks: Double = 1
    private var beatsPerBar = 4
    private var maxBeats: Int?
    private var latencyTicks: Double = 0
    private var ticksPerSample: Double = 0
    private var sampleRate: Double = 44_100

    // Synth state, audio thread only
    private var lastBeat = -1
    private var clickSample = Int.max
    private var clickIsAccent = false
    private var phase: Double = 0

    /// A click: a short sine burst with a fast decay. Beat 1 is higher and louder.
    private let clickSeconds = 0.035
    private let decaySeconds = 0.010

    func configure(startHostTime: UInt64, beatTicks: UInt64, beatsPerBar: Int, maxBeats: Int?,
                   volume: Float, outputLatency: TimeInterval, sampleRate: Double) {
        self.startHostTime = Double(startHostTime)
        self.beatTicks = Double(beatTicks)
        self.beatsPerBar = beatsPerBar
        self.maxBeats = maxBeats
        self.latencyTicks = Double(HostTime.ticks(seconds: outputLatency))
        self.sampleRate = sampleRate
        self.ticksPerSample = HostTime.ticksPerSecond / sampleRate
        lastBeat = -1
        clickSample = Int.max
        phase = 0
        volumeBits.store(volume.bitPattern, ordering: .relaxed)
        active.store(true, ordering: .relaxed)
    }

    func fill(timeStamp: AudioTimeStamp, frames: Int, buffers: UnsafeMutableAudioBufferListPointer,
              isSilence: UnsafeMutablePointer<ObjCBool>) {
        guard active.load(ordering: .relaxed) else {
            for buffer in buffers { memset(buffer.mData, 0, Int(buffer.mDataByteSize)) }
            isSilence.pointee = true
            return
        }
        let volume = Float(bitPattern: volumeBits.load(ordering: .relaxed))
        let clickLength = Int(clickSeconds * sampleRate)
        // Which output channels carry the click; past the interface's last channel → Ch 1–2
        var first = outputChannel.load(ordering: .relaxed)
        var stereo = outputStereo.load(ordering: .relaxed)
        if first + (stereo ? 1 : 0) >= buffers.count { first = 0; stereo = true }
        let last = min(buffers.count - 1, stereo ? first + 1 : first)

        // When this buffer's first sample is heard: its output time plus the output's delay
        let hostTimeValid = timeStamp.mFlags.contains(.hostTimeValid)
        let bufferHost = hostTimeValid ? Double(timeStamp.mHostTime) : Double(mach_absolute_time())
        let firstHeard = bufferHost + latencyTicks

        for frame in 0..<frames {
            let heard = firstHeard + Double(frame) * ticksPerSample
            let sinceStart = heard - startHostTime
            if sinceStart >= 0 {
                let position = sinceStart / beatTicks
                let beat = Int(position)
                if beat != lastBeat {
                    // Joining a clock that's already going: wait for the next beat rather
                    // than clicking part-way through this one
                    let onTheBeat = lastBeat >= 0 || (position - Double(beat)) * beatTicks < ticksPerSample * 2
                    lastBeat = beat
                    if onTheBeat, maxBeats.map({ beat < $0 }) ?? true {
                        clickSample = 0
                        clickIsAccent = beat % beatsPerBar == 0
                        phase = 0
                    }
                }
            }

            var value: Float = 0
            if clickSample < clickLength {
                let t = Double(clickSample) / sampleRate
                let frequency = clickIsAccent ? 1_600.0 : 1_000.0
                let level = (clickIsAccent ? 1.0 : 0.6) * exp(-t / decaySeconds)
                value = Float(sin(phase) * level) * volume
                phase += 2 * .pi * frequency / sampleRate
                clickSample += 1
            }
            for b in 0..<buffers.count {
                buffers[b].mData?.assumingMemoryBound(to: Float.self)[frame] = b >= first && b <= last ? value : 0
            }
        }
        isSilence.pointee = false
    }
}
