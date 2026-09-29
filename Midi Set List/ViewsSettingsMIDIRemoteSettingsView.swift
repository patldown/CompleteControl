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
            Text("The app listens to every connected input. Bluetooth foot controllers need to be paired here (or in the MIDI Devices tab) — not in the iOS Bluetooth settings.")
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
                LabeledContent("Snapshot 1", value: "\(remote.snapshotKind.rawValue) \(remote.snapshotBase)")
            }
            learnButton(.snapshots)
            if remote.snapshotKind == .controlChange {
                Toggle("Ignore Value 0", isOn: $remote.ignoreZeroValues)
            }
            DisclosureGroup("All 12 Snapshots") {
                ForEach(0..<Song.maxSnapshots, id: \.self) { index in
                    LabeledContent("Snapshot \(index + 1)", value: remote.snapshotBinding(for: index)?.label ?? "—")
                }
            }
        } header: {
            Text("Snapshots")
        } footer: {
            Text("Snapshot numbers count up from Snapshot 1 — with \(remote.snapshotKind.rawValue) \(remote.snapshotBase) for Snapshot 1, Snapshot 2 is \(remote.snapshotKind.rawValue) \(remote.snapshotBase + 1), and so on. They act on the song playing in Perform, or the song open in the Songs tab.\(remote.snapshotKind == .controlChange ? " \"Ignore Value 0\" stops momentary footswitches from firing twice (press and release)." : "")")
        }
    }

    // MARK: Navigation

    private var navigationSection: some View {
        Section {
            ForEach(MIDIRemoteLearnTarget.navigation) { target in
                HStack {
                    Text(target.title)
                    Spacer()
                    if performance.learnTarget == target {
                        ProgressView()
                    } else {
                        Text(remote.binding(for: target)?.label ?? "Off")
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
                        Button(role: .destructive) {
                            remote.setBinding(nil, for: target)
                        } label: {
                            Label("Turn Off", systemImage: "xmark")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        } header: {
            Text("Previous / Next")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("Previous / Next Song only work while a set list is playing in Perform. Tap ⋯ → Learn, then press the pedal to assign it.")
                if !remote.overlappingTargets.isEmpty {
                    Text("\(remote.overlappingTargets.map(\.title).joined(separator: ", ")) share a number with a snapshot — the snapshot won't be reachable from MIDI.")
                        .foregroundStyle(.orange)
                }
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
