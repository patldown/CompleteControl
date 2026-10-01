//
//  PerformanceSession.swift
//  Midi Set List
//
//  The "what's playing now" state shared by the Perform tab and the song editor:
//  which set list is playing, which song is loaded, and which snapshot is active.
//  Incoming MIDI (see MIDIRemoteSettings) is routed here.
//

import CoreData
import Foundation
import Observation

@Observable
final class PerformanceSession {

    // Set by the app after the managers are created
    var midiManager: MIDIManager?
    var activityLog: ActivityLog?

    // ── Set list playback (Perform tab) ───────────────────────────────
    private(set) var setList: SetList?
    private(set) var songIndex = 0

    var isPlaying: Bool { setList != nil }

    var songs: [Song] {
        (setList?.songs ?? []).filter { !$0.isDeleted && $0.managedObjectContext != nil }
    }

    var currentSong: Song? {
        let list = songs
        guard isPlaying, list.indices.contains(songIndex) else { return nil }
        return list[songIndex]
    }

    var hasPreviousSong: Bool { isPlaying && songIndex > 0 }
    var hasNextSong: Bool { isPlaying && songIndex < songs.count - 1 }

    // ── Song open in the song editor ──────────────────────────────────
    /// MIDI snapshot recalls go to this song when no set list is playing.
    private(set) var focusedSong: Song?

    /// The song MIDI snapshot triggers act on.
    var activeSong: Song? { currentSong ?? focusedSong }

    /// Last snapshot recalled on `activeSong` (0-based); -1 when a song loaded without
    /// sending one (see Song.sendsSnapshotOnLoad), so "next snapshot" goes to Snapshot 1.
    private(set) var activeSnapshot = 0

    // ── Feedback for the UI ───────────────────────────────────────────
    private(set) var lastError: String?
    private(set) var isSending = false
    /// Most recent incoming message and what it did, for the settings "monitor".
    private(set) var lastRemoteEvent: RemoteEvent?

    struct RemoteEvent: Equatable {
        let date: Date
        let message: MIDIRemoteMessage
        let outcome: String
    }

    /// While set, the next accepted message is assigned to this target instead of acting.
    var learnTarget: MIDIRemoteLearnTarget?

    private var sendTask: Task<Void, Never>?
    private let settings = MIDIRemoteSettings.shared

    /// Called whenever the set list, song or live snapshot changes — Live Follow's
    /// leader broadcasts it to the band
    var onStateChange: (() -> Void)?

    // MARK: - Set list playback

    /// Starts a set list: loads the first song (or `index`) and sends its Snapshot 1
    /// unless the song has that turned off.
    func play(_ setList: SetList, startAt index: Int = 0) {
        self.setList = setList
        activityLog?.log("Perform: started \"\(setList.name)\"", direction: .system)
        goToSong(index)
    }

    func stop() {
        sendTask?.cancel()
        if let setList { activityLog?.log("Perform: stopped \"\(setList.name)\"", direction: .system) }
        setList = nil
        songIndex = 0
        activeSnapshot = 0
        lastError = nil
        onStateChange?()
    }

    func goToSong(_ index: Int) {
        let list = songs
        guard isPlaying, list.indices.contains(index) else { return }
        songIndex = index
        let song = list[index]
        followClock(for: song)
        if song.sendsSnapshotOnLoad {
            recall(snapshot: 0, of: song)
        } else {
            sendTask?.cancel()
            isSending = false
            lastError = nil
            activeSnapshot = -1
            onStateChange?()
        }
    }

    /// Live Follow: move to the leader's set list, song and snapshot. With `sendCommands`
    /// off (the default) nothing is sent — the leader's gear is already being driven,
    /// and a follower sending too would double every change on shared equipment.
    func follow(_ setList: SetList, songIndex index: Int, snapshot: Int, sendCommands: Bool) {
        if self.setList?.objectID != setList.objectID {
            self.setList = setList
            activityLog?.log("Perform: following \"\(setList.name)\"", direction: .system)
        }
        let list = songs
        guard list.indices.contains(index) else { return }
        let songChanged = index != songIndex
        songIndex = index
        let song = list[index]

        guard sendCommands else {
            sendTask?.cancel()
            isSending = false
            activeSnapshot = snapshot
            return
        }
        if songChanged { followClock(for: song) }
        if snapshot < 0 {
            activeSnapshot = -1
        } else if songChanged || snapshot != activeSnapshot {
            recall(snapshot: snapshot, of: song)
        }
    }

    func nextSong() { if hasNextSong { goToSong(songIndex + 1) } }
    func previousSong() { if hasPreviousSong { goToSong(songIndex - 1) } }

    // MARK: - Snapshots

    func selectSnapshot(_ index: Int) {
        guard let song = activeSong, index >= 0, index < song.snapshotCount else { return }
        recall(snapshot: index, of: song)
    }

    /// Following a leader (without the override): only the leader changes snapshots
    var snapshotsLocked: Bool { LiveFollowSession.shared.snapshotsLocked }

    func nextSnapshot() {
        guard !snapshotsLocked else { return }
        guard let song = activeSong, activeSnapshot < song.snapshotCount - 1 else { return }
        recall(snapshot: activeSnapshot + 1, of: song)
    }

    func previousSnapshot() {
        guard !snapshotsLocked else { return }
        guard activeSong != nil, activeSnapshot > 0 else { return }
        selectSnapshot(activeSnapshot - 1)
    }

    /// True when `index` is the live snapshot of `song`.
    func isActive(snapshot index: Int, of song: Song) -> Bool {
        activeSong?.objectID == song.objectID && activeSnapshot == index
    }

    // MARK: - Song editor focus

    func focus(_ song: Song) {
        guard focusedSong?.objectID != song.objectID else { return }
        focusedSong = song
        if currentSong == nil { activeSnapshot = 0 }
    }

    func unfocus(_ song: Song) {
        guard focusedSong?.objectID == song.objectID else { return }
        focusedSong = nil
        if currentSong == nil { activeSnapshot = 0 }
    }

    func clearError() { lastError = nil }

    // MARK: - Incoming MIDI

    func handle(_ message: MIDIRemoteMessage) {
        guard settings.accepts(channel: message.channel) else {
            record(message, "Ignored — receive channel is \(settings.receiveChannelLabel)")
            return
        }

        if let target = learnTarget {
            let binding = MIDIRemoteBinding(kind: message.kind, number: message.number)
            settings.setBinding(binding, for: target)
            learnTarget = nil
            record(message, "Learned for \(target.title)")
            return
        }

        guard settings.isEnabled else {
            record(message, "Ignored — MIDI control is off")
            return
        }
        guard let action = settings.action(for: message) else {
            record(message, "No action assigned")
            return
        }

        switch action {
        case .snapshot, .nextSnapshot, .previousSnapshot:
            if snapshotsLocked { return record(message, "\(action.displayName) — the leader controls snapshots") }
        case .nextSong, .previousSong:
            break
        }

        switch action {
        case .snapshot(let index):
            guard let song = activeSong else { return record(message, "\(action.displayName) — no song open") }
            guard index < song.snapshotCount else {
                return record(message, "\(action.displayName) — \"\(song.name)\" has \(song.snapshotCount)")
            }
            selectSnapshot(index)
        case .nextSong, .previousSong:
            guard isPlaying else { return record(message, "\(action.displayName) — no set list playing") }
            if action == .nextSong { nextSong() } else { previousSong() }
        case .nextSnapshot:
            guard activeSong != nil else { return record(message, "\(action.displayName) — no song open") }
            nextSnapshot()
        case .previousSnapshot:
            guard activeSong != nil else { return record(message, "\(action.displayName) — no song open") }
            previousSnapshot()
        }
        record(message, action.displayName)
        activityLog?.log("Remote: \(message.description) → \(action.displayName)", direction: .system, proto: .midi)
    }

    private func record(_ message: MIDIRemoteMessage, _ outcome: String) {
        lastRemoteEvent = RemoteEvent(date: Date(), message: message, outcome: outcome)
    }

    // MARK: - Sending

    /// Marks `index` active and sends its commands, cancelling any send still running
    /// so rapid pedal presses always land on the latest snapshot.
    private func recall(snapshot index: Int, of song: Song) {
        activeSnapshot = index
        lastError = nil
        sendTask?.cancel()
        isSending = false
        onStateChange?()
        guard let midiManager, !song.commands(inSnapshot: index).isEmpty else { return }

        isSending = true
        sendTask = Task { @MainActor [weak self] in
            do {
                try await midiManager.sendSnapshot(index, of: song)
            } catch is CancellationError {
                return
            } catch {
                self?.lastError = error.localizedDescription
            }
            self?.isSending = false
        }
    }

    /// If the MIDI clock is running, move it to the new song's tempo (or stop it).
    private func followClock(for song: Song) {
        guard let midiManager, midiManager.isClockRunning else { return }
        if let bpm = song.clockBPM {
            midiManager.startClock(bpm: bpm, sendTransport: midiManager.clockSendsTransport)
        } else {
            midiManager.stopClock()
        }
    }
}
