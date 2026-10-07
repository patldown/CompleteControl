//
//  AudioRoutingEngine.swift
//  Midi Set List
//
//  Manages a single AVAudioEngine graph built from the user's AudioChannel list.
//  Graph topology per channel:
//    inputNode[bus N] → inputMixer → [FX1] → [FX2] → [FX3] → [FX4] → outputBusMixer → outputNode[bus M]
//
//  All built-in FX nodes (including LevelRider) are in-process. Custom AUAudioUnit
//  subclasses are found synchronously via AVAudioUnitEffect(audioComponentDescription:),
//  which calls AudioComponentFindNext and picks up classes registered with
//  AUAudioUnit.registerSubclass — no async instantiation or App Extension required.
//
//  Only changing an FX *type* in a slot requires a restart (different node class needed).
//
//  Note: starting this engine sets AVAudioSession to .playAndRecord. The Metronome uses
//  the same category when this engine is running — see ManagersMetronome.swift.
//

import AVFoundation
import Observation

@Observable
@MainActor
final class AudioRoutingEngine {
    static let shared = AudioRoutingEngine()

    private(set) var isRunning = false
    private(set) var lastError: String?
    /// Set true when a slot's FX type changed — a restart applies the new graph.
    var needsRestart = false

    // MARK: Buffer size / latency

    static let bufferSizeOptions = [64, 128, 256, 512]
    private static let bufferFramesKey = "routingBufferFrames"

    /// Requested I/O buffer in samples. Smaller = less latency but more risk of crackles.
    /// Device-specific, so it lives in UserDefaults rather than synced preferences.
    var bufferFrames: Int = {
        let saved = UserDefaults.standard.integer(forKey: AudioRoutingEngine.bufferFramesKey)
        return AudioRoutingEngine.bufferSizeOptions.contains(saved) ? saved : 128
    }() {
        didSet {
            UserDefaults.standard.set(bufferFrames, forKey: Self.bufferFramesKey)
            if isRunning { Task { await start() } }
        }
    }
    /// What iOS actually granted — it may round the request
    private(set) var actualBufferFrames: Int?
    /// Input → app → output, as reported by iOS: both converter/driver latencies plus
    /// one input and one output buffer. The built-in effects add none (no lookahead).
    private(set) var roundTripLatency: TimeInterval?
    private(set) var sampleRate: Double?

    private var engine: AVAudioEngine?
    private var graphs: [UUID: ChannelGraph] = [:]
    private let store = AudioRoutingStore.shared

    private init() {
        AUAudioUnit.registerSubclass(
            LevelRiderAudioUnit.self,
            as: LevelRiderAudioUnit.componentDescription,
            name: "LevelRider",
            version: 1
        )
        AUAudioUnit.registerSubclass(
            VintageCompressorAudioUnit.self,
            as: VintageCompressorAudioUnit.optoDescription,
            name: "Opto Comp",
            version: 1
        )
        AUAudioUnit.registerSubclass(
            VintageCompressorAudioUnit.self,
            as: VintageCompressorAudioUnit.fetDescription,
            name: "FET Comp",
            version: 1
        )
        AUAudioUnit.registerSubclass(
            FeedbackNotchAudioUnit.self,
            as: FeedbackNotchAudioUnit.componentDescription,
            name: "Feedback Notch",
            version: 1
        )
    }

    // MARK: - Lifecycle

    func start() async {
        stop()
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default,
                                    options: [.mixWithOthers, .defaultToSpeaker, .allowBluetoothHFP])
            // A preference only: iOS may round it, so the granted size is read back below
            try? session.setPreferredIOBufferDuration(Double(bufferFrames) / max(1, session.sampleRate))
            try session.setActive(true)

            let eng = AVAudioEngine()
            guard let stereo = AVAudioFormat(
                standardFormatWithSampleRate: eng.outputNode.outputFormat(forBus: 0).sampleRate,
                channels: 2
            ), stereo.sampleRate > 0 else { throw RoutingError.noOutput }

            try buildGraph(in: eng, format: stereo)
            eng.prepare()
            try eng.start()
            engine = eng
            isRunning = true
            needsRestart = false
            lastError = nil
            sampleRate = session.sampleRate
            actualBufferFrames = Int((session.ioBufferDuration * session.sampleRate).rounded())
            roundTripLatency = session.inputLatency + session.outputLatency + 2 * session.ioBufferDuration
        } catch {
            lastError = error.localizedDescription
        }
    }

    func stop() {
        engine?.stop()
        engine = nil
        graphs = [:]
        isRunning = false
        actualBufferFrames = nil
        roundTripLatency = nil
        sampleRate = nil
    }

    // MARK: - Graph construction

    private func buildGraph(in eng: AVAudioEngine, format: AVAudioFormat) throws {
        // One output-bus mixer per hardware output pair — multiple channels targeting
        // the same output pair share a mixer rather than fighting over the connection.
        var outputMixers: [Int: AVAudioMixerNode] = [:]

        for channel in store.channels {
            let inputMixer = AVAudioMixerNode()
            eng.attach(inputMixer)
            inputMixer.volume = channel.isMuted ? 0 : channel.volume

            let inputBus = AVAudioNodeBus(channel.inputIndex)
            let inputFormat = eng.inputNode.outputFormat(forBus: inputBus)
            let connFormat = inputFormat.sampleRate > 0 ? inputFormat : format
            eng.connect(eng.inputNode, to: inputMixer,
                        fromBus: inputBus, toBus: 0, format: connFormat)

            if channel.isStereoLinked {
                let nextBus = AVAudioNodeBus(channel.inputIndex + 1)
                let nextFmt = eng.inputNode.outputFormat(forBus: nextBus)
                if nextFmt.sampleRate > 0 {
                    eng.connect(eng.inputNode, to: inputMixer,
                                fromBus: nextBus, toBus: 1, format: nextFmt)
                }
            }

            var fxNodes: [AVAudioNode?] = []
            var tail: AVAudioNode = inputMixer
            for slot in channel.slots {
                if let node = makeNode(for: slot) {
                    eng.attach(node)
                    eng.connect(tail, to: node, format: format)
                    tail = node
                    fxNodes.append(node)
                } else {
                    fxNodes.append(nil)
                }
            }

            let busMixer: AVAudioMixerNode
            if let existing = outputMixers[channel.outputBus] {
                busMixer = existing
            } else {
                busMixer = AVAudioMixerNode()
                eng.attach(busMixer)
                let safeBus = min(channel.outputBus, store.availableOutputBusPairCount - 1)
                eng.connect(busMixer, to: eng.outputNode,
                            fromBus: 0, toBus: AVAudioNodeBus(safeBus), format: format)
                outputMixers[channel.outputBus] = busMixer
            }
            eng.connect(tail, to: busMixer, format: format)

            graphs[channel.id] = ChannelGraph(inputMixer: inputMixer, fxNodes: fxNodes,
                                               outputBus: channel.outputBus)
        }
    }

    // MARK: - Node factory

    private func makeNode(for slot: ChannelFXSlot) -> AVAudioNode? {
        guard let type = slot.type, !slot.isBypassed else { return nil }
        switch type {
        case .gain:
            let mixer = AVAudioMixerNode()
            mixer.volume = slot.gain.volume
            mixer.pan = slot.gain.pan
            return mixer
        case .eq3Band:
            let eq = AVAudioUnitEQ(numberOfBands: 3)
            applyEQ(slot.eq, to: eq)
            return eq
        case .reverb:
            let rv = AVAudioUnitReverb()
            applyReverb(slot.reverb, to: rv)
            return rv
        case .delay:
            let dl = AVAudioUnitDelay()
            applyDelay(slot.delay, to: dl)
            return dl
        case .levelRider:
            // AVAudioUnitEffect(audioComponentDescription:) calls AudioComponentFindNext,
            // which finds subclasses registered via AUAudioUnit.registerSubclass — sync,
            // in-process, no App Extension or XPC required.
            let effect = AVAudioUnitEffect(
                audioComponentDescription: LevelRiderAudioUnit.componentDescription)
            (effect.auAudioUnit as? LevelRiderAudioUnit)?.kernel.applyParams(slot.levelRider)
            return effect
        case .optoComp:
            let effect = AVAudioUnitEffect(
                audioComponentDescription: VintageCompressorAudioUnit.optoDescription)
            (effect.auAudioUnit as? VintageCompressorAudioUnit)?.kernel.applyParams(slot.optoComp)
            return effect
        case .fetComp:
            let effect = AVAudioUnitEffect(
                audioComponentDescription: VintageCompressorAudioUnit.fetDescription)
            (effect.auAudioUnit as? VintageCompressorAudioUnit)?.kernel.applyParams(slot.fetComp)
            return effect
        case .feedbackNotch:
            let effect = AVAudioUnitEffect(
                audioComponentDescription: FeedbackNotchAudioUnit.componentDescription)
            (effect.auAudioUnit as? FeedbackNotchAudioUnit)?.kernel.applyParams(slot.feedbackNotch)
            return effect
        case .pitchGuide:
            return nil  // DSP not yet implemented; slot passes signal through unaffected
        }
    }

    // MARK: - Live parameter application

    /// Applies a macro to a running channel without stopping the engine.
    /// Only volume, mute, and same-type FX params update live.
    /// If any slot's FX type changes, `needsRestart` is set instead.
    func applyMacro(_ macro: ChannelMacro, to channelID: UUID) {
        guard var channel = store.channels.first(where: { $0.id == channelID }) else { return }
        let previousTypes = channel.slots.map(\.type)
        channel.slots = macro.slots
        channel.outputBus = macro.outputBus
        channel.volume = macro.volume
        channel.isMuted = macro.isMuted
        store.update(channel)

        if macro.slots.map(\.type) != previousTypes { needsRestart = true }

        guard let graph = graphs[channelID] else { return }
        graph.inputMixer.volume = macro.isMuted ? 0 : macro.volume
        for (i, slot) in macro.slots.enumerated() where i < graph.fxNodes.count {
            applySlotParams(slot, to: graph.fxNodes[i])
        }
    }

    /// The running Feedback Notch kernel in a channel's slot, for ring-out. Nil when the
    /// engine is stopped or the slot's current graph node isn't a Feedback Notch.
    func feedbackNotchKernel(channelID: UUID, slotIndex: Int) -> FeedbackNotchKernel? {
        guard let nodes = graphs[channelID]?.fxNodes, nodes.indices.contains(slotIndex),
              let effect = nodes[slotIndex] as? AVAudioUnitEffect else { return nil }
        return (effect.auAudioUnit as? FeedbackNotchAudioUnit)?.kernel
    }

    func applyVolume(of channel: AudioChannel) {
        graphs[channel.id]?.inputMixer.volume = channel.isMuted ? 0 : channel.volume
    }

    private func applySlotParams(_ slot: ChannelFXSlot, to node: AVAudioNode?) {
        guard let node else { return }
        switch slot.type {
        case .gain:
            if let m = node as? AVAudioMixerNode { m.volume = slot.gain.volume; m.pan = slot.gain.pan }
        case .eq3Band:
            if let eq = node as? AVAudioUnitEQ { applyEQ(slot.eq, to: eq) }
        case .reverb:
            if let rv = node as? AVAudioUnitReverb { rv.wetDryMix = slot.reverb.wetDryMix }
        case .delay:
            if let dl = node as? AVAudioUnitDelay { applyDelay(slot.delay, to: dl) }
        case .levelRider:
            if let effect = node as? AVAudioUnitEffect,
               let au = effect.auAudioUnit as? LevelRiderAudioUnit {
                au.kernel.applyParams(slot.levelRider)
            }
        case .optoComp:
            ((node as? AVAudioUnitEffect)?.auAudioUnit as? VintageCompressorAudioUnit)?
                .kernel.applyParams(slot.optoComp)
        case .fetComp:
            ((node as? AVAudioUnitEffect)?.auAudioUnit as? VintageCompressorAudioUnit)?
                .kernel.applyParams(slot.fetComp)
        case .feedbackNotch:
            ((node as? AVAudioUnitEffect)?.auAudioUnit as? FeedbackNotchAudioUnit)?
                .kernel.applyParams(slot.feedbackNotch)
        case .pitchGuide:
            break
        case nil:
            break
        }
    }

    // MARK: - FX parameter helpers

    private func applyEQ(_ p: EQ3BandParams, to eq: AVAudioUnitEQ) {
        let b = eq.bands
        b[0].filterType = .lowShelf;   b[0].frequency = p.lowShelfFrequency
        b[0].gain = p.lowShelfGain;    b[0].bypass = false
        b[1].filterType = .parametric; b[1].frequency = p.midFrequency
        b[1].gain = p.midGain;         b[1].bandwidth = p.midBandwidth; b[1].bypass = false
        b[2].filterType = .highShelf;  b[2].frequency = p.highShelfFrequency
        b[2].gain = p.highShelfGain;   b[2].bypass = false
    }

    private func applyReverb(_ p: ReverbParams, to rv: AVAudioUnitReverb) {
        if let preset = AVAudioUnitReverbPreset(rawValue: p.roomPreset) { rv.loadFactoryPreset(preset) }
        rv.wetDryMix = p.wetDryMix
    }

    private func applyDelay(_ p: DelayParams, to dl: AVAudioUnitDelay) {
        dl.delayTime = p.delayTime
        dl.feedback = p.feedback
        dl.lowPassCutoff = p.lowPassCutoff
        dl.wetDryMix = p.wetDryMix
    }
}

// MARK: - Supporting types

private struct ChannelGraph {
    let inputMixer: AVAudioMixerNode
    let fxNodes: [AVAudioNode?]
    let outputBus: Int
}

enum RoutingError: LocalizedError {
    case noOutput
    var errorDescription: String? { "No audio output available." }
}
