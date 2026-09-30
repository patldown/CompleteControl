//
//  UserPreferences.swift
//  Midi Set List
//
//  Per-person performance settings. Each song remembers, for each person, whether they
//  last read its lyrics or sheet music and at what scroll speed. A Settings override
//  can show one view everywhere without erasing that memory. Stored in iCloud
//  key-value storage, which belongs to the signed-in Apple ID, so each person keeps
//  their own even when song data is shared. UserDefaults mirrors every value, so it
//  all works on this device when iCloud is unavailable or not set up.
//

import Combine
import Foundation

/// What the Perform screen shows below the snapshots
enum PerformChartMode: String, CaseIterable, Identifiable {
    case lyrics
    case sheetMusic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .lyrics: "Lyrics"
        case .sheetMusic: "Sheet Music"
        }
    }

    var systemImage: String {
        switch self {
        case .lyrics: "text.alignleft"
        case .sheetMusic: "music.note.list"
        }
    }
}

/// What one person last used on one song
struct SongPerformanceMemory: Codable, Equatable {
    var chartMode: PerformChartMode?
    var lyricsScrollSpeed: Double?
    var sheetMusicScrollSpeed: Double?
}

extension PerformChartMode: Codable {}

final class UserPreferences: ObservableObject {
    static let shared = UserPreferences()

    // Keys match the old @AppStorage keys, so existing settings carry over
    private enum Key {
        static let lastChartMode = "performChartMode"
        static let chartModeOverride = "performChartModeOverride"
        static let songMemory = "performSongMemory"
        static let lyricsScrollSpeed = "performLyricsScrollSpeed"
        static let sheetMusicScrollSpeed = "performSheetMusicScrollSpeed"
        static let lyricsLeadInLines = "lyricsLeadInLines"
    }

    static let scrollSpeedRange: ClosedRange<Double> = 5...100
    static let leadInLinesRange = 0...10

    /// Settings override: show this view on every song that has it. Nil = each song
    /// shows what this person last used on it. Turning it off brings those back untouched.
    @Published var chartModeOverride: PerformChartMode? {
        didSet {
            store(chartModeOverride?.rawValue ?? "", Key.chartModeOverride)
            visitChartModes = [:]
        }
    }
    /// Each song's last view and speeds, for this person, keyed by song ID
    @Published private(set) var songMemory: [UUID: SongPerformanceMemory] = [:] {
        didSet { storeSongMemory() }
    }
    /// The view last picked on any song — the starting point for songs not played yet
    @Published private(set) var lastChartMode: PerformChartMode {
        didSet { store(lastChartMode.rawValue, Key.lastChartMode) }
    }
    /// Starting speeds for songs this person hasn't set a speed on yet
    @Published var lyricsScrollSpeed: Double {
        didSet { store(lyricsScrollSpeed, Key.lyricsScrollSpeed) }
    }
    @Published var sheetMusicScrollSpeed: Double {
        didSet { store(sheetMusicScrollSpeed, Key.sheetMusicScrollSpeed) }
    }
    /// Blank lines above a song's lyrics
    @Published var lyricsLeadInLines: Int {
        didSet { store(lyricsLeadInLines, Key.lyricsLeadInLines) }
    }

    /// Views picked on Perform while the override is on: kept for this visit only, so the
    /// per-song memory stays exactly as it was
    @Published private var visitChartModes: [UUID: PerformChartMode] = [:]

    private let cloud = NSUbiquitousKeyValueStore.default
    private let local = UserDefaults.standard
    private var isApplyingCloudChange = false
    private var cancellable: AnyCancellable?

    private init() {
        chartModeOverride = nil
        lastChartMode = .lyrics
        lyricsScrollSpeed = 20
        sheetMusicScrollSpeed = 20
        lyricsLeadInLines = 5
        load()

        cancellable = NotificationCenter.default
            .publisher(for: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: cloud)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.load() }
        cloud.synchronize()
    }

    // MARK: View per song

    /// The view to show for a song: the override if on, else this person's last choice on
    /// this song, else their most recent choice anywhere. Songs with only one kind show that.
    func chartMode(for song: Song) -> PerformChartMode? {
        guard song.hasLyricsText && song.hasSheetMusic else { return song.chartMode(preferred: .lyrics) }
        if let override = chartModeOverride {
            return visitChartModes[song.id] ?? override
        }
        return songMemory[song.id]?.chartMode ?? lastChartMode
    }

    func setChartMode(_ mode: PerformChartMode, for song: Song) {
        if chartModeOverride != nil {
            visitChartModes[song.id] = mode
        } else {
            songMemory[song.id, default: SongPerformanceMemory()].chartMode = mode
            lastChartMode = mode
        }
    }

    /// True when the override is deciding this song's view
    func isOverriding(_ song: Song) -> Bool {
        chartModeOverride != nil && song.hasLyricsText && song.hasSheetMusic
    }

    // MARK: Speed per song

    func scrollSpeed(for mode: PerformChartMode, song: Song) -> Double {
        let memory = songMemory[song.id]
        switch mode {
        case .lyrics: return memory?.lyricsScrollSpeed ?? lyricsScrollSpeed
        case .sheetMusic: return memory?.sheetMusicScrollSpeed ?? sheetMusicScrollSpeed
        }
    }

    func setScrollSpeed(_ speed: Double, for mode: PerformChartMode, song: Song) {
        let clamped = Self.clampSpeed(speed)
        switch mode {
        case .lyrics: songMemory[song.id, default: SongPerformanceMemory()].lyricsScrollSpeed = clamped
        case .sheetMusic: songMemory[song.id, default: SongPerformanceMemory()].sheetMusicScrollSpeed = clamped
        }
    }

    private static func clampSpeed(_ speed: Double) -> Double {
        min(max(speed, scrollSpeedRange.lowerBound), scrollSpeedRange.upperBound)
    }

    // MARK: Storage

    /// iCloud first (this person's latest choice from any device), then this device
    private func value(_ key: String) -> Any? {
        cloud.object(forKey: key) ?? local.object(forKey: key)
    }

    private func load() {
        isApplyingCloudChange = true
        defer { isApplyingCloudChange = false }
        if let raw = value(Key.chartModeOverride) as? String {
            let override = PerformChartMode(rawValue: raw)
            if override != chartModeOverride { chartModeOverride = override }
        }
        if let raw = value(Key.lastChartMode) as? String, let mode = PerformChartMode(rawValue: raw) {
            lastChartMode = mode
        }
        if let data = value(Key.songMemory) as? Data,
           let decoded = try? JSONDecoder().decode([UUID: SongPerformanceMemory].self, from: data) {
            songMemory = decoded
        }
        if let speed = (value(Key.lyricsScrollSpeed) as? NSNumber)?.doubleValue {
            lyricsScrollSpeed = Self.clampSpeed(speed)
        }
        if let speed = (value(Key.sheetMusicScrollSpeed) as? NSNumber)?.doubleValue {
            sheetMusicScrollSpeed = Self.clampSpeed(speed)
        }
        if let lines = (value(Key.lyricsLeadInLines) as? NSNumber)?.intValue {
            lyricsLeadInLines = min(max(lines, Self.leadInLinesRange.lowerBound), Self.leadInLinesRange.upperBound)
        }
    }

    private func storeSongMemory() {
        guard let data = try? JSONEncoder().encode(songMemory) else { return }
        store(data, Key.songMemory)
    }

    private func store(_ value: Any, _ key: String) {
        local.set(value, forKey: key)
        // Don't echo values that just arrived from iCloud back up to it
        guard !isApplyingCloudChange else { return }
        cloud.set(value, forKey: key)
    }
}
