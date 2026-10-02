//
//  BandFeaturesTests.swift
//  Midi Set ListTests
//
//  Band roles and song parts, chord display, sharing parts between devices, the set
//  list assistant's plan checks, Live Follow's song/snapshot following, snapshots,
//  and the text parsing behind the Create Song shortcut's AI options.
//

import Testing
import CoreData
import Foundation
@testable import Midi_Set_List

/// A built-in role from a store's seeded roster
@MainActor
private func role(_ name: String, in ctx: NSManagedObjectContext) -> BandRole {
    BandRole.all(in: ctx).first { $0.name == name }!
}

// MARK: - Band roles

@Suite("BandRole")
@MainActor
struct BandRoleTests {
    let controller = PersistenceController(inMemory: true)
    var ctx: NSManagedObjectContext { controller.viewContext }

    @Test func seedsBuiltInRolesWithFixedIDs() {
        let roles = BandRole.all(in: ctx)
        #expect(roles.map(\.name) == ["Vocals", "Guitar", "Keys", "Bass", "Drums"])
        // Fixed IDs are what make "Guitar" the same role on every bandmate's device
        #expect(roles.map(\.id.uuidString) == BandRole.builtIns.map(\.id))
    }

    @Test func seedingTwiceDoesNotDuplicate() {
        BandRole.seedDefaultsIfNeeded(in: ctx)
        #expect(BandRole.all(in: ctx).count == 5)
    }

    @Test func seenByLabel_emptyIsEveryone() {
        #expect([BandRole]().seenByLabel == "Everyone")
    }

    @Test func seenByLabel_listsRolesInRosterOrder() {
        let label = [role("Keys", in: ctx), role("Guitar", in: ctx)].seenByLabel
        #expect(label == "🎸 Guitar, 🎹 Keys")
    }
}

// MARK: - Song parts and who sees them

@Suite("Song parts")
@MainActor
struct SongPartTests {
    let controller = PersistenceController(inMemory: true)
    var ctx: NSManagedObjectContext { controller.viewContext }

    /// Chart (guitar + keys), Drum Cues (drums), Lyrics (everyone)
    private func bandSong() -> (Song, SongPart, SongPart) {
        let song = Song.create(name: "Wonderwall", lyrics: "Today is gonna be", in: ctx)
        song.setSeenBy([role("Guitar", in: ctx), role("Keys", in: ctx)])
        let drums = SongPart.create(name: "Drum Cues", for: song, in: ctx)
        drums.lyrics = "Fill into chorus"
        drums.setSeenBy([role("Drums", in: ctx)])
        let lyrics = SongPart.create(name: "Lyrics", for: song, in: ctx)
        lyrics.lyrics = "Today is gonna be the day"
        return (song, drums, lyrics)
    }

    private func names(_ charts: [any ChartSource]) -> [String] { charts.map(\.chartName) }

    @Test func chartSources_songChartFirstThenPartsInOrder() {
        let (song, _, _) = bandSong()
        #expect(names(song.chartSources) == ["Chart", "Drum Cues", "Lyrics"])
    }

    @Test func noRoles_showsEveryChartWithContent() {
        let (song, _, _) = bandSong()
        SongPart.create(name: "Empty Part", for: song, in: ctx)
        #expect(names(song.visibleChartSources(for: nil)) == ["Chart", "Drum Cues", "Lyrics"])
    }

    @Test func keys_seesSharedChartAndEveryonePart() {
        let (song, _, _) = bandSong()
        let keys: Set = [role("Keys", in: ctx).id]
        #expect(names(song.visibleChartSources(for: keys)) == ["Chart", "Lyrics"])
    }

    @Test func drums_seesOwnPartAndEveryonePart() {
        let (song, _, _) = bandSong()
        let drums: Set = [role("Drums", in: ctx).id]
        #expect(names(song.visibleChartSources(for: drums)) == ["Drum Cues", "Lyrics"])
    }

    @Test func nothingAddressedToRole_fallsBackToEveryChart() {
        let song = Song.create(name: "Clocks", lyrics: "Lights go out", in: ctx)
        song.setSeenBy([role("Guitar", in: ctx)])
        let bass: Set = [role("Bass", in: ctx).id]
        // Better every chart than a blank screen
        #expect(names(song.visibleChartSources(for: bass)) == ["Chart"])
    }

    @Test func contentSummary() {
        let (song, drums, _) = bandSong()
        #expect(song.contentSummary == "Lyrics")
        drums.chartImageNames = ["a.jpg", "b.jpg"]
        #expect(drums.contentSummary == "Lyrics · 2 images")
        #expect(SongPart.create(name: "New", for: song, in: ctx).contentSummary == "Empty")
    }

    @Test func deletingRole_makesItsPartsEveryone() throws {
        let (song, drums, _) = bandSong()
        try ctx.save()
        ctx.delete(role("Drums", in: ctx))
        try ctx.save()
        #expect(drums.seenBy.isEmpty)
        #expect(song.parts.count == 2)
    }

    @Test func deletingSong_deletesItsParts() throws {
        let (song, _, _) = bandSong()
        try ctx.save()
        ctx.delete(song)
        try ctx.save()
        #expect(try ctx.count(for: NSFetchRequest<SongPart>(entityName: "SongPart")) == 0)
    }
}

// MARK: - Capo shapes vs concert pitch

@Suite("Chord display")
@MainActor
struct ChordDisplayTests {
    let controller = PersistenceController(inMemory: true)
    var ctx: NSManagedObjectContext { controller.viewContext }

    private func song(capo: Int?, keepsKey: Bool = true, transpose: Int = 0) -> Song {
        let song = Song.create(name: "Test", in: ctx)
        song.originalKey = MusicalKey(root: "A", scale: .major)
        song.capoEnabled = capo != nil
        song.capo = capo ?? 0
        song.capoKeepsKey = keepsKey
        song.transpose = transpose
        return song
    }

    @Test func noCapo_concertMatchesTranspose() {
        #expect(song(capo: nil, transpose: 3).concertChordOffset == 3)
    }

    @Test func capoKeepingKey_concertAddsCapoOnly() {
        // A song charted in G shapes with capo 2 sounds in A: concert chords are +2
        let s = song(capo: 2, keepsKey: true, transpose: -2)
        #expect(s.concertChordOffset == 2)
        #expect(s.currentKey?.root == "A")
    }

    @Test func capoNotKeepingKey_concertAddsTransposeAndCapo() {
        #expect(song(capo: 2, keepsKey: false, transpose: 1).concertChordOffset == 3)
    }

    @Test func chordEngine_movesShapesToConcertPitch() {
        #expect(ChordEngine.transpose("G", by: 2, flats: false) == "A")
        #expect(ChordEngine.transpose("Em", by: 2, flats: false) == "F#m")
    }

    @Test func chordEngine_hideChordsLeavesJustTheWords() {
        let text = "[Chorus]\nD        C         G\nSweet Home Alabama\n\n[G]Where the [C]skies are blue"
        let shown = ChordEngine.render(text, transpose: 0, flats: nil)
        #expect(shown.text == text)
        let hidden = ChordEngine.render(text, transpose: 0, flats: nil, hideChords: true)
        #expect(hidden.text == "[Chorus]\nSweet Home Alabama\n\nWhere the skies are blue")
        #expect(hidden.chordRanges.isEmpty)
    }

    @Test func lyricsFit_shrinksOnlyForLongLines() {
        let short = AutoScrollingTextView.fittedFontSize(for: "Short line", maxSize: 24, width: 600)
        #expect(short == 24)
        let long = String(repeating: "x", count: 80)
        let fitted = AutoScrollingTextView.fittedFontSize(for: "a\n" + long, maxSize: 24, width: 600)
        #expect(fitted < 24)
        #expect(fitted >= AutoScrollingTextView.minimumFittedFontSize)
    }
}

// MARK: - Sharing parts and roles

@Suite("DataArchive with parts")
@MainActor
struct DataArchivePartsTests {
    let leader = PersistenceController(inMemory: true)
    let follower = PersistenceController(inMemory: true)

    private func share(_ setList: SetList, into ctx: NSManagedObjectContext,
                       mode: DataArchiveImporter.Mode = .merge) throws {
        let archive = try DataArchiveExporter.share([setList], title: setList.name)
        // Through a real file, like Share and Live Follow
        let url = try DataArchiveExporter.write(archive, fileName: "test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try DataArchiveImporter.apply(try DataArchiveImporter.read(url), mode: mode, context: ctx)
    }

    private func fetchSongs(_ ctx: NSManagedObjectContext) throws -> [Song] {
        let request = NSFetchRequest<Song>(entityName: "Song")
        request.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
        return try ctx.fetch(request)
    }

    @Test func sharedSetList_bringsPartsAddressedToTheSameRoles() throws {
        let l = leader.viewContext
        let song = Song.create(name: "Clocks", lyrics: "Lights go out", in: l)
        let riff = SongPart.create(name: "Piano Riff", for: song, in: l)
        riff.lyrics = "Eb Bb Bb Fm"
        riff.setSeenBy([role("Keys", in: l)])
        let setList = SetList.create(name: "Friday", in: l)
        setList.addSong(song)
        try l.save()

        let f = follower.viewContext
        try share(setList, into: f)

        let imported = try #require(try fetchSongs(f).first)
        #expect(imported.parts.map(\.name) == ["Piano Riff"])
        #expect(imported.parts.first?.lyrics == "Eb Bb Bb Fm")
        #expect(imported.parts.first?.seenBy.map(\.id) == [role("Keys", in: f).id])
        #expect(BandRole.all(in: f).count == 5)   // built-ins matched, not duplicated
    }

    @Test func customRole_matchesOneOfTheSameName() throws {
        let l = leader.viewContext
        let lHorns = BandRole.create(name: "Horns", emoji: "🎺", order: 5, in: l)
        let song = Song.create(name: "Vehicle", in: l)
        let part = SongPart.create(name: "Horn Lines", for: song, in: l)
        part.lyrics = "Bah bah"
        part.setSeenBy([lHorns])
        let setList = SetList.create(name: "Saturday", in: l)
        setList.addSong(song)
        try l.save()

        let f = follower.viewContext
        let fHorns = BandRole.create(name: "horns", emoji: "🎷", order: 5, in: f)
        try f.save()
        try share(setList, into: f)

        let horns = BandRole.all(in: f).filter { $0.name.lowercased() == "horns" }
        #expect(horns.count == 1)
        #expect(horns.first?.id == fHorns.id)
        let imported = try #require(try fetchSongs(f).first)
        #expect(imported.parts.first?.seenBy.map(\.id) == [fHorns.id])
    }

    @Test func addNewOnly_keepsExistingSongsAndAddsNewOnes() throws {
        let l = leader.viewContext
        let song = Song.create(name: "Wonderwall", in: l)
        let setList = SetList.create(name: "Gig", in: l)
        setList.addSong(song)
        try l.save()

        let f = follower.viewContext
        try share(setList, into: f)
        try #require(try fetchSongs(f).first).name = "Wonderwall (my version)"
        try f.save()

        // The leader edits the song and adds another
        song.name = "Wonderwall (leader's)"
        setList.addSong(Song.create(name: "Africa", in: l))
        try l.save()
        try share(setList, into: f, mode: .addNewOnly)

        #expect(try fetchSongs(f).map(\.name) == ["Africa", "Wonderwall (my version)"])
    }

    @Test func merge_updatesExistingSongs() throws {
        let l = leader.viewContext
        let song = Song.create(name: "Wonderwall", in: l)
        let setList = SetList.create(name: "Gig", in: l)
        setList.addSong(song)
        try l.save()

        let f = follower.viewContext
        try share(setList, into: f)
        song.name = "Wonderwall (leader's)"
        try l.save()
        try share(setList, into: f, mode: .merge)

        #expect(try fetchSongs(f).map(\.name) == ["Wonderwall (leader's)"])
    }
}

// MARK: - Set list assistant plans

@Suite("SetListAssistant")
@MainActor
struct SetListAssistantTests {
    let controller = PersistenceController(inMemory: true)
    var ctx: NSManagedObjectContext { controller.viewContext }

    private func plan(_ json: String) throws -> SetListPlan {
        try JSONDecoder().decode(SetListPlan.self, from: Data(json.utf8))
    }

    /// Songs A, B (S1, S2); set lists "Open" (L1, has A) and "Friday Gig" (L2, has B)
    private func fixture() -> (SetListAssistant.Catalog, SetList, SetList) {
        let a = Song.create(name: "Africa", in: ctx)
        let b = Song.create(name: "Wonderwall", in: ctx)
        let open = SetList.create(name: "Open", in: ctx)
        open.addSong(a)
        let friday = SetList.create(name: "Friday Gig", in: ctx)
        friday.addSong(b)
        return (SetListAssistant.Catalog(songs: [a, b], setLists: [open, friday]), open, friday)
    }

    @Test func replacingIDs_usesTitles() {
        let (catalog, _, _) = fixture()
        #expect(catalog.replacingIDs(in: "Added S2 to L2") == "Added \"Wonderwall\" to \"Friday Gig\"")
    }

    @Test func replacingIDs_leavesUnknownIDsAndWords() {
        let (catalog, _, _) = fixture()
        #expect(catalog.replacingIDs(in: "S9 and SL2 stay") == "S9 and SL2 stay")
    }

    @Test func update_targetsTheNamedSetList_notTheOpenOne() throws {
        let (catalog, open, friday) = fixture()
        let preview = SetListAssistant.preview(
            for: try plan(#"{"action":"update","setListID":"L2","songIDs":["S2","S1"],"summary":"Added S1"}"#),
            catalog: catalog, current: open)
        #expect(preview.kind == .update)
        #expect(preview.target === friday)
        #expect(preview.finalSongs.map(\.song.name) == ["Wonderwall", "Africa"])
        #expect(preview.summary == "Added \"Africa\"")
    }

    @Test func update_withoutSetListID_targetsTheOpenOne() throws {
        let (catalog, open, _) = fixture()
        let preview = SetListAssistant.preview(
            for: try plan(#"{"action":"update","songIDs":["S1","S2"],"summary":"ok"}"#),
            catalog: catalog, current: open)
        #expect(preview.target === open)
    }

    @Test func update_withNothingOpenOrNamed_becomesCreate() throws {
        let (catalog, _, _) = fixture()
        let preview = SetListAssistant.preview(
            for: try plan(#"{"action":"update","songIDs":["S1"],"summary":"ok"}"#),
            catalog: catalog, current: nil)
        #expect(preview.kind == .create)
    }

    @Test func createWithNoSongs_isNotOffered() throws {
        let (catalog, _, _) = fixture()
        let preview = SetListAssistant.preview(
            for: try plan(#"{"action":"create","name":"Empty","songIDs":[],"summary":"ok"}"#),
            catalog: catalog, current: nil)
        #expect(preview.kind == .none)
        #expect(!preview.hasChanges)
    }

    @Test func playlistOfOpenSetList() throws {
        let (catalog, open, _) = fixture()
        let json = #"{"action":"none","songIDs":[],"summary":"ok","playlist":true}"#
        #expect(SetListAssistant.preview(for: try plan(json), catalog: catalog, current: open).makePlaylist)
        #expect(!SetListAssistant.preview(for: try plan(json), catalog: catalog, current: nil).makePlaylist)
    }

    @Test func unknownSongIDs_areDroppedAndReported() throws {
        let (catalog, open, _) = fixture()
        let preview = SetListAssistant.preview(
            for: try plan(#"{"action":"update","songIDs":["S1","S7"],"summary":"ok"}"#),
            catalog: catalog, current: open)
        #expect(preview.finalSongs.count == 1)
        #expect(preview.unknownIDs == ["S7"])
    }
}

// MARK: - Performing and following

@Suite("PerformanceSession")
@MainActor
struct PerformanceSessionTests {
    let controller = PersistenceController(inMemory: true)
    var ctx: NSManagedObjectContext { controller.viewContext }

    private func setList(_ names: [String]) -> SetList {
        let setList = SetList.create(name: "Gig", in: ctx)
        names.forEach { setList.addSong(Song.create(name: $0, in: ctx)) }
        return setList
    }

    @Test func play_loadsFirstSongOnSnapshot1() {
        let performance = PerformanceSession()
        performance.play(setList(["A", "B"]))
        #expect(performance.currentSong?.name == "A")
        #expect(performance.activeSnapshot == 0)
    }

    @Test func songThatDoesNotSendOnLoad_startsWithNoSnapshotLive() {
        let list = setList(["A"])
        list.songs[0].sendsSnapshotOnLoad = false
        let performance = PerformanceSession()
        performance.play(list)
        #expect(performance.activeSnapshot == -1)
        // Next Snapshot then goes to Snapshot 1, not 2
        performance.nextSnapshot()
        #expect(performance.activeSnapshot == 0)
    }

    @Test func stateChanges_areReported() {
        let performance = PerformanceSession()
        var changes = 0
        performance.onStateChange = { changes += 1 }
        performance.play(setList(["A", "B"]))
        performance.nextSong()
        performance.stop()
        #expect(changes >= 3)
    }

    @Test func follow_movesToLeadersSongAndSnapshot() {
        let list = setList(["A", "B", "C"])
        let performance = PerformanceSession()
        performance.follow(list, songIndex: 2, snapshot: 1, sendCommands: false)
        #expect(performance.setList === list)
        #expect(performance.currentSong?.name == "C")
        #expect(performance.activeSnapshot == 1)
    }

    @Test func follow_ignoresSongsOutOfRange() {
        let list = setList(["A"])
        let performance = PerformanceSession()
        performance.follow(list, songIndex: 0, snapshot: 0, sendCommands: false)
        performance.follow(list, songIndex: 5, snapshot: 0, sendCommands: false)
        #expect(performance.currentSong?.name == "A")
    }
}

// MARK: - Snapshots

@Suite("Snapshots")
@MainActor
struct SnapshotTests {
    let controller = PersistenceController(inMemory: true)
    var ctx: NSManagedObjectContext { controller.viewContext }

    private func command(_ value: Int) -> MIDICommand {
        MIDICommand(commandType: .programChange, channel: 1, value1: value, context: ctx)
    }

    @Test func moreSnapshotsUnlockOnceSnapshot1HasCommands() {
        let song = Song.create(name: "Test", in: ctx)
        #expect(!song.canAddSnapshot)
        song.addCommand(command(1))
        #expect(song.addSnapshot() == 1)
        #expect(song.snapshotCount == 2)
    }

    @Test func duplicateSnapshot_copiesCommandsAndName() {
        let song = Song.create(name: "Test", in: ctx)
        song.addCommand(command(7))
        song.renameSnapshot(0, to: "Verse")
        let copy = song.duplicateSnapshot(0, in: ctx)
        #expect(copy == 1)
        #expect(song.snapshotName(1) == "Verse Copy")
        #expect(song.commands(inSnapshot: 1).map(\.value1) == [7])
    }

    @Test func deleteSnapshot_movesLaterOnesUp() {
        let song = Song.create(name: "Test", in: ctx)
        song.addCommand(command(1))
        _ = song.addSnapshot()
        song.addCommand(command(2), toSnapshot: 1)
        song.renameSnapshot(1, to: "Chorus")
        song.deleteSnapshot(0, in: ctx)
        #expect(song.snapshotCount == 1)
        #expect(song.snapshotName(0) == "Chorus")
        #expect(song.commands(inSnapshot: 0).map(\.value1) == [2])
    }

    @Test func sendsSnapshotOnLoad_defaultsOn() {
        #expect(Song.create(name: "Test", in: ctx).sendsSnapshotOnLoad)
    }
}

// MARK: - Create Song shortcut parsing

@Suite("SongDetailsAI parsing")
@MainActor
struct SongDetailsParsingTests {

    @Test(arguments: [("f♯", "F#"), ("Bb", "Bb"), ("e♭", "Eb"), ("C", "C"), ("  A ", "A")])
    func normalizedRoot_spellsLikeTheKeyPicker(input: String, expected: String) {
        #expect(SongDetailsAI.normalizedRoot(input) == expected)
    }

    @Test(arguments: ["H", "E#", "", "   "])
    func normalizedRoot_rejectsWhatThePickerCannotShow(input: String) {
        #expect(SongDetailsAI.normalizedRoot(input) == nil)
    }

    private let chart = """
        Wonderwall - Oasis
        Key: F#m  Capo 2

        Em7        G
        Today is gonna be the day
        Dsus4          A7sus4
        That they're gonna throw it back to you
        """

    @Test func lyricsSpan_copiesChordLinesVerbatim() {
        let lyrics = SongDetailsAI.lyricsSpan(in: chart, first: "Em7        G",
                                              last: "That they're gonna throw it back to you")
        #expect(lyrics?.hasPrefix("Em7        G\nToday") == true)
        #expect(lyrics?.hasSuffix("back to you") == true)
        #expect(lyrics?.contains("Key:") == false)
    }

    @Test func lyricsSpan_matchesLooselyAndRunsToEndWithoutALastLine() {
        let lyrics = SongDetailsAI.lyricsSpan(in: chart, first: "  today is GONNA be the day ", last: nil)
        #expect(lyrics?.hasPrefix("Today is gonna be the day") == true)
        #expect(lyrics?.hasSuffix("back to you") == true)
    }

    @Test func lyricsSpan_nilWhenFirstLineIsNotInTheText() {
        #expect(SongDetailsAI.lyricsSpan(in: chart, first: "Hello from the other side", last: nil) == nil)
        #expect(SongDetailsAI.lyricsSpan(in: chart, first: nil, last: nil) == nil)
    }
}

// MARK: - Apple Music reference tracks

@Suite("ReferenceTrack")
@MainActor
struct ReferenceTrackTests {
    let controller = PersistenceController(inMemory: true)

    @Test func durationText() {
        #expect(ReferenceTrack(id: "1", title: "T", artist: "A", duration: 245).durationText == "4:05")
        #expect(ReferenceTrack(id: "1", title: "T", artist: "A").durationText == nil)
    }

    @Test func linkAndUnlinkOnSong() {
        let song = Song.create(name: "Clocks", in: controller.viewContext)
        let url = URL(string: "https://music.apple.com/song/1")
        song.linkReferenceTrack(ReferenceTrack(id: "1", title: "Clocks", artist: "Coldplay", url: url, duration: 307))
        #expect(song.hasReferenceTrack)
        #expect(song.referenceTrack?.duration == 307)
        #expect(song.referenceTrack?.url == url)
        song.unlinkReferenceTrack()
        #expect(!song.hasReferenceTrack)
        #expect(song.referenceTrackDuration == nil)
    }
}

// MARK: - BPM and MIDI clock

@Suite("BPM and MIDI clock")
@MainActor
struct SongClockTests {
    let controller = PersistenceController(inMemory: true)
    var ctx: NSManagedObjectContext { controller.viewContext }

    @Test func songMadeWithATempo_sendsClockAtIt() {
        let song = Song.create(name: "Test", bpm: 98, in: ctx)
        #expect(song.midiClockEnabled)
        #expect(song.clockBPM == 98)
    }

    @Test func songWithoutATempo_sendsNoClock() {
        #expect(Song.create(name: "Test", in: ctx).clockBPM == nil)
    }

    @Test func clockOff_keepsTheSongsBPM() {
        let song = Song.create(name: "Test", bpm: 120, in: ctx)
        song.midiClockEnabled = false
        #expect(song.bpm == 120)
        #expect(song.clockBPM == nil)
    }

    @Test func settingABPMLater_doesNotTurnTheClockOn() {
        let song = Song.create(name: "Test", in: ctx)
        song.bpm = 140
        #expect(song.clockBPM == nil)
    }
}

// MARK: - Group macro stamp and snapshot behavior

@Suite("GroupMacro")
@MainActor
struct GroupMacroTests {
    let controller = PersistenceController(inMemory: true)
    var ctx: NSManagedObjectContext { controller.viewContext }

    // MARK: Fixture

    /// Five-song set list with two solo macros and one group macro.
    /// soloA: LSB + PC (2 commands); soloB: CC only (1 command)
    /// groupMacro: [soloA, soloB] → expands to 3 commands total
    private struct Fixture {
        let setList: SetList
        let songs: [Song]
        let soloA: DeviceMacro
        let soloB: DeviceMacro
        let groupMacro: DeviceMacro
        let device: InstrumentDevice
        let category: MacroCategory
    }

    private func makeFixture() -> Fixture {
        let device = InstrumentDevice.create(name: "Synth One", manufacturer: "ArtValley", in: ctx)
        let category = MacroCategory.create(name: "Patches", device: device, in: ctx)

        let soloA = DeviceMacro.create(name: "Bank A", lsbValue: 0, pcValue: 1, in: ctx)
        soloA.category = category
        let soloB = DeviceMacro.create(name: "Volume Up", ccNumber: 7, ccValue: 100, in: ctx)
        soloB.category = category

        let group = DeviceMacro.create(name: "Full Init", in: ctx)
        group.isGroup = true
        group.setChildMacros([soloA, soloB])
        group.category = category

        let songNames = ["Clocks", "Fix You", "The Scientist", "Yellow", "Speed of Sound"]
        let songs = songNames.map { Song.create(name: $0, in: ctx) }
        let setList = SetList.create(name: "Coldplay Night", in: ctx)
        songs.forEach { setList.addSong($0) }

        return Fixture(setList: setList, songs: songs,
                       soloA: soloA, soloB: soloB, groupMacro: group,
                       device: device, category: category)
    }

    /// Replicates the stamp logic from QuickMacrosPickerView.addMacro and Song.applyMacroDrift.
    private func addMacro(_ macro: DeviceMacro, to song: Song, snapshot: Int = 0) {
        let commands = macro.toMIDICommands(in: ctx)
        let groupInstanceID = macro.isGroup ? UUID().uuidString : nil
        for command in commands {
            command.sourceMacro = macro
            command.sourceGroupInstanceID = groupInstanceID
            song.addCommand(command, toSnapshot: snapshot)
        }
    }

    // MARK: Fixture validation

    @Test func fixture_hasFiveSongsInSetList() {
        let f = makeFixture()
        #expect(f.setList.songs.count == 5)
        #expect(f.songs.map(\.name) == ["Clocks", "Fix You", "The Scientist", "Yellow", "Speed of Sound"])
    }

    @Test func fixture_groupHasTwoChildren() {
        let f = makeFixture()
        #expect(f.groupMacro.isGroup)
        #expect(f.groupMacro.childMacros.count == 2)
    }

    @Test func fixture_groupExpandsToThreeCommands() {
        let f = makeFixture()
        // soloA → LSB + PC = 2 commands; soloB → CC = 1 command
        #expect(f.groupMacro.toMIDICommands(in: ctx).count == 3)
    }

    // MARK: sourceGroupInstanceID stamping

    @Test func groupMacro_allCommandsShareSameInstanceID() {
        let f = makeFixture()
        let song = f.songs[0]
        addMacro(f.groupMacro, to: song)
        let cmds = song.commands(inSnapshot: 0)
        #expect(cmds.count == 3)
        #expect(cmds.allSatisfy { $0.sourceGroupInstanceID != nil })
        #expect(Set(cmds.compactMap(\.sourceGroupInstanceID)).count == 1)
    }

    @Test func groupMacro_addedTwice_givesDifferentInstanceIDs() {
        let f = makeFixture()
        let song = f.songs[0]
        addMacro(f.groupMacro, to: song)
        addMacro(f.groupMacro, to: song)
        let ids = Set(song.commands(inSnapshot: 0).compactMap(\.sourceGroupInstanceID))
        #expect(ids.count == 2)
    }

    @Test func soloMacro_hasNilInstanceID() {
        let f = makeFixture()
        let song = f.songs[1]
        addMacro(f.soloA, to: song)
        let cmds = song.commands(inSnapshot: 0)
        #expect(cmds.allSatisfy { $0.sourceGroupInstanceID == nil })
    }

    // MARK: duplicateSnapshot preserves instanceID

    @Test func duplicateSnapshot_copiesGroupInstanceID() throws {
        let f = makeFixture()
        let song = f.songs[2]
        addMacro(f.groupMacro, to: song)
        try ctx.save()
        let originalIDs = song.commands(inSnapshot: 0).compactMap(\.sourceGroupInstanceID)

        _ = song.duplicateSnapshot(0, in: ctx)

        #expect(song.commands(inSnapshot: 1).compactMap(\.sourceGroupInstanceID) == originalIDs)
    }

    @Test func duplicateSnapshot_soloCommandsRetainNilInstanceID() throws {
        let f = makeFixture()
        let song = f.songs[3]
        addMacro(f.soloB, to: song)
        try ctx.save()

        _ = song.duplicateSnapshot(0, in: ctx)

        #expect(song.commands(inSnapshot: 1).allSatisfy { $0.sourceGroupInstanceID == nil })
    }

    // MARK: Mixed snapshot (group + solo in same snapshot)

    @Test func mixedSnapshot_groupCommandsHaveInstanceID_soloDoesNot() {
        let f = makeFixture()
        let song = f.songs[4]
        addMacro(f.groupMacro, to: song)  // 3 commands with instanceID
        addMacro(f.soloB, to: song)        // 1 command, nil instanceID

        let cmds = song.commands(inSnapshot: 0)
        #expect(cmds.count == 4)
        #expect(cmds.filter { $0.sourceGroupInstanceID != nil }.count == 3)
        #expect(cmds.filter { $0.sourceGroupInstanceID == nil }.count == 1)
    }
}
