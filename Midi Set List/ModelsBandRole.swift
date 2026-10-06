//
//  BandRole.swift
//  Midi Set List
//
//  A role in the band — Vocals, Guitar, Keys… Song parts are addressed to roles
//  ("Seen by"), and each device says which roles it plays (BandSettings).
//
//  The built-in roles have fixed IDs, so "Guitar" is the same role on every bandmate's
//  device: a shared song's parts land on the right people without any setup.
//

import CoreData
import Foundation

@objc(BandRole)
class BandRole: NSManagedObject, Identifiable {
    @NSManaged var id: UUID
    @NSManaged var name: String
    /// One emoji shown beside the name
    @NSManaged var emoji: String
    /// Sort key for fetch requests; use `orderIndex` otherwise
    @NSManaged var orderIndexRaw: Int32

    var orderIndex: Int {
        get { Int(orderIndexRaw) }
        set { orderIndexRaw = Int32(newValue) }
    }

    var label: String { emoji.isEmpty ? name : "\(emoji) \(name)" }

    // ── Built-in roles ─────────────────────────────────────────────────
    static let builtIns: [(id: String, name: String, emoji: String)] = [
        ("B0000000-0000-4000-8000-000000000001", "Vocals", "🎤"),
        ("B0000000-0000-4000-8000-000000000002", "Guitar", "🎸"),
        ("B0000000-0000-4000-8000-000000000003", "Keys",   "🎹"),
        ("B0000000-0000-4000-8000-000000000004", "Bass",   "🎵"),
        ("B0000000-0000-4000-8000-000000000005", "Drums",  "🥁"),
    ]

    /// Adds any missing built-in roles. Checks each UUID individually so it's safe to call
    /// on every launch and on every device — won't double-create after CloudKit sync.
    static func seedDefaultsIfNeeded(in context: NSManagedObjectContext) {
        var created = false
        for (index, builtIn) in builtIns.enumerated() {
            guard let id = UUID(uuidString: builtIn.id) else { continue }
            let request = NSFetchRequest<BandRole>(entityName: "BandRole")
            request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            guard (try? context.count(for: request)) == 0 else { continue }
            create(name: builtIn.name, emoji: builtIn.emoji, id: id, order: index, in: context)
            created = true
        }
        if created { try? context.save() }
    }

    /// Removes duplicate built-in BandRole records caused by concurrent CloudKit seeding.
    /// Keeps the record with the smallest objectID (deterministic), re-points all SongPart
    /// and Song relationships to the canonical record, then deletes the extras.
    static func deduplicateBuiltIns(in context: NSManagedObjectContext) {
        var changed = false
        for builtIn in builtIns {
            guard let id = UUID(uuidString: builtIn.id) else { continue }
            let request = NSFetchRequest<BandRole>(entityName: "BandRole")
            request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            guard let all = try? context.fetch(request), all.count > 1 else { continue }

            let sorted = all.sorted { $0.objectID.uriRepresentation().absoluteString < $1.objectID.uriRepresentation().absoluteString }
            let canonical = sorted[0]

            for dup in sorted.dropFirst() {
                // Re-point SongPart.rolesRaw before nullify-on-delete drops the reference
                for case let part as NSManagedObject in (dup.value(forKey: "partsRaw") as? NSSet ?? NSSet()) {
                    var roles = Set((part.value(forKey: "rolesRaw") as? NSSet ?? NSSet()).compactMap { $0 as? BandRole })
                    roles.remove(dup)
                    roles.insert(canonical)
                    part.setValue(NSSet(set: roles), forKey: "rolesRaw")
                }
                // Re-point Song.chartRolesRaw
                for case let song as NSManagedObject in (dup.value(forKey: "chartSongsRaw") as? NSSet ?? NSSet()) {
                    var roles = Set((song.value(forKey: "chartRolesRaw") as? NSSet ?? NSSet()).compactMap { $0 as? BandRole })
                    roles.remove(dup)
                    roles.insert(canonical)
                    song.setValue(NSSet(set: roles), forKey: "chartRolesRaw")
                }
                context.delete(dup)
                changed = true
            }
        }
        if changed { try? context.save() }
    }

    @discardableResult
    static func create(name: String, emoji: String, id: UUID = UUID(), order: Int,
                       in context: NSManagedObjectContext) -> BandRole {
        let role = BandRole(context: context)
        role.id = id
        role.name = name
        role.emoji = emoji
        role.orderIndex = order
        return role
    }

    static func all(in context: NSManagedObjectContext) -> [BandRole] {
        let request = NSFetchRequest<BandRole>(entityName: "BandRole")
        request.sortDescriptors = [NSSortDescriptor(key: "orderIndexRaw", ascending: true)]
        return (try? context.fetch(request)) ?? []
    }
}

extension Collection where Element == BandRole {
    /// "🎸 Guitar, 🎹 Keys", or "Everyone" when empty
    var seenByLabel: String {
        isEmpty ? "Everyone" : sorted { $0.orderIndex < $1.orderIndex }.map(\.label).joined(separator: ", ")
    }
}
