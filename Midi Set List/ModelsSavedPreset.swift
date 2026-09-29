//
//  SavedPreset.swift
//  Midi Set List
//

import CoreData
import Foundation

@objc(SavedPreset)
class SavedPreset: NSManagedObject, Identifiable {

    // ── Attributes ─────────────────────────────────────────────────────
    @NSManaged var id: UUID
    @NSManaged var name: String
    @NSManaged var category: String
    @NSManaged var dateCreated: Date
    @NSManaged var commandsData: Data

    // ── Factory ────────────────────────────────────────────────────────
    static func create(
        name: String,
        category: String = "Custom",
        commands: [MIDICommand],
        in context: NSManagedObjectContext
    ) -> SavedPreset {
        let p = SavedPreset(context: context)
        p.id = UUID()
        p.name = name
        p.category = category
        p.dateCreated = Date()
        p.commandsData = Self.encode(commands)
        return p
    }

    // ── Encode / decode ────────────────────────────────────────────────
    private static func encode(_ commands: [MIDICommand]) -> Data {
        let exported = commands.map { cmd in
            ExportedCommand(
                commandType: cmd.commandType.rawValue,
                channel: cmd.channel,
                value1: cmd.value1,
                value2: cmd.value2,
                delayMilliseconds: cmd.delayMilliseconds,
                notes: cmd.notes
            )
        }
        return (try? JSONEncoder().encode(exported)) ?? Data()
    }

    func getCommands(in context: NSManagedObjectContext) -> [MIDICommand] {
        guard let exported = try? JSONDecoder().decode([ExportedCommand].self,
                                                       from: commandsData)
        else { return [] }
        return exported.enumerated().map { index, e in
            let type = MIDICommandType(rawValue: e.commandType) ?? .programChange
            let cmd = MIDICommand(commandType: type, channel: e.channel,
                                  value1: e.value1, value2: e.value2,
                                  delayMilliseconds: e.delayMilliseconds,
                                  notes: e.notes, context: context)
            cmd.orderIndex = index
            return cmd
        }
    }

    func applyTo(song: Song, in context: NSManagedObjectContext) {
        for command in getCommands(in: context) {
            song.addCommand(command)
        }
    }
}

// Common preset categories
extension SavedPreset {
    static let categories = ["BeatBuddy", "HX Stomp", "Synth", "Pedal", "Rack Unit", "Custom"]
}
