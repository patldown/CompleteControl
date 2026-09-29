//
//  CommandExporter.swift
//  Midi Set List
//
//  Created by Patrick Downey on 9/25/26.
//

import Foundation
import UniformTypeIdentifiers
import CoreData

struct CommandExporter {
    
    /// Export commands to JSON format
    static func exportCommands(_ commands: [MIDICommand]) -> Data? {
        let exportData = commands.map { command in
            ExportedCommand(
                commandType: command.commandType.rawValue,
                channel: command.channel,
                value1: command.value1,
                value2: command.value2,
                delayMilliseconds: command.delayMilliseconds,
                notes: command.notes
            )
        }
        
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(exportData)
    }
    
    /// Import commands from JSON data
    static func importCommands(from data: Data, in context: NSManagedObjectContext) -> [MIDICommand]? {
        let decoder = JSONDecoder()
        guard let exportedCommands = try? decoder.decode([ExportedCommand].self, from: data) else {
            return nil
        }

        return exportedCommands.enumerated().map { index, exported in
            let commandType = MIDICommandType(rawValue: exported.commandType) ?? .programChange
            let cmd = MIDICommand(
                commandType: commandType,
                channel: exported.channel,
                value1: exported.value1,
                value2: exported.value2,
                delayMilliseconds: exported.delayMilliseconds,
                notes: exported.notes,
                context: context
            )
            cmd.orderIndex = index
            return cmd
        }
    }
    
    /// Export commands as human-readable text
    static func exportAsText(_ commands: [MIDICommand]) -> String {
        var text = "MIDI Command Sequence\n"
        text += "=====================\n\n"
        
        for (index, command) in commands.enumerated() {
            text += "\(index + 1). \(command.displayDescription)\n"
            if let notes = command.notes, !notes.isEmpty {
                text += "   Notes: \(notes)\n"
            }
            text += "   Delay: \(command.delayMilliseconds)ms\n"
            text += "\n"
        }
        
        return text
    }
}

struct ExportedCommand: Codable {
    let commandType: String
    let channel: Int?
    let value1: Int
    let value2: Int?
    let delayMilliseconds: Int
    let notes: String?
}

// Custom UTType for MIDI command files
extension UTType {
    static let midiCommands = UTType(exportedAs: "com.midisetlist.commands")
}
