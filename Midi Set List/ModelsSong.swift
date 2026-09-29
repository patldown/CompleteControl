//
//  Song.swift
//  Midi Set List
//

import CoreData
import Foundation

@objc(Song)
class Song: NSManagedObject, Identifiable {

    // ── Scalar attributes ──────────────────────────────────────────────
    @NSManaged var id: UUID
    @NSManaged var name: String
    @NSManaged var artist: String?
    @NSManaged var genre: String?
    @NSManaged var notes: String?
    @NSManaged var lyrics: String?
    @NSManaged var pdfFileName: String?
    @NSManaged var timeSignature: String?
    @NSManaged var dateCreated: Date
    @NSManaged var dateModified: Date

    // bpm is stored as NSNumber? so nil means "no clock"
    @NSManaged private var bpmRaw: NSNumber?
    var bpm: Int? {
        get { bpmRaw?.intValue }
        set { bpmRaw = newValue.map { NSNumber(value: $0) } }
    }

    // ── Relationships (raw Core Data storage) ──────────────────────────
    @NSManaged private var commandsRaw: NSSet
    @NSManaged private var setListsRaw: NSSet

    // ── Public array views (same names as old SwiftData model) ─────────
    var commands: [MIDICommand] {
        (commandsRaw.allObjects as? [MIDICommand]) ?? []
    }

    var setLists: [SetList] {
        (setListsRaw.allObjects as? [SetList]) ?? []
    }

    // ── Genre (multi-select, stored as JSON array in genre: String?) ───

    static let predefinedGenres: [String] = [
        "Blues", "Classical", "Country", "Electronic", "Folk", "Gospel",
        "Hip-Hop", "Jazz", "Latin", "Metal", "Pop", "Punk", "R&B",
        "Reggae", "Rock", "Soul", "World"
    ]

    var genres: [String] {
        guard let raw = genre,
              let data = raw.data(using: .utf8),
              let arr = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return arr
    }

    func setGenres(_ genres: [String]) {
        let sorted = genres.sorted()
        if sorted.isEmpty {
            genre = nil
        } else if let data = try? JSONEncoder().encode(sorted),
                  let str = String(data: data, encoding: .utf8) {
            genre = str
        }
    }

    var genreDisplayText: String {
        let g = genres
        return g.isEmpty ? "Unspecified" : g.joined(separator: ", ")
    }

    // ── Core Data relationship mutators ────────────────────────────────
    @objc(addCommandsRawObject:)
    @NSManaged func addToCommandsRaw(_ value: MIDICommand)

    @objc(removeCommandsRawObject:)
    @NSManaged func removeFromCommandsRaw(_ value: MIDICommand)

    // ── Factory ────────────────────────────────────────────────────────
    static func create(
        name: String,
        artist: String? = nil,
        notes: String? = nil,
        lyrics: String? = nil,
        bpm: Int? = nil,
        timeSignature: String? = nil,
        in context: NSManagedObjectContext
    ) -> Song {
        let s = Song(context: context)
        s.id = UUID()
        s.name = name
        s.artist = artist
        s.notes = notes
        s.lyrics = lyrics
        s.bpmRaw = bpm.map { NSNumber(value: $0) }
        s.timeSignature = timeSignature
        s.dateCreated = Date()
        s.dateModified = Date()
        return s
    }

    // ── Computed properties ────────────────────────────────────────────
    var pdfFileURL: URL? {
        guard let filename = pdfFileName else { return nil }
        return FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent(filename)
    }

    var sortedCommands: [MIDICommand] {
        commands.sorted { $0.orderIndex < $1.orderIndex }
    }

    var displayName: String {
        if let artist, !artist.isEmpty { return "\(name) - \(artist)" }
        return name
    }

    /// Devices referenced by this song's commands (via sourceMacro provenance)
    var associatedDevices: [InstrumentDevice] {
        var seen = Set<NSManagedObjectID>()
        return commands.compactMap { $0.sourceMacro?.category?.device }.filter {
            seen.insert($0.objectID).inserted
        }
    }

    // ── Mutation helpers ───────────────────────────────────────────────
    func addCommand(_ command: MIDICommand) {
        command.orderIndex = commands.count
        command.song = self
        addToCommandsRaw(command)
        dateModified = Date()
    }

    func removeCommand(_ command: MIDICommand) {
        removeFromCommandsRaw(command)
        reorderCommands()
        dateModified = Date()
    }

    func reorderCommands() {
        for (index, command) in sortedCommands.enumerated() {
            command.orderIndex = index
        }
    }

    func moveCommand(from source: Int, to destination: Int) {
        var sorted = sortedCommands
        let command = sorted.remove(at: source)
        sorted.insert(command, at: min(destination, sorted.count))
        for (index, cmd) in sorted.enumerated() {
            cmd.orderIndex = index
        }
        dateModified = Date()
    }

    /// Replaces commands that originated from `macro` with regenerated versions,
    /// preserving the block's position in the song's command sequence.
    func applyMacroDrift(_ macro: DeviceMacro, in context: NSManagedObjectContext) {
        let allSorted = sortedCommands
        let macroCommands = allSorted.filter { $0.sourceMacro?.objectID == macro.objectID }
        guard !macroCommands.isEmpty,
              let anchorIndex = allSorted.firstIndex(where: { $0.objectID == macroCommands.first!.objectID })
        else { return }

        // Build: before + new block + after
        let before = Array(allSorted.prefix(anchorIndex))
        let after  = Array(allSorted.dropFirst(anchorIndex + macroCommands.count))
        let newCmds = macro.toMIDICommands(in: context)
        newCmds.forEach { $0.sourceMacro = macro; $0.song = self }

        // Delete old macro commands
        macroCommands.forEach {
            removeFromCommandsRaw($0)
            context.delete($0)
        }

        // Insert new commands
        newCmds.forEach { addToCommandsRaw($0) }

        // Resequence all
        let rebuilt = before + newCmds + after
        for (i, cmd) in rebuilt.enumerated() { cmd.orderIndex = i }

        dateModified = Date()
    }
}
