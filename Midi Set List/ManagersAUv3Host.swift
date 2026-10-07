//
//  AUv3Host.swift
//  Midi Set List
//
//  A four-slot serial audio effects chain:
//    interface input (chosen channel pair)
//    → up to 4 AUv3 effects in order
//    → interface output (same or different channel pair)
//
//  Uses playAndRecord so the metronome and Apple Music reference keep running
//  alongside it. Plugins run out-of-process — a crash in a plugin can't take
//  down the host app.
//

import AudioToolbox
import AVFoundation
import Observation

// MARK: - Host

@Observable
@MainActor
final class AUv3Host {
    static let shared = AUv3Host()

    private(set) var isRunning = false
    private(set) var lastError: String?

    /// Input channel pair (0 = Ch 1-2, 1 = Ch 3-4, …). Restart required to apply.
    var inputBus: Int = 0
    /// Output channel pair (0 = Ch 1-2, 1 = Ch 3-4, …). Restart required to apply.
    var outputBus: Int = 0

    /// The four effect slots. Always exactly four; empty slots are pass-through.
    let slots: [AUv3Slot] = (0..<4).map { _ in AUv3Slot() }

    @ObservationIgnored private var engine: AVAudioEngine?

    private init() {}

    // MARK: - Plugin discovery

    /// All installed AUv3 effect and music-effect components, sorted by name.
    static func availableEffects() -> [AVAudioUnitComponent] {
        let manager = AVAudioUnitComponentManager.shared()
        var seen = Set<String>()
        var components: [AVAudioUnitComponent] = []

        for type in [kAudioUnitType_Effect, kAudioUnitType_MusicEffect] {
            let desc = AudioComponentDescription(
                componentType: type, componentSubType: 0,
                componentManufacturer: 0, componentFlags: 0, componentFlagsMask: 0
            )
            for c in manager.components(matching: desc) {
                let key = c.componentID
                if seen.insert(key).inserted { components.append(c) }
            }
        }
        return components.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    // MARK: - Hardware channel availability

    /// Stereo channel-pair count for the current input route.
    static var inputBusPairCount: Int {
        let n = AVAudioSession.sharedInstance().maximumInputNumberOfChannels
        return n > 0 ? max(1, n / 2) : 1
    }

    /// Stereo channel-pair count for the current output route.
    static var outputBusPairCount: Int {
        let n = AVAudioSession.sharedInstance().maximumOutputNumberOfChannels
        return n > 0 ? max(1, n / 2) : 1
    }

    // MARK: - Engine lifecycle

    func start() async throws {
        stop()
        do {
            let session = AVAudioSession.sharedInstance()
            // playAndRecord lets us read hardware input while the metronome and
            // Apple Music keep playing. defaultToSpeaker prevents iOS routing
            // output to the earpiece when a mic/interface is active.
            try session.setCategory(.playAndRecord, mode: .default,
                                    options: [.mixWithOthers, .defaultToSpeaker])
            try session.setActive(true)

            let engine = AVAudioEngine()
            try await buildGraph(in: engine)
            engine.prepare()
            try engine.start()
            self.engine = engine
            isRunning = true
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    func stop() {
        engine?.stop()
        engine = nil
        isRunning = false
    }

    // MARK: - Graph construction

    private func buildGraph(in engine: AVAudioEngine) async throws {
        let sampleRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        guard sampleRate > 0,
              let stereo = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)
        else { throw AUv3HostError.noOutput }

        // Input: an AVAudioMixerNode handles any mono→stereo upmix from the
        // hardware input bus, giving the chain a consistent stereo feed.
        let inputMixer = AVAudioMixerNode()
        engine.attach(inputMixer)
        let inputPairs = Self.inputBusPairCount
        let safeIn = AVAudioNodeBus(min(max(0, inputBus), inputPairs - 1))
        let inputFormat = engine.inputNode.outputFormat(forBus: safeIn)
        let connFormat = inputFormat.sampleRate > 0 ? inputFormat : stereo
        engine.connect(engine.inputNode, to: inputMixer,
                       fromBus: safeIn, toBus: 0, format: connFormat)

        // Chain: wire loaded slots in order; empty slots are skipped.
        var tail: AVAudioNode = inputMixer
        for slot in slots where slot.isLoaded {
            let au = slot.audioUnit!
            engine.attach(au)
            engine.connect(tail, to: au, format: stereo)
            tail = au
        }

        // Output: send the chain's result to the chosen hardware output bus.
        let outputPairs = Self.outputBusPairCount
        let safeOut = AVAudioNodeBus(min(max(0, outputBus), outputPairs - 1))
        engine.connect(tail, to: engine.outputNode,
                       fromBus: 0, toBus: safeOut, format: stereo)
    }

    // MARK: - Slot management

    func loadPlugin(_ component: AVAudioUnitComponent, intoSlot index: Int) async throws {
        guard slots.indices.contains(index) else { return }
        let au = try await instantiate(component)
        slots[index].audioUnit = au
        slots[index].component = component
        if isRunning { try await restart() }
    }

    func removePlugin(fromSlot index: Int) {
        guard slots.indices.contains(index) else { return }
        slots[index].audioUnit = nil
        slots[index].component = nil
        if isRunning { Task { @MainActor [weak self] in try? await self?.restart() } }
    }

    func setBypass(_ bypassed: Bool, forSlot index: Int) {
        guard slots.indices.contains(index) else { return }
        slots[index].isBypassed = bypassed
        slots[index].audioUnit?.auAudioUnit.shouldBypassEffect = bypassed
    }

    // MARK: - Helpers

    private func restart() async throws {
        stop()
        try await start()
    }

    private func instantiate(_ component: AVAudioUnitComponent) async throws -> AVAudioUnit {
        try await withCheckedThrowingContinuation { continuation in
            // On iOS, AUv3 extensions always run in their own extension process
            // regardless of the options flag. loadOutOfProcess makes this explicit.
            AVAudioUnit.instantiate(
                with: component.audioComponentDescription,
                options: .loadOutOfProcess
            ) { unit, error in
                if let unit { continuation.resume(returning: unit) }
                else { continuation.resume(throwing: error ?? AUv3HostError.instantiationFailed) }
            }
        }
    }
}

// MARK: - Slot

@Observable
final class AUv3Slot {
    var audioUnit: AVAudioUnit?
    var component: AVAudioUnitComponent?
    var isBypassed = false

    var name: String { component?.name ?? "Empty" }
    var manufacturer: String { component?.manufacturerName ?? "" }
    var isLoaded: Bool { audioUnit != nil }
}

// MARK: - Errors

enum AUv3HostError: LocalizedError {
    case noOutput
    case instantiationFailed

    var errorDescription: String? {
        switch self {
        case .noOutput:            "No audio output available."
        case .instantiationFailed: "Could not load the AUv3 plugin."
        }
    }
}

// MARK: - AVAudioUnitComponent helpers

extension AVAudioUnitComponent {
    /// Stable unique key built from the component description's four-char codes.
    var componentID: String {
        let d = audioComponentDescription
        return "\(d.componentType).\(d.componentSubType).\(d.componentManufacturer)"
    }
}
