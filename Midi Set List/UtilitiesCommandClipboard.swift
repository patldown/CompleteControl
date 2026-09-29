//
//  CommandClipboard.swift
//  Midi Set List
//
//  Created by Patrick Downey on 9/25/26.
//

import Foundation
import SwiftUI
import CoreData

/// Simple clipboard for copying and pasting MIDI commands
@Observable
class CommandClipboard {
    static let shared = CommandClipboard()
    
    private(set) var copiedCommands: [CommandData] = []
    
    struct CommandData {
        let commandType: MIDICommandType
        let channel: Int?
        let value1: Int
        let value2: Int?
        let delayMilliseconds: Int
        let notes: String?
    }
    
    var hasCommands: Bool {
        !copiedCommands.isEmpty
    }
    
    var commandCount: Int {
        copiedCommands.count
    }
    
    func copy(_ commands: [MIDICommand]) {
        copiedCommands = commands.map { command in
            CommandData(
                commandType: command.commandType,
                channel: command.channel,
                value1: command.value1,
                value2: command.value2,
                delayMilliseconds: command.delayMilliseconds,
                notes: command.notes
            )
        }
    }
    
    func paste(to song: Song, in context: NSManagedObjectContext) {
        for commandData in copiedCommands {
            let newCommand = MIDICommand(
                commandType: commandData.commandType,
                channel: commandData.channel,
                value1: commandData.value1,
                value2: commandData.value2,
                delayMilliseconds: commandData.delayMilliseconds,
                notes: commandData.notes,
                context: context
            )
            song.addCommand(newCommand)
        }
    }
    
    func clear() {
        copiedCommands.removeAll()
    }
}
