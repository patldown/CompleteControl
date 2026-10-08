//
//  AudioRoutingEngine.swift
//  Midi Set List
//
//  Manages a single AVAudioEngine graph built from the user's AudioChannel list.
//  Graph topology per channel:
//    inputNode (all channels) → input picker → inputMixer → [FX1…FX4] → pair mixer → output packer → outputNode
//
//  All built-in FX nodes (including LevelRider) are in-process. Custom AUAudioUnit
//  subclasses are found synchronously via AVAudioUnitEffect(audioComponentDescription:),
//  which calls AudioComponentFindNext and picks up classes registered with
//  AUAudioUnit.registerSubclass — no async instantiation or App Extension required.
//
//  Nothing a performer changes restarts the engine. Parameter, bypass, volume and mute
//  changes apply to the running nodes, and so do input, stereo link and output choices
//  (the picker and packer switch instantly). Structural changes (an FX type, adding or
//  removing a channel) rebuild only that channel's nodes via syncChannel
//  while every other channel keeps playing. Only the I/O buffer size, chosen at setup,
//  restarts, and the engine restarts itself if iOS stops it (interface reconnect,
//  sample-rate change, interruption).
//
//  Inputs and outputs: an interface's channels arrive as one N-channel input bus and leave
//  as one M-channel output bus; InputPickerAudioUnit and OutputPackerAudioUnit (see
//  ManagersRoutingIOAU.swift) pick and place channels within them.
//
//  Note: starting this engine sets AVAudioSession to .playAndRecord. The Metronome uses
//  the same category when this engine is running — see ManagersMetronome.swift.
//

import AVFoundation
import Observation
import Synchronization

@Observable
@MainActor
final class AudioRoutingEngine {
    static let shared = AudioRoutingEngine()

    private(set) var isRunning = false
    private(set) var lastError: String?

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

    /// Key of the song loaded in Perform; Pitch Guide slots set to follow it use it
    private(set) var songKey: MusicalKey?

    private var engine: AVAudioEngine?
    private var graphs: [UUID: ChannelGraph] = [:]
    /// Places every channel on its outputs; each channel owns one of its input busses
    private var packer: AVAudioUnitEffect?
    private var packerBus: [UUID: Int] = [:]
    /// Format inside the channel strips (stereo) and of the whole interface input
    private var graphFormat: AVAudioFormat?
    private var inputFormat: AVAudioFormat?
    /// Channels mid-rebuild, and ones changed again meanwhile (rebuilt once more after)
    private var syncing: Set<UUID> = []
    private var pendingSync: Set<UUID> = []
    /// Rebuild timings go to the Activity log; set by the app at launch
    var activityLog: ActivityLog?
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
        AUAudioUnit.registerSubclass(
            InputPickerAudioUnit.self,
            as: InputPickerAudioUnit.componentDescription,
            name: "Input Picker",
            version: 1
        )
        AUAudioUnit.registerSubclass(
            OutputPackerAudioUnit.self,
            as: OutputPackerAudioUnit.componentDescription,
            name: "Output Packer",
            version: 1
        )
        AUAudioUnit.registerSubclass(
            PitchGuideAudioUnit.self,
            as: PitchGuideAudioUnit.componentDescription,
            name: "Pitch Guide",
            version: 1
        )

        // iOS stops the engine when the hardware configuration changes (interface
        // re-plugged, sample rate) — bring it straight back rather than going silent
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main
        ) { [weak self] note in
            let changed = note.object as AnyObject?
            MainActor.assumeIsolated {
                guard let self, self.isRunning, let engine = self.engine, changed === engine else { return }
                Task { await self.start() }
            }
        }
        // A phone call or Siri interrupts the session; resume when it's over
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            MainActor.assumeIsolated {
                guard let self, self.isRunning, raw == AVAudioSession.InterruptionType.ended.rawValue,
                      self.engine?.isRunning != true else { return }
                Task { await self.start() }
            }
        }
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
            // Record from the interface itself, with every channel it has — iOS otherwise
            // hands apps 2 channels. Same for outputs, so Ch 3–4 and up exist.
            if let port = store.externalInputPort { try? session.setPreferredInput(port) }
            try? session.setPreferredInputNumberOfChannels(session.maximumInputNumberOfChannels)
            try? session.setPreferredOutputNumberOfChannels(session.maximumOutputNumberOfChannels)
            store.refreshHardwareInfo()

            let eng = AVAudioEngine()
            let hardwareOut = eng.outputNode.outputFormat(forBus: 0)
            let hardwareIn = eng.inputNode.outputFormat(forBus: 0)
            guard hardwareOut.sampleRate > 0, hardwareOut.channelCount > 0,
                  let stereo = AVAudioFormat(standardFormatWithSampleRate: hardwareOut.sampleRate, channels: 2)
            else { throw RoutingError.noOutput }

            buildGraph(in: eng, stereo: stereo, hardwareIn: hardwareIn, hardwareOut: hardwareOut)
            eng.prepare()
            try eng.start()
            engine = eng
            isRunning = true
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
        packer = nil
        packerBus = [:]
        graphFormat = nil
        inputFormat = nil
        syncing = []
        pendingSync = []
        isRunning = false
        actualBufferFrames = nil
        roundTripLatency = nil
        sampleRate = nil
    }

    // MARK: - Graph construction
    //
    //  inputNode (all N interface channels)
    //     ├─▶ picker ─▶ inputMixer ─▶ FX1…FX4 ─▶ packer bus 0 ─┐  (one row per channel; the
    //     ├─▶ picker ─▶ inputMixer ─▶ …       ─▶ packer bus 1 ─┤   picker selects its input
    //     ⋮                                                     ▼   channel or stereo pair)
    //                  output packer (each bus → one output, mono, or a pair) ─▶ outputNode

    private func buildGraph(in eng: AVAudioEngine, stereo: AVAudioFormat,
                            hardwareIn: AVAudioFormat, hardwareOut: AVAudioFormat) {
        graphs = [:]
        packerBus = [:]
        graphFormat = stereo
        inputFormat = hardwareIn

        let packer = AVAudioUnitEffect(audioComponentDescription: OutputPackerAudioUnit.componentDescription)
        eng.attach(packer)
        eng.connect(packer, to: eng.outputNode, format: hardwareOut)
        self.packer = packer

        for channel in store.channels {
            buildChannel(channel, in: eng)
        }
        connectInputs(in: eng)
    }

    /// Picker + fader + FX chain for one channel (its picker still needs connectInputs)
    private func buildChannel(_ channel: AudioChannel, in eng: AVAudioEngine, startSilent: Bool = false) {
        guard let stereo = graphFormat else { return }
        let picker = AVAudioUnitEffect(audioComponentDescription: InputPickerAudioUnit.componentDescription)
        eng.attach(picker)
        (picker.auAudioUnit as? InputPickerAudioUnit)?
            .select(index: channel.inputIndex, stereo: channel.isStereoLinked)

        let inputMixer = AVAudioMixerNode()
        eng.attach(inputMixer)
        inputMixer.volume = startSilent || channel.isMuted ? 0 : channel.volume
        eng.connect(picker, to: inputMixer, format: stereo)

        // A packer bus of its own; the channel's output choice is just that bus's route
        if packerBus[channel.id] == nil,
           let free = (0..<OutputPackerAudioUnit.maxChannels).first(where: { !packerBus.values.contains($0) }) {
            packerBus[channel.id] = free
        }
        var graph = ChannelGraph(picker: picker, inputMixer: inputMixer, fxNodes: [])
        buildChain(for: channel, into: &graph, in: eng)
        graphs[channel.id] = graph
        updateOutput(of: channel)
    }

    /// FX nodes from the channel's fader to its output pair
    private func buildChain(for channel: AudioChannel, into graph: inout ChannelGraph, in eng: AVAudioEngine) {
        guard let stereo = graphFormat else { return }
        var nodes: [AVAudioNode?] = []
        var tail: AVAudioNode = graph.inputMixer
        for slot in channel.slots {
            if let node = makeNode(for: slot) {
                eng.attach(node)
                eng.connect(tail, to: node, format: stereo)
                tail = node
                nodes.append(node)
                if slot.isBypassed { applySlotParams(slot, to: node) }
            } else {
                nodes.append(nil)
            }
        }
        if let packer, let bus = packerBus[channel.id] {
            eng.connect(tail, to: packer, fromBus: 0, toBus: AVAudioNodeBus(bus), format: stereo)
        }
        graph.fxNodes = nodes
    }

    private func teardownChain(_ graph: ChannelGraph, in eng: AVAudioEngine) {
        eng.disconnectNodeOutput(graph.inputMixer)
        for node in graph.fxNodes.compactMap({ $0 }) {
            eng.disconnectNodeOutput(node)
            eng.detach(node)
        }
    }

    /// The interface input feeds every channel's picker (one source, many destinations)
    private func connectInputs(in eng: AVAudioEngine) {
        guard let format = inputFormat, format.sampleRate > 0, format.channelCount > 0 else { return }
        let points = graphs.values.map { AVAudioConnectionPoint(node: $0.picker, bus: 0) }
        if points.isEmpty {
            eng.disconnectNodeOutput(eng.inputNode)
        } else {
            eng.connect(eng.inputNode, to: points, fromBus: 0, format: format)
        }
    }

    // MARK: - Live structural changes (no engine restart)

    /// Output changed (pair, single output, mono/stereo): the packer re-routes instantly
    func updateOutput(of channel: AudioChannel) {
        guard let bus = packerBus[channel.id],
              let routes = (packer?.auAudioUnit as? OutputPackerAudioUnit)?.routes else { return }
        let last = max(0, store.outputChannelCount - 1)
        let start = min(max(0, channel.output.channel), channel.output.stereo ? max(0, last - 1) : last)
        routes.set(bus: bus, channel: start, stereo: channel.output.stereo)
    }

    /// Input or stereo link changed: the picker switches channels instantly
    func updateInput(of channel: AudioChannel) {
        (graphs[channel.id]?.picker.auAudioUnit as? InputPickerAudioUnit)?
            .select(index: channel.inputIndex, stereo: channel.isStereoLinked)
    }

    /// Brings one channel's nodes in line with its saved settings on the running engine:
    /// FX type changes (rebuilds its chain), channel added, channel removed.
    /// The channel fades out ~10 ms, is rebuilt, and fades back in; others keep playing.
    func syncChannel(_ id: UUID) {
        guard isRunning, let eng = engine else { return }
        guard !syncing.contains(id) else { pendingSync.insert(id); return }
        let started = Date()
        let existing = graphs[id]

        guard let existing else {
            // Added
            guard let channel = store.channels.first(where: { $0.id == id }) else { return }
            buildChannel(channel, in: eng, startSilent: true)
            connectInputs(in: eng)
            if !eng.isRunning { try? eng.start() }
            if let mixer = graphs[id]?.inputMixer {
                fade(mixer, to: channel.isMuted ? 0 : channel.volume) { [weak self] in
                    self?.logRebuild(channel.displayName, "added", since: started)
                }
            }
            return
        }

        // FX type changed: restart cleanly rather than hot-rewiring packer connections
        // (hot-wiring causes a race with allocateRenderResources on the running packer)
        if store.channels.contains(where: { $0.id == id }) {
            logRebuild(store.channels.first { $0.id == id }?.displayName ?? "channel",
                       "restarting engine for FX change", since: started)
            Task { await start() }
            return
        }

        // Channel removed: fade to silence, then tear down
        syncing.insert(id)
        fade(existing.inputMixer, to: 0) { [weak self] in
            guard let self else { return }
            guard let eng = self.engine, let graph = self.graphs[id] else {
                self.syncing.remove(id)
                return
            }
            self.teardownChain(graph, in: eng)
            for node in [graph.inputMixer, graph.picker] as [AVAudioNode] {
                eng.disconnectNodeInput(node)
                eng.disconnectNodeOutput(node)
                eng.detach(node)
            }
            self.graphs[id] = nil
            if let bus = self.packerBus.removeValue(forKey: id) {
                (self.packer?.auAudioUnit as? OutputPackerAudioUnit)?.routes.clear(bus: bus)
            }
            self.connectInputs(in: eng)
            self.finishSync(id)
        }
    }

    private func finishSync(_ id: UUID) {
        syncing.remove(id)
        if pendingSync.remove(id) != nil { syncChannel(id) }
    }

    /// ~10 ms stepped fade of a channel's fader — turns a rebuild's hard cut into a dip
    private func fade(_ mixer: AVAudioMixerNode, to target: Float, then done: @escaping () -> Void) {
        let from = mixer.volume
        Task { @MainActor in
            for step in 1...5 {
                mixer.volume = from + (target - from) * Float(step) / 5
                try? await Task.sleep(for: .milliseconds(2))
            }
            done()
        }
    }

    private func logRebuild(_ name: String, _ what: String, since start: Date) {
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        activityLog?.log("Routing: \(name) \(what) in \(ms) ms (other channels kept playing)",
                         direction: .system, proto: .system)
    }

    // MARK: - Node factory

    private func makeNode(for slot: ChannelFXSlot) -> AVAudioNode? {
        // Bypassed slots are still built (then bypassed below) so bypass can toggle live
        guard let type = slot.type else { return nil }
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
        case .reverb, .delay:
            return nil   // removed; interface handles room FX onboard
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
            let effect = AVAudioUnitEffect(
                audioComponentDescription: PitchGuideAudioUnit.componentDescription)
            (effect.auAudioUnit as? PitchGuideAudioUnit)?.kernel
                .applyParams(slot.pitchGuide.resolved(songKey: songKey))
            return effect
        }
    }

    // MARK: - Live parameter application

    /// Applies a macro to a running channel without stopping the engine.
    /// Volume, mute and same-type FX params update live; if any slot's FX type changed,
    /// only this channel is rebuilt.
    func applyMacro(_ macro: ChannelMacro, to channelID: UUID) {
        guard var channel = store.channels.first(where: { $0.id == channelID }) else { return }
        let previousTypes = channel.slots.map(\.type)
        channel.slots = macro.slots
        channel.output = macro.output
        channel.volume = macro.volume
        channel.isMuted = macro.isMuted
        store.update(channel)

        updateOutput(of: channel)
        if macro.slots.map(\.type) != previousTypes {
            syncChannel(channelID)
            return
        }

        guard let graph = graphs[channelID] else { return }
        graph.inputMixer.volume = macro.isMuted ? 0 : macro.volume
        for (i, slot) in macro.slots.enumerated() where i < graph.fxNodes.count {
            applySlot(slot, channelID: channelID, slotIndex: i)
        }
    }

    /// Applies one slot's settings to the running graph (OSC control, live edits). Bypass
    /// flips the node's bypass; a slot built while bypassed has no node, so un-bypassing
    /// it asks for a restart.
    func applySlot(_ slot: ChannelFXSlot, channelID: UUID, slotIndex: Int) {
        guard let graph = graphs[channelID], graph.fxNodes.indices.contains(slotIndex) else { return }
        guard let node = graph.fxNodes[slotIndex] else {
            if slot.type != nil { syncChannel(channelID) }
            return
        }
        applySlotParams(slot, to: node)
    }

    /// The running in-house AU in a channel's slot, for live editing, ring-out and meters.
    /// Nil when the engine is stopped or the slot has no AU node in the current graph.
    func liveAudioUnit(channelID: UUID, slotIndex: Int) -> AUAudioUnit? {
        guard let nodes = graphs[channelID]?.fxNodes, nodes.indices.contains(slotIndex),
              let effect = nodes[slotIndex] as? AVAudioUnitEffect else { return nil }
        return effect.auAudioUnit
    }

    /// A song loaded (or its transpose changed): retarget every Pitch Guide following the song key
    func followSongKey(_ key: MusicalKey?) {
        guard key != songKey else { return }
        songKey = key
        for channel in store.channels {
            guard let graph = graphs[channel.id] else { continue }
            for (i, slot) in channel.slots.enumerated()
            where slot.type == .pitchGuide && slot.pitchGuide.songKeyDrive && i < graph.fxNodes.count {
                applySlotParams(slot, to: graph.fxNodes[i])
            }
        }
    }

    func applyVolume(of channel: AudioChannel) {
        graphs[channel.id]?.inputMixer.volume = channel.isMuted ? 0 : channel.volume
    }

    // MARK: - Level meters (audio thread → main thread)

    /// Pre-FX input level from the interface for this channel (dBFS, -120 when stopped)
    func channelInputLevel(id: UUID) -> Float {
        guard let picker = graphs[id]?.picker,
              let sel = (picker.auAudioUnit as? InputPickerAudioUnit)?.selection else { return -120 }
        return Float(bitPattern: sel.levelBits.load(ordering: .relaxed))
    }

    /// Post-FX output level going to the interface output for this channel (dBFS, -120 when stopped)
    func channelOutputLevel(id: UUID) -> Float {
        guard let bus = packerBus[id],
              let routes = (packer?.auAudioUnit as? OutputPackerAudioUnit)?.routes else { return -120 }
        return routes.level(bus)
    }

    private func applySlotParams(_ slot: ChannelFXSlot, to node: AVAudioNode?) {
        guard let node else { return }
        (node as? AVAudioUnitEffect)?.bypass = slot.isBypassed
        switch slot.type {
        case .gain:
            if let m = node as? AVAudioMixerNode {
                m.volume = slot.isBypassed ? 1 : slot.gain.volume
                m.pan = slot.isBypassed ? 0 : slot.gain.pan
            }
        case .eq3Band:
            if let eq = node as? AVAudioUnitEQ { applyEQ(slot.eq, to: eq) }
        case .reverb, .delay:
            break
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
            ((node as? AVAudioUnitEffect)?.auAudioUnit as? PitchGuideAudioUnit)?
                .kernel.applyParams(slot.pitchGuide.resolved(songKey: songKey))
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

}

// MARK: - Supporting types

private struct ChannelGraph {
    let picker: AVAudioUnitEffect
    let inputMixer: AVAudioMixerNode
    var fxNodes: [AVAudioNode?]
}

enum RoutingError: LocalizedError {
    case noOutput
    var errorDescription: String? { "No audio output available." }
}
