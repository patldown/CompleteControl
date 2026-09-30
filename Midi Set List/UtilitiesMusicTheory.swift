//
//  MusicTheory.swift
//  Midi Set List
//
//  Song keys, chord detection in lyrics, and transposing. Transposing is display-only:
//  the saved lyrics keep their original chords and the song stores an offset.
//

import Foundation

// MARK: - Notes

enum NoteName {
    /// Root spellings offered in pickers, in pitch order
    static let pickerRoots = ["C", "C#", "Db", "D", "D#", "Eb", "E", "F", "F#", "Gb",
                              "G", "G#", "Ab", "A", "A#", "Bb", "B"]

    private static let sharps = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
    private static let flats  = ["C", "Db", "D", "Eb", "E", "F", "Gb", "G", "Ab", "A", "Bb", "B"]
    private static let letters: [Character: Int] = ["C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11]

    /// Pitch class 0–11 for "C", "F#", "Bb", "E♭" …
    static func pitchClass(_ note: String) -> Int? {
        guard let first = note.first, let base = letters[first] else { return nil }
        var pc = base
        for ch in note.dropFirst() {
            switch ch {
            case "#", "♯": pc += 1
            case "b", "♭": pc -= 1
            default: return nil
            }
        }
        return (pc % 12 + 12) % 12
    }

    static func name(_ pitchClass: Int, flats useFlats: Bool) -> String {
        let pc = (pitchClass % 12 + 12) % 12
        return useFlats ? flats[pc] : sharps[pc]
    }

    static func usesFlat(_ note: String) -> Bool {
        note.dropFirst().contains { $0 == "b" || $0 == "♭" }
    }
}

// MARK: - Scales

enum MusicalScale: String, CaseIterable, Identifiable {
    case major = "Major"
    case minor = "Minor"
    case harmonicMinor = "Harmonic Minor"
    case melodicMinor = "Melodic Minor"
    case majorPentatonic = "Major Pentatonic"
    case minorPentatonic = "Minor Pentatonic"
    case blues = "Blues"
    case dorian = "Dorian"
    case phrygian = "Phrygian"
    case lydian = "Lydian"
    case mixolydian = "Mixolydian"
    case locrian = "Locrian"

    var id: String { rawValue }

    /// Minor-sounding scales take minor-key spellings (A minor → no flats, D minor → B♭)
    var isMinor: Bool {
        switch self {
        case .minor, .harmonicMinor, .melodicMinor, .minorPentatonic, .blues, .dorian, .phrygian, .locrian:
            return true
        case .major, .majorPentatonic, .lydian, .mixolydian:
            return false
        }
    }
}

// MARK: - Key

struct MusicalKey: Equatable {
    var root: String
    var scale: MusicalScale

    /// Keys conventionally written with flats (F major, D minor, …)
    private static let flatMajors: Set<Int> = [5, 10, 3, 8, 1]   // F Bb Eb Ab Db
    private static let flatMinors: Set<Int> = [2, 7, 0, 5, 10]   // D G C F Bb

    var pitchClass: Int? { NoteName.pitchClass(root) }

    /// Whether chords in this key read better with flats
    var prefersFlats: Bool {
        guard let pc = pitchClass else { return false }
        if NoteName.usesFlat(root) { return true }
        if root.contains("#") || root.contains("♯") { return false }
        return scale.isMinor ? Self.flatMinors.contains(pc) : Self.flatMajors.contains(pc)
    }

    func transposed(by semitones: Int) -> MusicalKey {
        guard semitones != 0, let pc = pitchClass else { return self }
        let newPC = ((pc + semitones) % 12 + 12) % 12
        // Pick the spelling a musician would expect for the new key
        let asSharp = MusicalKey(root: NoteName.name(newPC, flats: false), scale: scale)
        let asFlat  = MusicalKey(root: NoteName.name(newPC, flats: true), scale: scale)
        if asSharp.root == asFlat.root { return asSharp }
        let flatPreferred = (scale.isMinor ? Self.flatMinors : Self.flatMajors).contains(newPC)
            || (newPC == 6 && NoteName.usesFlat(root))  // F# / Gb: keep the original's side
        return flatPreferred ? asFlat : asSharp
    }

    var displayName: String {
        let pretty = root.replacingOccurrences(of: "#", with: "♯").replacingOccurrences(of: "b", with: "♭")
        return "\(pretty) \(scale.rawValue)"
    }
}

// MARK: - Chords

enum ChordEngine {
    /// Root, quality, extensions, optional (…) and slash bass: A, Am7, Cmaj7, D/F#, Bb7b9, Gsus4, C(add9)
    private static let chordPattern = try! NSRegularExpression(pattern:
        #"^([A-G][#b♯♭]?)((?:maj|min|m|M|dim|aug|sus|°|ø|\+|-)?\d{0,2}(?:(?:add|sus|maj|b|#|♭|♯|\+|-)\d{1,2})*(?:\([^)]*\))?)(?:/([A-G][#b♯♭]?))?$"#)
    /// Tokens that may sit on a chord line without making it a lyric line: | / - % x2 (x4) N.C.
    private static let neutralPattern = try! NSRegularExpression(pattern:
        #"^(?:\|+:?|:?\|+|/|-+|%|\(?[x×]\d+\)?|\(?\d+[x×]\)?|N\.?C\.?|\.+|:)$"#, options: [.caseInsensitive])
    private static let tokenPattern = try! NSRegularExpression(pattern: #"\S+"#)
    private static let inlinePattern = try! NSRegularExpression(pattern: #"\[([^\]\n]+)\]"#)

    static func isChord(_ token: String) -> Bool {
        let range = NSRange(token.startIndex..., in: token)
        return chordPattern.firstMatch(in: token, range: range) != nil
    }

    private static func isNeutral(_ token: String) -> Bool {
        neutralPattern.firstMatch(in: token, range: NSRange(token.startIndex..., in: token)) != nil
    }

    /// Transposes one chord symbol. Returns nil if it isn't a chord.
    static func transpose(_ chord: String, by semitones: Int, flats: Bool?) -> String? {
        let ns = chord as NSString
        guard let m = chordPattern.firstMatch(in: chord, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let root = ns.substring(with: m.range(at: 1))
        let quality = ns.substring(with: m.range(at: 2))
        let bass = m.range(at: 3).location != NSNotFound ? ns.substring(with: m.range(at: 3)) : nil
        guard semitones != 0 else { return chord }

        // Key-driven spelling if known; otherwise keep the chord's own accidental, or flats going down
        let useFlats = flats ?? (NoteName.usesFlat(root) || (!root.contains("#") && !root.contains("♯") && semitones < 0))
        func shift(_ note: String) -> String {
            guard let pc = NoteName.pitchClass(note) else { return note }
            return NoteName.name(pc + semitones, flats: useFlats)
        }
        return shift(root) + quality + (bass.map { "/" + shift($0) } ?? "")
    }

    struct Rendered {
        var text: String
        /// UTF-16 ranges of recognised chords in `text`
        var chordRanges: [NSRange]
    }

    /// Finds chords — whole chord lines and inline [G] — transposes them, and keeps chord
    /// lines lined up over the lyric below.
    static func render(_ text: String, transpose semitones: Int, flats: Bool?) -> Rendered {
        var output = ""
        var ranges: [NSRange] = []
        var outLength = 0  // UTF-16 length of `output`

        let lines = text.components(separatedBy: "\n")
        for (i, line) in lines.enumerated() {
            let ns = line as NSString
            let tokens = tokenPattern.matches(in: line, range: NSRange(location: 0, length: ns.length))
            let words = tokens.map { ns.substring(with: $0.range) }

            // A chord line: every token is a chord (bare or in parentheses) or neutral, and at least one chord
            func core(_ w: String) -> String {
                w.count > 2 && w.hasPrefix("(") && w.hasSuffix(")") ? String(w.dropFirst().dropLast()) : w
            }
            let chordFlags = words.map { isChord(core($0)) }
            let isChordLine = !words.isEmpty && chordFlags.contains(true)
                && zip(words, chordFlags).allSatisfy { $1 || isNeutral($0) }

            var lineOut = ""
            if isChordLine {
                for (t, match) in tokens.enumerated() {
                    // Keep each chord at its original column when there's room
                    let targetColumn = match.range.location
                    let currentColumn = (lineOut as NSString).length
                    let gap = max(targetColumn - currentColumn, t == 0 ? 0 : 1)
                    lineOut += String(repeating: " ", count: gap)

                    let word = words[t]
                    if chordFlags[t] {
                        let inner = core(word)
                        let wrapped = inner != word
                        let moved = transpose(inner, by: semitones, flats: flats) ?? inner
                        if wrapped { lineOut += "(" }
                        ranges.append(NSRange(location: outLength + (lineOut as NSString).length,
                                              length: (moved as NSString).length))
                        lineOut += moved
                        if wrapped { lineOut += ")" }
                    } else {
                        lineOut += word
                    }
                }
            } else {
                // Lyric line: only [Chord] brackets count; [Chorus] and friends are left alone
                var cursor = 0
                for m in inlinePattern.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
                    let inner = ns.substring(with: m.range(at: 1))
                    guard isChord(inner) else { continue }
                    lineOut += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
                    let moved = transpose(inner, by: semitones, flats: flats) ?? inner
                    lineOut += "["
                    ranges.append(NSRange(location: outLength + (lineOut as NSString).length,
                                          length: (moved as NSString).length))
                    lineOut += moved + "]"
                    cursor = m.range.location + m.range.length
                }
                lineOut += ns.substring(from: cursor)
            }

            output += lineOut
            outLength += (lineOut as NSString).length
            if i < lines.count - 1 {
                output += "\n"
                outLength += 1
            }
        }
        return Rendered(text: output, chordRanges: ranges)
    }
}
