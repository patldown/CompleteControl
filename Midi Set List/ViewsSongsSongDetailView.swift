//
//  SongDetailView.swift
//  Midi Set List
//
//  Created by Patrick Downey on 9/25/26.
//

import SwiftUI
import CoreData

struct SongDetailView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @Environment(MIDIManager.self) private var midiManager
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var song: Song
    
    @State private var showingGenrePicker = false
    @State private var selectedGenres: Set<String> = []
    @State private var showingAddCommand = false
    @State private var editingCommand: MIDICommand?
    @State private var showingDeleteConfirmation = false
    @State private var showingQuickCommands = false
    @State private var showingBatchEdit = false
    @State private var selectedCommands: Set<MIDICommand.ID> = []
    @State private var isSelectMode = false
    @State private var showingExportMenu = false
    @State private var showingImport = false
    @State private var exportedText = ""
    @State private var isSendingCommands = false
    @State private var sendError: String?
    @State private var showingSendError = false
    @State private var showingLyricsPerformance = false
    @State private var showingEditLyrics = false
    @State private var clockSendTransport = false

    // Track if we're in a navigation stack or presented as sheet
    var isInSheet: Bool = false

    private let timeSignatures = ["2/4", "3/4", "4/4", "5/4", "6/8", "7/8", "9/8", "12/8"]
    
    private let clipboard = CommandClipboard.shared
    
    var body: some View {
        List(selection: $selectedCommands) {
            Section("Song Information") {
                LabeledContent("Name") {
                    TextField("Song Name", text: Binding(
                        get: { song.name },
                        set: { song.name = $0 }
                    ))
                    .multilineTextAlignment(.trailing)
                }
                
                LabeledContent("Artist") {
                    TextField("Artist", text: Binding(
                        get: { song.artist ?? "" },
                        set: { song.artist = $0.isEmpty ? nil : $0 }
                    ))
                    .multilineTextAlignment(.trailing)
                }

                Button {
                    showingGenrePicker = true
                } label: {
                    LabeledContent("Genre") {
                        Text(selectedGenres.isEmpty
                             ? "Unspecified"
                             : selectedGenres.sorted().joined(separator: ", "))
                            .foregroundStyle(selectedGenres.isEmpty ? .secondary : .primary)
                            .multilineTextAlignment(.trailing)
                    }
                }
                .foregroundStyle(.primary)

                LabeledContent("Notes") {
                    TextField("Notes", text: Binding(
                        get: { song.notes ?? "" },
                        set: { song.notes = $0.isEmpty ? nil : $0 }
                    ), axis: .vertical)
                    .multilineTextAlignment(.trailing)
                }
            }
            
            // MIDI Clock Section
            Section {
                Toggle("Enable MIDI Clock", isOn: Binding(
                    get: { song.bpm != nil },
                    set: { enabled in
                        if enabled {
                            song.bpm = 120
                            if song.timeSignature == nil { song.timeSignature = "4/4" }
                        } else {
                            midiManager.stopClock()
                            song.bpm = nil
                        }
                    }
                ))

                if song.bpm != nil {
                    LabeledContent("BPM") {
                        TextField("20–300", value: Binding(
                            get: { song.bpm ?? 120 },
                            set: { newBPM in
                                let clamped = max(20, min(300, newBPM))
                                song.bpm = clamped
                                if midiManager.isClockRunning {
                                    midiManager.startClock(bpm: clamped, sendTransport: clockSendTransport)
                                }
                            }
                        ), format: .number)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 70)
                        .monospacedDigit()
                    }

                    Picker("Time Signature", selection: Binding(
                        get: { song.timeSignature ?? "4/4" },
                        set: { song.timeSignature = $0 }
                    )) {
                        ForEach(timeSignatures, id: \.self) { sig in
                            Text(sig).tag(sig)
                        }
                    }

                    if midiManager.isInitialized {
                        Toggle("Send Start / Stop", isOn: $clockSendTransport)
                            .disabled(midiManager.isClockRunning)

                        Button {
                            if midiManager.isClockRunning {
                                midiManager.stopClock()
                            } else {
                                midiManager.startClock(bpm: song.bpm ?? 120, sendTransport: clockSendTransport)
                            }
                        } label: {
                            HStack {
                                Image(systemName: midiManager.isClockRunning ? "stop.fill" : "metronome")
                                Text(midiManager.isClockRunning ? "Stop Clock" : "Start Clock")
                                if midiManager.isClockRunning {
                                    Spacer()
                                    Text("\(midiManager.currentClockBPM) BPM")
                                        .font(.caption)
                                        .foregroundStyle(.white.opacity(0.8))
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(midiManager.isClockRunning ? .red : .green)
                        .disabled(midiManager.availableDevices.isEmpty)
                    }
                }
            } header: {
                Text("MIDI Clock")
            } footer: {
                if song.bpm == nil {
                    Text("Enable to send MIDI clock pulses to connected devices.")
                } else if midiManager.availableDevices.isEmpty {
                    Text("No MIDI devices found. Make sure your device is connected.")
                } else {
                    Text(clockSendTransport
                         ? "Sends 24 PPQN + Start/Stop to all available devices. Time signature is display-only."
                         : "Sends 24 PPQN tempo only — no Start/Stop. Devices sync to tempo but play/stop independently.")
                }
            }

            // Lyrics/Tabs Section
            Section {
                Button {
                    showingEditLyrics = true
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Lyrics / Tabs")
                                .font(.headline)
                                .foregroundStyle(.primary)
                            
                            if let lyrics = song.lyrics, !lyrics.isEmpty {
                                Text(lyrics.prefix(100) + (lyrics.count > 100 ? "..." : ""))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            } else {
                                Text("Add lyrics or guitar tabs")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        
                        Spacer()
                        
                        Image(systemName: "chevron.right")
                            .foregroundStyle(.tertiary)
                    }
                }
                
                if song.lyrics != nil && !song.lyrics!.isEmpty {
                    Button {
                        showingLyricsPerformance = true
                    } label: {
                        Label("Performance Mode", systemImage: "play.rectangle.fill")
                            .foregroundStyle(.green)
                    }
                }
            } header: {
                Text("Performance")
            } footer: {
                if song.lyrics == nil || song.lyrics!.isEmpty {
                    Text("Add lyrics or tabs to enable Performance Mode with auto-scroll")
                } else {
                    Text("Performance Mode shows full-screen lyrics with auto-scroll for hands-free playing")
                }
            }
            
            // Send Section — shown whenever there are commands
            if !song.commands.isEmpty {
                Section {
                    Button {
                        Task { await sendAllCommands() }
                    } label: {
                        HStack {
                            if isSendingCommands {
                                ProgressView()
                            } else {
                                Image(systemName: "paperplane.fill")
                            }
                            Text("Send All Commands")
                            Spacer()
                            if !midiManager.connectedDevices.isEmpty {
                                Text("\(midiManager.connectedDevices.count) MIDI")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .disabled(!canSendAny)
                } header: {
                    Text("MIDI / OSC")
                } footer: {
                    if canSendAny {
                        Text("Sends all \(song.commands.count) command(s) in sequence.")
                    } else {
                        Text("Connect a MIDI device or an OSC target to send commands.")
                    }
                }
            }
            
            Section {
                ForEach(song.sortedCommands) { command in
                    Button {
                        if isSelectMode {
                            toggleSelection(command)
                        } else {
                            editingCommand = command
                        }
                    } label: {
                        MIDICommandRowView(
                            command: command,
                            isSelected: selectedCommands.contains(command.id),
                            showSelection: isSelectMode
                        )
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            deleteCommand(command)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                    .swipeActions(edge: .leading, allowsFullSwipe: false) {
                        if canSend(command) {
                            Button {
                                Task {
                                    await sendSingleCommand(command)
                                }
                            } label: {
                                Label("Send", systemImage: "paperplane")
                            }
                            .tint(.green)
                        }
                        
                        Button {
                            duplicateCommand(command)
                        } label: {
                            Label("Duplicate", systemImage: "doc.on.doc")
                        }
                        .tint(.blue)
                    }
                    .contextMenu {
                        Button {
                            editingCommand = command
                        } label: {
                            Label("Edit", systemImage: "pencil")
                        }
                        
                        Button {
                            duplicateCommand(command)
                        } label: {
                            Label("Duplicate", systemImage: "doc.on.doc")
                        }
                        
                        Divider()
                        
                        Button(role: .destructive) {
                            deleteCommand(command)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
                .onMove(perform: moveCommands)
                
                Menu {
                    Button {
                        showingAddCommand = true
                    } label: {
                        Label("Manual Entry", systemImage: "keyboard")
                    }
                    
                    Button {
                        showingQuickCommands = true
                    } label: {
                        Label("Quick Add", systemImage: "bolt.fill")
                    }
                } label: {
                    Label("Add Command", systemImage: "plus.circle.fill")
                }
            } header: {
                HStack {
                    Text("Commands")
                    Spacer()
                    if isSelectMode {
                        Text("\(selectedCommands.count) selected")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("\(song.commands.count)")
                            .foregroundStyle(.secondary)
                    }
                }
            } footer: {
                if isSelectMode {
                    Text("Select commands for batch operations.")
                } else if !song.commands.isEmpty {
                    Text("Commands are sent in order from top to bottom. Tap to edit, swipe left to delete, swipe right to send/duplicate. Long-press and drag to reorder.")
                }
            }
        }
        .navigationTitle(song.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Show Done button if presented in sheet, otherwise show menu items
            if isInSheet {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            
            ToolbarItem(placement: .primaryAction) {
                if isSelectMode {
                    Button("Done") {
                        isSelectMode = false
                        selectedCommands.removeAll()
                    }
                } else {
                    // Show command count or nothing
                    EmptyView()
                }
            }
            
            ToolbarItem(placement: .secondaryAction) {
                Menu {
                    Button {
                        isSelectMode.toggle()
                        if !isSelectMode {
                            selectedCommands.removeAll()
                        }
                    } label: {
                        Label(isSelectMode ? "Cancel Selection" : "Select Commands", 
                              systemImage: "checkmark.circle")
                    }
                    
                    if !song.commands.isEmpty {
                        Divider()
                        
                        // Copy/Paste
                        if isSelectMode && !selectedCommands.isEmpty {
                            Button {
                                copySelectedCommands()
                            } label: {
                                Label("Copy \(selectedCommands.count)", systemImage: "doc.on.doc")
                            }
                        }
                        
                        if clipboard.hasCommands {
                            Button {
                                pasteCommands()
                            } label: {
                                Label("Paste \(clipboard.commandCount)", systemImage: "doc.on.clipboard")
                            }
                        }
                        
                        Divider()
                        
                        // Export
                        Button {
                            showingExportMenu = true
                        } label: {
                            Label("Export Commands", systemImage: "square.and.arrow.up")
                        }
                        
                        // Import
                        Button {
                            showingImport = true
                        } label: {
                            Label("Import Commands", systemImage: "square.and.arrow.down")
                        }
                        
                        Divider()
                        
                        Button {
                            showingBatchEdit = true
                        } label: {
                            Label("Batch Edit All", systemImage: "slider.horizontal.3")
                        }
                        
                        Button(role: .destructive) {
                            showingDeleteConfirmation = true
                        } label: {
                            Label("Clear All Commands", systemImage: "trash")
                        }
                    }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showingAddCommand) {
            AddMIDICommandView(song: song)
        }
        .sheet(item: $editingCommand) { command in
            EditMIDICommandView(command: command)
        }
        .sheet(isPresented: $showingQuickCommands) {
            QuickCommandsView(song: song)
        }
        .sheet(isPresented: $showingBatchEdit) {
            BatchEditCommandsView(
                song: song,
                selectedCommands: Array(selectedCommands.compactMap { id in
                    song.commands.first(where: { $0.id == id })
                })
            )
        }
        .sheet(isPresented: $showingExportMenu) {
            ExportCommandsView(commands: song.sortedCommands)
        }
        .sheet(isPresented: $showingImport) {
            ImportCommandsView(song: song)
        }
        .confirmationDialog(
            "Delete All Commands?",
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete All", role: .destructive) {
                clearAllCommands()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently delete all \(song.commands.count) MIDI commands from this song.")
        }
        .alert("MIDI Error", isPresented: $showingSendError) {
            Button("OK", role: .cancel) {}
        } message: {
            if let error = sendError {
                Text(error)
            }
        }
        .fullScreenCover(isPresented: $showingLyricsPerformance) {
            LyricsPerformanceView(song: song)
        }
        .sheet(isPresented: $showingEditLyrics) {
            EditLyricsView(song: song)
        }
        .onAppear { selectedGenres = Set(song.genres) }
        .onChange(of: selectedGenres) { _, newValue in
            song.setGenres(Array(newValue))
            song.dateModified = Date()
            try? viewContext.save()
        }
        .sheet(isPresented: $showingGenrePicker) {
            GenrePickerSheet(selectedGenres: $selectedGenres)
        }
        .onChange(of: song.name)   { _, _ in song.dateModified = Date(); try? viewContext.save() }
        .onChange(of: song.artist) { _, _ in song.dateModified = Date(); try? viewContext.save() }
        .onChange(of: song.notes)  { _, _ in song.dateModified = Date(); try? viewContext.save() }
        .onChange(of: song.lyrics) { _, _ in song.dateModified = Date(); try? viewContext.save() }
        .onChange(of: song.bpm)    { _, _ in song.dateModified = Date(); try? viewContext.save() }
    }
    
    // A command can be sent if it's OSC (no MIDI device needed) or if a MIDI device is connected
    private func canSend(_ command: MIDICommand) -> Bool {
        command.commandType == .oscMessage || !midiManager.connectedDevices.isEmpty
    }

    // The "Send All" button is enabled if any command in the song can be sent
    private var canSendAny: Bool {
        !isSendingCommands && song.commands.contains { canSend($0) }
    }

    private func toggleSelection(_ command: MIDICommand) {
        if selectedCommands.contains(command.id) {
            selectedCommands.remove(command.id)
        } else {
            selectedCommands.insert(command.id)
        }
    }
    
    private func duplicateCommand(_ command: MIDICommand) {
        let duplicate = MIDICommand(
            commandType: command.commandType,
            channel: command.channel,
            value1: command.value1,
            value2: command.value2,
            delayMilliseconds: command.delayMilliseconds,
            notes: command.notes.map { $0 + " (Copy)" },
            context: viewContext
        )
        song.addCommand(duplicate)
        try? viewContext.save()
    }
    
    private func deleteCommand(_ command: MIDICommand) {
        song.removeCommand(command)
        viewContext.delete(command)
        try? viewContext.save()
    }

    private func deleteCommands(at offsets: IndexSet) {
        let sortedCommands = song.sortedCommands
        for index in offsets {
            let command = sortedCommands[index]
            song.removeCommand(command)
            viewContext.delete(command)
        }
        try? viewContext.save()
    }

    private func clearAllCommands() {
        for command in song.commands { viewContext.delete(command) }
        song.dateModified = Date()
        try? viewContext.save()
    }
    
    private func moveCommands(from source: IndexSet, to destination: Int) {
        guard let sourceIndex = source.first else { return }
        song.moveCommand(from: sourceIndex, to: destination)
    }
    
    private func copySelectedCommands() {
        let commands = selectedCommands.compactMap { id in
            song.commands.first(where: { $0.id == id })
        }
        clipboard.copy(commands)
    }
    
    private func pasteCommands() {
        clipboard.paste(to: song, in: viewContext)
    }
    
    private func sendSingleCommand(_ command: MIDICommand) async {
        let ctx = FormulaEvaluator.Context.forSong(bpm: song.bpm)
        do {
            try await midiManager.sendCommand(command, formulaContext: ctx)
        } catch {
            sendError = error.localizedDescription
            showingSendError = true
        }
    }
    
    private func sendAllCommands() async {
        isSendingCommands = true
        do {
            try await midiManager.sendSong(song)
        } catch {
            sendError = error.localizedDescription
            showingSendError = true
        }
        isSendingCommands = false
    }
}

/// Observes the macro so it re-renders whenever the macro's fields change,
/// allowing deviatesFromMacro to re-evaluate reactively.
private struct MacroDeviationLabel: View {
    @ObservedObject var macro: DeviceMacro
    let command: MIDICommand

    var body: some View {
        if command.deviatesFromMacro {
            Label("Overridden from \"\(macro.name)\"", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                .font(.caption2)
                .foregroundStyle(.orange)
        }
    }
}

struct MIDICommandRowView: View {
    @ObservedObject var command: MIDICommand
    var isSelected: Bool = false
    var showSelection: Bool = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            if showSelection {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? .blue : .secondary)
                    .imageScale(.large)
            }

            // Order indicator
            Text("#\(command.orderIndex + 1)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 30, alignment: .leading)

            VStack(alignment: .leading, spacing: 4) {
                Text(command.displayDescription)
                    .font(.body)
                    .foregroundStyle(.primary)

                if let macro = command.sourceMacro {
                    MacroDeviationLabel(macro: macro, command: command)
                }

                if let notes = command.notes, !notes.isEmpty {
                    Text(notes)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if command.delayMilliseconds > 0 {
                    Text("Delay: \(command.delayMilliseconds)ms")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            
            Spacer()
            
            // Validation indicator
            if !command.isValid {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help("Invalid MIDI values")
            }
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    let ctx = PersistenceController.preview.viewContext
    let song = Song.create(name: "Sweet Home Alabama", artist: "Lynyrd Skynyrd", in: ctx)
    let c1 = MIDICommand(commandType: .bankSelectMSB, channel: 1, value1: 0,
                          delayMilliseconds: 50, notes: "Bank MSB", context: ctx)
    let c2 = MIDICommand(commandType: .programChange, channel: 1, value1: 5,
                          delayMilliseconds: 100, notes: "Load preset 5", context: ctx)
    song.addCommand(c1); song.addCommand(c2)
    try? ctx.save()
    return NavigationStack { SongDetailView(song: song) }
        .environment(\.managedObjectContext, ctx)
        .environment(MIDIManager())
}
