//
//  ChordProTests.swift
//  Midi Set ListTests
//

import Testing
import CoreData
@testable import Midi_Set_List

@Suite("ChordPro")
@MainActor
struct ChordProTests {

    @Test func inlineChordsBecomeAChordLineOverTheWords() {
        let split = ChordPro.chordsOverLyrics("[G]Sweet home [C]Alabama")
        #expect(split == ["G          C", "Sweet home Alabama"])
    }

    @Test func longChordsPushTheWordsAlong() {
        let split = ChordPro.chordsOverLyrics("[Gmaj7]Sw[C]eet")
        #expect(split?[0] == "Gmaj7 C")
        #expect(split?[1].hasPrefix("Sw") == true)
    }

    @Test func directivesFillTheSongDetails() {
        let parsed = ChordPro.parse("""
        {title: Wonderwall}
        {artist: Oasis}
        {key: F#m}
        {tempo: 87}
        {time: 4/4}
        {capo: 2}
        # an editor's note
        {soc}
        [Em7]Today is gonna be the day
        {eoc}
        """)
        #expect(parsed.title == "Wonderwall")
        #expect(parsed.artist == "Oasis")
        #expect(parsed.key == MusicalKey(root: "F#", scale: .minor))
        #expect(parsed.bpm == 87)
        #expect(parsed.timeSignature == "4/4")
        #expect(parsed.capo == 2)
        #expect(parsed.lyrics == "[Chorus]\nEm7\nToday is gonna be the day")
    }

    @Test func exportPutsChordsBackInline() {
        let lines = ChordPro.inlineChords("[Chorus]\nG          C\nSweet home Alabama")
        #expect(lines == ["{comment: Chorus}", "[G]Sweet home [C]Alabama"])
    }

    @Test func importSkipsSongsAlreadyInTheLibrary() throws {
        let ctx = PersistenceController(inMemory: true).viewContext
        _ = Song.create(name: "Wonderwall", artist: "Oasis", in: ctx)
        try ctx.save()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let dupe = folder.appendingPathComponent("a.cho")
        let fresh = folder.appendingPathComponent("b.cho")
        try "{title: Wonderwall}\n{artist: Oasis}".write(to: dupe, atomically: true, encoding: .utf8)
        try "{t: Africa}\n{st: Toto}\n[A]It's gonna take a lot".write(to: fresh, atomically: true, encoding: .utf8)

        let summary = try ChordPro.importFiles([dupe, fresh], context: ctx)
        #expect(summary.added == ["Africa"])
        #expect(summary.skipped == ["Wonderwall"])
    }

    @Test func beatsPerBarCountsTheFeltBeat() {
        let ctx = PersistenceController(inMemory: true).viewContext
        let song = Song.create(name: "Waltz", in: ctx)
        #expect(song.beatsPerBar == 4)
        song.timeSignature = "3/4"; #expect(song.beatsPerBar == 3)
        song.timeSignature = "6/8"; #expect(song.beatsPerBar == 2)
        song.timeSignature = "12/8"; #expect(song.beatsPerBar == 4)
        song.timeSignature = "7/8"; #expect(song.beatsPerBar == 7)
    }
}
