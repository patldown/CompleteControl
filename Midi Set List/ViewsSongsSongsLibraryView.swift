//
//  SongsLibraryView.swift
//  Midi Set List
//

import SwiftUI
import CoreData

// MARK: - Sort option

enum SongSortOption: String, CaseIterable, Identifiable {
    var id: String { rawValue }
    case name   = "Song Name"
    case artist = "Artist"
    case bpm    = "BPM"
}

// MARK: - Library view

struct SongsLibraryView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @FetchRequest(sortDescriptors: [SortDescriptor(\.name)]) private var songs: FetchedResults<Song>

    @State private var showingAddSong = false
    @State private var searchText = ""
    @State private var showingFilters = false
    @State private var selectedGenreFilters: Set<String> = []
    @State private var sortOption: SongSortOption = .name

    private var isFiltered: Bool { !selectedGenreFilters.isEmpty || sortOption != .name }

    var filteredSongs: [Song] {
        var result = Array(songs)

        if !searchText.isEmpty {
            result = result.filter { song in
                song.name.localizedCaseInsensitiveContains(searchText) ||
                (song.artist?.localizedCaseInsensitiveContains(searchText) ?? false)
            }
        }

        if !selectedGenreFilters.isEmpty {
            result = result.filter { song in
                !Set(song.genres).isDisjoint(with: selectedGenreFilters)
            }
        }

        switch sortOption {
        case .name:
            result.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .artist:
            result.sort {
                let a0 = $0.artist ?? ""; let a1 = $1.artist ?? ""
                if a0 != a1 { return a0.localizedCaseInsensitiveCompare(a1) == .orderedAscending }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        case .bpm:
            result.sort {
                let b0 = $0.bpm ?? 0; let b1 = $1.bpm ?? 0
                if b0 != b1 { return b0 < b1 }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        }

        return result
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(filteredSongs) { song in
                    NavigationLink {
                        SongDetailView(song: song)
                    } label: {
                        SongRowView(song: song)
                    }
                }
                .onDelete(perform: deleteSongs)
            }
            .navigationTitle("Songs")
            .offlineStatusBadge()
            .searchable(text: $searchText, prompt: "Search by name or artist")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showingAddSong = true } label: {
                        Label("Add Song", systemImage: "plus")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { showingFilters = true } label: {
                        Label("Filter", systemImage: isFiltered
                              ? "line.3.horizontal.decrease.circle.fill"
                              : "line.3.horizontal.decrease.circle")
                    }
                    .foregroundStyle(isFiltered ? .orange : .accentColor)
                }
                ToolbarItem(placement: .secondaryAction) {
                    EditButton()
                }
            }
            .sheet(isPresented: $showingAddSong) {
                AddSongView()
            }
            .sheet(isPresented: $showingFilters) {
                SongFilterSheet(selectedGenres: $selectedGenreFilters, sortOption: $sortOption)
            }
            .overlay {
                if songs.isEmpty {
                    ContentUnavailableView {
                        Label("No Songs", systemImage: "music.note")
                    } description: {
                        Text("Add your first song to get started")
                    } actions: {
                        Button("Add Song") { showingAddSong = true }
                            .buttonStyle(.borderedProminent)
                    }
                } else if filteredSongs.isEmpty {
                    ContentUnavailableView {
                        Label("No Results", systemImage: "magnifyingglass")
                    } description: {
                        Text("Try adjusting your search or filters.")
                    } actions: {
                        Button("Clear Filters") {
                            searchText = ""
                            selectedGenreFilters = []
                            sortOption = .name
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
    }

    private func deleteSongs(at offsets: IndexSet) {
        for index in offsets { viewContext.delete(filteredSongs[index]) }
        try? viewContext.save()
    }
}

// MARK: - Song row

struct SongRowView: View {
    let song: Song

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(song.name)
                .font(.headline)

            HStack(spacing: 4) {
                if let artist = song.artist, !artist.isEmpty {
                    Text(artist)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if !song.genres.isEmpty {
                    if let artist = song.artist, !artist.isEmpty {
                        Text("·").foregroundStyle(.tertiary).font(.subheadline)
                    }
                    Text(song.genreDisplayText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 4) {
                Label("\(song.commands.count)", systemImage: "list.bullet")
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                if !song.commands.isEmpty, let first = song.sortedCommands.first {
                    Text("·").foregroundStyle(.tertiary).font(.caption)
                    Text(first.displayDescription)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                if let bpm = song.bpm {
                    Text("·").foregroundStyle(.tertiary).font(.caption)
                    Text("\(bpm) BPM")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Filter & sort sheet

struct SongFilterSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var selectedGenres: Set<String>
    @Binding var sortOption: SongSortOption

    var body: some View {
        NavigationStack {
            List {
                Section("Sort By") {
                    ForEach(SongSortOption.allCases) { option in
                        Button {
                            sortOption = option
                        } label: {
                            HStack {
                                Text(option.rawValue).foregroundStyle(.primary)
                                Spacer()
                                if sortOption == option {
                                    Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                                }
                            }
                        }
                    }
                }

                Section {
                    Button {
                        selectedGenres = []
                    } label: {
                        HStack {
                            Text("All Genres").foregroundStyle(.primary)
                            Spacer()
                            if selectedGenres.isEmpty {
                                Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                            }
                        }
                    }

                    ForEach(Song.predefinedGenres.sorted(), id: \.self) { genre in
                        Button {
                            if selectedGenres.contains(genre) {
                                selectedGenres.remove(genre)
                            } else {
                                selectedGenres.insert(genre)
                            }
                        } label: {
                            HStack {
                                Text(genre).foregroundStyle(.primary)
                                Spacer()
                                Image(systemName: selectedGenres.contains(genre)
                                      ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selectedGenres.contains(genre) ? Color.accentColor : Color.secondary)
                            }
                        }
                    }
                } header: {
                    Text("Filter by Genre")
                } footer: {
                    if !selectedGenres.isEmpty {
                        Text("Showing songs tagged with: \(selectedGenres.sorted().joined(separator: ", "))")
                    }
                }
            }
            .navigationTitle("Filter & Sort")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Reset") {
                        selectedGenres = []
                        sortOption = .name
                    }
                    .foregroundStyle(.red)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Genre picker (reused in AddSong + SongDetail)

struct GenrePickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var selectedGenres: Set<String>

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        selectedGenres = []
                    } label: {
                        HStack {
                            Text("Unspecified")
                                .foregroundStyle(.primary)
                            Spacer()
                            if selectedGenres.isEmpty {
                                Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                            }
                        }
                    }
                }

                Section {
                    ForEach(Song.predefinedGenres.sorted(), id: \.self) { genre in
                        Button {
                            if selectedGenres.contains(genre) {
                                selectedGenres.remove(genre)
                            } else {
                                selectedGenres.insert(genre)
                            }
                        } label: {
                            HStack {
                                Text(genre).foregroundStyle(.primary)
                                Spacer()
                                Image(systemName: selectedGenres.contains(genre)
                                      ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selectedGenres.contains(genre) ? Color.accentColor : Color.secondary)
                            }
                        }
                    }
                } header: {
                    Text("Select one or more genres")
                }
            }
            .navigationTitle("Genre")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

#Preview {
    let ctx = PersistenceController.preview.viewContext
    let s1 = Song.create(name: "Sweet Home Alabama", artist: "Lynyrd Skynyrd", in: ctx)
    s1.setGenres(["Rock", "Country"])
    let _ = Song.create(name: "Wonderwall", artist: "Oasis", in: ctx)
    try? ctx.save()
    return SongsLibraryView()
        .environment(\.managedObjectContext, ctx)
}
