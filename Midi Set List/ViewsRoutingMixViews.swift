//
//  ViewsRoutingMixViews.swift
//  Midi Set List
//
//  Routing's mix tools: the AI mix wand (fader levels from a description of the song)
//  and mix presets (save the current effects / faders / volumes, tick what to keep, recall).
//

import SwiftUI

// MARK: - AI mix wand

struct MixLevelsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("mixLevels.lastDescription") private var description = MixLevelsAI.example
    @State private var levels: [MixLevelSuggestion] = []
    @State private var notes = ""
    @State private var isLoading = false
    @State private var error: String?

    private let store = AudioRoutingStore.shared
    private let link = MixerLink.shared

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $description)
                        .frame(minHeight: 100)
                } header: {
                    Text("Describe the Song and Mix")
                } footer: {
                    Text("Style, what should be up front, who sings lead. The AI reads your channel names (and their effects) to tell what each one is.")
                }

                Section {
                    Button {
                        Task { await suggest() }
                    } label: {
                        HStack {
                            Label("Suggest Fader Levels", systemImage: "wand.and.stars")
                            if isLoading { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(isLoading || store.channels.isEmpty
                              || description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if let error {
                        Text(error).font(.callout).foregroundStyle(.red)
                    }
                }

                if !levels.isEmpty {
                    Section {
                        ForEach($levels) { $level in
                            Stepper(value: $level.db, in: -40...5, step: 1) {
                                LabeledContent(level.name) {
                                    HStack(spacing: 6) {
                                        if let now = link.faderDB[level.channelID] {
                                            Text(MixerLinkSettings.faderLabel(now, floor: link.settings.faderFloorDB))
                                                .foregroundStyle(.secondary)
                                            Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.secondary)
                                        }
                                        Text(String(format: "%+.0f dB", level.db)).fontWeight(.semibold)
                                    }
                                    .monospacedDigit()
                                }
                            }
                        }
                    } header: {
                        Text("Suggested Faders")
                    } footer: {
                        Text(notes.isEmpty ? "Adjust any level, then Apply to send them to the mixer." : notes)
                    }
                }
            }
            .navigationTitle("AI Mix")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") { apply(); dismiss() }
                        .disabled(levels.isEmpty)
                }
            }
        }
    }

    private func suggest() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let result = try await MixLevelsAI.suggest(description: description, channels: store.channels)
            levels = result.levels
            notes = result.notes
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func apply() {
        for level in levels {
            guard let channel = store.channels.first(where: { $0.id == level.channelID }) else { continue }
            link.setFader(level.db, for: channel)
        }
    }
}

// MARK: - Mix presets

struct MixPresetsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var editing: MixPreset?
    @State private var lastRecall: String?

    private let presets = MixPresetStore.shared

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        editing = presets.captureCurrentMix(named: presets.uniqueName("Mix \(presets.presets.count + 1)", excluding: nil))
                    } label: {
                        Label("Save Current Mix…", systemImage: "plus.circle.fill")
                    }
                } footer: {
                    Text("Captures each channel's effect settings, mixer fader and volume. You choose what the preset keeps; recalling it changes only those, live — nothing reloads.")
                }

                if !presets.presets.isEmpty {
                    Section {
                        ForEach(presets.presets) { preset in
                            HStack {
                                Button { editing = preset } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(preset.name).foregroundStyle(.primary)
                                        Text(preset.summary).font(.caption).foregroundStyle(.secondary)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                Button("Recall") { lastRecall = presets.recall(preset) }
                                    .buttonStyle(.bordered)
                            }
                        }
                        .onDelete { offsets in
                            for i in offsets { presets.delete(presets.presets[i]) }
                        }
                    } header: {
                        Text("Presets")
                    } footer: {
                        Text(lastRecall ?? "To recall a preset with a song section, open the song, pick a snapshot, then Quick Add › Mix Presets. It adds the preset's /app/mix/… command.")
                    }
                }
            }
            .navigationTitle("Mix Presets")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .sheet(item: $editing) { preset in
                MixPresetEditor(preset: preset, isNew: !presets.presets.contains { $0.id == preset.id })
            }
        }
    }
}

struct MixPresetEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var preset: MixPreset
    let isNew: Bool
    private let presets = MixPresetStore.shared
    private let link = MixerLink.shared

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $preset.name)
                    if !isNew {
                        Button("Update Values from Current Mix") { preset = presets.recaptured(preset) }
                    }
                } header: {
                    Text("Name")
                } footer: {
                    Text("Recall over OSC: \(preset.oscAddress)")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }

                ForEach($preset.channels) { $part in
                    Section {
                        ForEach(part.capturedSlots, id: \.self) { i in
                            Toggle(isOn: Binding(
                                get: { part.includedSlots.contains(i) },
                                set: { on in
                                    if on { part.includedSlots.insert(i) } else { part.includedSlots.remove(i) }
                                }
                            )) {
                                Label(part.slots[i].type?.displayName ?? "Effect",
                                      systemImage: part.slots[i].type?.systemImage ?? "circle")
                            }
                        }
                        if let fader = part.faderDB {
                            Toggle(isOn: $part.includeFader) {
                                Label("Fader \(MixerLinkSettings.faderLabel(fader, floor: link.settings.faderFloorDB))",
                                      systemImage: "slider.vertical.3")
                            }
                        }
                        Toggle(isOn: $part.includeVolume) {
                            Label("Volume \(Int(part.volume * 100))%\(part.isMuted ? ", muted" : "")",
                                  systemImage: "speaker.wave.2")
                        }
                    } header: {
                        HStack {
                            Text(part.channelName)
                            Spacer()
                            Button(allOn(part) ? "None" : "All") { setAll(&part, on: !allOn(part)) }
                                .font(.caption)
                                .textCase(nil)
                        }
                    } footer: {
                        Text("Just this channel: \(preset.oscAddress(for: part))")
                            .font(.caption2.monospaced())
                            .textSelection(.enabled)
                    }
                }
            }
            .navigationTitle(isNew ? "New Mix Preset" : "Edit Mix Preset")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { presets.upsert(preset); dismiss() }
                }
            }
        }
    }

    private func allOn(_ part: MixPresetChannel) -> Bool {
        part.includedSlots.count == part.capturedSlots.count
            && (part.faderDB == nil || part.includeFader) && part.includeVolume
    }

    private func setAll(_ part: inout MixPresetChannel, on: Bool) {
        part.includedSlots = on ? Set(part.capturedSlots) : []
        part.includeFader = on && part.faderDB != nil
        part.includeVolume = on
    }
}
