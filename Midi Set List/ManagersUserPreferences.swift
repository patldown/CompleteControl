//
//  UserPreferences.swift
//  Midi Set List
//
//  Per-person performance defaults — which chart view they last used, their scroll
//  speeds, lead-in lines. Stored in iCloud key-value storage, which belongs to the
//  signed-in Apple ID, so each person gets their own defaults on every device even
//  when song data is shared. UserDefaults mirrors every value, so it all works on
//  this device when iCloud is unavailable or not set up.
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

final class UserPreferences: ObservableObject {
    static let shared = UserPreferences()

    // Keys match the old @AppStorage keys, so existing settings carry over
    private enum Key {
        static let performChartMode = "performChartMode"
        static let lyricsScrollSpeed = "performLyricsScrollSpeed"
        static let sheetMusicScrollSpeed = "performSheetMusicScrollSpeed"
        static let lyricsLeadInLines = "lyricsLeadInLines"
    }

    static let scrollSpeedRange: ClosedRange<Double> = 5...100
    static let leadInLinesRange = 0...10

    /// The view this person last chose on Perform; used whenever a song has both
    @Published var performChartMode: PerformChartMode {
        didSet { store(performChartMode.rawValue, Key.performChartMode) }
    }
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

    private let cloud = NSUbiquitousKeyValueStore.default
    private let local = UserDefaults.standard
    private var isApplyingCloudChange = false
    private var cancellable: AnyCancellable?

    private init() {
        performChartMode = .lyrics
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

    func scrollSpeed(for mode: PerformChartMode) -> Double {
        mode == .lyrics ? lyricsScrollSpeed : sheetMusicScrollSpeed
    }

    func setScrollSpeed(_ speed: Double, for mode: PerformChartMode) {
        let clamped = min(max(speed, Self.scrollSpeedRange.lowerBound), Self.scrollSpeedRange.upperBound)
        if mode == .lyrics { lyricsScrollSpeed = clamped } else { sheetMusicScrollSpeed = clamped }
    }

    // MARK: Storage

    /// iCloud first (this person's latest choice from any device), then this device
    private func value(_ key: String) -> Any? {
        cloud.object(forKey: key) ?? local.object(forKey: key)
    }

    private func load() {
        isApplyingCloudChange = true
        defer { isApplyingCloudChange = false }
        if let raw = value(Key.performChartMode) as? String, let mode = PerformChartMode(rawValue: raw) {
            performChartMode = mode
        }
        if let speed = (value(Key.lyricsScrollSpeed) as? NSNumber)?.doubleValue {
            lyricsScrollSpeed = min(max(speed, Self.scrollSpeedRange.lowerBound), Self.scrollSpeedRange.upperBound)
        }
        if let speed = (value(Key.sheetMusicScrollSpeed) as? NSNumber)?.doubleValue {
            sheetMusicScrollSpeed = min(max(speed, Self.scrollSpeedRange.lowerBound), Self.scrollSpeedRange.upperBound)
        }
        if let lines = (value(Key.lyricsLeadInLines) as? NSNumber)?.intValue {
            lyricsLeadInLines = min(max(lines, Self.leadInLinesRange.lowerBound), Self.leadInLinesRange.upperBound)
        }
    }

    private func store(_ value: Any, _ key: String) {
        local.set(value, forKey: key)
        // Don't echo values that just arrived from iCloud back up to it
        guard !isApplyingCloudChange else { return }
        cloud.set(value, forKey: key)
    }
}
