//
//  SongPart.swift
//  Midi Set List
//
//  A song's charts, and who sees them. Every song has a built-in chart — its own
//  lyrics and sheet music, exactly as before — and can add parts (a piano part, drum
//  cues…). Each is addressed to band roles ("Seen by"); none means everyone.
//
//  Song and SongPart both conform to ChartSource, so the editor, auto-scroll and
//  per-person memory work the same for either.
//

import CoreData
import Foundation

// MARK: - Chart source

/// Something that holds a chart: lyrics text, and a PDF or a set of page images
protocol ChartSource: AnyObject {
    var id: UUID { get }
    /// Shown in part pickers and the editor's title
    var chartName: String { get }
    var lyrics: String? { get set }
    var pdfFileName: String? { get set }
    var chartImageNames: [String] { get set }
    /// Roles this chart is addressed to; empty means everyone
    var seenBy: [BandRole] { get }
    func setSeenBy(_ roles: [BandRole])
}

extension ChartSource {
    var pdfFileURL: URL? {
        guard let filename = pdfFileName else { return nil }
        return FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent(filename)
    }

    var chartImageURLs: [URL] {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return [] }
        return chartImageNames.map { docs.appendingPathComponent($0) }
    }

    var hasLyricsText: Bool { !(lyrics ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var hasSheetMusic: Bool { pdfFileName != nil || !chartImageNames.isEmpty }
    var hasContent: Bool { hasLyricsText || hasSheetMusic }

    var seenByIDs: Set<UUID> { Set(seenBy.map(\.id)) }

    /// Shown for everyone, or for any of `roleIDs`
    func isSeen(by roleIDs: Set<UUID>) -> Bool {
        let ids = seenByIDs
        return ids.isEmpty || !ids.isDisjoint(with: roleIDs)
    }

    /// What to show on Perform: this person's last choice when it has both,
    /// otherwise whichever it has. Nil when it has neither.
    func chartMode(preferred: PerformChartMode) -> PerformChartMode? {
        switch (hasLyricsText, hasSheetMusic) {
        case (true, true): preferred
        case (true, false): .lyrics
        case (false, true): .sheetMusic
        case (false, false): nil
        }
    }

    /// Short description for lists: "Lyrics · PDF", "3 images", "Empty"
    var contentSummary: String {
        var parts: [String] = []
        if hasLyricsText { parts.append("Lyrics") }
        if pdfFileName != nil {
            parts.append("PDF")
        } else if !chartImageNames.isEmpty {
            parts.append("\(chartImageNames.count) image\(chartImageNames.count == 1 ? "" : "s")")
        }
        return parts.isEmpty ? "Empty" : parts.joined(separator: " · ")
    }

    /// Deletes this chart's PDF and page images from Documents
    func removeAttachedFiles() {
        if let url = pdfFileURL { try? FileManager.default.removeItem(at: url) }
        chartImageURLs.forEach { try? FileManager.default.removeItem(at: $0) }
    }
}

// MARK: - Song part

@objc(SongPart)
class SongPart: NSManagedObject, Identifiable, ChartSource {
    @NSManaged var id: UUID
    @NSManaged var name: String
    @NSManaged var lyrics: String?
    @NSManaged var pdfFileName: String?
    /// JSON-encoded [String] of page-image files in Documents, in page order
    @NSManaged var chartImageNamesData: String?
    @NSManaged private var orderIndexRaw: Int32
    @NSManaged var dateCreated: Date
    @NSManaged var song: Song?
    @NSManaged private var rolesRaw: NSSet

    var orderIndex: Int {
        get { Int(orderIndexRaw) }
        set { orderIndexRaw = Int32(newValue) }
    }

    var chartName: String { name }

    var chartImageNames: [String] {
        get { Self.decodeNames(chartImageNamesData) }
        set { chartImageNamesData = Self.encodeNames(newValue) }
    }

    var seenBy: [BandRole] {
        ((rolesRaw.allObjects as? [BandRole]) ?? []).sorted { $0.orderIndex < $1.orderIndex }
    }

    func setSeenBy(_ roles: [BandRole]) {
        rolesRaw = NSSet(array: roles)
        song?.dateModified = Date()
    }

    static func create(name: String, for song: Song, in context: NSManagedObjectContext) -> SongPart {
        let part = SongPart(context: context)
        part.id = UUID()
        part.name = name
        part.dateCreated = Date()
        part.orderIndex = (song.parts.map(\.orderIndex).max() ?? -1) + 1
        part.song = song
        song.dateModified = Date()
        return part
    }

    static func decodeNames(_ raw: String?) -> [String] {
        guard let raw, let data = raw.data(using: .utf8),
              let names = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return names
    }

    static func encodeNames(_ names: [String]) -> String? {
        names.isEmpty ? nil : (try? JSONEncoder().encode(names)).flatMap { String(data: $0, encoding: .utf8) }
    }
}

// MARK: - Song's charts

extension Song {
    var parts: [SongPart] {
        ((value(forKey: "partsRaw") as? NSSet)?.allObjects as? [SongPart] ?? [])
            .sorted { $0.orderIndex < $1.orderIndex }
    }

    /// The built-in chart first, then the added parts
    var chartSources: [any ChartSource] { [self] + parts }

    /// The charts to show for these roles (nil = show every chart). Only charts with
    /// something in them count. If nothing is addressed to these roles or to everyone,
    /// every chart is shown rather than a blank screen.
    func visibleChartSources(for roleIDs: Set<UUID>?) -> [any ChartSource] {
        let filled = chartSources.filter(\.hasContent)
        guard let roleIDs else { return filled }
        let mine = filled.filter { $0.isSeen(by: roleIDs) }
        return mine.isEmpty ? filled : mine
    }

    func chartSource(id: UUID) -> (any ChartSource)? {
        chartSources.first { $0.id == id }
    }

    func deletePart(_ part: SongPart, in context: NSManagedObjectContext) {
        part.removeAttachedFiles()
        context.delete(part)
        dateModified = Date()
    }

    /// Semitones to shift the written chords so they read in concert pitch — the key the
    /// audience hears — instead of the capo shapes a guitarist plays.
    var concertChordOffset: Int {
        (isCapoKeepingKey ? 0 : transpose) + (capoEnabled ? capo : 0)
    }

    var concertChordsPreferFlats: Bool? { currentKey?.prefersFlats }
}
