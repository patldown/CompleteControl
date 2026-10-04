//
//  SongDetailsAI.swift
//  Midi Set List
//
//  Reads a song's details — title, artist, key, scale, BPM, genres and lyrics — out of
//  free text (a pasted chart, a name and artist) or a file (text, RTF, PDF or a photo of
//  a chart). Used by the Create Song shortcut's "with AI" options.
//
//  The AI never retypes lyrics: it names the first and last line of the lyrics, and the
//  app copies that span from the original text, so chord lines stay aligned over the words.
//

import CoreData
import Foundation
import FoundationModels
import PDFKit
import UIKit
import UniformTypeIdentifiers
import Vision

// MARK: - On-device structured output

@Generable
struct GeneratedSongDetails {
    @Guide(description: "The song's title. Empty if the text doesn't say or clearly imply one.")
    var title: String
    @Guide(description: "Artist or band. Empty if unknown.")
    var artist: String
    @Guide(description: "Root note of the key, like A, F#, Bb. Empty if not stated and not confidently known.")
    var keyRoot: String
    @Guide(description: "Scale of the key: Major, Minor, Blues, Dorian, Mixolydian, etc. Empty if unknown.")
    var scale: String
    @Guide(description: "Tempo in beats per minute. 0 if not stated and not confidently known.")
    var bpm: Int
    @Guide(description: "Time signature like 4/4, 3/4 or 6/8, from the text or from knowing the song. Empty if not confident.")
    var timeSignature: String
    @Guide(description: "Genres, only from the allowed list. Empty if unsure.")
    var genres: [String]
    @Guide(description: "The first line of the lyrics or chord chart, copied exactly from the text. Empty if the text has no lyrics.")
    var lyricsFirstLine: String
    @Guide(description: "The last line of the lyrics or chord chart, copied exactly from the text. Empty if the text has no lyrics.")
    var lyricsLastLine: String
}

// MARK: - Result

struct SongDetails {
    var title: String?
    var artist: String?
    var key: MusicalKey?
    var bpm: Int?
    /// "4/4", "6/8"…; nil when not written and the AI wasn't confident
    var timeSignature: String?
    var genres: [String] = []
    var lyrics: String?
}

enum SongDetailsError: Error, LocalizedError {
    case aiUnavailable
    case emptyInput
    case unreadableFile
    case noTitle
    case badResponse(String)

    var errorDescription: String? {
        switch self {
        case .aiUnavailable:
            return "No AI is available. Turn on Apple Intelligence, or add a Claude or ChatGPT key in Settings › AI."
        case .emptyInput:
            return "There's no text to read song details from."
        case .unreadableFile:
            return "Couldn't read any text from that file. Try a text file, PDF, or a clear photo of the chart."
        case .noTitle:
            return "Couldn't find a song title. Include the song's name in the text, or use Enter Myself."
        case .badResponse(let text):
            return "Couldn't read the AI's answer: \(text.prefix(200))"
        }
    }
}

// MARK: - Extraction

enum SongDetailsAI {

    /// On-device models have a small context window; keep their input well inside it
    private static let onDeviceInputLimit = 6_000
    private static let externalInputLimit = 60_000

    static var instructions: String {
        """
        You read song details out of text a musician gives you: a pasted chord chart or lyric \
        sheet, a file's contents, or just a song name and artist.

        - title and artist: from the text. If the text is only a name and artist, use those.
        - keyRoot and scale: use a key written in the text (e.g. "Key: F#m" → F#, Minor). If none \
        is written, give the song's well-known key only if you are confident; otherwise leave empty. \
        Write sharps as # and flats as b.
        - bpm: a tempo written in the text, or the song's well-known tempo if you are confident. 0 otherwise.
        - timeSignature: one written in the text (e.g. "6/8"). If none is written but you recognise \
        the song, give its time signature from what you know of it — most well-known pop and rock \
        songs are 4/4; waltzes and many ballads are 3/4 or 6/8. If you don't recognise the song or \
        aren't confident, leave it empty — never guess.
        - genres: only from this list: \(Song.predefinedGenres.joined(separator: ", ")).
        - lyricsFirstLine: the very first non-header line of the body, copied exactly — even if it \
        is only chord names like "D  C  G". In a chord/lyric chart the first line is often a chord \
        row above the first lyric; that chord row IS lyricsFirstLine. Skip only header lines \
        (title, artist, key, tempo, BPM, capo, time signature). Never write from memory.
        - lyricsLastLine: the very last line of the body, copied exactly. If the text has no lyrics \
        or chord chart, leave both fields empty.
        """
    }

    static let jsonFormat = """

        Respond ONLY with a JSON object — no markdown fences, no explanation:
        {"title": "", "artist": "", "keyRoot": "", "scale": "", "bpm": 0, "timeSignature": "", "genres": [], "lyricsFirstLine": "", "lyricsLastLine": ""}
        """

    private struct Raw: Decodable {
        var title: String?
        var artist: String?
        var keyRoot: String?
        var scale: String?
        var bpm: Int?
        var timeSignature: String?
        var genres: [String]?
        var lyricsFirstLine: String?
        var lyricsLastLine: String?

        init(_ g: GeneratedSongDetails) {
            title = g.title; artist = g.artist; keyRoot = g.keyRoot; scale = g.scale; bpm = g.bpm
            timeSignature = g.timeSignature
            genres = g.genres; lyricsFirstLine = g.lyricsFirstLine; lyricsLastLine = g.lyricsLastLine
        }
    }

    static func extract(from input: String) async throws -> SongDetails {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw SongDetailsError.emptyInput }

        let ai = AISettings.shared
        guard ai.isAvailable(.songDetails) else { throw SongDetailsError.aiUnavailable }
        let provider = ai.provider(for: .songDetails)

        func onDevice() async throws -> Raw {
            guard ai.onDeviceAvailable else { throw SongDetailsError.aiUnavailable }
            let session = LanguageModelSession(instructions: instructions)
            let response = try await session.respond(to: String(text.prefix(onDeviceInputLimit)),
                                                     generating: GeneratedSongDetails.self)
            return Raw(response.content)
        }

        let raw: Raw
        if provider == .onDevice {
            raw = try await onDevice()
        } else {
            guard let apiKey = provider == .openAI ? ai.openAIKey : ai.anthropicKey
            else { throw ExternalAIError.notConfigured }
            do {
                let response = try await ExternalAIClient.chat(
                    provider: provider,
                    apiKey: apiKey,
                    systemPrompt: instructions + jsonFormat,
                    messages: [ExternalAIMessage(role: "user", content: String(text.prefix(externalInputLimit)))],
                    workspaceID: provider == .anthropic ? ai.anthropicWorkspaceID : nil,
                    anthropicModelID: ai.anthropicModel(for: .songDetails),
                    anthropicThinking: ai.thinkingEnabled(for: .songDetails)
                )
                let reply = response.text
                guard let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"),
                      let data = String(reply[start...end]).data(using: .utf8),
                      let decoded = try? JSONDecoder().decode(Raw.self, from: data)
                else { throw SongDetailsError.badResponse(reply) }
                raw = decoded
            } catch let error where ExternalAIError.isConnectivity(error) && ai.onDeviceAvailable {
                raw = try await onDevice()
            }
        }
        return details(from: raw, source: text)
    }

    // MARK: Cleaning up the AI's answer

    private static func details(from raw: Raw, source: String) -> SongDetails {
        var details = SongDetails()
        details.title = nonEmpty(raw.title)
        details.artist = nonEmpty(raw.artist)
        if let bpm = raw.bpm, (20...300).contains(bpm) { details.bpm = bpm }
        details.timeSignature = normalizedTimeSignature(raw.timeSignature)

        if let root = normalizedRoot(raw.keyRoot) {
            let scale = raw.scale.flatMap { name in
                MusicalScale.allCases.first { $0.rawValue.caseInsensitiveCompare(name.trimmingCharacters(in: .whitespaces)) == .orderedSame }
            }
            details.key = MusicalKey(root: root, scale: scale ?? .major)
        }

        details.genres = (raw.genres ?? []).compactMap { genre in
            Song.predefinedGenres.first { $0.caseInsensitiveCompare(genre.trimmingCharacters(in: .whitespaces)) == .orderedSame }
        }

        details.lyrics = lyricsSpan(in: source, first: raw.lyricsFirstLine, last: raw.lyricsLastLine)
        return details
    }

    private static func nonEmpty(_ text: String?) -> String? {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    /// "6/8" or " 6 / 8 " → "6/8"; nil unless it's one of the song editor's time signatures
    static func normalizedTimeSignature(_ text: String?) -> String? {
        guard let text = nonEmpty(text) else { return nil }
        let compact = text.filter { !$0.isWhitespace }
        return TimeSignatureAppEnum(rawValue: compact)?.rawValue
    }

    /// "f♯" → "F#", "Bb" → "Bb"; nil unless it's one of the key picker's spellings
    static func normalizedRoot(_ root: String?) -> String? {
        guard let root = nonEmpty(root), let letter = root.first?.uppercased() else { return nil }
        let accidental = root.dropFirst().first.map { ch -> String in
            switch ch {
            case "#", "♯": return "#"
            case "b", "♭": return "b"
            default: return ""
            }
        } ?? ""
        let spelled = letter + accidental
        return NoteName.pickerRoots.contains(spelled) ? spelled : nil
    }

    /// Returns true when a line is a chart header (e.g. "Key: G", "Capo: 2"), so we don't
    /// accidentally absorb header lines when walking back past the AI-identified first line.
    private static let knownHeaderKeywords: Set<String> = [
        "title", "artist", "key", "scale", "tempo", "bpm", "capo",
        "time", "signature", "tuning", "notes", "genre", "composer", "style"
    ]
    private static func isHeaderLine(_ line: String) -> Bool {
        guard let colon = line.firstIndex(of: ":") else { return false }
        let keyword = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
        return knownHeaderKeywords.contains(keyword)
    }

    /// Copies the lyrics from the original text, first line through last line, untouched.
    /// If the AI identified a lyric line as lyricsFirstLine but the line immediately above it
    /// is a chord row (non-blank, not a header), include that chord row too — it was cut off.
    static func lyricsSpan(in source: String, first: String?, last: String?) -> String? {
        guard let first = nonEmpty(first) else { return nil }
        let lines = source.components(separatedBy: .newlines)
        let key = { (line: String) in line.trimmingCharacters(in: .whitespaces).lowercased() }
        guard let found = lines.firstIndex(where: { key($0) == first.lowercased() }) else { return nil }

        // Walk back one line: if the AI named a lyric line, include any chord row sitting
        // directly above it (standard chord/lyric chart format: chords then words).
        var start = found
        if start > 0 {
            let prev = lines[start - 1].trimmingCharacters(in: .whitespaces)
            if !prev.isEmpty && !isHeaderLine(prev) {
                start -= 1
            }
        }

        var end = lines.count - 1
        if let last = nonEmpty(last),
           let lastFound = lines.indices.last(where: { $0 >= start && key(lines[$0]) == last.lowercased() }) {
            end = lastFound
        }
        let span = lines[start...end].joined(separator: "\n").trimmingCharacters(in: .newlines)
        return span.isEmpty ? nil : span
    }

    // MARK: Reading files

    /// Plain text from a text, RTF, PDF or image file (images are read with on-device OCR)
    static func text(fromFile data: Data, type: UTType?, filename: String?) throws -> String {
        let type = type ?? filename.flatMap { UTType(filenameExtension: ($0 as NSString).pathExtension) }

        if type?.conforms(to: .pdf) == true {
            return PDFDocument(data: data)?.string ?? ""
        }
        if type?.conforms(to: .image) == true {
            guard let cgImage = UIImage(data: data)?.cgImage else { throw SongDetailsError.unreadableFile }
            return try recognizeText(in: cgImage)
        }
        if type?.conforms(to: .rtf) == true || type?.conforms(to: .rtfd) == true,
           let attributed = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf],
                                                    documentAttributes: nil) {
            return attributed.string
        }
        if let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) {
            return text
        }
        throw SongDetailsError.unreadableFile
    }

    private static func recognizeText(in cgImage: CGImage) throws -> String {
        var lines: [String] = []
        var failure: Error?
        let request = VNRecognizeTextRequest { request, error in
            if let error { failure = error; return }
            lines = (request.results as? [VNRecognizedTextObservation])?
                .compactMap { $0.topCandidates(1).first?.string } ?? []
        }
        request.recognitionLevel = .accurate
        try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
        if let failure { throw failure }
        return lines.joined(separator: "\n")
    }
}
