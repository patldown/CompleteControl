//
//  MacroCategory.swift
//  Midi Set List
//

import CoreData
import Foundation

@objc(MacroCategory)
class MacroCategory: NSManagedObject, Identifiable {

    // ── Attributes ─────────────────────────────────────────────────────
    @NSManaged var id: UUID
    @NSManaged var name: String

    @NSManaged private var orderIndexRaw: Int32
    var orderIndex: Int {
        get { Int(orderIndexRaw) }
        set { orderIndexRaw = Int32(newValue) }
    }

    // ── Relationships ──────────────────────────────────────────────────
    @NSManaged var device: InstrumentDevice?

    @NSManaged private var macrosRaw: NSSet
    var macros: [DeviceMacro] {
        (macrosRaw.allObjects as? [DeviceMacro]) ?? []
    }

    @objc(addMacrosRawObject:)
    @NSManaged func addToMacrosRaw(_ value: DeviceMacro)

    @objc(removeMacrosRawObject:)
    @NSManaged func removeFromMacrosRaw(_ value: DeviceMacro)

    // ── Factory ────────────────────────────────────────────────────────
    static func create(
        name: String,
        orderIndex: Int = 0,
        device: InstrumentDevice? = nil,
        in context: NSManagedObjectContext
    ) -> MacroCategory {
        let c = MacroCategory(context: context)
        c.id = UUID()
        c.name = name
        c.orderIndexRaw = Int32(orderIndex)
        c.device = device
        return c
    }

    // ── Computed ───────────────────────────────────────────────────────
    var sortedMacros: [DeviceMacro] {
        macros.sorted { $0.orderIndex < $1.orderIndex }
    }
}
