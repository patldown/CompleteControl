//
//  SetListAssistant.swift
//  Midi Set List
//
//  Natural-language set list editing: "remove the two slowest songs",
//  "new set list with these in order: …". It can also hand the result to
//  Apple Music: "make this a playlist" opens the playlist review screen.
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
    @Guide(description: "\"update\" to change an existing set list, \"create\" for a new set list, or \"none\" if nothing should change")
    var action: String
    @Guide(description: "For \"update\": the ID of the set list to change, like L2. Empty means the open set list.")
    var setListID: String
    @Guide(description: "Name for a new set list, or the new name when renaming. Empty to keep the current name.")
    var name: String
    @Guide(description: "The COMPLETE final song list in play order, using library IDs like S3")
    var songIDs: [String]
    @Guide(description: "One or two sentences telling the user what will change and why. Name songs and set lists by title, never by ID.")
    var summary: String
    @Guide(description: "True when the user wants an Apple Music playlist made from the resulting set list")
    var playlist: Bool
}

// MARK: - Plan (what the AI proposed)

struct SetListPlan: Decodable {
    var action: String
    var setListID: String?
    var name: String?
    var songIDs: [String]?
    var summary: String
    var playlist: Bool?

    init(_ g: GeneratedSetListPlan) {
        action = g.action; setListID = g.setListID; name = g.name; songIDs = g.songIDs; summary = g.summary; playlist = g.playlist
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
    /// The set list an update changes (the open one, or another named in the request)
    let target: SetList?
    let summary: String
    /// New set list name (create), or rename target (update); nil keeps the name
    let newName: String?
    let oldName: String?
    let finalSongs: [Entry]
    let removed: [Song]
    /// IDs the AI returned that aren't in the library — dropped, but shown to the user
    let unknownIDs: [String]
    /// Open the Apple Music playlist review for the resulting set list (the open one when kind is .none)
    let makePlaylist: Bool

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
        /// Maps master song.id UUID → catalog string ID, so set-list copies can be looked up by canonicalID
        let idsByUUID: [UUID: String]
        let listing: String
        /// Set lists get IDs too (L1, L2, …) so a request can change one that isn't open
        let setListsByID: [String: SetList]
        let idsBySetList: [NSManagedObjectID: String]
        let setLists: [SetList]

        init(songs: [Song], setLists: [SetList]) {
            var byID: [String: Song] = [:]
            var bySong: [NSManagedObjectID: String] = [:]
            var byUUID: [UUID: String] = [:]
            var lines: [String] = []
            for (index, song) in songs.enumerated() {
                let id = "S\(index + 1)"
                byID[id] = song
                bySong[song.objectID] = id
                byUUID[song.id] = id
                var parts = ["\(id) | \(song.name)"]
                if let artist = song.artist, !artist.isEmpty { parts[0] += " — \(artist)" }
                if let bpm = song.bpm { parts.append("\(bpm) BPM") }
                if let seconds = song.referenceTrackDuration {
                    parts.append(String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60))
                }
                if let key = song.currentKey { parts.append("Key \(key.root) \(key.scale.rawValue)") }
                if !song.genres.isEmpty { parts.append(song.genres.joined(separator: "/")) }
                if let ts = song.timeSignature, !ts.isEmpty { parts.append(ts) }
                lines.append(parts.joined(separator: " | "))
            }
            songsByID = byID
            idsBySong = bySong
            idsByUUID = byUUID
            listing = lines.joined(separator: "\n")

            var listsByID: [String: SetList] = [:]
            var idsByList: [NSManagedObjectID: String] = [:]
            for (index, setList) in setLists.enumerated() {
                listsByID["L\(index + 1)"] = setList
                idsByList[setList.objectID] = "L\(index + 1)"
            }
            setListsByID = listsByID
            idsBySetList = idsByList
            self.setLists = setLists
        }

        /// Swaps any song or set list IDs (S3, L2) that slipped into AI text for their titles
        func replacingIDs(in text: String) -> String {
            guard let regex = try? NSRegularExpression(pattern: #"\b([SL])(\d+)\b"#) else { return text }
            var result = text
            let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            for match in matches.reversed() {
                guard let range = Range(match.range, in: result) else { continue }
                let id = String(result[range])
                let title: String? = id.hasPrefix("S")
                    ? songsByID[id].map { "\"\($0.name)\"" }
                    : setListsByID[id].map { "\"\($0.name)\"" }
                if let title { result.replaceSubrange(range, with: title) }
            }
            return result
        }

        /// Returns catalog IDs for the given songs. Works for both master songs and set-list copies.
        func ids(for songs: [Song]) -> String {
            songs.compactMap { song in
                idsBySong[song.objectID] ?? song.canonicalID.flatMap { idsByUUID[$0] }
            }.joined(separator: ", ")
        }
    }

    // MARK: Prompt

    static func systemPrompt(catalog: Catalog, current: SetList?) -> String {
        var prompt = """
            You are the set list assistant in "Complete Control", an app musicians use to plan gigs.
            You change set lists by returning the COMPLETE final song order. The app works out what \
            was added, removed and moved, and shows the user a summary to approve before anything changes.

            SONG LIBRARY (ID | title — artist | BPM | length | key | genre | time signature):
            \(catalog.listing.isEmpty ? "(empty)" : catalog.listing)
            """

        if let current, let id = catalog.idsBySetList[current.objectID] {
            prompt += """


                OPEN SET LIST \(id) "\(current.name)" (in play order): \(current.songs.isEmpty ? "(no songs)" : catalog.ids(for: current.songs))
                """
        } else {
            prompt += "\n\nNo set list is open. To change an existing set list, name it with setListID."
        }

        let others = catalog.setLists.filter { $0.objectID != current?.objectID }.prefix(30)
        if !others.isEmpty {
            prompt += "\n\nOTHER SET LISTS, most recently changed first (ID | name: songs in order). Update one by giving its setListID:"
            for sl in others {
                let id = catalog.idsBySetList[sl.objectID] ?? "?"
                prompt += "\n\(id) | \"\(sl.name)\": \(sl.songs.isEmpty ? "(no songs)" : catalog.ids(for: sl.songs))"
            }
        }

        prompt += """


            Rules:
            - action "update": change an existing set list. setListID is the one to change — empty for the open \
            set list, or the ID (like L2) of the set list the user names. songIDs is the FULL final list of THAT \
            set list in order — include its unchanged songs.
            - When the user names an existing set list ("add Wonderwall to Friday Gig"), update that set list. \
            Never create a new set list just because the named one isn't open. Match set list names loosely too.
            - action "create": only when the user asks for a new set list, or names one that doesn't exist.
            - For "create", give the set list a short, descriptive name. songIDs is its songs in order.
            - action "none": the message is a question or can't be done with these songs. songIDs is empty. Answer in summary.
            - Only use IDs from the song library. Never invent songs. If a song the user names isn't in the library, say so in summary.
            - Match song names loosely: ignore case, small typos and partial titles.
            - Keep songs in their existing relative order unless the user asks to reorder.
            - If the user is vague (e.g. "remove 2 songs"), make a sensible choice and name the songs in summary.
            - In summary, always call songs and set lists by their titles. Never write IDs like S2 or L1 there — \
            IDs are only for songIDs and setListID.
            - When ordering by energy or tempo, use BPM where known and explain your logic in summary.
            - Set "name" only when creating or when the user asks to rename; otherwise leave it empty.
            - Follow-up messages revise your previous plan — always return the complete revised plan.
            - For a set of a given length (e.g. "45 minutes"), add up song lengths. Where a length isn't \
            listed, assume 4 minutes. Get as close to the target as you can without going far over, and \
            give the estimated total in summary.
            - Set "playlist" to true when the user wants an Apple Music playlist (e.g. "make this a \
            playlist", "…and make it a playlist"). The app then shows a playlist review screen for the \
            resulting set list. To make a playlist of the open set list as it is, use action "none" with \
            "playlist": true. Otherwise leave "playlist" false.
            """
        return prompt
    }

    static let jsonFormat = """

        Respond ONLY with a JSON object — no markdown fences, no explanation:
        {"action": "update" | "create" | "none", "setListID": "L2 or empty", "name": "string or empty", "songIDs": ["S1", "S2"], "summary": "string", "playlist": false}
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
        // The set list the request is about: one it named, else the open one
        let namedID = plan.setListID?.trimmingCharacters(in: .whitespaces).uppercased() ?? ""
        let target = catalog.setListsByID[namedID] ?? current

        var kind: SetListChangePreview.Kind
        switch plan.action.lowercased() {
        case "update": kind = target == nil ? .create : .update
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
        let currentSongs = kind == .update ? (target?.songs ?? []) : []
        // Set lists hold copies; map each to its master's UUID for comparison against the catalog's masters.
        let currentMasterIDs = Set(currentSongs.map { $0.canonicalID ?? $0.id })
        let finalMasterIDs = Set(final.map(\.id))

        // A song is "moved" when its position among the songs kept from before changed
        let keptBefore = currentSongs.filter { finalMasterIDs.contains($0.canonicalID ?? $0.id) }.map { $0.canonicalID ?? $0.id }
        let keptAfter  = final.filter { currentMasterIDs.contains($0.id) }.map(\.id)
        let entries = final.map { song -> SetListChangePreview.Entry in
            guard kind == .update, currentMasterIDs.contains(song.id) else {
                return .init(song: song, mark: kind == .update ? .added : .unchanged)
            }
            let moved = keptBefore.firstIndex(of: song.id) != keptAfter.firstIndex(of: song.id)
            return .init(song: song, mark: moved ? .moved : .unchanged)
        }

        let newName: String?
        switch kind {
        case .create: newName = trimmedName.isEmpty ? "New Set List" : trimmedName
        case .update: newName = (trimmedName.isEmpty || trimmedName == target?.name) ? nil : trimmedName
        case .none:   newName = nil
        }

        // An update or create with no songs at all is almost certainly a misread — don't offer to apply it
        let requestedKind = kind
        if kind == .create && final.isEmpty { kind = .none }

        // A playlist of the open set list as-is needs one open; a failed create gets no playlist
        let makePlaylist = (plan.playlist ?? false)
            && (kind != .none || (requestedKind == .none && target != nil))

        return SetListChangePreview(
            kind: kind,
            target: kind == .create ? nil : target,
            summary: catalog.replacingIDs(in: plan.summary),
            newName: newName,
            oldName: kind == .update ? target?.name : nil,
            finalSongs: entries,
            removed: currentSongs.filter { !finalMasterIDs.contains($0.canonicalID ?? $0.id) },
            unknownIDs: unknown,
            makePlaylist: makePlaylist
        )
    }

    // MARK: Apply (only after the user approves)

    @discardableResult
    static func apply(_ preview: SetListChangePreview, in context: NSManagedObjectContext) throws -> SetList? {
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
            guard let setList = preview.target else { return nil }
            if let name = preview.newName { setList.name = name }
            preview.removed.forEach(setList.removeSong)
            ordered.forEach(setList.addSong)   // no-op for songs already in the list
            // setSongOrder uses copy UUIDs; look up each master's copy in the set list
            let copiesByCanonical = Dictionary(uniqueKeysWithValues:
                setList.songs.compactMap { song -> (UUID, Song)? in
                    guard let cid = song.canonicalID else { return nil }
                    return (cid, song)
                }
            )
            setList.setSongOrder(ordered.compactMap { copiesByCanonical[$0.id] })
            try context.save()
            return setList
        }
    }
}
