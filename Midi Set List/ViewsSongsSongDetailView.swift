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
    @Environment(PerformanceSession.self) private var performance
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var song: Song

    /// The snapshot whose commands are listed and edited below.
    @State private var selectedSnapshot = 0
    
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

            ReferenceTrackSection(song: song)

            keySection

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
                            Text("Lyrics & Sheet Music")
                                .font(.headline)
                                .foregroundStyle(.primary)

                            if song.pdfFileName != nil {
                                Label("Sheet music PDF", systemImage: "doc.fill")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else if !song.chartImageNames.isEmpty {
                                Label("Sheet music: \(song.chartImageNames.count) image\(song.chartImageNames.count == 1 ? "" : "s")",
                                      systemImage: "photo.on.rectangle")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            if let lyrics = song.lyrics, !lyrics.isEmpty {
                                Text(lyrics.prefix(100) + (lyrics.count > 100 ? "..." : ""))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            } else if !song.hasSheetMusic {
                                Text("Add lyrics, tabs, or sheet music (PDF or images)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        
                        Spacer()
                        
                        Image(systemName: "chevron.right")
                            .foregroundStyle(.tertiary)
                    }
                }
                
                if song.hasLyricsText || song.hasSheetMusic {
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
                if !song.hasLyricsText && !song.hasSheetMusic {
                    Text("Add lyrics or sheet music to enable Performance Mode with auto-scroll")
                } else if song.hasLyricsText && song.hasSheetMusic {
                    Text("Performance Mode shows lyrics or sheet music full screen with auto-scroll. Whichever you pick last is remembered for you.")
                } else {
                    Text("Performance Mode shows it full screen with auto-scroll for hands-free playing")
                }
            }
            
            SongSnapshotsSection(song: song, selected: $selectedSnapshot,
                                 footerOverride: isSelectMode ? "Select commands for batch operations." : nil) {
                if !snapshotCommands.isEmpty {
                    HStack {
                        Text("\(song.snapshotName(selectedSnapshot)) Commands")
                        Spacer()
                        Text(isSelectMode ? "\(selectedCommands.count) selected" : "\(snapshotCommands.count)")
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                }

                ForEach(snapshotCommands) { command in
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
                    Label("Add to \(song.snapshotName(selectedSnapshot))", systemImage: "plus.circle.fill")
                }

                if !snapshotCommands.isEmpty {
                    Button {
                        Task { await sendAllCommands() }
                    } label: {
                        HStack {
                            if isSendingCommands {
                                ProgressView()
                            } else {
                                Image(systemName: "paperplane.fill")
                            }
                            Text("Send \(song.snapshotName(selectedSnapshot))")
                            Spacer()
                            if !canSendAny && !isSendingCommands {
                                Text("No MIDI or OSC connected")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else if !midiManager.connectedDevices.isEmpty {
                                Text("\(midiManager.connectedDevices.count) MIDI")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .disabled(!canSendAny)
                }

                Toggle(isOn: Binding(
                    get: { song.sendsSnapshotOnLoad },
                    set: { song.sendsSnapshotOnLoad = $0; saveSong() }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Send \(song.snapshotName(0)) When Song Loads")
                        Text(song.sendsSnapshotOnLoad
                             ? "In Perform, loading this song sends its first snapshot."
                             : "In Perform, nothing is sent until you tap a snapshot or press a pedal.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
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
                    ShareItemButton(object: song, kindName: "Song", itemName: song.name)
                    Divider()

                    Button {
                        isSelectMode.toggle()
                        if !isSelectMode {
                            selectedCommands.removeAll()
                        }
                    } label: {
                        Label(isSelectMode ? "Cancel Selection" : "Select Commands", 
                              systemImage: "checkmark.circle")
                    }
                    
                    if !snapshotCommands.isEmpty {
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
                            Label("Clear \(song.snapshotName(selectedSnapshot))", systemImage: "trash")
                        }
                    }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showingAddCommand) {
            AddMIDICommandView(song: song, snapshotIndex: selectedSnapshot)
        }
        .sheet(item: $editingCommand) { command in
            EditMIDICommandView(command: command)
        }
        .sheet(isPresented: $showingQuickCommands) {
            QuickCommandsView(song: song, snapshotIndex: selectedSnapshot)
        }
        .sheet(isPresented: $showingBatchEdit) {
            BatchEditCommandsView(
                song: song,
                snapshotIndex: selectedSnapshot,
                selectedCommands: Array(selectedCommands.compactMap { id in
                    song.commands.first(where: { $0.id == id })
                })
            )
        }
        .sheet(isPresented: $showingExportMenu) {
            ExportCommandsView(commands: snapshotCommands)
        }
        .sheet(isPresented: $showingImport) {
            ImportCommandsView(song: song, snapshotIndex: selectedSnapshot)
        }
        .confirmationDialog(
            "Clear \(song.snapshotName(selectedSnapshot))?",
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete Commands", role: .destructive) {
                clearAllCommands()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently delete the \(snapshotCommands.count) command(s) in \(song.snapshotName(selectedSnapshot)). The snapshot itself stays.")
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
        .onAppear {
            selectedGenres = Set(song.genres)
            // MIDI snapshot recalls act on the open song when no set list is playing
            performance.focus(song)
        }
        .onDisappear {
            performance.unfocus(song)
            AppleMusicReference.shared.stop()
        }
        .onChange(of: selectedSnapshot) { _, _ in selectedCommands.removeAll() }
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
    
    // MARK: - Key, transpose & capo

    private func saveSong() {
        song.dateModified = Date()
        try? viewContext.save()
    }

    private var keySection: some View {
        Section {
            Picker("Key", selection: Binding(
                get: { song.keyRoot ?? "" },
                set: { root in
                    if root.isEmpty {
                        song.originalKey = nil
                    } else {
                        song.originalKey = MusicalKey(root: root, scale: song.originalKey?.scale ?? .major)
                    }
                    saveSong()
                }
            )) {
                Text("None").tag("")
                ForEach(NoteName.pickerRoots, id: \.self) { root in
                    Text(root.replacingOccurrences(of: "#", with: "♯").replacingOccurrences(of: "b", with: "♭"))
                        .tag(root)
                }
            }

            if let key = song.originalKey {
                Picker("Scale", selection: Binding(
                    get: { key.scale },
                    set: { song.originalKey = MusicalKey(root: key.root, scale: $0); saveSong() }
                )) {
                    ForEach(MusicalScale.allCases) { scale in
                        Text(scale.rawValue).tag(scale)
                    }
                }
            }

            Stepper(value: Binding(
                get: { song.transpose },
                set: { song.transpose = $0; saveSong() }
            ), in: Song.transposeRange) {
                LabeledContent("Transpose") {
                    Text(song.transpose == 0 ? "Original" : "\(TransposeMenu.offsetLabel(song.transpose)) semitones")
                        .monospacedDigit()
                }
            }

            Toggle("Capo", isOn: Binding(
                get: { song.capoEnabled },
                set: { song.capoEnabled = $0; saveSong() }
            ))

            if song.capoEnabled {
                Stepper(value: Binding(
                    get: { song.capo },
                    set: { song.capo = $0; saveSong() }
                ), in: Song.capoRange) {
                    LabeledContent("Chart Capo Fret") {
                        Text(song.capo == 0 ? "None" : "\(song.capo)")
                            .monospacedDigit()
                    }
                }

                Toggle(isOn: Binding(
                    get: { song.capoKeepsKey },
                    set: { song.capoKeepsKey = $0; saveSong() }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Capo Keeps Original Key")
                        Text(song.capoKeepsKey
                             ? "Transpose changes the chord shapes; the capo moves to keep the key."
                             : "Transpose changes the key; the capo stays put.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if song.transpose != 0 || song.capo != 0 {
                    LabeledContent("Capo Now") {
                        if let fret = song.effectiveCapo {
                            Text(fret == 0 ? "None" : "Fret \(fret)")
                        } else {
                            Text("Out of range — transpose the other way")
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }

            if song.originalKey != nil, song.transpose != 0 || song.capoEnabled {
                if let key = song.currentKey {
                    LabeledContent("Sounds In", value: key.displayName)
                }
                if song.capoEnabled, let shapes = song.chordShapeKey {
                    LabeledContent("Chord Shapes In", value: shapes.displayName)
                }
            }
        } header: {
            Text("Key & Capo")
        } footer: {
            Text("Set the key the song sounds in. Transpose shifts the chords in the lyrics without changing the saved lyrics. With Capo on and Capo Keeps Original Key, transposing down gives easier shapes and moves the capo up to match, so the audience hears the same key. Turn it off to really change the key and set the capo yourself.")
        }
    }

    private var snapshotCommands: [MIDICommand] {
        song.commands(inSnapshot: selectedSnapshot)
    }

    // A command can be sent if it's OSC (no MIDI device needed) or if a MIDI device is connected
    private func canSend(_ command: MIDICommand) -> Bool {
        command.commandType == .oscMessage || !midiManager.connectedDevices.isEmpty
    }

    // The "Send All" button is enabled if any command in the song can be sent
    private var canSendAny: Bool {
        !isSendingCommands && snapshotCommands.contains { canSend($0) }
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
        song.addCommand(duplicate, toSnapshot: command.snapshotIndex)
        try? viewContext.save()
    }
    
    private func deleteCommand(_ command: MIDICommand) {
        song.removeCommand(command)
        viewContext.delete(command)
        try? viewContext.save()
    }

    private func deleteCommands(at offsets: IndexSet) {
        let sortedCommands = snapshotCommands
        for index in offsets {
            let command = sortedCommands[index]
            song.removeCommand(command)
            viewContext.delete(command)
        }
        try? viewContext.save()
    }

    private func clearAllCommands() {
        for command in snapshotCommands {
            song.removeCommand(command)
            viewContext.delete(command)
        }
        song.dateModified = Date()
        try? viewContext.save()
    }
    
    private func moveCommands(from source: IndexSet, to destination: Int) {
        guard let sourceIndex = source.first else { return }
        song.moveCommand(from: sourceIndex, to: destination, inSnapshot: selectedSnapshot)
        try? viewContext.save()
    }
    
    private func copySelectedCommands() {
        let commands = selectedCommands.compactMap { id in
            song.commands.first(where: { $0.id == id })
        }
        clipboard.copy(commands)
    }
    
    private func pasteCommands() {
        clipboard.paste(to: song, snapshot: selectedSnapshot, in: viewContext)
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
            try await midiManager.sendSnapshot(selectedSnapshot, of: song)
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
        .environment(PerformanceSession())
}
