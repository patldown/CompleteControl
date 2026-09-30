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

    /// Adds the built-in roles the first time the app runs (or after a restore without any)
    static func seedDefaultsIfNeeded(in context: NSManagedObjectContext) {
        let request = NSFetchRequest<BandRole>(entityName: "BandRole")
        guard (try? context.count(for: request)) == 0 else { return }
        for (index, builtIn) in builtIns.enumerated() {
            guard let id = UUID(uuidString: builtIn.id) else { continue }
            create(name: builtIn.name, emoji: builtIn.emoji, id: id, order: index, in: context)
        }
        try? context.save()
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
