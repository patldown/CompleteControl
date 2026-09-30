//
//  ReferenceTrackSection.swift
//  Midi Set List
//
//  The song editor's "Reference Track": link an Apple Music recording to a song
//  and play it from there, for learning parts or checking the feel before a set.
//

import SwiftUI
import CoreData

struct ReferenceTrackSection: View {
    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.openURL) private var openURL
    @ObservedObject var song: Song

    private let music = AppleMusicReference.shared
    @State private var showingSearch = false

    var body: some View {
        Section {
            if let trackID = song.referenceTrackID {
                HStack(spacing: 12) {
                    Image(systemName: "music.note")
                        .font(.title3)
                        .foregroundStyle(.pink)
                        .frame(width: 32)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(song.referenceTrackTitle ?? "Reference Track")
                            .lineLimit(1)
                        if let artist = song.referenceTrackArtist {
                            Text(artist)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }

                    Spacer()

                    let isLoaded = music.loadedTrackID == trackID
                    Group {
                        Button {
                            music.restart()
                        } label: {
                            Image(systemName: "backward.end.fill")
                        }
                        .accessibilityLabel("Restart")

                        Button {
                            music.skip(by: -15)
                        } label: {
                            Image(systemName: "gobackward.15")
                                .font(.title3)
                        }
                        .accessibilityLabel("Back 15 Seconds")

                        Button {
                            music.skip(by: 15)
                        } label: {
                            Image(systemName: "goforward.15")
                                .font(.title3)
                        }
                        .accessibilityLabel("Forward 15 Seconds")
                    }
                    .buttonStyle(.borderless)
                    .disabled(!isLoaded)

                    PlayPauseButton(trackID: trackID, music: music)
                }

                if let url = song.referenceTrackURL.flatMap(URL.init(string:)) {
                    Button {
                        openURL(url)
                    } label: {
                        Label("Open in Apple Music", systemImage: "arrow.up.forward.app")
                    }
                }

                Button {
                    showingSearch = true
                } label: {
                    Label("Change Track", systemImage: "arrow.triangle.2.circlepath")
                }

                Button(role: .destructive) {
                    if music.loadedTrackID == trackID { music.stop() }
                    song.unlinkReferenceTrack()
                    try? viewContext.save()
                } label: {
                    Label("Remove Reference Track", systemImage: "minus.circle")
                }
            } else {
                Button {
                    showingSearch = true
                } label: {
                    Label("Link Apple Music Track", systemImage: "music.note.list")
                }
            }
        } header: {
            Text("Reference Track")
        } footer: {
            if let error = music.lastError {
                Text(error).foregroundStyle(.orange)
            } else if music.isNotSetUp {
                Text(AppleMusicError.notSetUp.localizedDescription).foregroundStyle(.orange)
            } else if music.isDenied {
                Text("Apple Music access is off. Turn it on in Settings › Privacy & Security › Media & Apple Music.")
            } else if !song.hasReferenceTrack {
                Text("Link a recording to play while you learn or rehearse the song.")
            }
        }
        .sheet(isPresented: $showingSearch) {
            ReferenceTrackSearchView(initialQuery: [song.name, song.artist ?? ""]
                .filter { !$0.isEmpty }.joined(separator: " ")) { track in
                song.linkReferenceTrack(track)
                try? viewContext.save()
            }
        }
        .task { await music.refreshSubscription() }
    }
}

private struct PlayPauseButton: View {
    let trackID: String
    let music: AppleMusicReference

    var body: some View {
        Button {
            Task { await music.togglePlayback(of: trackID) }
        } label: {
            if music.loadingTrackID == trackID {
                ProgressView()
            } else {
                Image(systemName: music.isPlaying(trackID) ? "pause.circle.fill" : "play.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.pink)
            }
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(music.isPlaying(trackID) ? "Pause" : "Play")
    }
}

/// Searches the Apple Music catalog; tap a result to link it, or preview it first.
struct ReferenceTrackSearchView: View {
    @Environment(\.dismiss) private var dismiss

    let onPick: (ReferenceTrack) -> Void

    private let music = AppleMusicReference.shared
    @State private var query: String
    @State private var results: [ReferenceTrack] = []
    @State private var isSearching = false
    @State private var searchError: String?

    init(initialQuery: String, onPick: @escaping (ReferenceTrack) -> Void) {
        _query = State(initialValue: initialQuery)
        self.onPick = onPick
    }

    var body: some View {
        NavigationStack {
            List {
                if music.isDenied {
                    ContentUnavailableView(
                        "Apple Music Access Off",
                        systemImage: "music.note",
                        description: Text("Turn on access in Settings › Privacy & Security › Media & Apple Music.")
                    )
                } else if let searchError {
                    ContentUnavailableView(music.isNotSetUp ? "Apple Music Not Set Up" : "Search Failed",
                                           systemImage: "exclamationmark.triangle",
                                           description: Text(searchError))
                } else if results.isEmpty && !isSearching && !query.isEmpty {
                    ContentUnavailableView.search(text: query)
                }

                ForEach(results) { track in
                    HStack(spacing: 12) {
                        Button {
                            onPick(track)
                            dismiss()
                        } label: {
                            ResultRow(track: track)
                        }
                        .buttonStyle(.plain)

                        PlayPauseButton(trackID: track.id, music: music)
                    }
                }
            }
            .overlay {
                if isSearching && results.isEmpty { ProgressView() }
            }
            .searchable(text: $query, prompt: "Song or artist")
            .navigationTitle("Apple Music")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task(id: query) { await runSearch() }
            .onDisappear { music.stop() }  // end any preview
        }
    }

    private func runSearch() async {
        // Wait for typing to pause; a newer keystroke cancels this task
        try? await Task.sleep(for: .milliseconds(350))
        guard !Task.isCancelled else { return }
        isSearching = true
        defer { isSearching = false }
        do {
            let found = try await music.search(query)
            guard !Task.isCancelled else { return }
            results = found
            searchError = nil
        } catch is CancellationError {
        } catch {
            searchError = error.localizedDescription
        }
    }
}

private struct ResultRow: View {
    let track: ReferenceTrack

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: track.artworkURL) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Color.secondary.opacity(0.2)
                    .overlay(Image(systemName: "music.note").foregroundStyle(.secondary))
            }
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title).lineLimit(1)
                Text([track.artist, track.album].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            if let duration = track.durationText {
                Text(duration)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .contentShape(Rectangle())
    }
}
