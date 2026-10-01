//
//  ChordPro.swift
//  Midi Set List
//
//  Import and export of ChordPro (.cho, .chordpro, .chopro, .crd, .pro) — the format
//  OnSong, Songbook Pro, Ultimate Guitar and most chord apps read and write — plus plain
//  text chord charts.
//
//  ChordPro puts chords inline ("[G]Sweet home [C]Alabama"); charts here are chord lines
//  over lyric lines. Import turns inline chords into a chord line above the words, so they
//  read the same as every other chart; export turns them back.
//

import CoreData
import Foundation
import UniformTypeIdentifiers

extension UTType {
    static let chordPro = UTType(importedAs: "org.chordpro.chordpro")
}

enum ChordPro {

    struct ParsedSong {
        var title: String?
        var artist: String?
        var key: MusicalKey?
        var bpm: Int?
        var timeSignature: String?
        var capo: Int?
        var lyrics: String
    }

    private static let directivePattern = try! NSRegularExpression(
        pattern: #"^\s*\{\s*([A-Za-z_]+)\s*(?:[:\s]\s*(.*?))?\s*\}\s*$"#)
    private static let inlineChordPattern = try! NSRegularExpression(pattern: #"\[([^\]\n]+)\]"#)
    private static let headingPattern = try! NSRegularExpression(pattern: #"^\s*\[([^\]]+)\]\s*$"#)

    /// True when the text uses ChordPro directives or inline chords
    static func looksLikeChordPro(_ text: String) -> Bool {
        let lines = text.components(separatedBy: .newlines)
        return lines.contains { line in
            let range = NSRange(location: 0, length: (line as NSString).length)
            if directivePattern.firstMatch(in: line, range: range) != nil { return true }
            // An inline chord sitting in a lyric line, not a lone [Chorus] heading
            return inlineChordPattern.matches(in: line, range: range).contains { match in
                ChordEngine.isChord((line as NSString).substring(with: match.range(at: 1)))
            } && headingPattern.firstMatch(in: line, range: range) == nil
        }
    }

    // MARK: Import

    static func parse(_ input: String) -> ParsedSong {
        let text = input.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var song = ParsedSong(lyrics: "")
        var out: [String] = []
        var inTab = false

        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("#") { continue }   // ChordPro comment for editors, not the chart
            let ns = line as NSString
            if let match = directivePattern.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
                let name = ns.substring(with: match.range(at: 1)).lowercased()
                let value = match.range(at: 2).location == NSNotFound
                    ? "" : ns.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespaces)
                switch name {
                case "title", "t": song.title = nonEmpty(value)
                case "artist", "subtitle", "st", "su":
                    if song.artist == nil { song.artist = nonEmpty(value) }
                case "key": song.key = key(from: value)
                case "tempo": song.bpm = Int(value.prefix { $0.isNumber }).flatMap { (20...300).contains($0) ? $0 : nil }
                case "time": song.timeSignature = value.range(of: #"^\d{1,2}/\d{1,2}$"#, options: .regularExpression) != nil ? value : nil
                case "capo": song.capo = Int(value).flatMap { (0...12).contains($0) ? $0 : nil }
                case "comment", "c", "comment_italic", "ci", "comment_box", "cb", "highlight":
                    if let value = nonEmpty(value) { out.append(value) }
                case "start_of_chorus", "soc": out.append("[\(nonEmpty(value) ?? "Chorus")]")
                case "start_of_verse", "sov": out.append("[\(nonEmpty(value) ?? "Verse")]")
                case "start_of_bridge", "sob": out.append("[\(nonEmpty(value) ?? "Bridge")]")
                case "chorus": out.append("[Chorus]")
                case "start_of_tab", "sot":
                    inTab = true
                    if let value = nonEmpty(value) { out.append("[\(value)]") }
                case "end_of_tab", "eot": inTab = false
                default: break   // end_of_chorus, page breaks, fonts…: nothing to show
                }
                continue
            }
            if !inTab, let split = chordsOverLyrics(line) {
                out.append(contentsOf: split)
            } else {
                out.append(line)
            }
        }

        song.lyrics = out.joined(separator: "\n").trimmingCharacters(in: .newlines)
        return song
    }

    /// "[G]Sweet home [C]Alabama" → "G          C" over "Sweet home Alabama".
    /// Nil when the line has no inline chords. Brackets that aren't chords stay as text.
    static func chordsOverLyrics(_ line: String) -> [String]? {
        let ns = line as NSString
        var chordLine = ""
        var lyric = ""
        var cursor = 0
        var found = false
        for match in inlineChordPattern.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
            let chord = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
            guard ChordEngine.isChord(chord) else { continue }
            lyric += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            cursor = match.range.location + match.range.length
            // The previous chord runs past here: push the words along so chords never touch
            if !chordLine.isEmpty, chordLine.count >= lyric.count {
                lyric += String(repeating: " ", count: chordLine.count + 1 - lyric.count)
            }
            chordLine += String(repeating: " ", count: max(0, lyric.count - chordLine.count))
            chordLine += chord
            found = true
        }
        guard found else { return nil }
        lyric += ns.substring(from: cursor)
        let words = String(lyric.reversed().drop(while: \.isWhitespace).reversed())
        return words.isEmpty ? [chordLine] : [chordLine, words]
    }

    /// "F#m" → F♯ Minor, "Bb" → B♭ Major
    static func key(from text: String) -> MusicalKey? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first else { return nil }
        var rootText = String(first)
        var rest = trimmed.dropFirst()
        if let accidental = rest.first, "#b♯♭".contains(accidental) {
            rootText.append(accidental)
            rest = rest.dropFirst()
        }
        guard let root = SongDetailsAI.normalizedRoot(rootText) else { return nil }
        let quality = rest.lowercased().trimmingCharacters(in: .whitespaces)
        let isMinor = quality.hasPrefix("min") || (quality.hasPrefix("m") && !quality.hasPrefix("maj"))
        return MusicalKey(root: root, scale: isMinor ? .minor : .major)
    }

    private static func nonEmpty(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: Export

    static func export(_ song: Song) -> String {
        var out: [String] = ["{title: \(song.name)}"]
        if let artist = song.artist, !artist.isEmpty { out.append("{artist: \(artist)}") }
        if let key = song.originalKey { out.append("{key: \(chordProKey(key))}") }
        if let bpm = song.bpm { out.append("{tempo: \(bpm)}") }
        if let time = song.timeSignature { out.append("{time: \(time)}") }
        if song.capoEnabled, song.capo > 0 { out.append("{capo: \(song.capo)}") }
        out.append("")
        out.append(contentsOf: inlineChords(song.lyrics ?? ""))
        return out.joined(separator: "\n") + "\n"
    }

    /// Chord lines over lyric lines → inline chords; [Chorus]-style headings → comments
    static func inlineChords(_ chart: String) -> [String] {
        let lines = chart.components(separatedBy: .newlines)
        var out: [String] = []
        var i = 0
        while i < lines.count {
            let line = lines[i]
            if let heading = heading(line) {
                out.append("{comment: \(heading)}")
                i += 1
                continue
            }
            if let chords = ChordEngine.chordLineTokens(line) {
                let next = i + 1 < lines.count ? lines[i + 1] : nil
                if let next, !next.trimmingCharacters(in: .whitespaces).isEmpty,
                   ChordEngine.chordLineTokens(next) == nil, heading(next) == nil {
                    out.append(insert(chords, into: next))
                    i += 2
                } else {
                    out.append(insert(chords, into: ""))
                    i += 1
                }
                continue
            }
            out.append(line)
            i += 1
        }
        return out
    }

    private static func heading(_ line: String) -> String? {
        let ns = line as NSString
        guard let match = headingPattern.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let inner = ns.substring(with: match.range(at: 1))
        return ChordEngine.isChord(inner) ? nil : inner
    }

    private static func insert(_ chords: [(column: Int, chord: String)], into lyric: String) -> String {
        var characters = Array(lyric)
        if let last = chords.map(\.column).max(), characters.count < last {
            characters += Array(repeating: " ", count: last - characters.count)
        }
        for (column, chord) in chords.sorted(by: { $0.column > $1.column }) {
            characters.insert(contentsOf: Array("[\(chord)]"), at: column)
        }
        return String(String(characters).reversed().drop(while: \.isWhitespace).reversed())
    }

    /// ChordPro keys are written like chords: "F#m", "Bb"
    private static func chordProKey(_ key: MusicalKey) -> String {
        key.root + (key.scale.rawValue.contains("Minor") ? "m" : "")
    }

    static func fileName(for song: Song) -> String {
        let base = [song.artist, song.name].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " - ")
        let safe = base.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>")).joined(separator: "-")
        return (safe.isEmpty ? "Song" : safe) + ".cho"
    }

    // MARK: Files

    struct ImportSummary {
        var added: [String] = []
        var skipped: [String] = []
        var failed: [String] = []

        var message: String {
            var parts: [String] = []
            if !added.isEmpty { parts.append("Added \(added.count) song\(added.count == 1 ? "" : "s").") }
            if !skipped.isEmpty {
                parts.append("Skipped \(skipped.count) already in your library: \(skipped.prefix(5).joined(separator: ", "))\(skipped.count > 5 ? "…" : "").")
            }
            if !failed.isEmpty { parts.append("Couldn't read: \(failed.joined(separator: ", ")).") }
            return parts.isEmpty ? "Nothing to import." : parts.joined(separator: "\n\n")
        }
    }

    /// Adds a song per file. ChordPro files bring their title, artist, key, tempo, time
    /// signature and capo; plain charts are named after the file. A song already in the
    /// library (same name and artist) is skipped, never overwritten.
    static func importFiles(_ urls: [URL], context: NSManagedObjectContext) throws -> ImportSummary {
        var summary = ImportSummary()
        let existing = try context.fetch(NSFetchRequest<Song>(entityName: "Song"))
        var known = Set(existing.map { identity($0.name, $0.artist) })

        for url in urls {
            let fileTitle = url.deletingPathExtension().lastPathComponent
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url),
                  let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
            else {
                summary.failed.append(url.lastPathComponent)
                continue
            }

            var parsed = looksLikeChordPro(text)
                ? parse(text)
                : ParsedSong(lyrics: text.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .newlines))
            if parsed.title == nil { parsed.title = fileTitle }
            let title = parsed.title ?? fileTitle

            guard known.insert(identity(title, parsed.artist)).inserted else {
                summary.skipped.append(title)
                continue
            }

            let song = Song.create(name: title, artist: parsed.artist,
                                   lyrics: parsed.lyrics.isEmpty ? nil : parsed.lyrics,
                                   bpm: parsed.bpm,
                                   timeSignature: parsed.timeSignature ?? SongDefaults.timeSignature,
                                   in: context)
            song.originalKey = parsed.key
            if let capo = parsed.capo, capo > 0 {
                song.capoEnabled = true
                song.capo = capo
            }
            summary.added.append(title)
        }
        if context.hasChanges { try context.save() }
        return summary
    }

    private static func identity(_ name: String, _ artist: String?) -> String {
        name.trimmingCharacters(in: .whitespaces).lowercased() + "|" + (artist ?? "").trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// Writes one .cho file per song into a fresh temporary folder, for the share sheet
    static func writeFiles(for songs: [Song]) throws -> [URL] {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ChordPro-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var used = Set<String>()
        return try songs.map { song in
            var name = fileName(for: song)
            var n = 2
            while !used.insert(name.lowercased()).inserted {
                name = (fileName(for: song) as NSString).deletingPathExtension + " \(n).cho"
                n += 1
            }
            let url = folder.appendingPathComponent(name)
            try export(song).write(to: url, atomically: true, encoding: .utf8)
            return url
        }
    }
}
