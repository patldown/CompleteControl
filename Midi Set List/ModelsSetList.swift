//
//  SetList.swift
//  Midi Set List
//

import CoreData
import Foundation

@objc(SetList)
class SetList: NSManagedObject, Identifiable {

    // ── Attributes ─────────────────────────────────────────────────────
    @NSManaged var id: UUID
    @NSManaged var name: String
    @NSManaged var dateCreated: Date
    @NSManaged var dateModified: Date
    @NSManaged var notes: String?
    /// JSON-encoded [String] of song UUID strings, in display order.
    @NSManaged var songOrderData: String?

    // ── Relationships (raw) ────────────────────────────────────────────
    @NSManaged private var songsRaw: NSSet

    /// Songs in their persisted display order.
    var songs: [Song] {
        let all = (songsRaw.allObjects as? [Song]) ?? []
        let ids = decodedOrderIDs
        guard !ids.isEmpty else {
            return all.sorted { $0.dateCreated < $1.dateCreated }
        }
        let map = Dictionary(uniqueKeysWithValues: all.map { ($0.id.uuidString, $0) })
        let ordered = ids.compactMap { map[$0] }
        // Append any songs not yet in the order array (e.g. added before migration)
        let known = Set(ids)
        let extras = all
            .filter { !known.contains($0.id.uuidString) }
            .sorted { $0.dateCreated < $1.dateCreated }
        return ordered + extras
    }

    @objc(addSongsRawObject:)
    @NSManaged func addToSongsRaw(_ value: Song)

    @objc(removeSongsRawObject:)
    @NSManaged func removeFromSongsRaw(_ value: Song)

    // ── Factory ────────────────────────────────────────────────────────
    static func create(
        name: String,
        notes: String? = nil,
        in context: NSManagedObjectContext
    ) -> SetList {
        let sl = SetList(context: context)
        sl.id = UUID()
        sl.name = name
        sl.notes = notes
        sl.dateCreated = Date()
        sl.dateModified = Date()
        return sl
    }

    // ── Computed ───────────────────────────────────────────────────────
    var totalCommandCount: Int {
        songs.reduce(0) { $0 + $1.commands.count }
    }

    // ── Mutation helpers ───────────────────────────────────────────────

    func addSong(_ song: Song) {
        guard !songs.contains(where: { $0.objectID == song.objectID }) else { return }
        addToSongsRaw(song)
        var ids = decodedOrderIDs
        ids.append(song.id.uuidString)
        songOrderData = encode(ids)
        dateModified = Date()
    }

    func removeSong(_ song: Song) {
        removeFromSongsRaw(song)
        var ids = decodedOrderIDs
        ids.removeAll { $0 == song.id.uuidString }
        songOrderData = encode(ids)
        dateModified = Date()
    }

    /// Reorders songs; caller must save the context.
    func moveSong(from source: IndexSet, to destination: Int) {
        var ids = songs.map { $0.id.uuidString }
        // Extract items in forward order, then remove back-to-front to keep indices valid
        let moving = source.map { ids[$0] }
        for i in source.reversed() { ids.remove(at: i) }
        // Adjust destination for items removed before it
        let adj = source.filter { $0 < destination }.count
        let insert = max(0, min(destination - adj, ids.count))
        ids.insert(contentsOf: moving, at: insert)
        songOrderData = encode(ids)
        dateModified = Date()
    }

    // ── Private order helpers ──────────────────────────────────────────

    private var decodedOrderIDs: [String] {
        guard let raw = songOrderData,
              let data = raw.data(using: .utf8),
              let ids = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return ids
    }

    private func encode(_ ids: [String]) -> String {
        guard let data = try? JSONEncoder().encode(ids),
              let str = String(data: data, encoding: .utf8) else { return "[]" }
        return str
    }
}
