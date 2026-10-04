//
//  ManagersSnapshotNamesAI.swift
//  Midi Set List
//
//  Given a song's snapshot macro names and its lyrics/chord chart, asks the AI to
//  return one short, unique name for each snapshot (e.g. "Intro", "Verse", "Drive").
//

import Foundation
import FoundationModels

// MARK: - On-device structured output

@Generable
struct GeneratedSnapshotNames {
    @Guide(description: "One short name per snapshot, in the same order they were listed. 1–3 words, max 15 characters each, all unique. Use musical section names when the lyrics confirm them (Intro, Verse, Chorus, Bridge, Solo, Outro); otherwise name for the dominant effect or macro (e.g. Clean, Drive, Solo Boost).")
    var names: [String]
}

// MARK: - AI call

enum SnapshotNamesAI {

    private static var instructions: String {
        """
        You name a musician's snapshots. Each snapshot is a preset that configures \
        their instruments for one section of a song.

        Primary signal — use the macro/effect names loaded into the snapshot. \
        Shorten them to the key word: "Electric Drive Boost" → "Drive", \
        "Clean Acoustic w/ Reverb" → "Clean Reverb", "Vocal Delay + Chorus" → "Vocal Delay".

        Secondary signal — if the song has a chord chart or lyrics with section markers \
        (e.g. [Verse], [Chorus], [Bridge]) and the snapshot order clearly maps to those \
        sections, prefer the section name: "Verse", "Chorus", "Bridge", "Outro", "Solo", "Intro".

        Rules:
        • Return exactly one name per snapshot, in the same order they were listed.
        • Every name must be 1–3 words and unique across the list.
        • Never return "Snapshot 1", "Snapshot 2", etc.
        """
    }

    private static let jsonFormat = """

        Reply ONLY with a JSON object — no markdown, no explanation:
        {"names": ["Name 1", "Name 2"]}
        """

    static func prompt(for song: Song) -> String {
        var lines: [String] = []

        var header = "Song: \"\(song.name)\""
        if let artist = song.artist, !artist.isEmpty { header += " by \(artist)" }
        var details: [String] = []
        if let key = song.currentKey { details.append("Key: \(key.displayName)") }
        if let bpm = song.bpm { details.append("\(bpm) BPM") }
        if !details.isEmpty { header += " — " + details.joined(separator: ", ") }
        lines.append(header)
        lines.append("")

        lines.append("Snapshots:")
        for index in 0..<song.snapshotCount {
            let cmds = song.commands(inSnapshot: index)
            let macroNames = cmds.compactMap { $0.sourceMacro?.name }.uniqued()
            let noteNames = cmds.compactMap { cmd -> String? in
                let n = cmd.notes?.trimmingCharacters(in: .whitespaces) ?? ""
                return n.isEmpty ? nil : n
            }.uniqued()
            let names = macroNames.isEmpty ? noteNames : macroNames
            var desc = "\(index + 1):"
            if !names.isEmpty {
                desc += " macros = [\(names.joined(separator: ", "))]"
            } else {
                desc += " \(cmds.count) command\(cmds.count == 1 ? "" : "s"), no macro names"
            }
            lines.append(desc)
        }

        if let lyrics = song.lyrics, !lyrics.isEmpty {
            let sectionLines = lyrics.components(separatedBy: .newlines)
                .filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("[") }
                .prefix(20)
            if !sectionLines.isEmpty {
                lines.append("")
                lines.append("Song sections from chart (in order):")
                lines.append(contentsOf: sectionLines)
            }
        }

        return lines.joined(separator: "\n")
    }

    /// Returns one suggested name per snapshot, in order.
    static func suggest(for song: Song) async throws -> [String] {
        let ai = AISettings.shared
        guard ai.isAvailable(.snapshotNames) else { throw SongDetailsError.aiUnavailable }
        let provider = ai.provider(for: .snapshotNames)
        let userPrompt = prompt(for: song)
        let count = song.snapshotCount

        func onDevice() async throws -> [String] {
            guard ai.onDeviceAvailable else { throw SongDetailsError.aiUnavailable }
            let session = LanguageModelSession(instructions: instructions)
            let response = try await session.respond(to: userPrompt, generating: GeneratedSnapshotNames.self)
            return padded(response.content.names, to: count)
        }

        if provider == .onDevice { return try await onDevice() }

        guard let apiKey = provider == .openAI ? ai.openAIKey : ai.anthropicKey
        else { throw ExternalAIError.notConfigured }

        do {
            let response = try await ExternalAIClient.chat(
                provider: provider,
                apiKey: apiKey,
                systemPrompt: instructions + jsonFormat,
                messages: [ExternalAIMessage(role: "user", content: userPrompt)],
                workspaceID: provider == .anthropic ? ai.anthropicWorkspaceID : nil,
                anthropicModelID: ai.anthropicModel(for: .snapshotNames),
                anthropicThinking: ai.thinkingEnabled(for: .snapshotNames)
            )
            let reply = response.text
            guard let start = reply.firstIndex(of: "{"),
                  let end = reply.lastIndex(of: "}"),
                  let data = String(reply[start...end]).data(using: .utf8),
                  let decoded = try? JSONDecoder().decode(NamesRaw.self, from: data),
                  let names = decoded.names
            else { throw SongDetailsError.badResponse(reply) }
            return padded(names, to: count)
        } catch let error where ExternalAIError.isConnectivity(error) && ai.onDeviceAvailable {
            return try await onDevice()
        }
    }

    // MARK: Helpers

    private struct NamesRaw: Decodable {
        var names: [String]?
    }

    private static func padded(_ names: [String], to count: Int) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        for raw in names.prefix(count) {
            var name = String(raw.trimmingCharacters(in: .whitespaces).prefix(20))
            if name.isEmpty { name = "Snapshot \(result.count + 1)" }
            if seen.contains(name.lowercased()) { name = "\(name) \(result.count + 1)" }
            seen.insert(name.lowercased())
            result.append(name)
        }
        while result.count < count {
            result.append("Snapshot \(result.count + 1)")
        }
        return result
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
