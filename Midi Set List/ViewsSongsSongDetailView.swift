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
    /// Group macro instance IDs that are currently expanded in the snapshot list.
    @State private var expandedGroups: Set<String> = []

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
    @State private var clockSendTransport = false
    @State private var bpmText: String = ""
    @FocusState private var bpmFieldFocused: Bool

    // Track if we're in a navigation stack or presented as sheet
    var isInSheet: Bool = false

    private let timeSignatures = SongDefaults.timeSignatures
    
    private let clipboard = CommandClipboard.shared
    
    var body: some View {
        List(selection: $selectedCommands) {
            Section("Song Information") {
                // Name and Artist side by side, above Genre / BPM / Time Sig.
                HStack(alignment: .top, spacing: 12) {
                    compactField("Name") {
                        TextField("Song Name", text: Binding(
                            get: { song.name },
                            set: { song.name = $0 }
                        ))
                        .font(.headline)
                        .padding(.vertical, 6)
                    }
                    compactField("Artist") {
                        TextField("Artist", text: Binding(
                            get: { song.artist ?? "" },
                            set: { song.artist = $0.isEmpty ? nil : $0 }
                        ))
                        .padding(.vertical, 6)
                    }
                }

                // Genre, BPM and time signature side by side; BPM and time signature are
                // the song's own, whether or not it sends MIDI clock
                HStack(alignment: .top, spacing: 12) {
                    compactField("Genre") {
                        Button {
                            showingGenrePicker = true
                        } label: {
                            Text(selectedGenres.isEmpty ? "None" : selectedGenres.sorted().joined(separator: ", "))
                                .foregroundStyle(selectedGenres.isEmpty ? .secondary : .primary)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 6)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                    }
                    compactField("BPM") {
                        TextField("—", text: $bpmText)
                            .keyboardType(.numberPad)
                            .monospacedDigit()
                            .padding(.vertical, 6)
                            .focused($bpmFieldFocused)
                            .onSubmit { commitBPM() }
                            .onChange(of: bpmFieldFocused) { _, focused in
                                if !focused { commitBPM() }
                            }
                    }
                    compactField("Time Sig.") {
                        Picker("Time Signature", selection: Binding(
                            get: { song.timeSignature ?? "" },
                            set: { song.timeSignature = $0.isEmpty ? nil : $0; saveSong() }
                        )) {
                            Text("—").tag("")
                            ForEach(timeSignatures, id: \.self) { Text($0).tag($0) }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                    }
                }

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

            clickTrackSection

            midiClockSection

            SongChartsSection(song: song) { showingLyricsPerformance = true }

            SongSnapshotsSection(song: song, selected: $selectedSnapshot,
                                 footerOverride: isSelectMode ? "Select commands for batch operations." : nil) {
                snapshotSectionContent
            }
        }
        .navigationTitle(song.name)
        .navigationBarTitleDisplayMode(.inline)
        .performShortcutDetail()
        .toolbar {
            // Show Done button if presented in sheet, otherwise show menu items
            if isInSheet {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }

            // Push-to-main: only for set-list copies that the local user owns
            if !song.isMaster && !PersistenceController.shared.isSharedByOther(song) {
                ToolbarItem(placement: .secondaryAction) {
                    PushToMainButton(song: song)
                }
            }

            // iCloud sharing: only for master songs
            if song.isMaster {
                ToolbarItem(placement: .secondaryAction) {
                    CloudSongShareButton(song: song)
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
                    ChordProExportButton(songs: [song])
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
        .onAppear {
            selectedGenres = Set(song.genres)
            bpmText = song.bpm.map(String.init) ?? ""
            // MIDI snapshot recalls act on the open song when no set list is playing
            performance.focus(song)
        }
        .onDisappear {
            performance.unfocus(song)
            AppleMusicReference.shared.stop()
        }
        .onChange(of: selectedSnapshot) { _, _ in selectedCommands.removeAll(); expandedGroups.removeAll() }
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
        .onChange(of: song.bpm)    { _, newBPM in
            song.dateModified = Date()
            try? viewContext.save()
            if !bpmFieldFocused { bpmText = newBPM.map(String.init) ?? "" }
        }
    }

    // MARK: - Key, transpose & capo

    private func saveSong() {
        song.dateModified = Date()
        try? viewContext.save()
    }

    private func commitBPM() {
        if bpmText.isEmpty {
            song.bpm = nil
        } else if let value = Int(bpmText) {
            let clamped = max(20, min(300, value))
            song.bpm = clamped
            bpmText = String(clamped)
        } else {
            bpmText = song.bpm.map(String.init) ?? ""
        }
        if let bpm = song.clockBPM, midiManager.isClockRunning {
            midiManager.startClock(bpm: bpm, sendTransport: clockSendTransport)
        } else if song.clockBPM == nil, midiManager.isClockRunning {
            midiManager.stopClock()
        }
    }

    /// Key and Scale side by side; Transpose, Capo and Sounds In below them. The capo's
    /// settings live in one menu, and "capo now / shapes" shows only when it tells you
    /// something the row doesn't.
    private var keySection: some View {
        Section {
            HStack(alignment: .top, spacing: 12) {
                compactField("Key") {
                    Picker("Key", selection: Binding(
                        get: { song.keyRoot ?? "" },
                        set: { root in
                            song.originalKey = root.isEmpty
                                ? nil
                                : MusicalKey(root: root, scale: song.originalKey?.scale ?? .major)
                            saveSong()
                        }
                    )) {
                        Text("None").tag("")
                        ForEach(NoteName.pickerRoots, id: \.self) { root in
                            Text(root.replacingOccurrences(of: "#", with: "♯").replacingOccurrences(of: "b", with: "♭"))
                                .tag(root)
                        }
                    }
                    // Full width for the picker's label, so it's never cut off
                    .fixedSize()
                }
                compactField("Scale") {
                    Picker("Scale", selection: Binding(
                        get: { song.originalKey?.scale ?? .major },
                        set: { scale in
                            guard let key = song.originalKey else { return }
                            song.originalKey = MusicalKey(root: key.root, scale: scale)
                            saveSong()
                        }
                    )) {
                        ForEach(MusicalScale.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .disabled(song.originalKey == nil)
                    .fixedSize()
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 12) {
                    compactField("Transpose") { transposeStepper }
                    compactField("Capo") { capoMenu }
                    compactField("Sounds In") {
                        Text(song.currentKey?.displayName ?? "—")
                            .foregroundStyle(song.currentKey == nil ? .secondary : .primary)
                            .padding(.vertical, 6)
                    }
                }
                if let detail = capoDetail {
                    Text(detail.text)
                        .font(.caption)
                        .foregroundStyle(detail.isWarning ? .orange : .secondary)
                }
            }
        } header: {
            Text("Key & Capo")
        } footer: {
            Text("Transpose moves the chords in the lyrics without changing the saved lyrics. With the capo keeping the original key, transposing down gives easier shapes and moves the capo up, so the audience hears the same key.")
        }
    }

    private func compactField<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var transposeStepper: some View {
        HStack(spacing: 10) {
            Button {
                song.transpose -= 1
                saveSong()
            } label: {
                Image(systemName: "minus.circle.fill")
            }
            .disabled(song.transpose <= Song.transposeRange.lowerBound)
            .accessibilityLabel("Transpose down")

            Text(TransposeMenu.offsetLabel(song.transpose))
                .monospacedDigit()
                .frame(minWidth: 24)

            Button {
                song.transpose += 1
                saveSong()
            } label: {
                Image(systemName: "plus.circle.fill")
            }
            .disabled(song.transpose >= Song.transposeRange.upperBound)
            .accessibilityLabel("Transpose up")
        }
        .font(.title3)
        // Borderless: several buttons in one list row each need their own tap
        .buttonStyle(.borderless)
        .padding(.vertical, 2)
    }

    /// Capo on / off, the fret the chart is written for, and whether it keeps the key
    private var capoMenu: some View {
        Menu {
            Toggle("Use a Capo", isOn: Binding(
                get: { song.capoEnabled },
                set: { song.capoEnabled = $0; saveSong() }
            ))
            // Stay open, so the capo's options appear as soon as it's turned on
            .menuActionDismissBehavior(.disabled)
            if !song.capoEnabled {
                Text("Turn on to pick the fret and whether it keeps the key")
            }
            if song.capoEnabled {
                Picker("Chart Capo Fret", selection: Binding(
                    get: { song.capo },
                    set: { song.capo = $0; saveSong() }
                )) {
                    ForEach(Array(Song.capoRange), id: \.self) { fret in
                        Text(fret == 0 ? "No Capo on Chart" : "Fret \(fret)").tag(fret)
                    }
                }
                .pickerStyle(.menu)
                Toggle("Keeps Original Key", isOn: Binding(
                    get: { song.capoKeepsKey },
                    set: { song.capoKeepsKey = $0; saveSong() }
                ))
            }
        } label: {
            HStack(spacing: 4) {
                Text(capoSummary)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
            }
            .padding(.vertical, 6)
        }
        .accessibilityLabel("Capo")
        .accessibilityValue(capoSummary)
    }

    private var capoSummary: String {
        guard song.capoEnabled else { return "Off" }
        return song.capo == 0 ? "On" : "Fret \(song.capo)"
    }

    /// "Capo now: fret 4 · G shapes" when transposing moves the capo or changes the shapes
    private var capoDetail: (text: String, isWarning: Bool)? {
        guard song.capoEnabled, song.transpose != 0 || song.capo != 0 else { return nil }
        guard let fret = song.effectiveCapo else {
            return ("Capo out of range — transpose the other way", true)
        }
        var parts = [fret == 0 ? "No capo now" : "Capo now: fret \(fret)"]
        if let shapes = song.chordShapeKey, song.originalKey != nil {
            parts.append("\(shapes.displayName) shapes")
        }
        if !song.capoKeepsKey { parts.append("key changes with transpose") }
        return (parts.joined(separator: " · "), false)
    }

    private var snapshotCommands: [MIDICommand] {
        song.commands(inSnapshot: selectedSnapshot)
    }

    private var snapshotMoveHandler: ((IndexSet, Int) -> Void)? {
        if hasGroupCommands { return nil }
        return moveCommands
    }

    private var snapshotSectionContent: some View {
        Group {
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

        ForEach(snapshotDisplayItems) { item in
            snapshotItemRow(item)
        }
        .onMove(perform: snapshotMoveHandler)

        Menu {
            Button { showingAddCommand = true } label: {
                Label("Manual Entry", systemImage: "keyboard")
            }
            Button { showingQuickCommands = true } label: {
                Label("Quick Add", systemImage: "bolt.fill")
            }
        } label: {
            Label("Add to \(song.snapshotName(selectedSnapshot))", systemImage: "plus.circle.fill")
        }

        if !snapshotCommands.isEmpty {
            Button { Task { await sendAllCommands() } } label: {
                snapshotSendLabel
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
        } // end Group
    }

    @ViewBuilder
    private var snapshotSendLabel: some View {
        HStack {
            if isSendingCommands { ProgressView() }
            else { Image(systemName: "paperplane.fill") }
            Text("Send \(song.snapshotName(selectedSnapshot))")
            Spacer()
            if !canSendAny && !isSendingCommands {
                Text("No MIDI or OSC connected").font(.caption).foregroundStyle(.secondary)
            } else if !midiManager.connectedDevices.isEmpty {
                Text("\(midiManager.connectedDevices.count) MIDI").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var clickTrackSection: some View {
        Section {
            Toggle("Click Track", isOn: Binding(
                get: { song.clickEnabled && song.bpm != nil },
                set: { enabled in
                    song.clickEnabled = enabled
                    if enabled, song.bpm == nil { song.bpm = 120 }
                    saveSong()
                }
            ))
        } footer: {
            let plural = song.beatsPerBar == 1 ? "" : "s"
            Text("Starts the metronome at the song's BPM when it loads in Perform, \(song.beatsPerBar) click\(plural) a bar with beat 1 accented. Each person chooses in Settings whether it plays and whether it just counts in.")
        }
    }

    @ViewBuilder
    private var midiClockSection: some View {
        Section {
            Toggle("Send MIDI Clock", isOn: Binding(
                get: { song.midiClockEnabled && song.bpm != nil },
                set: { enabled in
                    song.midiClockEnabled = enabled
                    if enabled {
                        if song.bpm == nil { song.bpm = 120 }
                    } else {
                        midiManager.stopClock()
                    }
                    saveSong()
                }
            ))
            if let clockBPM = song.clockBPM, midiManager.isInitialized {
                Toggle("Send Start / Stop", isOn: $clockSendTransport)
                    .disabled(midiManager.isClockRunning)
                Button {
                    if midiManager.isClockRunning { midiManager.stopClock() }
                    else { midiManager.startClock(bpm: clockBPM, sendTransport: clockSendTransport) }
                } label: { clockToggleLabel }
                .buttonStyle(.borderedProminent)
                .tint(midiManager.isClockRunning ? Color.red : Color.green)
                .disabled(midiManager.availableDevices.isEmpty)
            }
        } header: {
            Text("MIDI Clock")
        } footer: {
            if song.clockBPM == nil {
                Text("Sends clock pulses at the song's BPM so connected gear follows its tempo.")
            } else if midiManager.availableDevices.isEmpty {
                Text("No MIDI devices found. Make sure your device is connected.")
            } else {
                Text(clockSendTransport
                     ? "Sends 24 PPQN at \(song.bpm ?? 120) BPM + Start/Stop to all available devices."
                     : "Sends 24 PPQN at \(song.bpm ?? 120) BPM, tempo only — devices sync to tempo but play/stop independently.")
            }
        }
    }

    @ViewBuilder
    private var clockToggleLabel: some View {
        HStack {
            Image(systemName: midiManager.isClockRunning ? "stop.fill" : "metronome")
            Text(midiManager.isClockRunning ? "Stop Clock" : "Start Clock")
            if midiManager.isClockRunning {
                Spacer()
                Text("\(midiManager.currentClockBPM) BPM")
                    .font(.caption)
                    .foregroundStyle(Color.white.opacity(0.8))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
    }

    // MARK: - Row builders (broken out so the type-checker doesn't time out)

    // AnyView type-erasure breaks the exponential type-inference chain that
    // occurs when the compiler tries to resolve nested @ViewBuilder return types
    // across groupRow / childRow / soloRow simultaneously.
    private func snapshotItemRow(_ item: SnapshotItem) -> AnyView {
        switch item {
        case .group(let instanceID, let macro, let count):
            return AnyView(groupRow(instanceID: instanceID, macro: macro, count: count))
        case .child(let command):
            return AnyView(childRow(command))
        case .solo(let command):
            return AnyView(soloRow(command))
        }
    }

    @ViewBuilder
    private func groupRow(instanceID: String, macro: DeviceMacro, count: Int) -> some View {
        let isExpanded = expandedGroups.contains(instanceID)
        Button {
            if isExpanded { expandedGroups.remove(instanceID) }
            else          { expandedGroups.insert(instanceID) }
        } label: {
            GroupMacroRowView(macro: macro, commandCount: count, isExpanded: isExpanded)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) { deleteGroupCommands(instanceID: instanceID) } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            let groupCmds = snapshotCommands.filter { $0.sourceGroupInstanceID == instanceID }
            if groupCmds.contains(where: canSend) {
                Button {
                    Task { for cmd in groupCmds { await sendSingleCommand(cmd) } }
                } label: { Label("Send", systemImage: "paperplane") }
                .tint(.green)
            }
        }
        .moveDisabled(true)
    }

    @ViewBuilder
    private func childRow(_ command: MIDICommand) -> some View {
        Button {
            if isSelectMode { toggleSelection(command) }
            else            { editingCommand = command }
        } label: {
            MIDICommandRowView(command: command,
                               isSelected: selectedCommands.contains(command.id),
                               showSelection: isSelectMode)
                .padding(.leading, 16)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) { deleteCommand(command) } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .moveDisabled(true)
    }

    @ViewBuilder
    private func soloRow(_ command: MIDICommand) -> some View {
        Button {
            if isSelectMode { toggleSelection(command) }
            else            { editingCommand = command }
        } label: {
            MIDICommandRowView(command: command,
                               isSelected: selectedCommands.contains(command.id),
                               showSelection: isSelectMode)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) { deleteCommand(command) } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            if canSend(command) {
                Button { Task { await sendSingleCommand(command) } } label: {
                    Label("Send", systemImage: "paperplane")
                }.tint(.green)
            }
            Button { duplicateCommand(command) } label: {
                Label("Duplicate", systemImage: "doc.on.doc")
            }.tint(.blue)
        }
        .contextMenu {
            Button { editingCommand = command } label: { Label("Edit", systemImage: "pencil") }
            Button { duplicateCommand(command) } label: { Label("Duplicate", systemImage: "doc.on.doc") }
            Divider()
            Button(role: .destructive) { deleteCommand(command) } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private var hasGroupCommands: Bool {
        snapshotCommands.contains { $0.sourceGroupInstanceID != nil }
    }

    // MARK: - Snapshot display model

    private enum SnapshotItem: Identifiable {
        case group(instanceID: String, macro: DeviceMacro, commandCount: Int)
        case child(MIDICommand)
        case solo(MIDICommand)

        var id: String {
            switch self {
            case .group(let id, _, _):    return "grp_\(id)"
            case .child(let cmd):         return "child_\(cmd.id.uuidString)"
            case .solo(let cmd):          return cmd.id.uuidString
            }
        }
    }

    private var snapshotDisplayItems: [SnapshotItem] {
        let cmds = snapshotCommands
        var items: [SnapshotItem] = []
        var seenGroups: Set<String> = []

        for cmd in cmds {
            if let instanceID = cmd.sourceGroupInstanceID,
               let macro = cmd.sourceMacro, macro.isGroup {
                if seenGroups.insert(instanceID).inserted {
                    let count = cmds.filter { $0.sourceGroupInstanceID == instanceID }.count
                    items.append(.group(instanceID: instanceID, macro: macro, commandCount: count))
                }
                if expandedGroups.contains(instanceID) {
                    items.append(.child(cmd))
                }
            } else {
                items.append(.solo(cmd))
            }
        }
        return items
    }

    private func deleteGroupCommands(instanceID: String) {
        let toDelete = snapshotCommands.filter { $0.sourceGroupInstanceID == instanceID }
        song.batchDelete(toDelete, in: viewContext)
        try? viewContext.save()
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
        song.batchDelete([command], in: viewContext)
        try? viewContext.save()
    }

    private func deleteCommands(at offsets: IndexSet) {
        let toDelete = offsets.map { snapshotCommands[$0] }
        song.batchDelete(toDelete, in: viewContext)
        try? viewContext.save()
    }

    private func clearAllCommands() {
        song.batchDelete(snapshotCommands, in: viewContext)
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

// MARK: - Push to Main

/// Toolbar button that copies this set-list song's data back to the master.
/// Owns its own confirmation state so it doesn't add complexity to SongDetailView.
private struct PushToMainButton: View {
    let song: Song
    @Environment(\.managedObjectContext) private var viewContext
    @State private var confirming = false

    var body: some View {
        Button {
            confirming = true
        } label: {
            Label("Push to Main Song", systemImage: "arrow.up.square")
        }
        .confirmationDialog(
            "Overwrite main song with this version?",
            isPresented: $confirming,
            titleVisibility: .visible
        ) {
            Button("Push to Main", role: .destructive) {
                song.pushToMaster(in: viewContext)
                try? viewContext.save()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This copies all fields and commands from this set list's version back to the main song in your library.")
        }
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

struct GroupMacroRowView: View {
    @ObservedObject var macro: DeviceMacro
    let commandCount: Int
    let isExpanded: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isExpanded ? "chevron.down.circle.fill" : "chevron.right.circle.fill")
                .foregroundStyle(.secondary)
                .imageScale(.medium)

            VStack(alignment: .leading, spacing: 3) {
                Text(macro.name)
                    .font(.body)
                    .foregroundStyle(.primary)
                Text("\(commandCount) command\(commandCount == 1 ? "" : "s") · tap to \(isExpanded ? "collapse" : "expand")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Image(systemName: "link")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
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
