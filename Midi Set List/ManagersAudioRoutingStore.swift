//
//  AudioRoutingStore.swift
//  Midi Set List
//
//  Persists user-defined audio channels as JSON in Documents and tracks
//  which hardware input buses are currently available from AVAudioSession.
//

import AVFoundation
import Foundation
import Observation

// MARK: - Hardware input descriptor

struct AudioInputPort: Identifiable, Equatable {
    let id: String          // portUID:channelIndex
    let portUID: String
    let portName: String
    let channelIndex: Int   // within the port (0-based)
    let monoIndex: Int      // global 0-based mono bus index on inputNode

    var displayName: String {
        channelIndex == 0 ? portName : "\(portName) · Ch \(channelIndex + 1)"
    }
}

// MARK: - Store

@Observable
@MainActor
final class AudioRoutingStore {
    static let shared = AudioRoutingStore()

    var channels: [AudioChannel] = []
    private(set) var availableInputs: [AudioInputPort] = []
    private(set) var availableOutputBusPairCount: Int = 1
    private(set) var isExternalInterfaceConnected: Bool = false

    private static let fileURL: URL = {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AudioRoutingChannels.json")
    }()

    private init() {
        load()
        refreshHardwareInfo()
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshHardwareInfo() }
        }
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: Self.fileURL),
              let decoded = try? JSONDecoder().decode([AudioChannel].self, from: data)
        else { return }
        channels = decoded
    }

    func save() {
        guard let data = try? JSONEncoder().encode(channels) else { return }
        try? data.write(to: Self.fileURL, options: .atomic)
    }

    // MARK: - Channel management

    func add(_ channel: AudioChannel) {
        channels.append(channel)
        save()
    }

    func remove(_ channel: AudioChannel) {
        channels.removeAll { $0.id == channel.id }
        save()
    }

    func update(_ channel: AudioChannel) {
        guard let i = channels.firstIndex(where: { $0.id == channel.id }) else { return }
        channels[i] = channel
        save()
    }

    // MARK: - Hardware info

    func refreshHardwareInfo() {
        let session = AVAudioSession.sharedInstance()
        let externalTypes: Set<AVAudioSession.Port> = [.usbAudio, .lineIn, .thunderbolt, .headsetMic]
        isExternalInterfaceConnected = session.currentRoute.inputs
            .contains { externalTypes.contains($0.portType) }

        let outChannels = session.maximumOutputNumberOfChannels
        availableOutputBusPairCount = outChannels > 0 ? max(1, outChannels / 2) : 1

        guard let inputs = session.availableInputs else { availableInputs = []; return }
        var ports: [AudioInputPort] = []
        var mono = 0
        for input in inputs {
            let count = max(1, input.channels?.count ?? 1)
            for ch in 0..<count {
                ports.append(AudioInputPort(
                    id: "\(input.uid):\(ch)",
                    portUID: input.uid,
                    portName: input.portName,
                    channelIndex: ch,
                    monoIndex: mono
                ))
                mono += 1
            }
        }
        availableInputs = ports
    }

    // MARK: - Helpers

    func outputBusLabel(_ bus: Int) -> String {
        "Ch \(bus * 2 + 1)–\(bus * 2 + 2)"
    }

    func inputPort(for channel: AudioChannel) -> AudioInputPort? {
        availableInputs.first { $0.monoIndex == channel.inputIndex }
    }
}
