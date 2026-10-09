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

    var displayName: String { "\(portName) · In \(channelIndex + 1)" }
}

// MARK: - Store

@Observable
@MainActor
final class AudioRoutingStore {
    static let shared = AudioRoutingStore()

    var channels: [AudioChannel] = []
    private(set) var availableInputs: [AudioInputPort] = []
    /// Hardware output channels on the interface (2 without one)
    private(set) var outputChannelCount: Int = 2
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
        // Older saves could hold duplicate names; make them unique so /app/ addresses are unambiguous
        var fixed: [AudioChannel] = []
        var needsSave = false
        for var channel in decoded {
            channel.name = Self.uniqueName(channel.name, excluding: channel.id, among: fixed)
            // Migrate: expand channels saved with fewer than 6 FX slots
            if channel.slots.count < 6 {
                channel.slots += Array(repeating: ChannelFXSlot(), count: 6 - channel.slots.count)
                needsSave = true
            }
            for i in channel.macros.indices where channel.macros[i].slots.count < 6 {
                channel.macros[i].slots += Array(repeating: ChannelFXSlot(),
                                                 count: 6 - channel.macros[i].slots.count)
                needsSave = true
            }
            // Migrate: clear reverb/delay slots (removed; interface handles room FX onboard)
            for i in channel.slots.indices where channel.slots[i].type == .reverb || channel.slots[i].type == .delay {
                channel.slots[i] = ChannelFXSlot()
                needsSave = true
            }
            for mi in channel.macros.indices {
                for si in channel.macros[mi].slots.indices
                where channel.macros[mi].slots[si].type == .reverb || channel.macros[mi].slots[si].type == .delay {
                    channel.macros[mi].slots[si] = ChannelFXSlot()
                    needsSave = true
                }
            }
            // Migrate: Bleed Duck moved from Pitch Guide to Smart Gate
            if channel.slots.moveBleedDuckToSmartGate() != nil { needsSave = true }
            for mi in channel.macros.indices where channel.macros[mi].slots.moveBleedDuckToSmartGate() != nil {
                needsSave = true
            }
            fixed.append(channel)
        }
        channels = fixed
        if fixed.map(\.name) != decoded.map(\.name) || needsSave { save() }
    }

    // MARK: - Unique names
    // Channel names are OSC addresses (/app/<name>/…), so no two may match once case, spaces,
    // "-" and "_" are ignored, and none may look like a position (ch2) or "engine".
    // Empty names are allowed; those channels are addressed by position.

    func isNameAvailable(_ name: String, excluding id: UUID?) -> Bool {
        Self.isNameAvailable(name, excluding: id, among: channels)
    }

    /// `name` if it's free, otherwise "name 2", "name 3"…
    func uniqueName(_ name: String, excluding id: UUID?) -> String {
        Self.uniqueName(name, excluding: id, among: channels)
    }

    private static func isNameAvailable(_ name: String, excluding id: UUID?, among list: [AudioChannel]) -> Bool {
        let n = AppOSC.normalize(name)
        guard !n.isEmpty else { return true }
        guard !AppOSC.isReservedName(name) else { return false }
        return !list.contains { $0.id != id && AppOSC.normalize($0.name) == n }
    }

    private static func uniqueName(_ name: String, excluding id: UUID?, among list: [AudioChannel]) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if isNameAvailable(trimmed, excluding: id, among: list) { return trimmed }
        let base = AppOSC.isReservedName(trimmed) ? "Channel \(trimmed)" : trimmed
        if isNameAvailable(base, excluding: id, among: list) { return base }
        var n = 2
        while !isNameAvailable("\(base) \(n)", excluding: id, among: list) { n += 1 }
        return "\(base) \(n)"
    }

    func save() {
        guard let data = try? JSONEncoder().encode(channels) else { return }
        try? data.write(to: Self.fileURL, options: .atomic)
    }

    // MARK: - Channel management

    func add(_ channel: AudioChannel) {
        var channel = channel
        channel.name = uniqueName(channel.name, excluding: channel.id)
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
        outputChannelCount = max(2, outChannels)

        guard isExternalInterfaceConnected else { availableInputs = []; return }
        // Keep the last known input list while the category hides inputs (e.g. metronome
        // switched to .playback), so existing channel strips keep their input names.
        guard categorySupportsInput(session.category), let port = externalInputPort else { return }
        // The engine records from this one port, so its channels are the engine's input
        // channels 0…N-1 (the picker selects among them). While the session is active the
        // live channel count is the truth; the port's own list is the fallback.
        let liveCount = session.isInputAvailable ? session.inputNumberOfChannels : 0
        let count = max(1, max(liveCount, port.channels?.count ?? 1))
        availableInputs = (0..<count).map { ch in
            AudioInputPort(id: "\(port.uid):\(ch)", portUID: port.uid, portName: port.portName,
                           channelIndex: ch, monoIndex: ch)
        }
    }

    /// The interface the routing engine records from (USB, line in, Thunderbolt)
    var externalInputPort: AVAudioSessionPortDescription? {
        let externalTypes: Set<AVAudioSession.Port> = [.usbAudio, .lineIn, .thunderbolt]
        return AVAudioSession.sharedInstance().availableInputs?.first { externalTypes.contains($0.portType) }
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

    /// Every output a channel can use: stereo pairs (1–2, 3–4…) first, then single outputs
    var outputRoutes: [OutputRoute] {
        let pairs = stride(from: 0, to: outputChannelCount - 1, by: 2).map { OutputRoute(channel: $0, stereo: true) }
        let monos = (0..<outputChannelCount).map { OutputRoute(channel: $0, stereo: false) }
        return pairs + monos
    }


    func inputPort(for channel: AudioChannel) -> AudioInputPort? {
        availableInputs.first { $0.monoIndex == channel.inputIndex }
    }
}
