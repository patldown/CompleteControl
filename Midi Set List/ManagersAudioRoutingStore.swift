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
import UIKit

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
        // Route changes made while the app was in the background aren't delivered,
        // so re-check when returning to the foreground (e.g. XR18 plugged in meanwhile).
        for name in [UIApplication.didBecomeActiveNotification,
                     AVAudioSession.mediaServicesWereResetNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.refreshHardwareInfo() }
            }
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
        // Inputs are only listed when the session category supports recording; at launch
        // the category is .soloAmbient and the metronome uses .playback, so availableInputs
        // is empty. The output side of the route is reported in every category, and a USB
        // interface like the XR18 shows up there too, so check both.
        let externalTypes: Set<AVAudioSession.Port> = [.usbAudio, .lineIn, .lineOut, .thunderbolt]
        let route = session.currentRoute
        let routePorts = route.outputs + route.inputs + (session.availableInputs ?? [])
        isExternalInterfaceConnected = routePorts.contains { externalTypes.contains($0.portType) }

        let outChannels = session.maximumOutputNumberOfChannels
        availableOutputBusPairCount = outChannels > 0 ? max(1, outChannels / 2) : 1

        guard isExternalInterfaceConnected else { availableInputs = []; return }
        // Keep the last known input list while the category hides inputs (e.g. metronome
        // switched to .playback), so existing channel strips keep their input names.
        guard categorySupportsInput(session.category), let inputs = session.availableInputs
        else { return }
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

    /// Switches the session to .playAndRecord so the interface's inputs can be listed.
    /// Skipped while the metronome is clicking so its output isn't interrupted.
    func enableInputEnumeration() {
        let session = AVAudioSession.sharedInstance()
        if !categorySupportsInput(session.category) && !Metronome.shared.isRunning {
            try? session.setCategory(.playAndRecord, mode: .default,
                                     options: [.mixWithOthers, .defaultToSpeaker, .allowBluetoothHFP])
            try? session.setActive(true)
        }
        refreshHardwareInfo()
    }

    private func categorySupportsInput(_ category: AVAudioSession.Category) -> Bool {
        category == .playAndRecord || category == .record || category == .multiRoute
    }

    // MARK: - Helpers

    func outputBusLabel(_ bus: Int) -> String {
        "Ch \(bus * 2 + 1)–\(bus * 2 + 2)"
    }

    func inputPort(for channel: AudioChannel) -> AudioInputPort? {
        availableInputs.first { $0.monoIndex == channel.inputIndex }
    }
}
