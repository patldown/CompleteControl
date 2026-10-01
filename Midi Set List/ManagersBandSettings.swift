//
//  BandSettings.swift
//  Midi Set List
//
//  Which band roles this device plays, and how it shows charts. Kept on this device
//  only: the guitarist's iPad and the pianist's iPad share songs but not these.
//
//  No roles picked means "show every part" — how the app always worked, and what a
//  band leader's device usually wants.
//

import Combine
import CoreData
import Foundation

/// How chord symbols read when a song has a capo
enum ChordDisplay: String, CaseIterable, Identifiable {
    /// The shapes a guitarist's fingers play (what the chart says, moved with transpose)
    case capoShapes
    /// The chords the audience hears — for keys, bass, horns
    case concertPitch

    var id: String { rawValue }

    var title: String {
        switch self {
        case .capoShapes: "Capo Shapes"
        case .concertPitch: "Concert Pitch"
        }
    }
}

final class BandSettings: ObservableObject {
    static let shared = BandSettings()

    private enum Key {
        static let myRoles = "bandMyRoleIDs"
        static let chordDisplay = "bandChordDisplay"
        static let songRoles = "bandSongRoleOverrides"
        static let selectedCharts = "bandSelectedChartIDs"
    }

    /// Roles this device plays; empty shows every part
    @Published var myRoleIDs: Set<UUID> {
        didSet { store(Array(myRoleIDs).map(\.uuidString), Key.myRoles) }
    }

    @Published var chordDisplay: ChordDisplay {
        didSet { defaults.set(chordDisplay.rawValue, forKey: Key.chordDisplay) }
    }

    /// Songs where this device plays something else, e.g. keys on one song. Keyed by song ID.
    @Published private(set) var songRoleOverrides: [UUID: Set<UUID>] {
        didSet { storeDictionary(songRoleOverrides.mapValues { $0.map(\.uuidString) }, Key.songRoles) }
    }

    /// The chart last picked on each song when it has several for this device
    @Published private(set) var selectedChartIDs: [UUID: UUID] {
        didSet { storeDictionary(selectedChartIDs.mapValues(\.uuidString), Key.selectedCharts) }
    }

    private let defaults = UserDefaults.standard

    private init() {
        myRoleIDs = Set((defaults.stringArray(forKey: Key.myRoles) ?? []).compactMap(UUID.init(uuidString:)))
        chordDisplay = defaults.string(forKey: Key.chordDisplay).flatMap(ChordDisplay.init(rawValue:)) ?? .capoShapes
        songRoleOverrides = Self.loadDictionary([String: [String]].self, Key.songRoles)
            .mapValues { Set($0.compactMap(UUID.init(uuidString:))) }
        selectedChartIDs = Self.loadDictionary([String: String].self, Key.selectedCharts)
            .compactMapValues(UUID.init(uuidString:))
    }

    // MARK: Roles

    var showsAllParts: Bool { myRoleIDs.isEmpty }

    func toggleMyRole(_ role: BandRole) {
        if myRoleIDs.contains(role.id) { myRoleIDs.remove(role.id) } else { myRoleIDs.insert(role.id) }
    }

    /// The roles to show a song's charts for: its override if set, else this device's
    /// roles. Nil shows every chart.
    func roleIDs(for song: Song) -> Set<UUID>? {
        let ids = songRoleOverrides[song.id] ?? myRoleIDs
        return ids.isEmpty ? nil : ids
    }

    func roleOverride(for song: Song) -> Set<UUID>? { songRoleOverrides[song.id] }

    /// Nil clears the override, so the song follows this device's roles again
    func setRoleOverride(_ ids: Set<UUID>?, for song: Song) {
        songRoleOverrides[song.id] = (ids?.isEmpty ?? true) ? nil : ids
    }

    // MARK: Charts shown

    func visibleCharts(for song: Song) -> [any ChartSource] {
        song.visibleChartSources(for: roleIDs(for: song))
    }

    /// The chart to show now: the one last picked here if it's still visible, else the first
    func currentChart(for song: Song) -> (any ChartSource)? {
        let visible = visibleCharts(for: song)
        if let picked = selectedChartIDs[song.id], let match = visible.first(where: { $0.id == picked }) {
            return match
        }
        return visible.first
    }

    func selectChart(_ chart: any ChartSource, for song: Song) {
        selectedChartIDs[song.id] = chart.id
    }

    /// Transpose offset and spelling for a song's chords, per this device's chord display
    func chordRendering(for song: Song) -> (transpose: Int, flats: Bool?) {
        switch chordDisplay {
        case .capoShapes: (song.transpose, song.chordsPreferFlats)
        case .concertPitch: (song.concertChordOffset, song.concertChordsPreferFlats)
        }
    }

    // MARK: Storage

    private func store(_ value: Any, _ key: String) { defaults.set(value, forKey: key) }

    private func storeDictionary<Value: Encodable>(_ dictionary: [UUID: Value], _ key: String) {
        let keyed = Dictionary(uniqueKeysWithValues: dictionary.map { ($0.key.uuidString, $0.value) })
        if let data = try? JSONEncoder().encode(keyed) { defaults.set(data, forKey: key) }
    }

    private static func loadDictionary<Value: Decodable>(_ type: [String: Value].Type, _ key: String) -> [UUID: Value] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode(type, from: data) else { return [:] }
        return Dictionary(uniqueKeysWithValues: decoded.compactMap { key, value in
            UUID(uuidString: key).map { ($0, value) }
        })
    }
}
