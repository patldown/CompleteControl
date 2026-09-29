//
//  SongAppIntents.swift
//  Midi Set List
//

import AppIntents
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

struct CreateSongIntent: AppIntent {
    static let title: LocalizedStringResource = "Create Song"
    static let description = IntentDescription(
        "Creates a new song in your Midi Set List library. You can then add MIDI commands, lyrics, and clock settings to it."
    )

    @Parameter(title: "Song Name", description: "e.g. Wonderwall, Africa, Comfortably Numb")
    var songName: String

    @Parameter(title: "Artist", description: "e.g. Oasis, Toto (optional)")
    var artist: String?

    @Parameter(title: "BPM", description: "Tempo in beats per minute, used for MIDI clock. Leave empty to skip.")
    var bpm: Int?

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<SongEntity> {
        let name = songName; let bpmVal = bpm; let artistVal = artist
        let entity = try await MainActor.run {
            let ctx = PersistenceController.shared.viewContext
            let song = Song.create(name: name, artist: artistVal, in: ctx)
            if let bpmVal { song.bpm = bpmVal }
            try ctx.save()
            return SongEntity(id: song.id, name: song.name, artist: song.artist)
        }
        let artistPart = artist.map { " by \($0)" } ?? ""
        return .result(value: entity, dialog: "Created '\(songName)'\(artistPart).")
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
