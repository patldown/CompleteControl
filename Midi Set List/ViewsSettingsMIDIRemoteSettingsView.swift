//
//  MIDIRemoteSettingsView.swift
//  Midi Set List
//
//  MIDI receive setup: the channel the app listens on, which messages recall
//  snapshots, and which move to the previous / next song or snapshot.
//

import SwiftUI

struct MIDIRemoteSettingsView: View {
    @Environment(MIDIManager.self) private var midiManager
    @Environment(PerformanceSession.self) private var performance
    @ObservedObject private var remote = MIDIRemoteSettings.shared

    @State private var showingBTMIDI = false

    var body: some View {
        List {
            receiveSection
            monitorSection
            inputsSection
            snapshotSection
            individualSnapshotsSection
            navigationSection
        }
        .navigationTitle("MIDI Receive")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingBTMIDI) {
            BTMIDIConnectSheet()
        }
        // Don't leave a Learn waiting after the screen closes
        .onDisappear { performance.learnTarget = nil }
    }

    // MARK: Receive

    private var receiveSection: some View {
        Section {
            Toggle("Respond to MIDI", isOn: $remote.isEnabled)
            Picker("Receive Channel", selection: $remote.receiveChannel) {
                Text("Omni (all)").tag(0)
                ForEach(1...16, id: \.self) { ch in
                    Text("Channel \(ch)").tag(ch)
                }
            }
        } header: {
            Text("MIDI Receive")
        } footer: {
            Text("The app only reacts to messages on the receive channel. Set your controller to the same channel — or pick Omni to listen to everything.")
        }
    }

    // MARK: Monitor

    private var monitorSection: some View {
        Section {
            if let event = performance.lastRemoteEvent {
                VStack(alignment: .leading, spacing: 4) {
                    Text(event.message.description)
                        .font(.body.monospacedDigit())
                    Text(event.outcome)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .id(event.date)
            } else {
                Text("Press a button on your controller…")
                    .foregroundStyle(.secondary)
            }
            if let target = performance.learnTarget {
                HStack {
                    ProgressView()
                    Text("Listening for \(target.title)…")
                    Spacer()
                    Button("Cancel") { performance.learnTarget = nil }
                }
            }
        } header: {
            Text("Last Received")
        } footer: {
            Text("Shows the most recent message from any input and what the app did with it.")
        }
    }

    // MARK: Inputs

    private var inputsSection: some View {
        Section {
            if midiManager.availableSources.isEmpty {
                Text("No MIDI inputs found")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(midiManager.availableSources) { source in
                    Label(source.fullDescription, systemImage: "pianokeys")
                }
            }
            Button {
                showingBTMIDI = true
            } label: {
                Label("Connect Bluetooth Controller", systemImage: "wave.3.right")
            }
        } header: {
            Text("Inputs")
        } footer: {
            Text("The app listens to every connected input. Bluetooth foot controllers need to be paired here (or in the Connections tab) — not in the iOS Bluetooth settings.")
        }
    }

    // MARK: Snapshots

    private var snapshotSection: some View {
        Section {
            Picker("Message Type", selection: $remote.snapshotKind) {
                ForEach(MIDIRemoteMessage.Kind.allCases) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
            Stepper(value: $remote.snapshotBase, in: 0...MIDIRemoteSettings.maxSnapshotBase) {
                LabeledContent("Snapshot 1 starts at", value: "\(remote.snapshotKind.rawValue) \(remote.snapshotBase)")
            }
            learnButton(.snapshots)
            if remote.snapshotKind == .controlChange {
                Toggle("Ignore Value 0", isOn: $remote.ignoreZeroValues)
            }
        } header: {
            Text("Snapshot Numbering")
        } footer: {
            Text("Snapshot numbers count up from Snapshot 1 — with \(remote.snapshotKind.rawValue) \(remote.snapshotBase) for Snapshot 1, Snapshot 2 is \(remote.snapshotKind.rawValue) \(remote.snapshotBase + 1), and so on. They act on the song playing in Perform, or the song open in the Songs tab.\(remote.snapshotKind == .controlChange ? " \"Ignore Value 0\" stops momentary footswitches from firing twice (press and release)." : "")")
        }
    }

    private var individualSnapshotsSection: some View {
        Section {
            ForEach(0..<Song.maxSnapshots, id: \.self) { index in
                bindingRow(.snapshot(index),
                           value: remote.snapshotBinding(for: index)?.label ?? "—",
                           isCustom: remote.hasOverride(forSnapshot: index))
            }
            if remote.hasAnyOverride {
                Button("Reset All to Counted Numbers", role: .destructive) {
                    remote.clearSnapshotOverrides()
                }
            }
        } header: {
            Text("Individual Snapshots")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("Give any snapshot its own pedal: tap ⋯ → Learn, then press the pedal. It replaces that snapshot's counted number for every song. \"Custom\" marks the ones you've changed.")
                ForEach(Array(remote.conflicts.enumerated()), id: \.offset) { _, conflict in
                    Text("\(conflict.winner.title) and \(conflict.loser.title) both use \(conflict.binding.label) — only \(conflict.winner.title) will respond.")
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    // MARK: Navigation

    private var navigationSection: some View {
        Section {
            ForEach(MIDIRemoteLearnTarget.navigation) { target in
                bindingRow(target, value: remote.binding(for: target)?.label ?? "Off", isCustom: false)
            }
        } header: {
            Text("Previous / Next")
        } footer: {
            Text("Previous / Next Song only work while a set list is playing in Perform. Tap ⋯ → Learn, then press the pedal to assign it.")
        }
    }

    /// A trigger row: name, current binding, and a ⋯ menu to learn, pick or reset it.
    private func bindingRow(_ target: MIDIRemoteLearnTarget, value: String, isCustom: Bool) -> some View {
        HStack {
            Text(target.title)
            if isCustom {
                Text("Custom")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.15), in: Capsule())
                    .foregroundStyle(Color.accentColor)
            }
            Spacer()
            if performance.learnTarget == target {
                Text("Press a pedal…")
                    .foregroundStyle(.secondary)
                ProgressView()
            } else {
                Text(value)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Menu {
                Button {
                    performance.learnTarget = target
                } label: {
                    Label("Learn", systemImage: "ear")
                }
                Menu("Control Change") {
                    numberPicker(kind: .controlChange, target: target)
                }
                Menu("Program Change") {
                    numberPicker(kind: .programChange, target: target)
                }
                Menu("Note") {
                    numberPicker(kind: .note, target: target)
                }
                Divider()
                if case .snapshot = target {
                    if isCustom {
                        Button {
                            remote.setBinding(nil, for: target)
                        } label: {
                            Label("Use Counted Number", systemImage: "arrow.uturn.backward")
                        }
                    }
                } else {
                    Button(role: .destructive) {
                        remote.setBinding(nil, for: target)
                    } label: {
                        Label("Turn Off", systemImage: "xmark")
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    // MARK: Helpers

    private func learnButton(_ target: MIDIRemoteLearnTarget) -> some View {
        Button {
            performance.learnTarget = performance.learnTarget == target ? nil : target
        } label: {
            HStack {
                Label(performance.learnTarget == target ? "Press a pedal…" : "Learn from Controller",
                      systemImage: "ear")
                Spacer()
                if performance.learnTarget == target { ProgressView() }
            }
        }
    }

    /// Picks a number in blocks of 16 so the menu stays short.
    @ViewBuilder
    private func numberPicker(kind: MIDIRemoteMessage.Kind, target: MIDIRemoteLearnTarget) -> some View {
        ForEach(0..<8, id: \.self) { block in
            let range = (block * 16)...(block * 16 + 15)
            Menu("\(range.lowerBound)–\(range.upperBound)") {
                ForEach(Array(range), id: \.self) { number in
                    Button("\(kind.rawValue) \(number)") {
                        remote.setBinding(MIDIRemoteBinding(kind: kind, number: number), for: target)
                    }
                }
            }
        }
    }
}

#Preview {
    NavigationStack { MIDIRemoteSettingsView() }
        .environment(MIDIManager())
        .environment(PerformanceSession())
}
