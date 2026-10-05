//
//  Song.swift
//  Midi Set List
//

import CoreData
import Foundation

/// What a new song starts with when nothing more specific is known. Set in Settings.
nonisolated enum SongDefaults {
    static let timeSignatureKey = "defaultTimeSignature"
    static let timeSignatures = ["2/4", "3/4", "4/4", "5/4", "6/8", "7/8", "9/8", "12/8"]

    /// Time signature for new songs; nil (the default) leaves it unset
    static var timeSignature: String? {
        let value = UserDefaults.standard.string(forKey: timeSignatureKey) ?? ""
        return timeSignatures.contains(value) ? value : nil
    }
}

@objc(Song)
class Song: NSManagedObject, Identifiable, ChartSource {

    // ── Scalar attributes ──────────────────────────────────────────────
    @NSManaged var id: UUID
    /// nil = this is the master song in the library.
    /// non-nil = this is a set-list-specific copy; value is the master's id.
    @NSManaged var canonicalID: UUID?

    /// True when this is the authoritative library song, not a set-list copy.
    var isMaster: Bool { canonicalID == nil }

    @NSManaged var name: String
    @NSManaged var artist: String?
    @NSManaged var genre: String?
    @NSManaged var notes: String?
    @NSManaged var lyrics: String?
    @NSManaged var pdfFileName: String?
    /// JSON-encoded [String] of sheet-music image files in Documents, in page order
    @NSManaged var chartImageNamesData: String?
    @NSManaged var timeSignature: String?
    /// JSON-encoded [String] of snapshot names, one per snapshot ("" = default name).
    @NSManaged var snapshotNamesData: String?
    /// Apple Music reference track: catalog ID plus what's shown without a network lookup
    @NSManaged var referenceTrackID: String?
    @NSManaged var referenceTrackTitle: String?
    @NSManaged var referenceTrackArtist: String?
    @NSManaged var referenceTrackURL: String?
    @NSManaged private var referenceTrackDurationRaw: NSNumber?
    /// Length of the reference recording in seconds; helps AI plan sets to a running time
    var referenceTrackDuration: TimeInterval? {
        get { referenceTrackDurationRaw?.doubleValue }
        set { referenceTrackDurationRaw = newValue.map { NSNumber(value: $0) } }
    }
    @NSManaged var dateCreated: Date
    @NSManaged var dateModified: Date

    /// Key root spelling ("A", "F#", "Bb"), nil = no key set
    @NSManaged var keyRoot: String?
    /// MusicalScale raw value
    @NSManaged var keyScaleRaw: String?
    @NSManaged private var transposeRaw: Int16
    @NSManaged var capoEnabled: Bool
    /// True: the capo moves to keep the song in its original key as the chords are transposed.
    /// False: transposing changes the key and the capo stays where it's set.
    @NSManaged var capoKeepsKey: Bool
    /// Send Snapshot 1 when the song is loaded in Perform. Off: the song loads with no
    /// snapshot live, and the first pedal press (or tap) sends one.
    @NSManaged var sendsSnapshotOnLoad: Bool
    @NSManaged private var capoRaw: Int16

    /// The song's tempo; nil when not set. It's part of the song whether or not the clock runs.
    @NSManaged private var bpmRaw: NSNumber?
    var bpm: Int? {
        get { bpmRaw?.intValue }
        set { bpmRaw = newValue.map { NSNumber(value: $0) } }
    }

    /// Send MIDI clock at the song's BPM. Before this switch existed, having a BPM meant the
    /// clock was on — the stored default (true) keeps those songs as they were, and songs
    /// without a BPM have no clock either way.
    @NSManaged var midiClockEnabled: Bool

    /// The tempo to send as MIDI clock, or nil when this song sends none
    var clockBPM: Int? { midiClockEnabled ? bpm : nil }

    /// Click track: Perform starts the metronome when this song loads (needs a BPM)
    @NSManaged var clickEnabled: Bool

    /// Clicks per bar from the time signature, counting the felt beat: 3 for 3/4, but 2 for
    /// 6/8, 3 for 9/8 and 4 for 12/8 (BPM is that dotted beat). 4 when there's none.
    var beatsPerBar: Int {
        guard let signature = timeSignature, let slash = signature.firstIndex(of: "/"),
              let top = Int(signature[..<slash]), let bottom = Int(signature[signature.index(after: slash)...]),
              top > 0
        else { return 4 }
        if bottom == 8, top > 3, top % 3 == 0 { return top / 3 }
        return top
    }

    // ── Key, transpose & capo ──────────────────────────────────────────
    static let transposeRange = -6...6
    static let capoRange = 0...11

    /// The key the song sounds in as charted — chords as written, with the chart capo if any
    var originalKey: MusicalKey? {
        get {
            guard let keyRoot, NoteName.pitchClass(keyRoot) != nil else { return nil }
            return MusicalKey(root: keyRoot, scale: keyScaleRaw.flatMap(MusicalScale.init(rawValue:)) ?? .major)
        }
        set {
            keyRoot = newValue?.root
            keyScaleRaw = newValue?.scale.rawValue
        }
    }

    /// Semitones the chords are shown shifted by, -6…+6. Lyrics are never rewritten.
    var transpose: Int {
        get { Int(transposeRaw) }
        set { transposeRaw = Int16(min(max(newValue, Self.transposeRange.lowerBound), Self.transposeRange.upperBound)) }
    }

    /// Whether the capo is compensating for the transpose, so the key the audience hears stays put
    var isCapoKeepingKey: Bool { capoEnabled && capoKeepsKey }

    /// The key the audience hears. With the capo keeping the key it's the original key;
    /// otherwise it moves with the transpose.
    var currentKey: MusicalKey? {
        isCapoKeepingKey ? originalKey : originalKey?.transposed(by: transpose)
    }

    /// The key of the chord shapes shown in the lyrics (what the fingers play). Differs from
    /// `currentKey` when a capo is on.
    var chordShapeKey: MusicalKey? {
        originalKey?.transposed(by: transpose - (capoEnabled ? capo : 0))
    }

    /// Capo fret the original chart is written for
    var capo: Int {
        get { Int(capoRaw) }
        set { capoRaw = Int16(min(max(newValue, Self.capoRange.lowerBound), Self.capoRange.upperBound)) }
    }

    /// Capo fret to use now. Keeping the key, the capo moves opposite the chords — chords
    /// down 2 (easier open shapes), capo up 2 — so the song still sounds in its original key.
    /// Otherwise it stays at the chart fret. Nil when that fret can't exist (below the nut or
    /// past fret 12).
    var effectiveCapo: Int? {
        let fret = isCapoKeepingKey ? capo - transpose : capo
        return (0...12).contains(fret) ? fret : nil
    }

    /// Chord spelling for lyrics: from the chord shapes' key when set, otherwise per chord
    var chordsPreferFlats: Bool? { chordShapeKey?.prefersFlats }

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
        // As before the switch existed: a song made with a tempo sends clock at it
        s.midiClockEnabled = bpm != nil
        s.timeSignature = timeSignature
        s.dateCreated = Date()
        s.dateModified = Date()
        return s
    }

    // ── Built-in chart (ChartSource: PDF / image URLs and content checks live there) ──
    var chartName: String { "Chart" }

    /// Roles the built-in chart is addressed to; empty means everyone
    var seenBy: [BandRole] {
        ((value(forKey: "chartRolesRaw") as? NSSet)?.allObjects as? [BandRole] ?? [])
            .sorted { $0.orderIndex < $1.orderIndex }
    }

    func setSeenBy(_ roles: [BandRole]) {
        setValue(NSSet(array: roles), forKey: "chartRolesRaw")
        dateModified = Date()
    }

    // ── Sheet music (a PDF or a set of images) ─────────────────────────
    var chartImageNames: [String] {
        get {
            guard let raw = chartImageNamesData, let data = raw.data(using: .utf8),
                  let names = try? JSONDecoder().decode([String].self, from: data) else { return [] }
            return names
        }
        set {
            chartImageNamesData = newValue.isEmpty ? nil
                : (try? JSONEncoder().encode(newValue)).flatMap { String(data: $0, encoding: .utf8) }
        }
    }


    // ── Reference track (Apple Music) ──────────────────────────────────
    var hasReferenceTrack: Bool { referenceTrackID != nil }

    var referenceTrack: ReferenceTrack? {
        guard let referenceTrackID else { return nil }
        return ReferenceTrack(id: referenceTrackID,
                              title: referenceTrackTitle ?? name,
                              artist: referenceTrackArtist ?? artist ?? "",
                              url: referenceTrackURL.flatMap(URL.init(string:)),
                              duration: referenceTrackDuration)
    }

    func linkReferenceTrack(_ track: ReferenceTrack) {
        referenceTrackID = track.id
        referenceTrackTitle = track.title
        referenceTrackArtist = track.artist
        referenceTrackURL = track.url?.absoluteString
        referenceTrackDuration = track.duration
        dateModified = Date()
    }

    func unlinkReferenceTrack() {
        referenceTrackID = nil
        referenceTrackTitle = nil
        referenceTrackArtist = nil
        referenceTrackURL = nil
        referenceTrackDuration = nil
        dateModified = Date()
    }

    /// True when the built-in chart or any part has something to show
    var hasAnyChart: Bool { chartSources.contains { $0.hasContent } }

    /// All commands, grouped by snapshot and then in send order.
    var sortedCommands: [MIDICommand] {
        commands.sorted { ($0.snapshotIndex, $0.orderIndex) < ($1.snapshotIndex, $1.orderIndex) }
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

    // ── Snapshots ──────────────────────────────────────────────────────
    //
    // A snapshot is one named group of commands (macros, macro groups or manual
    // commands) inside a song. Snapshot 1 (index 0) is what gets sent when the
    // song is loaded; the others are recalled on demand — by tapping them, or
    // from a MIDI controller (see MIDIRemoteSettings).

    static let maxSnapshots = 12

    var snapshotCount: Int {
        let highest = commands.map(\.snapshotIndex).max() ?? 0
        return min(Self.maxSnapshots, max(1, storedSnapshotNames.count, highest + 1))
    }

    func commands(inSnapshot index: Int) -> [MIDICommand] {
        commands.filter { $0.snapshotIndex == index }.sorted { $0.orderIndex < $1.orderIndex }
    }

    func snapshotName(_ index: Int) -> String {
        let names = storedSnapshotNames
        if index < names.count {
            let name = names[index].trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { return name }
        }
        return "Snapshot \(index + 1)"
    }

    func renameSnapshot(_ index: Int, to name: String) {
        var names = paddedSnapshotNames
        guard index < names.count else { return }
        names[index] = name.trimmingCharacters(in: .whitespaces)
        storedSnapshotNames = names
        dateModified = Date()
    }

    /// A new snapshot can be added once Snapshot 1 has something in it, up to 12.
    var canAddSnapshot: Bool {
        snapshotCount < Self.maxSnapshots && !commands(inSnapshot: 0).isEmpty
    }

    /// Appends an empty snapshot and returns its index.
    @discardableResult
    func addSnapshot() -> Int? {
        guard canAddSnapshot else { return nil }
        var names = paddedSnapshotNames
        names.append("")
        storedSnapshotNames = names
        dateModified = Date()
        return names.count - 1
    }

    /// Appends a copy of snapshot `index` (commands included) and returns the new index.
    @discardableResult
    func duplicateSnapshot(_ index: Int, in context: NSManagedObjectContext) -> Int? {
        guard canAddSnapshot, let newIndex = addSnapshot() else { return nil }
        renameSnapshot(newIndex, to: "\(snapshotName(index)) Copy")
        for original in commands(inSnapshot: index) {
            let copy = MIDICommand(commandType: original.commandType, channel: original.channel,
                                   value1: original.value1, value2: original.value2,
                                   delayMilliseconds: original.delayMilliseconds,
                                   notes: original.notes, context: context)
            copy.oscAddress    = original.oscAddress
            copy.oscFloatArg   = original.oscFloatArg
            copy.oscFormula    = original.oscFormula
            copy.value1Formula = original.value1Formula
            copy.value2Formula = original.value2Formula
            copy.sourceMacro            = original.sourceMacro
            copy.sourceGroupInstanceID  = original.sourceGroupInstanceID
            addCommand(copy, toSnapshot: newIndex)
        }
        return newIndex
    }

    /// Deletes a snapshot and its commands; later snapshots move up one place.
    /// Snapshot 1 can only be deleted when another snapshot can take its place.
    func deleteSnapshot(_ index: Int, in context: NSManagedObjectContext) {
        let count = snapshotCount
        guard index < count, count > 1 else { return }
        for command in commands(inSnapshot: index) {
            removeFromCommandsRaw(command)
            context.delete(command)
        }
        for command in commands where command.snapshotIndex > index {
            command.snapshotIndex -= 1
        }
        var names = paddedSnapshotNames
        names.remove(at: index)
        storedSnapshotNames = names
        dateModified = Date()
    }

    private var storedSnapshotNames: [String] {
        get {
            guard let raw = snapshotNamesData,
                  let data = raw.data(using: .utf8),
                  let names = try? JSONDecoder().decode([String].self, from: data) else { return [] }
            return names
        }
        set {
            if let data = try? JSONEncoder().encode(newValue),
               let str = String(data: data, encoding: .utf8) {
                snapshotNamesData = str
            }
        }
    }

    /// Stored names padded (or trimmed) to exactly `snapshotCount` entries.
    private var paddedSnapshotNames: [String] {
        let count = snapshotCount
        var names = Array(storedSnapshotNames.prefix(count))
        while names.count < count { names.append("") }
        return names
    }

    // ── Mutation helpers ───────────────────────────────────────────────
    func addCommand(_ command: MIDICommand, toSnapshot snapshot: Int = 0) {
        command.snapshotIndex = snapshot
        command.orderIndex = commands(inSnapshot: snapshot).count
        command.song = self
        addToCommandsRaw(command)
        dateModified = Date()
    }

    func removeCommand(_ command: MIDICommand) {
        batchDelete([command], in: managedObjectContext!)
    }

    /// Removes and deletes multiple commands in one pass, calling reorderCommands only once.
    /// Avoids CoreData relationship management issues that occur when removeCommand (which
    /// calls reorderCommands) and context.delete are interleaved in a loop.
    func batchDelete(_ commandsToDelete: [MIDICommand], in context: NSManagedObjectContext) {
        for command in commandsToDelete {
            removeFromCommandsRaw(command)
            context.delete(command)
        }
        reorderCommands()
        dateModified = Date()
    }

    /// Renumbers each snapshot's commands 0, 1, 2… keeping their current order.
    func reorderCommands() {
        for snapshot in 0..<snapshotCount {
            for (index, command) in commands(inSnapshot: snapshot).enumerated() {
                command.orderIndex = index
            }
        }
    }

    func moveCommand(from source: Int, to destination: Int, inSnapshot snapshot: Int = 0) {
        var sorted = commands(inSnapshot: snapshot)
        guard source < sorted.count else { return }
        let command = sorted.remove(at: source)
        // List's onMove destination counts the moved row, so adjust when moving down
        let insertAt = destination > source ? destination - 1 : destination
        sorted.insert(command, at: max(0, min(insertAt, sorted.count)))
        for (index, cmd) in sorted.enumerated() {
            cmd.orderIndex = index
        }
        dateModified = Date()
    }

    /// Replaces commands that originated from `macro` with regenerated versions,
    /// preserving each block's position in its snapshot's command sequence.
    func applyMacroDrift(_ macro: DeviceMacro, in context: NSManagedObjectContext) {
        let snapshots = Set(commands.filter { $0.sourceMacro?.objectID == macro.objectID }.map(\.snapshotIndex))
        for snapshot in snapshots.sorted() {
            applyMacroDrift(macro, inSnapshot: snapshot, context: context)
        }
    }

    // ── Per-set-list copy support ──────────────────────────────────────

    /// Creates a deep copy of this song with canonicalID pointing back to self.id.
    /// Does NOT add the copy to any set list — the caller handles that.
    func makeCopy(in context: NSManagedObjectContext) -> Song {
        let copy = Song(context: context)
        copy.id = UUID()
        copy.canonicalID = self.id
        copy.name = self.name
        copy.artist = self.artist
        copy.genre = self.genre
        copy.notes = self.notes
        copy.lyrics = self.lyrics
        copy.bpm = self.bpm
        copy.midiClockEnabled = self.midiClockEnabled
        copy.clickEnabled = self.clickEnabled
        copy.timeSignature = self.timeSignature
        copy.snapshotNamesData = self.snapshotNamesData
        copy.referenceTrackID = self.referenceTrackID
        copy.referenceTrackTitle = self.referenceTrackTitle
        copy.referenceTrackArtist = self.referenceTrackArtist
        copy.referenceTrackURL = self.referenceTrackURL
        copy.referenceTrackDuration = self.referenceTrackDuration
        copy.keyRoot = self.keyRoot
        copy.keyScaleRaw = self.keyScaleRaw
        copy.transposeRaw = self.transposeRaw
        copy.capoEnabled = self.capoEnabled
        copy.capoKeepsKey = self.capoKeepsKey
        copy.capoRaw = self.capoRaw
        copy.sendsSnapshotOnLoad = self.sendsSnapshotOnLoad
        copy.pdfFileName = self.pdfFileName
        copy.chartImageNamesData = self.chartImageNamesData
        copy.dateCreated = Date()
        copy.dateModified = Date()
        for original in self.sortedCommands {
            let cmd = MIDICommand(commandType: original.commandType,
                                  channel: original.channel,
                                  value1: original.value1,
                                  value2: original.value2,
                                  delayMilliseconds: original.delayMilliseconds,
                                  notes: original.notes,
                                  context: context)
            cmd.oscAddress           = original.oscAddress
            cmd.oscFloatArg          = original.oscFloatArg
            cmd.oscFormula           = original.oscFormula
            cmd.value1Formula        = original.value1Formula
            cmd.value2Formula        = original.value2Formula
            cmd.sourceMacro          = original.sourceMacro
            cmd.sourceGroupInstanceID = original.sourceGroupInstanceID
            copy.addCommand(cmd, toSnapshot: original.snapshotIndex)
        }
        for original in self.parts {
            let partCopy = SongPart(context: context)
            partCopy.id = UUID()
            partCopy.name = original.name
            partCopy.lyrics = original.lyrics
            partCopy.pdfFileName = original.pdfFileName
            partCopy.chartImageNamesData = original.chartImageNamesData
            partCopy.orderIndex = original.orderIndex
            partCopy.dateCreated = Date()
            partCopy.song = copy
            partCopy.setSeenBy(original.seenBy)
        }
        return copy
    }

    /// Overwrites the master song's data with this copy's current state.
    /// Silently does nothing if this is already the master or if the master is not found.
    func pushToMaster(in context: NSManagedObjectContext) {
        guard let canonicalID else { return }
        let req = NSFetchRequest<Song>(entityName: "Song")
        req.predicate = NSPredicate(format: "id == %@ AND canonicalID == nil", canonicalID as CVarArg)
        req.fetchLimit = 1
        guard let master = (try? context.fetch(req))?.first else { return }

        master.name = self.name
        master.artist = self.artist
        master.genre = self.genre
        master.notes = self.notes
        master.lyrics = self.lyrics
        master.bpm = self.bpm
        master.midiClockEnabled = self.midiClockEnabled
        master.clickEnabled = self.clickEnabled
        master.timeSignature = self.timeSignature
        master.snapshotNamesData = self.snapshotNamesData
        master.referenceTrackID = self.referenceTrackID
        master.referenceTrackTitle = self.referenceTrackTitle
        master.referenceTrackArtist = self.referenceTrackArtist
        master.referenceTrackURL = self.referenceTrackURL
        master.referenceTrackDuration = self.referenceTrackDuration
        master.keyRoot = self.keyRoot
        master.keyScaleRaw = self.keyScaleRaw
        master.transposeRaw = self.transposeRaw
        master.capoEnabled = self.capoEnabled
        master.capoKeepsKey = self.capoKeepsKey
        master.capoRaw = self.capoRaw
        master.sendsSnapshotOnLoad = self.sendsSnapshotOnLoad
        master.pdfFileName = self.pdfFileName
        master.chartImageNamesData = self.chartImageNamesData
        master.dateModified = Date()

        for cmd in master.commands {
            master.removeFromCommandsRaw(cmd)
            context.delete(cmd)
        }
        for original in self.sortedCommands {
            let cmd = MIDICommand(commandType: original.commandType,
                                  channel: original.channel,
                                  value1: original.value1,
                                  value2: original.value2,
                                  delayMilliseconds: original.delayMilliseconds,
                                  notes: original.notes,
                                  context: context)
            cmd.oscAddress           = original.oscAddress
            cmd.oscFloatArg          = original.oscFloatArg
            cmd.oscFormula           = original.oscFormula
            cmd.value1Formula        = original.value1Formula
            cmd.value2Formula        = original.value2Formula
            cmd.sourceMacro          = original.sourceMacro
            cmd.sourceGroupInstanceID = original.sourceGroupInstanceID
            master.addCommand(cmd, toSnapshot: original.snapshotIndex)
        }
    }

    // Deleting a master also deletes all its set-list copies.
    override func prepareForDeletion() {
        super.prepareForDeletion()
        guard isMaster, let context = managedObjectContext else { return }
        let req = NSFetchRequest<Song>(entityName: "Song")
        req.predicate = NSPredicate(format: "canonicalID == %@", id as CVarArg)
        ((try? context.fetch(req)) ?? []).forEach { context.delete($0) }
    }

    private func applyMacroDrift(_ macro: DeviceMacro, inSnapshot snapshot: Int, context: NSManagedObjectContext) {
        let allSorted = commands(inSnapshot: snapshot)
        let macroCommands = allSorted.filter { $0.sourceMacro?.objectID == macro.objectID }
        guard !macroCommands.isEmpty,
              let anchorIndex = allSorted.firstIndex(where: { $0.objectID == macroCommands.first!.objectID })
        else { return }

        // Build: before + new block + after
        let before = Array(allSorted.prefix(anchorIndex))
        let after  = allSorted.dropFirst(anchorIndex).filter { $0.sourceMacro?.objectID != macro.objectID }
        let newCmds = macro.toMIDICommands(in: context)
        let groupInstanceID = macro.isGroup ? UUID().uuidString : nil
        newCmds.forEach {
            $0.sourceMacro = macro
            $0.song = self
            $0.snapshotIndex = snapshot
            $0.sourceGroupInstanceID = groupInstanceID
        }

        // Delete old macro commands
        macroCommands.forEach {
            removeFromCommandsRaw($0)
            context.delete($0)
        }

        // Insert new commands
        newCmds.forEach { addToCommandsRaw($0) }

        // Resequence the snapshot
        let rebuilt = before + newCmds + after
        for (i, cmd) in rebuilt.enumerated() { cmd.orderIndex = i }

        dateModified = Date()
    }
}
