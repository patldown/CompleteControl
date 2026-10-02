//
//  QuickCommandsView.swift
//  Midi Set List
//

import SwiftUI
import CoreData

// MARK: - Main Quick Add sheet

struct QuickCommandsView: View {
    let song: Song
    /// Snapshot new commands and macros are added to (0 = Snapshot 1)
    var snapshotIndex: Int = 0
    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.dismiss) private var dismiss
    @FetchRequest(sortDescriptors: [SortDescriptor(\.name)]) private var devices: FetchedResults<InstrumentDevice>

    @State private var addedCommands: Set<String> = []
    @State private var showingSuccessBanner = false
    @State private var lastAddedCommand = ""

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                List {
                    Section {
                        HStack {
                            Image(systemName: "info.circle.fill")
                                .foregroundStyle(.blue)
                            Text("\(song.commands(inSnapshot: snapshotIndex).count) command(s) in \(song.snapshotName(snapshotIndex))")
                                .font(.subheadline)
                        }
                    }

                    if !devices.isEmpty {
                        Section("Your Instruments") {
                            ForEach(devices) { device in
                                NavigationLink(
                                    destination: QuickDeviceCategoriesView(
                                        song: song,
                                        snapshotIndex: snapshotIndex,
                                        device: device,
                                        onAdded: handleAdded,
                                        onDone: { dismiss() }
                                    )
                                ) {
                                    HStack(spacing: 12) {
                                        Image(systemName: "pianokeys")
                                            .font(.title3)
                                            .foregroundStyle(.blue)
                                            .frame(width: 30)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(device.name)
                                                .font(.headline)
                                            if let m = device.manufacturer, !m.isEmpty {
                                                Text(m).font(.caption).foregroundStyle(.secondary)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }

                    Section("BeatBuddy") {
                        QuickCommandButton(
                            title: "Select Folder",
                            icon: "folder",
                            description: "Change BeatBuddy folder (Bank LSB)",
                            wasAdded: addedCommands.contains("beatbuddy_folder")
                        ) { addBeatBuddyFolder() }

                        QuickCommandButton(
                            title: "Select Song",
                            icon: "music.note",
                            description: "Change song in current folder (PC)",
                            wasAdded: addedCommands.contains("beatbuddy_song")
                        ) { addBeatBuddySong() }
                    }

                    Section("HX Stomp") {
                        QuickCommandButton(
                            title: "Load Preset",
                            icon: "rectangle.stack",
                            description: "Load a preset (PC)",
                            wasAdded: addedCommands.contains("hx_preset")
                        ) { addHXStompPreset() }

                        QuickCommandButton(
                            title: "Switch Snapshot",
                            icon: "camera.viewfinder",
                            description: "Change snapshot (CC 69)",
                            wasAdded: addedCommands.contains("hx_snapshot")
                        ) { addHXStompSnapshot() }
                    }

                    Section("Common Commands") {
                        QuickCommandButton(
                            title: "Program Change",
                            icon: "number",
                            description: "Generic program change",
                            wasAdded: addedCommands.contains("generic_pc")
                        ) { addProgramChange() }

                        QuickCommandButton(
                            title: "Control Change",
                            icon: "slider.horizontal.3",
                            description: "Generic control change",
                            wasAdded: addedCommands.contains("generic_cc")
                        ) { addControlChange() }

                        QuickCommandButton(
                            title: "Delay",
                            icon: "timer",
                            description: "Add a timed pause (200ms)",
                            wasAdded: addedCommands.contains("delay")
                        ) { addDelay() }
                    }
                }

                if showingSuccessBanner {
                    SuccessBanner(message: "Added: \(lastAddedCommand)")
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .navigationTitle("Quick Add")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    func handleAdded(commandName: String) {
        lastAddedCommand = commandName
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            showingSuccessBanner = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation(.easeOut(duration: 0.3)) { showingSuccessBanner = false }
        }
    }

    private func showSuccess(for commandName: String, id: String) {
        addedCommands.insert(id)
        handleAdded(commandName: commandName)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { addedCommands.remove(id) }
    }

    private func addBeatBuddyFolder() {
        let cmd = MIDICommand(commandType: .bankSelectLSB, channel: 1, value1: 0, delayMilliseconds: 50, notes: "BeatBuddy folder", context: viewContext)
        song.addCommand(cmd, toSnapshot: snapshotIndex)
        try? viewContext.save()
        showSuccess(for: "BeatBuddy Folder", id: "beatbuddy_folder")
    }
    private func addBeatBuddySong() {
        let cmd = MIDICommand(commandType: .programChange, channel: 1, value1: 0, delayMilliseconds: 100, notes: "BeatBuddy song", context: viewContext)
        song.addCommand(cmd, toSnapshot: snapshotIndex)
        try? viewContext.save()
        showSuccess(for: "BeatBuddy Song", id: "beatbuddy_song")
    }
    private func addHXStompPreset() {
        let cmd = MIDICommand(commandType: .programChange, channel: 1, value1: 0, delayMilliseconds: 150, notes: "HX Stomp preset", context: viewContext)
        song.addCommand(cmd, toSnapshot: snapshotIndex)
        try? viewContext.save()
        showSuccess(for: "HX Stomp Preset", id: "hx_preset")
    }
    private func addHXStompSnapshot() {
        let cmd = MIDICommand(commandType: .controlChange, channel: 1, value1: 69, value2: 0, delayMilliseconds: 50, notes: "HX Stomp snapshot (0-7)", context: viewContext)
        song.addCommand(cmd, toSnapshot: snapshotIndex)
        try? viewContext.save()
        showSuccess(for: "HX Stomp Snapshot", id: "hx_snapshot")
    }
    private func addProgramChange() {
        let cmd = MIDICommand(commandType: .programChange, channel: 1, value1: 0, delayMilliseconds: 50, context: viewContext)
        song.addCommand(cmd, toSnapshot: snapshotIndex)
        try? viewContext.save()
        showSuccess(for: "Program Change", id: "generic_pc")
    }
    private func addControlChange() {
        let cmd = MIDICommand(commandType: .controlChange, channel: 1, value1: 0, value2: 0, delayMilliseconds: 50, context: viewContext)
        song.addCommand(cmd, toSnapshot: snapshotIndex)
        try? viewContext.save()
        showSuccess(for: "Control Change", id: "generic_cc")
    }
    private func addDelay() {
        let cmd = MIDICommand(commandType: .programChange, channel: nil, value1: 0, delayMilliseconds: 200, notes: "Delay only (no MIDI sent)", context: viewContext)
        song.addCommand(cmd, toSnapshot: snapshotIndex)
        try? viewContext.save()
        showSuccess(for: "Delay", id: "delay")
    }
}

// MARK: - Drill-down: categories for a device

struct QuickDeviceCategoriesView: View {
    let song: Song
    var snapshotIndex: Int = 0
    let device: InstrumentDevice
    let onAdded: (String) -> Void
    /// Closes the whole Quick Add sheet (this view's own dismiss would only go back)
    let onDone: () -> Void

    var body: some View {
        List {
            if device.sortedCategories.isEmpty {
                ContentUnavailableView(
                    "No Categories",
                    systemImage: "folder",
                    description: Text("Open the Instruments tab to add macro categories to \(device.name).")
                )
            } else {
                ForEach(device.sortedCategories) { category in
                    NavigationLink(
                        destination: QuickMacrosPickerView(song: song, snapshotIndex: snapshotIndex, category: category,
                                                           onAdded: onAdded, onDone: onDone)
                    ) {
                        HStack {
                            Image(systemName: "folder.fill").foregroundStyle(.orange)
                            Text(category.name)
                            Spacer()
                            Text("\(category.macros.count)").foregroundStyle(.secondary).font(.caption)
                        }
                    }
                }
            }
        }
        .navigationTitle(device.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done", action: onDone)
            }
        }
    }
}

// MARK: - Drill-down: macros in a category → tap to add to song

struct QuickMacrosPickerView: View {
    @Environment(\.managedObjectContext) private var viewContext
    let song: Song
    var snapshotIndex: Int = 0
    let category: MacroCategory
    let onAdded: (String) -> Void
    let onDone: () -> Void

    @State private var addedMacroIDs: Set<UUID> = []

    var body: some View {
        List {
            if category.sortedMacros.isEmpty {
                ContentUnavailableView(
                    "No Macros",
                    systemImage: "waveform.badge.plus",
                    description: Text("Add macros to this category in the Instruments tab.")
                )
            } else {
                ForEach(category.sortedMacros) { macro in
                    Button { addMacro(macro) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "waveform")
                                .font(.title3)
                                .foregroundStyle(addedMacroIDs.contains(macro.id) ? .green : .blue)
                                .frame(width: 30)

                            VStack(alignment: .leading, spacing: 3) {
                                Text(macro.name).font(.headline).foregroundStyle(.primary)
                                Text(macro.displayDescription)
                                    .font(.caption).foregroundStyle(.secondary).fontDesign(.monospaced)
                            }

                            Spacer()

                            Image(systemName: addedMacroIDs.contains(macro.id) ? "checkmark.circle.fill" : "plus.circle.fill")
                                .foregroundStyle(addedMacroIDs.contains(macro.id) ? .green : .green)
                                .imageScale(.large)
                        }
                        .padding(.vertical, 4)
                    }
                    .animation(.spring(response: 0.3, dampingFraction: 0.6), value: addedMacroIDs.contains(macro.id))
                }
            }
        }
        .navigationTitle(category.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done", action: onDone)
            }
        }
    }

    private func addMacro(_ macro: DeviceMacro) {
        let commands = macro.toMIDICommands(in: viewContext)
        let groupInstanceID = macro.isGroup ? UUID().uuidString : nil
        for command in commands {
            command.sourceMacro = macro
            command.sourceGroupInstanceID = groupInstanceID
            song.addCommand(command, toSnapshot: snapshotIndex)
        }
        try? viewContext.save()
        addedMacroIDs.insert(macro.id)
        onAdded(macro.name)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            addedMacroIDs.remove(macro.id)
        }
    }
}

// MARK: - Shared subviews

struct QuickCommandButton: View {
    let title: String
    let icon: String
    let description: String
    var wasAdded: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(wasAdded ? .green : .blue)
                    .frame(width: 30)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline).foregroundStyle(.primary)
                    Text(description).font(.caption).foregroundStyle(.secondary)
                }

                Spacer()

                if wasAdded {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green).imageScale(.large)
                        .transition(.scale.combined(with: .opacity))
                } else {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(.green).imageScale(.large)
                }
            }
            .padding(.vertical, 4)
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: wasAdded)
    }
}

struct SuccessBanner: View {
    let message: String

    var body: some View {
        HStack {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.white)
            Text(message).foregroundStyle(.white).font(.subheadline).fontWeight(.medium)
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.green)
                .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
        )
        .padding(.horizontal)
        .padding(.top, 8)
    }
}

#Preview {
    let ctx = PersistenceController.preview.viewContext
    let song = Song.create(name: "Test Song", in: ctx)
    let _ = try? ctx.save()
    QuickCommandsView(song: song)
        .environment(\.managedObjectContext, ctx)
}
