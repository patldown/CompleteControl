//
//  SetListPlaylistView.swift
//  Midi Set List
//
//  Turns a set list into an Apple Music playlist. Songs with a reference track use
//  it; the rest are matched automatically from the catalog. Every match can be
//  reviewed, changed or skipped before the playlist is created.
//

import SwiftUI
import CoreData

struct SetListPlaylistView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @ObservedObject var setList: SetList

    private let music = AppleMusicReference.shared

    @State private var rows: [Row] = []
    @State private var playlistName: String
    @State private var saveMatches = true
    @State private var changingSong: Song?
    @State private var isCreating = false
    @State private var createError: String?
    @State private var created = false
    @State private var playlistURL: URL?

    struct Row: Identifiable {
        enum Status { case searching, linked, matched, notFound }

        let song: Song
        var track: ReferenceTrack?
        var status: Status
        var included = true

        var id: NSManagedObjectID { song.objectID }
        var willAdd: Bool { included && track != nil }
    }

    init(setList: SetList) {
        self.setList = setList
        _playlistName = State(initialValue: setList.name)
    }

    private var addCount: Int { rows.filter(\.willAdd).count }
    private var isMatching: Bool { rows.contains { $0.status == .searching } }
    private var newMatchCount: Int { rows.filter { $0.willAdd && $0.status == .matched }.count }

    var body: some View {
        NavigationStack {
            Group {
                if created {
                    ContentUnavailableView {
                        Label("Playlist Created", systemImage: "checkmark.circle.fill")
                    } description: {
                        Text("\"\(playlistName)\" is in your Apple Music library with \(addCount) song\(addCount == 1 ? "" : "s").")
                    } actions: {
                        if let playlistURL {
                            Button("Open Playlist") {
                                openURL(playlistURL)
                            }
                            .buttonStyle(.borderedProminent)
                        } else {
                            Button("Open Music") {
                                if let url = URL(string: "music://") { openURL(url) }
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                } else {
                    form
                }
            }
            .navigationTitle("Apple Music Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(created ? "Done" : "Cancel") { dismiss() }
                }
            }
            .sheet(item: $changingSong) { song in
                ReferenceTrackSearchView(initialQuery: [song.name, song.artist ?? ""]
                    .filter { !$0.isEmpty }.joined(separator: " ")) { track in
                    guard let index = rows.firstIndex(where: { $0.id == song.objectID }) else { return }
                    rows[index].track = track
                    rows[index].status = track.id == song.referenceTrackID ? .linked : .matched
                    rows[index].included = true
                }
            }
            .task { await matchSongs() }
        }
    }

    private var form: some View {
        List {
            Section {
                TextField("Playlist Name", text: $playlistName)
            } header: {
                Text("Playlist Name")
            }

            if music.isNotSetUp {
                Section {
                    Label(AppleMusicError.notSetUp.localizedDescription, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            } else if music.isDenied {
                Section {
                    Text("Apple Music access is off. Turn it on in Settings › Privacy & Security › Media & Apple Music.")
                        .foregroundStyle(.orange)
                }
            }

            Section {
                ForEach($rows) { $row in
                    PlaylistSongRow(row: $row, number: (rows.firstIndex { $0.id == row.id } ?? 0) + 1) {
                        changingSong = row.song
                    }
                }
            } header: {
                HStack {
                    Text("Songs")
                    Spacer()
                    if isMatching {
                        ProgressView().controlSize(.small)
                        Text("Matching…")
                    }
                }
            } footer: {
                Text("Songs with a reference track use it. The others were matched from Apple Music automatically, so check them. Tap a song to pick a different version, or untick it to leave it out.")
            }

            if newMatchCount > 0 {
                Section {
                    Toggle("Save Matches as Reference Tracks", isOn: $saveMatches)
                } footer: {
                    Text("Links the \(newMatchCount) new match\(newMatchCount == 1 ? "" : "es") to the songs, so you can play them from the song editor.")
                }
            }

            Section {
                Button {
                    Task { await createPlaylist() }
                } label: {
                    HStack {
                        Spacer()
                        if isCreating {
                            ProgressView()
                        } else {
                            Label("Create Playlist with \(addCount) Song\(addCount == 1 ? "" : "s")",
                                  systemImage: "music.note.list")
                                .bold()
                        }
                        Spacer()
                    }
                }
                .disabled(isCreating || isMatching || addCount == 0 || music.isNotSetUp
                          || playlistName.trimmingCharacters(in: .whitespaces).isEmpty)
            } footer: {
                if let createError {
                    Text(createError).foregroundStyle(.orange)
                } else {
                    Text("Adds a new playlist to your Apple Music library. Needs an Apple Music subscription.")
                }
            }
        }
    }

    // MARK: - Actions

    private func matchSongs() async {
        guard rows.isEmpty else { return }
        rows = setList.songs.map { (song) -> Row in
            if let track = song.referenceTrack {
                Row(song: song, track: track, status: .linked)
            } else {
                Row(song: song, track: nil, status: .searching)
            }
        }
        guard await music.requestAccess() else {
            for index in rows.indices where rows[index].status == .searching {
                rows[index].status = .notFound
            }
            return
        }
        // One at a time, so a long set list doesn't flood the catalog with requests
        for index in rows.indices where rows[index].status == .searching {
            let song = rows[index].song
            let match: ReferenceTrack?
            do {
                match = try await music.bestMatch(title: song.name, artist: song.artist)
            } catch AppleMusicError.notSetUp {
                // Every other search would fail the same way
                for rest in rows.indices where rows[rest].status == .searching {
                    rows[rest].status = .notFound
                }
                return
            } catch {
                match = nil
            }
            guard !Task.isCancelled else { return }
            rows[index].track = match
            rows[index].status = match == nil ? .notFound : .matched
        }
    }

    private func createPlaylist() async {
        isCreating = true
        createError = nil
        defer { isCreating = false }
        let adding = rows.filter(\.willAdd)
        do {
            let result = try await music.createPlaylist(
                name: playlistName.trimmingCharacters(in: .whitespaces),
                description: setList.notes,
                trackIDs: adding.compactMap { $0.track?.id }
            )
            // Persist the playlist link and ID so SetListDetailView can open it and
            // future song additions can append tracks automatically.
            let urlToStore = result.url ?? URL(string: "music://")
            setList.playlistURL = urlToStore?.absoluteString
            setList.playlistID = result.playlistID
            playlistURL = result.url
            if saveMatches {
                for row in adding where row.status == .matched {
                    guard let track = row.track else { continue }
                    row.song.linkReferenceTrack(track)
                    // Set-list songs are copies; also save to the library master so it
                    // appears in the Songs tab.
                    if let canonicalID = row.song.canonicalID {
                        let req = NSFetchRequest<Song>(entityName: "Song")
                        req.predicate = NSPredicate(format: "id == %@ AND canonicalID == nil", canonicalID as CVarArg)
                        req.fetchLimit = 1
                        if let master = (try? viewContext.fetch(req))?.first {
                            master.linkReferenceTrack(track)
                        }
                    }
                }
                try? viewContext.save()
            }
            created = true
        } catch {
            createError = error.localizedDescription
        }
    }
}

private struct PlaylistSongRow: View {
    @Binding var row: SetListPlaylistView.Row
    private let music = AppleMusicReference.shared
    let number: Int
    let onChange: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button {
                row.included.toggle()
            } label: {
                Image(systemName: row.included && row.track != nil ? "checkmark.circle.fill" : "circle")
                    .imageScale(.large)
                    .foregroundStyle(row.included && row.track != nil ? Color.accentColor : .secondary)
            }
            .buttonStyle(.borderless)
            .disabled(row.track == nil)
            .accessibilityLabel(row.included ? "Included" : "Left out")

            Button(action: onChange) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(number). \(row.song.displayName)")
                            .lineLimit(1)
                        matchLabel
                            .font(.caption)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .opacity(row.willAdd || row.status == .searching ? 1 : 0.6)
    }

    @ViewBuilder
    private var matchLabel: some View {
        switch row.status {
        case .searching:
            Label("Searching…", systemImage: "magnifyingglass")
                .foregroundStyle(.secondary)
        case .linked:
            Label(trackText, systemImage: "music.note")
                .foregroundStyle(.pink)
        case .matched:
            Label(trackText, systemImage: "wand.and.stars")
                .foregroundStyle(.secondary)
        case .notFound:
            if music.isNotSetUp {
                Label("Unavailable until Apple Music is set up", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            } else {
                Label("No match found — tap to search", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
        }
    }

    private var trackText: String {
        guard let track = row.track else { return "" }
        return "\(track.title) · \(track.artist)"
    }
}
