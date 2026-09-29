//
//  SetListAssistant.swift
//  Midi Set List
//
//  Natural-language set list editing: "remove the two slowest songs",
//  "new set list with these in order: …".
//
//  The AI never edits anything directly. It returns the COMPLETE final song
//  order (as short song IDs); the app validates it against the library, works
//  out what is added / removed / moved, and shows that summary for approval.
//  Only an approved plan is applied.
//

import CoreData
import Foundation
import FoundationModels

// MARK: - On-device structured output

@Generable
struct GeneratedSetListPlan {
    @Guide(description: "\"update\" to change the open set list, \"create\" for a new set list, or \"none\" if nothing should change")
    var action: String
    @Guide(description: "Name for a new set list, or the new name when renaming. Empty to keep the current name.")
    var name: String
    @Guide(description: "The COMPLETE final song list in play order, using library IDs like S3")
    var songIDs: [String]
    @Guide(description: "One or two sentences telling the user what will change and why")
    var summary: String
}

// MARK: - Plan (what the AI proposed)

struct SetListPlan: Decodable {
    var action: String
    var name: String?
    var songIDs: [String]?
    var summary: String

    init(_ g: GeneratedSetListPlan) {
        action = g.action; name = g.name; songIDs = g.songIDs; summary = g.summary
    }
}

// MARK: - Change preview (what the user approves)

struct SetListChangePreview {
    enum Kind { case update, create, none }
    enum Mark { case unchanged, added, moved }

    struct Entry: Identifiable {
        let song: Song
        let mark: Mark
        var id: NSManagedObjectID { song.objectID }
    }

    let kind: Kind
    let summary: String
    /// New set list name (create), or rename target (update); nil keeps the name
    let newName: String?
    let oldName: String?
    let finalSongs: [Entry]
    let removed: [Song]
    /// IDs the AI returned that aren't in the library — dropped, but shown to the user
    let unknownIDs: [String]

    var hasChanges: Bool {
        switch kind {
        case .none:   return false
        case .create: return true
        case .update: return newName != nil || !removed.isEmpty || finalSongs.contains { $0.mark != .unchanged }
        }
    }
}

// MARK: - Assistant

enum SetListAssistant {

    /// Short, stable IDs (S1, S2, …) for every library song, so prompts stay small
    /// and the AI can only reference songs that exist.
    struct Catalog {
        let songsByID: [String: Song]
        let idsBySong: [NSManagedObjectID: String]
        let listing: String

        init(songs: [Song]) {
            var byID: [String: Song] = [:]
            var bySong: [NSManagedObjectID: String] = [:]
            var lines: [String] = []
            for (index, song) in songs.enumerated() {
                let id = "S\(index + 1)"
                byID[id] = song
                bySong[song.objectID] = id
                var parts = ["\(id) | \(song.name)"]
                if let artist = song.artist, !artist.isEmpty { parts[0] += " — \(artist)" }
                if let bpm = song.bpm { parts.append("\(bpm) BPM") }
                if !song.genres.isEmpty { parts.append(song.genres.joined(separator: "/")) }
                if let ts = song.timeSignature, !ts.isEmpty { parts.append(ts) }
                lines.append(parts.joined(separator: " | "))
            }
            songsByID = byID
            idsBySong = bySong
            listing = lines.joined(separator: "\n")
        }

        func ids(for songs: [Song]) -> String {
            songs.compactMap { idsBySong[$0.objectID] }.joined(separator: ", ")
        }
    }

    // MARK: Prompt

    static func systemPrompt(catalog: Catalog, current: SetList?, otherSetLists: [SetList]) -> String {
        var prompt = """
            You are the set list assistant in "Midi Set List", an app musicians use to plan gigs.
            You change set lists by returning the COMPLETE final song order. The app works out what \
            was added, removed and moved, and shows the user a summary to approve before anything changes.

            SONG LIBRARY (ID | title — artist | BPM | genre | time signature):
            \(catalog.listing.isEmpty ? "(empty)" : catalog.listing)
            """

        if let current {
            prompt += """


                OPEN SET LIST "\(current.name)" (in play order): \(current.songs.isEmpty ? "(no songs)" : catalog.ids(for: current.songs))
                """
        } else {
            prompt += "\n\nNo set list is open — you can only create a new one (action \"create\")."
        }

        let others = otherSetLists.filter { $0.objectID != current?.objectID }.prefix(20)
        if !others.isEmpty {
            prompt += "\n\nOTHER SET LISTS (reference only, for requests like \"like Friday's set but…\"):"
            for sl in others {
                prompt += "\n\"\(sl.name)\": \(sl.songs.isEmpty ? "(no songs)" : catalog.ids(for: sl.songs))"
            }
        }

        prompt += """


            Rules:
            - action "update": change the open set list. songIDs is the FULL final list in order — include unchanged songs.
            - action "create": a new set list. Give it a short, descriptive name. songIDs is its songs in order.
            - action "none": the message is a question or can't be done with these songs. songIDs is empty. Answer in summary.
            - Only use IDs from the song library. Never invent songs. If a song the user names isn't in the library, say so in summary.
            - Match song names loosely: ignore case, small typos and partial titles.
            - Keep songs in their existing relative order unless the user asks to reorder.
            - If the user is vague (e.g. "remove 2 songs"), make a sensible choice and name the songs in summary.
            - When ordering by energy or tempo, use BPM where known and explain your logic in summary.
            - Set "name" only when creating or when the user asks to rename; otherwise leave it empty.
            - Follow-up messages revise your previous plan — always return the complete revised plan.
            """
        return prompt
    }

    static let jsonFormat = """

        Respond ONLY with a JSON object — no markdown fences, no explanation:
        {"action": "update" | "create" | "none", "name": "string or empty", "songIDs": ["S1", "S2"], "summary": "string"}
        """

    // MARK: Request

    /// Asks the routed provider for a plan. `history` must end with the user's latest message.
    /// Falls back to on-device if the connection drops.
    static func requestPlan(
        systemPrompt: String,
        history: [ExternalAIMessage],
        onDeviceSession: @escaping () -> LanguageModelSession
    ) async throws -> (plan: SetListPlan, rawText: String?) {
        let ai = AISettings.shared
        let provider = ai.provider(for: .setListAssistant)
        let latest = history.last?.content ?? ""

        func planOnDevice() async throws -> (plan: SetListPlan, rawText: String?) {
            guard ai.onDeviceAvailable else { throw ExternalAIError.apiError("On-device AI is not available.") }
            let response = try await onDeviceSession().respond(to: latest, generating: GeneratedSetListPlan.self)
            return (SetListPlan(response.content), nil)
        }

        guard provider != .onDevice else { return try await planOnDevice() }
        guard let apiKey = provider == .openAI ? ai.openAIKey : ai.anthropicKey
        else { throw ExternalAIError.notConfigured }

        do {
            let response = try await ExternalAIClient.chat(
                provider: provider,
                apiKey: apiKey,
                systemPrompt: systemPrompt + jsonFormat,
                messages: history,
                workspaceID: provider == .anthropic ? ai.anthropicWorkspaceID : nil,
                anthropicModelID: ai.anthropicModel(for: .setListAssistant),
                anthropicThinking: ai.thinkingEnabled(for: .setListAssistant)
            )
            let text = response.text
            guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"),
                  let data = String(text[start...end]).data(using: .utf8),
                  let plan = try? JSONDecoder().decode(SetListPlan.self, from: data)
            else { throw ExternalAIError.apiError("Could not read the plan. Model returned: \(text.prefix(300))") }
            return (plan, text)
        } catch let error where ExternalAIError.isConnectivity(error) && ai.onDeviceAvailable {
            return try await planOnDevice()
        }
    }

    // MARK: Preview

    static func preview(for plan: SetListPlan, catalog: Catalog, current: SetList?) -> SetListChangePreview {
        var kind: SetListChangePreview.Kind
        switch plan.action.lowercased() {
        case "update": kind = current == nil ? .create : .update
        case "create": kind = .create
        default:       kind = .none
        }

        // Resolve IDs → songs, dropping unknowns and duplicates
        var seen = Set<NSManagedObjectID>()
        var final: [Song] = []
        var unknown: [String] = []
        for raw in plan.songIDs ?? [] {
            let id = raw.trimmingCharacters(in: .whitespaces).uppercased()
            guard let song = catalog.songsByID[id] else { unknown.append(raw); continue }
            if seen.insert(song.objectID).inserted { final.append(song) }
        }

        let trimmedName = plan.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let currentSongs = kind == .update ? (current?.songs ?? []) : []
        let currentIDs = Set(currentSongs.map(\.objectID))
        let finalIDs = Set(final.map(\.objectID))

        // A song is "moved" when its position among the songs kept from before changed
        let keptBefore = currentSongs.filter { finalIDs.contains($0.objectID) }.map(\.objectID)
        let keptAfter = final.filter { currentIDs.contains($0.objectID) }.map(\.objectID)
        let entries = final.map { song -> SetListChangePreview.Entry in
            guard kind == .update, currentIDs.contains(song.objectID) else {
                return .init(song: song, mark: kind == .update ? .added : .unchanged)
            }
            let moved = keptBefore.firstIndex(of: song.objectID) != keptAfter.firstIndex(of: song.objectID)
            return .init(song: song, mark: moved ? .moved : .unchanged)
        }

        let newName: String?
        switch kind {
        case .create: newName = trimmedName.isEmpty ? "New Set List" : trimmedName
        case .update: newName = (trimmedName.isEmpty || trimmedName == current?.name) ? nil : trimmedName
        case .none:   newName = nil
        }

        // An update or create with no songs at all is almost certainly a misread — don't offer to apply it
        if kind == .create && final.isEmpty { kind = .none }

        return SetListChangePreview(
            kind: kind,
            summary: plan.summary,
            newName: newName,
            oldName: kind == .update ? current?.name : nil,
            finalSongs: entries,
            removed: currentSongs.filter { !finalIDs.contains($0.objectID) },
            unknownIDs: unknown
        )
    }

    // MARK: Apply (only after the user approves)

    @discardableResult
    static func apply(_ preview: SetListChangePreview, to current: SetList?, in context: NSManagedObjectContext) throws -> SetList? {
        let ordered = preview.finalSongs.map(\.song)
        switch preview.kind {
        case .none:
            return nil
        case .create:
            let setList = SetList.create(name: preview.newName ?? "New Set List", in: context)
            ordered.forEach(setList.addSong)
            try context.save()
            return setList
        case .update:
            guard let setList = current else { return nil }
            if let name = preview.newName { setList.name = name }
            preview.removed.forEach(setList.removeSong)
            ordered.forEach(setList.addSong)   // no-op for songs already in the list
            setList.setSongOrder(ordered)
            try context.save()
            return setList
        }
    }
}
