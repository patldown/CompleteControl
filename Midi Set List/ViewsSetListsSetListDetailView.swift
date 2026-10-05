//
//  SetListDetailView.swift
//  Midi Set List
//
//  Created by Patrick Downey on 9/25/26.
//

import SwiftUI
import CoreData

struct SetListDetailView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @Environment(MIDIManager.self) private var midiManager
    @FetchRequest(
        sortDescriptors: [SortDescriptor(\.name)],
        predicate: NSPredicate(format: "canonicalID == nil")
    ) private var allSongs: FetchedResults<Song>
    @ObservedObject var setList: SetList
    @ObservedObject private var ai = AISettings.shared

    @State private var showingAssistant = false
    @State private var showingAddSongs = false
    @State private var selectedSong: Song?
    @State private var isSendingSetList = false
    @State private var sendError: String?
    @State private var showingSendError = false
    @State private var showingPlaylist = false
    
    var body: some View {
        let songs = setList.songs
        let commandCount = songs.reduce(0) { $0 + $1.commands.count }

        return List {
            Section("Information") {
                LabeledContent("Name") {
                    TextField("Set List Name", text: Binding(
                        get: { setList.name },
                        set: { setList.name = $0 }
                    ))
                    .multilineTextAlignment(.trailing)
                }

                LabeledContent("Notes") {
                    TextField("Notes", text: Binding(
                        get: { setList.notes ?? "" },
                        set: { setList.notes = $0.isEmpty ? nil : $0 }
                    ), axis: .vertical)
                    .multilineTextAlignment(.trailing)
                }

                LabeledContent("Songs", value: "\(songs.count)")
                LabeledContent("Commands", value: "\(commandCount)")
            }

            // MIDI Send Section for entire set list
            if !songs.isEmpty && midiManager.isInitialized {
                Section {
                    Button {
                        Task {
                            await sendEntireSetList()
                        }
                    } label: {
                        HStack {
                            if isSendingSetList {
                                ProgressView()
                            } else {
                                Image(systemName: "play.fill")
                            }
                            Text("Send Entire Set List")
                            Spacer()
                            if !midiManager.connectedDevices.isEmpty {
                                Text("\(commandCount) cmd")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .disabled(isSendingSetList || midiManager.connectedDevices.isEmpty)
                } header: {
                    Text("Performance")
                } footer: {
                    if midiManager.connectedDevices.isEmpty {
                        Text("Connect a MIDI device to send commands")
                    } else {
                        Text("Sends Snapshot 1 of every song, in order. To step through songs live, use the Perform tab.")
                    }
                }
            }
            
            if !setList.songs.isEmpty {
                Section {
                    Button {
                        showingPlaylist = true
                    } label: {
                        Label("Create Apple Music Playlist", systemImage: "music.note.list")
                    }
                } footer: {
                    Text("Makes a playlist called \"\(setList.name)\" with these songs, in order, to listen along or rehearse with.")
                }
            }

            Section {
                ForEach(Array(setList.songs.enumerated()), id: \.element.id) { index, song in
                    Button {
                        selectedSong = song
                    } label: {
                        SetListSongRowView(song: song, index: index)
                    }
                    .swipeActions(edge: .leading, allowsFullSwipe: false) {
                        if midiManager.isInitialized && !midiManager.connectedDevices.isEmpty {
                            Button {
                                Task {
                                    await sendSong(song)
                                }
                            } label: {
                                Label("Send", systemImage: "paperplane.fill")
                            }
                            .tint(.green)
                        }
                    }
                }
                .onDelete(perform: removeSongs)
                .onMove(perform: moveSongs)
                
                Button {
                    showingAddSongs = true
                } label: {
                    Label("Add Songs", systemImage: "plus.circle.fill")
                }
            } header: {
                Text("Songs")
            } footer: {
                if setList.songs.isEmpty {
                    Text("Add songs to this set list to get started.")
                } else {
                    Text("Tap a song to view its MIDI commands. Long press to reorder.")
                }
            }
        }
        .navigationTitle(setList.name)
        .navigationBarTitleDisplayMode(.inline)
        .performShortcutDetail()
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                EditButton()
            }
            ToolbarItem(placement: .secondaryAction) {
                ShareItemButton(object: setList, kindName: "Set List", itemName: setList.name)
            }
            ToolbarItem(placement: .secondaryAction) {
                CloudShareButton(setList: setList)
            }
            ToolbarItem(placement: .secondaryAction) {
                ChordProExportButton(songs: setList.songs, title: "Export Songs as ChordPro…")
            }
            // Hidden when no AI is available
            if ai.isAvailable(.setListAssistant) {
                ToolbarItem(placement: .primaryAction) {
                    Button { showingAssistant = true } label: {
                        Label("Edit with AI", systemImage: "sparkles")
                            .foregroundStyle(ai.offlineMode ? Color.offlineMode : .accentColor)
                            .offlineModeDot(ai.offlineMode)
                    }
                }
            }
        }
        .sheet(isPresented: $showingAssistant) {
            SetListAssistantView(setList: setList)
        }
        .sheet(isPresented: $showingPlaylist) {
            SetListPlaylistView(setList: setList)
        }
        .sheet(isPresented: $showingAddSongs) {
            AddSongsToSetListView(setList: setList, availableSongs: availableSongs)
        }
        .sheet(item: $selectedSong) { song in
            NavigationStack {
                SongDetailView(song: song, isInSheet: true)
            }
        }
        .onChange(of: setList.name)  { _, _ in setList.dateModified = Date(); try? viewContext.save() }
        .onChange(of: setList.notes) { _, _ in setList.dateModified = Date(); try? viewContext.save() }
        .alert("MIDI Error", isPresented: $showingSendError) {
            Button("OK", role: .cancel) {}
        } message: {
            if let error = sendError {
                Text(error)
            }
        }
    }
    
    private var availableSongs: [Song] {
        let alreadyCopied = Set(setList.songs.compactMap { $0.canonicalID })
        return allSongs.filter { !alreadyCopied.contains($0.id) }
    }
    
    private func removeSongs(at offsets: IndexSet) {
        for index in offsets {
            let song = setList.songs[index]
            setList.removeSong(song)
        }
        try? viewContext.save()
    }

    private func moveSongs(from source: IndexSet, to destination: Int) {
        setList.moveSong(from: source, to: destination)
        try? viewContext.save()
    }
    
    private func sendSong(_ song: Song) async {
        do {
            try await midiManager.sendSong(song)
        } catch {
            sendError = error.localizedDescription
            showingSendError = true
        }
    }
    
    private func sendEntireSetList() async {
        isSendingSetList = true
        for song in setList.songs {
            do {
                try await midiManager.sendSong(song)
                // Small delay between songs
                try await Task.sleep(nanoseconds: 100_000_000) // 100ms
            } catch {
                sendError = error.localizedDescription
                showingSendError = true
                break
            }
        }
        isSendingSetList = false
    }
}

struct SetListSongRowView: View {
    let song: Song
    let index: Int
    
    var body: some View {
        HStack(spacing: 12) {
            // Position number
            Text("\(index + 1).")
                .font(.headline)
                .foregroundStyle(.secondary)
                .frame(width: 35, alignment: .trailing)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(song.name)
                    .font(.headline)
                    .foregroundStyle(.primary)
                
                if let artist = song.artist, !artist.isEmpty {
                    Text(artist)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                
                HStack {
                    Label("\(song.commands.count)", systemImage: "command")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    
                    if !song.commands.isEmpty {
                        Text("•")
                            .foregroundStyle(.tertiary)
                        
                        Text(song.sortedCommands.first?.displayDescription ?? "")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
            }
            
            Spacer()
            
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }
}

struct AddSongsToSetListView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) private var viewContext
    @ObservedObject var setList: SetList
    let availableSongs: [Song]
    
    @State private var selectedSongs: Set<Song.ID> = []
    @State private var searchText = ""
    @State private var showingCreateSong = false
    
    var filteredSongs: [Song] {
        if searchText.isEmpty {
            return availableSongs
        }
        return availableSongs.filter { song in
            song.name.localizedCaseInsensitiveContains(searchText) ||
            (song.artist?.localizedCaseInsensitiveContains(searchText) ?? false)
        }
    }
    
    var body: some View {
        NavigationStack {
            Group {
                if availableSongs.isEmpty {
                    // All songs are already in the set list
                    ContentUnavailableView {
                        Label("No Songs Available", systemImage: "music.note.list")
                    } description: {
                        Text("All your songs are already in this set list. Create a new song to add more.")
                    } actions: {
                        Button {
                            showingCreateSong = true
                        } label: {
                            Label("Create New Song", systemImage: "plus.circle.fill")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else {
                    List {
                        // Quick create section at top when searching with no results
                        if !searchText.isEmpty && filteredSongs.isEmpty {
                            Section {
                                Button {
                                    showingCreateSong = true
                                } label: {
                                    Label("Create \"\(searchText)\"", systemImage: "plus.circle")
                                }
                            } header: {
                                Text("No Results")
                            }
                        }
                        
                        // Available songs
                        ForEach(filteredSongs) { song in
                            Button {
                                toggleSelection(for: song)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(song.name)
                                            .font(.headline)
                                            .foregroundStyle(.primary)
                                        
                                        if let artist = song.artist, !artist.isEmpty {
                                            Text(artist)
                                                .font(.subheadline)
                                                .foregroundStyle(.secondary)
                                        }
                                        
                                        // Show command count
                                        if song.commands.count > 0 {
                                            Text("\(song.commands.count) commands")
                                                .font(.caption)
                                                .foregroundStyle(.tertiary)
                                        }
                                    }
                                    
                                    Spacer()
                                    
                                    if selectedSongs.contains(song.id) {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.blue)
                                            .imageScale(.large)
                                    } else {
                                        Image(systemName: "circle")
                                            .foregroundStyle(.secondary)
                                            .imageScale(.large)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Add Songs")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "Search songs")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                
                if !availableSongs.isEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            showingCreateSong = true
                        } label: {
                            Label("New Song", systemImage: "plus")
                        }
                    }
                    
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Add (\(selectedSongs.count))") {
                            addSelectedSongs()
                        }
                        .disabled(selectedSongs.isEmpty)
                    }
                }
            }
            .sheet(isPresented: $showingCreateSong) {
                QuickCreateSongView(
                    setList: setList,
                    suggestedName: searchText.isEmpty ? nil : searchText
                )
            }
        }
    }
    
    private func toggleSelection(for song: Song) {
        if selectedSongs.contains(song.id) {
            selectedSongs.remove(song.id)
        } else {
            selectedSongs.insert(song.id)
        }
    }
    
    private func addSelectedSongs() {
        let songsToAdd = availableSongs.filter { selectedSongs.contains($0.id) }
        for song in songsToAdd { setList.addSong(song) }
        try? viewContext.save()
        dismiss()
    }
}

// Quick create song view optimized for this context
struct QuickCreateSongView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) private var viewContext

    @ObservedObject var setList: SetList
    let suggestedName: String?
    
    @State private var name: String
    @State private var artist = ""
    @State private var addToSetListImmediately = true
    
    init(setList: SetList, suggestedName: String? = nil) {
        self.setList = setList
        self.suggestedName = suggestedName
        _name = State(initialValue: suggestedName ?? "")
    }
    
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Song Name", text: $name)
                    TextField("Artist (optional)", text: $artist)
                } header: {
                    Text("Song Details")
                }
                
                Section {
                    Toggle("Add to \"\(setList.name)\" immediately", isOn: $addToSetListImmediately)
                } header: {
                    Text("Set List")
                } footer: {
                    Text("You can add MIDI commands to this song later from the Songs tab")
                }
            }
            .navigationTitle("New Song")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        createSong()
                    }
                    .disabled(name.isEmpty)
                }
            }
        }
    }
    
    private func createSong() {
        let song = Song.create(name: name, artist: artist.isEmpty ? nil : artist, in: viewContext)
        if addToSetListImmediately { setList.addSong(song) }
        try? viewContext.save()
        dismiss()
    }
}

#Preview {
    let ctx = PersistenceController.preview.viewContext
    let s1 = Song.create(name: "Sweet Home Alabama", artist: "Lynyrd Skynyrd", in: ctx)
    let s2 = Song.create(name: "Wonderwall", artist: "Oasis", in: ctx)
    let sl = SetList.create(name: "Friday Night Gig", in: ctx)
    let cmd = MIDICommand(commandType: .programChange, channel: 1, value1: 5, context: ctx)
    s1.addCommand(cmd)
    sl.addSong(s1); sl.addSong(s2)
    try? ctx.save()
    return NavigationStack { SetListDetailView(setList: sl) }
        .environment(\.managedObjectContext, ctx)
        .environment(MIDIManager())
        .environment(PerformanceSession())
}
