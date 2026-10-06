//
//  AppleMusicReference.swift
//  Midi Set List
//
//  Plays a song's reference track from Apple Music (MusicKit) and searches the
//  catalog to link one. MusicKit stays inside this file: views work with
//  ReferenceTrack, so the app's own Song model never collides with MusicKit.Song.
//
//  Needs the MusicKit App Service enabled for the app's bundle ID in the Apple
//  Developer portal (Identifiers → App Services → MusicKit). Full playback needs an
//  Apple Music subscription; without one, tracks open in the Music app instead.
//

import Combine
import Foundation
import MusicKit
import Observation

/// A catalog track, as shown in search results and stored on a Song.
struct ReferenceTrack: Identifiable, Hashable {
    let id: String
    let title: String
    let artist: String
    var album: String?
    var duration: TimeInterval?
    var artworkURL: URL?
    var url: URL?

    init(id: String, title: String, artist: String, url: URL? = nil, duration: TimeInterval? = nil) {
        self.id = id
        self.title = title
        self.artist = artist
        self.url = url
        self.duration = duration
    }

    fileprivate init(_ song: MusicKit.Song) {
        id = song.id.rawValue
        title = song.title
        artist = song.artistName
        album = song.albumTitle
        duration = song.duration
        artworkURL = song.artwork?.url(width: 120, height: 120)
        url = song.url
    }

    var durationText: String? {
        guard let duration else { return nil }
        let seconds = Int(duration.rounded())
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

enum AppleMusicError: LocalizedError {
    case accessDenied, noTracks, notSetUp

    var errorDescription: String? {
        switch self {
        case .notSetUp: "Apple Music isn't set up for this app yet. Turn on MusicKit for the app's ID in the Apple Developer portal, then reopen the app."

        case .accessDenied: "Allow Apple Music access in Settings › Privacy & Security › Media & Apple Music."
        case .noTracks: "None of the tracks could be found in Apple Music."
        }
    }
}

@MainActor
@Observable
final class AppleMusicReference {

    static let shared = AppleMusicReference()

    private(set) var authorization = MusicAuthorization.currentStatus
    /// False until checked, and for people without an Apple Music subscription
    private(set) var canPlayCatalog = false
    /// Catalog ID of the track in the player, if any
    private(set) var loadedTrackID: String?
    private(set) var isPlaying = false
    /// Catalog ID of a track being fetched to play
    private(set) var loadingTrackID: String?
    var lastError: String?
    /// MusicKit isn't enabled for the app's ID, so Apple can't issue it a developer token.
    /// Every catalog request fails until it is, so the UI says so instead of "no match".
    private(set) var isNotSetUp = false
    /// Active loop region; nil when no loop is set.
    private(set) var loopRegion: ClosedRange<TimeInterval>? = nil

    @ObservationIgnored private let player = ApplicationMusicPlayer.shared
    @ObservationIgnored private var stateObserver: AnyCancellable?
    @ObservationIgnored private var loopEnforcer: Timer?

    private init() {
        // The player's state is an ObservableObject; mirror what the UI needs
        stateObserver = player.state.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.syncPlaybackState() }
    }

    var isAuthorized: Bool { authorization == .authorized }
    var isDenied: Bool { authorization == .denied || authorization == .restricted }

    func isPlaying(_ trackID: String) -> Bool { isPlaying && loadedTrackID == trackID }
    /// Current playback position; 0 when nothing is loaded.
    var currentPlaybackTime: TimeInterval { player.playbackTime }

    // MARK: - Access

    /// Asks for Apple Music access if it hasn't been decided yet. True when granted.
    @discardableResult
    func requestAccess() async -> Bool {
        if authorization == .notDetermined {
            authorization = await MusicAuthorization.request()
        }
        guard isAuthorized else { return false }
        await refreshSubscription()
        return true
    }

    func refreshSubscription() async {
        authorization = MusicAuthorization.currentStatus  // may have changed in Settings
        guard isAuthorized else { return }
        do {
            canPlayCatalog = try await MusicSubscription.current.canPlayCatalogContent
        } catch {
            _ = translated(error)
            canPlayCatalog = false
        }
    }

    /// Turns MusicKit's missing-developer-token failure into AppleMusicError.notSetUp
    private func translated(_ error: Error) -> Error {
        if let tokenError = error as? MusicTokenRequestError, case .developerTokenRequestFailed = tokenError {
            isNotSetUp = true
            return AppleMusicError.notSetUp
        }
        return error
    }

    // MARK: - Search

    func search(_ term: String) async throws -> [ReferenceTrack] {
        let term = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty, await requestAccess() else { return [] }
        var request = MusicCatalogSearchRequest(term: term, types: [MusicKit.Song.self])
        request.limit = 25
        do {
            return try await request.response().songs.map(ReferenceTrack.init)
        } catch {
            throw translated(error)
        }
    }

    /// The catalog's top hit for a song, used to match set list songs automatically
    func bestMatch(title: String, artist: String?) async throws -> ReferenceTrack? {
        try await search([title, artist ?? ""].joined(separator: " ")).first
    }

    // MARK: - Playlists

    /// Creates a playlist in the person's Apple Music library, tracks in the given order.
    /// Returns the playlist's deep-link URL and library ID for later updates.
    func createPlaylist(name: String, description: String?, trackIDs: [String]) async throws -> (url: URL?, playlistID: String?) {
        guard await requestAccess() else { throw AppleMusicError.accessDenied }
        let request = MusicCatalogResourceRequest<MusicKit.Song>(matching: \.id, memberOf: trackIDs.map { MusicItemID($0) })
        let found: MusicItemCollection<MusicKit.Song>
        do {
            found = try await request.response().items
        } catch {
            throw translated(error)
        }
        let byID = Dictionary(found.map { ($0.id.rawValue, $0) }, uniquingKeysWith: { first, _ in first })
        let ordered = trackIDs.compactMap { byID[$0] }
        guard !ordered.isEmpty else { throw AppleMusicError.noTracks }
        do {
            let playlist = try await MusicLibrary.shared.createPlaylist(name: name, description: description, items: ordered)
            return (playlist.url, playlist.id.rawValue)
        } catch {
            throw translated(error)
        }
    }

    /// Appends tracks to an existing library playlist. Silently skips tracks already in the playlist.
    func addTracksToPlaylist(playlistID: String, trackIDs: [String]) async throws {
        guard !trackIDs.isEmpty else { return }
        guard await requestAccess(), !isNotSetUp else { return }

        var playlistRequest = MusicLibraryRequest<Playlist>()
        playlistRequest.filter(matching: \.id, equalTo: MusicItemID(playlistID))
        guard let playlist = try await playlistRequest.response().items.first else { return }

        let songRequest = MusicCatalogResourceRequest<MusicKit.Song>(
            matching: \.id, memberOf: trackIDs.map { MusicItemID($0) }
        )
        let songs: MusicItemCollection<MusicKit.Song>
        do {
            songs = try await songRequest.response().items
        } catch {
            throw translated(error)
        }
        let byID = Dictionary(songs.map { ($0.id.rawValue, $0) }, uniquingKeysWith: { first, _ in first })
        for trackID in trackIDs {
            guard let song = byID[trackID] else { continue }
            do {
                try await MusicLibrary.shared.add(song, to: playlist)
            } catch MusicLibrary.Error.itemAlreadyAdded {
                continue
            }
        }
    }

    // MARK: - Playback

    /// Plays the track, or pauses/resumes it if it's already in the player.
    func togglePlayback(of trackID: String) async {
        lastError = nil
        if loadedTrackID == trackID {
            if player.state.playbackStatus == .playing {
                player.pause()
            } else {
                await play()
            }
            return
        }

        guard await requestAccess() else {
            lastError = "Allow Apple Music access in Settings to play reference tracks."
            return
        }
        guard !isNotSetUp else {
            lastError = AppleMusicError.notSetUp.localizedDescription
            return
        }
        guard canPlayCatalog else {
            lastError = "Playing in the app needs an Apple Music subscription. Use Open in Apple Music instead."
            return
        }

        clearLoopRegion()
        loadingTrackID = trackID
        defer { loadingTrackID = nil }
        do {
            let request = MusicCatalogResourceRequest<MusicKit.Song>(matching: \.id, equalTo: MusicItemID(trackID))
            guard let song = try await request.response().items.first else {
                lastError = "That track isn't available in Apple Music any more."
                return
            }
            player.queue = [song]
            loadedTrackID = trackID
            await play()
        } catch {
            lastError = translated(error).localizedDescription
        }
    }

    /// Back to the start of the loaded track, keeping it playing or paused.
    func restart() {
        player.playbackTime = 0
    }

    /// Jumps within the loaded track; negative seconds rewind, never past the start.
    /// Skipping past the end just ends the track.
    func skip(by seconds: TimeInterval) {
        guard loadedTrackID != nil else { return }
        player.playbackTime = max(0, player.playbackTime + seconds)
    }

    /// Seeks to an absolute time in the loaded track.
    func seek(to time: TimeInterval) {
        guard loadedTrackID != nil else { return }
        player.playbackTime = max(0, time)
    }

    // MARK: - Loop

    func setLoopRegion(start: TimeInterval, end: TimeInterval) {
        guard start < end else { return }
        loopRegion = start...end
        restartLoopEnforcer()
    }

    func clearLoopRegion() {
        loopRegion = nil
        loopEnforcer?.invalidate()
        loopEnforcer = nil
    }

    private func restartLoopEnforcer() {
        loopEnforcer?.invalidate()
        loopEnforcer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [weak self] in self?.enforceLoopIfNeeded() }
        }
    }

    private func enforceLoopIfNeeded() {
        guard let region = loopRegion, isPlaying else { return }
        if player.playbackTime >= region.upperBound {
            player.playbackTime = region.lowerBound
        }
    }

    func stop() {
        guard loadedTrackID != nil else { return }
        player.stop()
        loadedTrackID = nil
        clearLoopRegion()
        syncPlaybackState()
    }

    private func play() async {
        do {
            try await player.play()
        } catch {
            lastError = error.localizedDescription
        }
        syncPlaybackState()
    }

    private func syncPlaybackState() {
        isPlaying = player.state.playbackStatus == .playing
    }
}
