//
//  ManagersMixLevelsAI.swift
//  Midi Set List
//
//  The mix wand: from the routing channels' names (and their effects) plus a description
//  of the song, asks the AI for a fader level for each channel. The levels are shown for
//  approval, then sent to the linked mixer.
//

import Foundation
import FoundationModels

// MARK: - On-device structured output

@Generable
struct GeneratedMixLevel {
    @Guide(description: "The channel name exactly as listed")
    var channel: String
    @Guide(description: "Fader level in dB, from -40 to 5. 0 is unity.")
    var db: Double
}

@Generable
struct GeneratedMixLevels {
    @Guide(description: "One entry per listed channel")
    var levels: [GeneratedMixLevel]
    @Guide(description: "One or two sentences on the balance chosen")
    var notes: String
}

struct MixLevelSuggestion: Identifiable, Equatable {
    let channelID: UUID
    let name: String
    var db: Float
    var id: UUID { channelID }
}

// MARK: - AI call

enum MixLevelsAI {

    static let example = "A pop song with driving guitar and layered synths. The drums are in your face. Vocal 1 is the lead and Vocal 2 sings backing vocals."

    private static var instructions: String {
        """
        You are a live sound engineer setting the channel faders of a band's mix on a \
        digital mixer.

        Assume gain staging is done: every channel's preamp is set so its loudest peaks \
        sit around the same level. So the faders only set the balance between channels.

        Conventions:
        • 0 dB is unity. Give the channel that must be heard most (usually the lead vocal) \
        about 0 dB and set everything else relative to it.
        • Never go above +5 dB. Rarely go below -30 dB; use -40 only for something that \
        should be barely there.
        • Backing vocals usually sit 4–8 dB under the lead. Supporting parts (pads, layered \
        synths, rhythm parts) sit further back than featured parts.
        • Kick and snare carry the energy in most pop and rock; overheads/room sit back. \
        Bass sits with the kick.
        • Follow the description: if it says something is "in your face" or "driving", \
        bring it forward; "subtle", "under", "pad" means further back.
        • Use the channel's name, and its effects if listed, to tell what it is. If a name \
        says nothing (e.g. "Input 5"), put it at -10 dB.

        Return one level per channel, using each channel's name exactly as listed.
        """
    }

    private static let jsonFormat = """

        Reply ONLY with a JSON object — no markdown, no explanation:
        {"levels": [{"channel": "Name", "db": -3}], "notes": "One or two sentences."}
        """

    static func prompt(description: String, channels: [AudioChannel]) -> String {
        var lines = ["Song / mix description: \(description)", "", "Channels:"]
        for channel in channels {
            let fx = channel.slots.compactMap { slot -> String? in
                guard let type = slot.type, !slot.isBypassed else { return nil }
                return type.shortName
            }
            var line = "- \(channel.displayName)"
            if channel.isStereoLinked { line += " (stereo)" }
            if !fx.isEmpty { line += " — effects: \(fx.joined(separator: ", "))" }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    /// One suggested level per channel (in channel order), plus the AI's note on the balance
    static func suggest(description: String, channels: [AudioChannel]) async throws
        -> (levels: [MixLevelSuggestion], notes: String) {
        let ai = AISettings.shared
        guard ai.isAvailable(.mixLevels) else { throw SongDetailsError.aiUnavailable }
        let provider = ai.provider(for: .mixLevels)
        let userPrompt = prompt(description: description, channels: channels)

        func onDevice() async throws -> (levels: [MixLevelSuggestion], notes: String) {
            guard ai.onDeviceAvailable else { throw SongDetailsError.aiUnavailable }
            let session = LanguageModelSession(instructions: instructions)
            let response = try await session.respond(to: userPrompt, generating: GeneratedMixLevels.self)
            let raw = response.content.levels.map { (name: $0.channel, db: $0.db) }
            return (match(raw, to: channels), response.content.notes)
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
                anthropicModelID: ai.anthropicModel(for: .mixLevels),
                anthropicThinking: ai.thinkingEnabled(for: .mixLevels)
            )
            let reply = response.text
            guard let start = reply.firstIndex(of: "{"),
                  let end = reply.lastIndex(of: "}"),
                  let data = String(reply[start...end]).data(using: .utf8),
                  let decoded = try? JSONDecoder().decode(LevelsRaw.self, from: data)
            else { throw SongDetailsError.badResponse(reply) }
            let raw = decoded.levels.map { (name: $0.channel, db: $0.db) }
            return (match(raw, to: channels), decoded.notes ?? "")
        } catch let error where ExternalAIError.isConnectivity(error) && ai.onDeviceAvailable {
            return try await onDevice()
        }
    }

    // MARK: Helpers

    private struct LevelsRaw: Decodable {
        struct Level: Decodable { var channel: String; var db: Double }
        var levels: [Level]
        var notes: String?
    }

    /// Back to channels by name (ignoring case and spacing); channels the AI skipped get -10
    private static func match(_ raw: [(name: String, db: Double)], to channels: [AudioChannel]) -> [MixLevelSuggestion] {
        channels.map { channel in
            let wanted = AppOSC.normalize(channel.displayName)
            let db = raw.first { AppOSC.normalize($0.name) == wanted }?.db ?? -10
            return MixLevelSuggestion(channelID: channel.id, name: channel.displayName,
                                      db: Float(min(5, max(-40, db)).rounded()))
        }
    }
}
