//
//  SongAppIntents.swift
//  Midi Set List
//

import AppIntents
import UniformTypeIdentifiers
import CoreData
import Foundation

// MARK: - SongEntity

struct SongEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Song")
    static let defaultQuery = SongEntityQuery()

    var id: UUID
    var name: String
    var artist: String?

    var displayRepresentation: DisplayRepresentation {
        if let artist, !artist.isEmpty {
            return DisplayRepresentation(
                title: LocalizedStringResource(stringLiteral: name),
                subtitle: LocalizedStringResource(stringLiteral: artist)
            )
        }
        return DisplayRepresentation(title: LocalizedStringResource(stringLiteral: name))
    }
}

struct SongEntityQuery: EntityQuery {
    func entities(for identifiers: [UUID]) async throws -> [SongEntity] {
        try await MainActor.run {
            let ctx = PersistenceController.shared.viewContext
            let request = NSFetchRequest<Song>(entityName: "Song")
            let all = try ctx.fetch(request)
            return all.filter { identifiers.contains($0.id) }
                .map { SongEntity(id: $0.id, name: $0.name, artist: $0.artist) }
        }
    }

    func suggestedEntities() async throws -> [SongEntity] {
        try await MainActor.run {
            let ctx = PersistenceController.shared.viewContext
            let request = NSFetchRequest<Song>(entityName: "Song")
            request.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
            return try ctx.fetch(request)
                .map { SongEntity(id: $0.id, name: $0.name, artist: $0.artist) }
        }
    }
}

// MARK: - Create Song Intent

/// Where Create Song gets the song's details from
enum SongDetailsSourceAppEnum: String, AppEnum {
    case manual, text, file

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Song Details")
    static let caseDisplayRepresentations: [SongDetailsSourceAppEnum: DisplayRepresentation] = [
        .manual: DisplayRepresentation(title: "Enter Myself", image: .init(systemName: "keyboard")),
        .text: DisplayRepresentation(title: "From Text with AI", image: .init(systemName: "text.badge.star")),
        .file: DisplayRepresentation(title: "From File with AI", image: .init(systemName: "doc.badge.gearshape")),
    ]
}

struct CreateSongIntent: AppIntent {
    static let title: LocalizedStringResource = "Create Song"
    static let description = IntentDescription(
        "Creates a new song in your Complete Control library. Enter the details yourself, or let AI read the title, key, scale, BPM, genre and lyrics from text (a chord chart, lyric sheet, or just a name and artist) or from a file (text, PDF, or a photo of a chart)."
    )

    @Parameter(title: "Song Details", description: "Enter the details yourself, or have AI read them from text or a file.",
               default: .manual)
    var source: SongDetailsSourceAppEnum

    @Parameter(title: "Song Name", description: "e.g. Wonderwall, Africa, Comfortably Numb")
    var songName: String?

    @Parameter(title: "Text", description: "A chord chart, lyric sheet, or just a song name and artist.",
               inputOptions: String.IntentInputOptions(multiline: true))
    var sourceText: String?

    @Parameter(title: "File", description: "A text file, RTF, PDF, or photo of a chord chart or lyric sheet.",
               supportedContentTypes: [.plainText, .text, .rtf, .pdf, .image])
    var sourceFile: IntentFile?

    @Parameter(title: "Artist", description: "e.g. Oasis, Toto (optional)")
    var artist: String?

    @Parameter(title: "BPM", description: "Tempo in beats per minute, used for MIDI clock. Leave empty to skip.")
    var bpm: Int?

    @Parameter(title: "Time Signature",
               description: "Beats per bar, e.g. 4/4, 3/4 or 6/8. Leave empty to use the default from Settings, if one is set.")
    var timeSignature: TimeSignatureAppEnum?

    @Parameter(title: "Key", description: "Root note of the song's key, e.g. A or F♯. Leave empty to skip.")
    var keyRoot: KeyRootAppEnum?

    @Parameter(title: "Scale", description: "e.g. Major, Minor, Blues, Minor Pentatonic. Used with Key; defaults to Major.")
    var keyScale: KeyScaleAppEnum?

    static var parameterSummary: some ParameterSummary {
        Switch(\.$source) {
            Case(.text) {
                Summary("Create a song from \(\.$sourceText) (\(\.$source))")
            }
            Case(.file) {
                Summary("Create a song from \(\.$sourceFile) (\(\.$source))")
            }
            DefaultCase {
                Summary("Create \(\.$songName) (\(\.$source))") {
                    \.$artist
                    \.$bpm
                    \.$timeSignature
                    \.$keyRoot
                    \.$keyScale
                }
            }
        }
    }

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<SongEntity> {
        var details = SongDetails()

        switch source {
        case .manual:
            guard let name = songName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
                throw $songName.needsValueError("What's the song called?")
            }
            details.title = name
            details.artist = artist
            details.bpm = bpm
            details.timeSignature = timeSignature?.rawValue
            details.key = keyRoot.map { MusicalKey(root: $0.rawValue, scale: keyScale?.scale ?? .major) }

        case .text:
            guard let text = sourceText, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw $sourceText.needsValueError("What text should I read the song from?")
            }
            details = try await SongDetailsAI.extract(from: text)

        case .file:
            guard let file = sourceFile else {
                throw $sourceFile.needsValueError("Which file should I read the song from?")
            }
            let text = try await SongDetailsAI.text(fromFile: file.data, type: file.type, filename: file.filename)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw SongDetailsError.unreadableFile
            }
            details = try await SongDetailsAI.extract(from: text)
            // A file named after the song is a fair title when the contents don't give one
            if details.title == nil {
                let base = (file.filename as NSString).deletingPathExtension
                if !base.isEmpty { details.title = base }
            }
        }

        guard let title = details.title else { throw SongDetailsError.noTitle }
        // Not given and AI wasn't confident: the Settings default, else left unset
        if details.timeSignature == nil { details.timeSignature = SongDefaults.timeSignature }
        let result = details
        let entity = try await MainActor.run {
            let ctx = PersistenceController.shared.viewContext
            let song = Song.create(name: title, artist: result.artist, lyrics: result.lyrics, bpm: result.bpm,
                                   timeSignature: result.timeSignature, in: ctx)
            song.originalKey = result.key
            if !result.genres.isEmpty { song.setGenres(result.genres) }
            try ctx.save()
            return SongEntity(id: song.id, name: song.name, artist: song.artist)
        }
        return .result(value: entity, dialog: IntentDialog(stringLiteral: Self.summary(title: title, details: result)))
    }

    /// "Created 'Wonderwall' by Oasis — F♯ Minor, 87 BPM, 4/4, Rock, with lyrics."
    private static func summary(title: String, details: SongDetails) -> String {
        var text = "Created '\(title)'"
        if let artist = details.artist { text += " by \(artist)" }
        var parts: [String] = []
        if let key = details.key { parts.append(key.displayName) }
        if let bpm = details.bpm { parts.append("\(bpm) BPM") }
        if let timeSignature = details.timeSignature { parts.append(timeSignature) }
        if !details.genres.isEmpty { parts.append(details.genres.joined(separator: "/")) }
        if details.lyrics != nil { parts.append("with lyrics") }
        return parts.isEmpty ? text + "." : text + " — " + parts.joined(separator: ", ") + "."
    }
}

// MARK: - Time signature parameter

enum TimeSignatureAppEnum: String, AppEnum {
    case twoFour = "2/4", threeFour = "3/4", fourFour = "4/4", fiveFour = "5/4"
    case sixEight = "6/8", sevenEight = "7/8", nineEight = "9/8", twelveEight = "12/8"

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Time Signature")
    static let caseDisplayRepresentations: [TimeSignatureAppEnum: DisplayRepresentation] = [
        .twoFour: "2/4", .threeFour: "3/4", .fourFour: "4/4", .fiveFour: "5/4",
        .sixEight: "6/8", .sevenEight: "7/8", .nineEight: "9/8", .twelveEight: "12/8",
    ]
}

// MARK: - Key parameters

enum KeyRootAppEnum: String, AppEnum {
    case c = "C", cSharp = "C#", dFlat = "Db", d = "D", dSharp = "D#", eFlat = "Eb", e = "E", f = "F"
    case fSharp = "F#", gFlat = "Gb", g = "G", gSharp = "G#", aFlat = "Ab", a = "A", aSharp = "A#", bFlat = "Bb", b = "B"

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Key")
    static let caseDisplayRepresentations: [KeyRootAppEnum: DisplayRepresentation] = [
        .c: "C", .cSharp: "C♯", .dFlat: "D♭", .d: "D", .dSharp: "D♯", .eFlat: "E♭", .e: "E", .f: "F",
        .fSharp: "F♯", .gFlat: "G♭", .g: "G", .gSharp: "G♯", .aFlat: "A♭", .a: "A", .aSharp: "A♯", .bFlat: "B♭", .b: "B",
    ]
}

enum KeyScaleAppEnum: String, AppEnum {
    case major, minor, harmonicMinor, melodicMinor, majorPentatonic, minorPentatonic, blues
    case dorian, phrygian, lydian, mixolydian, locrian

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Scale")
    static let caseDisplayRepresentations: [KeyScaleAppEnum: DisplayRepresentation] = [
        .major: "Major", .minor: "Minor", .harmonicMinor: "Harmonic Minor", .melodicMinor: "Melodic Minor",
        .majorPentatonic: "Major Pentatonic", .minorPentatonic: "Minor Pentatonic", .blues: "Blues",
        .dorian: "Dorian", .phrygian: "Phrygian", .lydian: "Lydian", .mixolydian: "Mixolydian", .locrian: "Locrian",
    ]

    var scale: MusicalScale {
        switch self {
        case .major: .major
        case .minor: .minor
        case .harmonicMinor: .harmonicMinor
        case .melodicMinor: .melodicMinor
        case .majorPentatonic: .majorPentatonic
        case .minorPentatonic: .minorPentatonic
        case .blues: .blues
        case .dorian: .dorian
        case .phrygian: .phrygian
        case .lydian: .lydian
        case .mixolydian: .mixolydian
        case .locrian: .locrian
        }
    }
}

// MARK: - Add Lyrics to Song Intent

struct AddLyricsToSongIntent: AppIntent {
    static let title: LocalizedStringResource = "Add Lyrics to Song"
    static let description = IntentDescription(
        "Sets the lyrics for an existing song. The song must already exist in your library. Replaces any existing lyrics."
    )

    @Parameter(title: "Song", description: "The song to add lyrics to — must already exist in your library.")
    var song: SongEntity

    @Parameter(title: "Lyrics", description: "The full lyrics text for the song.")
    var lyrics: String

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<SongEntity> {
        let songID = song.id; let songName = song.name; let lyricsText = lyrics
        let entity = try await MainActor.run {
            let ctx = PersistenceController.shared.viewContext
            let request = NSFetchRequest<Song>(entityName: "Song")
            request.predicate = NSPredicate(format: "id == %@", songID as CVarArg)
            request.fetchLimit = 1
            guard let songRecord = try ctx.fetch(request).first else {
                throw SongIntentError.songNotFound(songName)
            }
            songRecord.lyrics = lyricsText
            songRecord.dateModified = Date()
            try ctx.save()
            return SongEntity(id: songRecord.id, name: songRecord.name, artist: songRecord.artist)
        }
        return .result(value: entity, dialog: "Added lyrics to '\(entity.name)'.")
    }
}

// MARK: - Errors

enum SongIntentError: Error, LocalizedError {
    case songNotFound(String)

    var errorDescription: String? {
        switch self {
        case .songNotFound(let name):
            return "No song named '\(name)' was found. Create it first using the Create Song shortcut or the Songs tab."
        }
    }
}
