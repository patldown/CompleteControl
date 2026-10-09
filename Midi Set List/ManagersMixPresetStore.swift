//
//  ManagersMixPresetStore.swift
//  Midi Set List
//
//  Mix presets: a named group capturing, per routing channel, the settings of chosen
//  effects, the linked mixer fader and the channel's own volume. Recall updates exactly
//  what was captured, live, without rebuilding audio: an effect slot is only updated when
//  it still holds the same kind of effect as when it was saved.
//
//  OSC (so presets can sit in song snapshots like any command):
//    /app/mix/<preset>             recall the whole group
//    /app/mix/<preset>/<channel>   recall one channel's part
//    /app/<channel>/preset/<name>  recall one of a channel's own presets (same live rules)
//

import Foundation
import Observation

// MARK: - Model

struct MixPresetChannel: Codable, Identifiable, Equatable {
    var channelID: UUID
    var channelName: String
    /// The channel's six slots as captured; only `includedSlots` are recalled
    var slots: [ChannelFXSlot]
    var includedSlots: Set<Int>
    var faderDB: Float?
    var includeFader: Bool
    var volume: Float
    var isMuted: Bool
    var includeVolume: Bool

    var id: UUID { channelID }

    /// Slot indexes that hold an effect, i.e. can be included
    var capturedSlots: [Int] { slots.indices.filter { slots[$0].type != nil } }
}

struct MixPreset: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var channels: [MixPresetChannel]
    var dateCreated = Date()

    var summary: String {
        let fx = channels.reduce(0) { $0 + $1.includedSlots.count }
        let faders = channels.filter { $0.includeFader && $0.faderDB != nil }.count
        let volumes = channels.filter(\.includeVolume).count
        var parts = ["\(fx) effect\(fx == 1 ? "" : "s")"]
        if faders > 0 { parts.append("\(faders) fader\(faders == 1 ? "" : "s")") }
        if volumes > 0 { parts.append("\(volumes) volume\(volumes == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }

    var oscAddress: String { "\(AppOSC.prefix)mix/\(name)" }

    func oscAddress(for part: MixPresetChannel) -> String { "\(oscAddress)/\(part.channelName)" }
}

// MARK: - Store

@Observable
@MainActor
final class MixPresetStore {
    static let shared = MixPresetStore()

    private(set) var presets: [MixPreset] = []

    @ObservationIgnored private let store = AudioRoutingStore.shared
    @ObservationIgnored private let engine = AudioRoutingEngine.shared

    private static let fileURL: URL = {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MixPresets.json")
    }()

    private init() {
        if let data = try? Data(contentsOf: Self.fileURL),
           let saved = try? JSONDecoder().decode([MixPreset].self, from: data) {
            presets = saved
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(presets) {
            try? data.write(to: Self.fileURL, options: .atomic)
        }
    }

    // MARK: Editing

    /// Captures every channel as it is now, with all effects, faders and volumes ticked
    func captureCurrentMix(named name: String) -> MixPreset {
        let link = MixerLink.shared
        let channels = store.channels.map { channel in
            let fader = link.settings.showFader ? link.faderDB[channel.id] : nil
            return MixPresetChannel(
                channelID: channel.id, channelName: channel.displayName,
                slots: channel.slots,
                includedSlots: Set(channel.slots.indices.filter { channel.slots[$0].type != nil }),
                faderDB: fader, includeFader: fader != nil,
                volume: channel.volume, isMuted: channel.isMuted, includeVolume: false)
        }
        return MixPreset(name: name, channels: channels)
    }

    /// The preset's ticks kept, its values replaced with how the channels are now
    func recaptured(_ preset: MixPreset) -> MixPreset {
        var fresh = captureCurrentMix(named: preset.name)
        fresh.id = preset.id
        fresh.dateCreated = preset.dateCreated
        for i in fresh.channels.indices {
            guard let old = preset.channels.first(where: { $0.channelID == fresh.channels[i].channelID })
            else { continue }
            fresh.channels[i].includedSlots = old.includedSlots.filter { fresh.channels[i].slots[$0].type != nil }
            fresh.channels[i].includeFader = old.includeFader && fresh.channels[i].faderDB != nil
            fresh.channels[i].includeVolume = old.includeVolume
        }
        return fresh
    }

    /// A name usable in an OSC address and unique among presets
    func uniqueName(_ name: String, excluding id: UUID?) -> String {
        let base = name.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespaces)
        let start = base.isEmpty ? "Mix" : base
        var candidate = start
        var n = 2
        while presets.contains(where: { $0.id != id && AppOSC.normalize($0.name) == AppOSC.normalize(candidate) }) {
            candidate = "\(start) \(n)"
            n += 1
        }
        return candidate
    }

    func upsert(_ preset: MixPreset) {
        var p = preset
        p.name = uniqueName(p.name, excluding: p.id)
        if let i = presets.firstIndex(where: { $0.id == p.id }) { presets[i] = p } else { presets.append(p) }
        save()
    }

    func delete(_ preset: MixPreset) {
        presets.removeAll { $0.id == preset.id }
        save()
    }

    func preset(named name: String) -> MixPreset? {
        let wanted = AppOSC.normalize(name)
        return presets.first { AppOSC.normalize($0.name) == wanted }
    }

    // MARK: Recall

    /// Applies a preset (or one channel's part of it). Returns a summary for the log.
    @discardableResult
    func recall(_ preset: MixPreset, onlyChannel channelName: String? = nil) -> String {
        var applied = 0, skipped = 0
        let parts = preset.channels.filter { part in
            channelName.map { AppOSC.normalize($0) == AppOSC.normalize(part.channelName) } ?? true
        }
        for part in parts {
            // By identity first; a channel deleted and re-added with the same name still works
            guard let channel = store.channels.first(where: { $0.id == part.channelID })
                ?? AppOSCRouter.findChannel(part.channelName, in: store.channels) else {
                skipped += part.includedSlots.count
                continue
            }
            let result = apply(slots: part.slots, included: part.includedSlots, to: channel,
                               volume: part.includeVolume ? (part.volume, part.isMuted) : nil)
            applied += result.applied
            skipped += result.skipped
            if part.includeFader, let db = part.faderDB,
               let current = store.channels.first(where: { $0.id == channel.id }) {
                MixerLink.shared.setFader(db, for: current)
                applied += 1
            }
        }
        var text = "Mix \"\(preset.name)\"\(channelName.map { " / \($0)" } ?? ""): \(applied) setting\(applied == 1 ? "" : "s")"
        if skipped > 0 { text += ", \(skipped) skipped (effect changed or channel missing)" }
        return text
    }

    /// One of a channel's own presets, with the same live rules
    @discardableResult
    func recall(_ macro: ChannelMacro, on channel: AudioChannel) -> String {
        let used = Set(macro.slots.indices.filter { macro.slots[$0].type != nil })
        let result = apply(slots: macro.slots, included: used, to: channel, volume: (macro.volume, macro.isMuted))
        var text = "\(channel.displayName) preset \"\(macro.name)\": \(result.applied) setting\(result.applied == 1 ? "" : "s")"
        if result.skipped > 0 { text += ", \(result.skipped) skipped (effect changed)" }
        return text
    }

    /// Writes the included slots that still hold the same effect, then pushes each to the
    /// running engine in place. Nothing is rebuilt.
    private func apply(slots: [ChannelFXSlot], included: Set<Int>, to channel: AudioChannel,
                       volume: (Float, Bool)?) -> (applied: Int, skipped: Int) {
        var c = channel
        var changed: [Int] = []
        var skipped = 0
        for i in included.sorted() where slots.indices.contains(i) && c.slots.indices.contains(i) {
            guard let type = slots[i].type, c.slots[i].type == type else { skipped += 1; continue }
            c.slots[i] = slots[i]
            changed.append(i)
        }
        if case let (v, muted)? = volume {
            c.volume = v
            c.isMuted = muted
        }
        store.update(c)
        if engine.isRunning {
            for i in changed { engine.applySlot(c.slots[i], channelID: c.id, slotIndex: i) }
            if volume != nil { engine.applyVolume(of: c) }
        }
        return (changed.count + (volume == nil ? 0 : 1), skipped)
    }
}
