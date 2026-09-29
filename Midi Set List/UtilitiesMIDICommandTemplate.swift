//
//  MIDICommandTemplate.swift
//  Midi Set List
//
//  Created by Patrick Downey on 9/25/26.
//

import Foundation
import CoreData

/// Predefined templates for common MIDI device commands
struct MIDICommandTemplate: Identifiable {
    let id = UUID()
    let name: String
    let description: String
    let deviceType: DeviceType
    let commands: [MIDICommandConfig]
    
    enum DeviceType: String, CaseIterable {
        case beatbuddy = "BeatBuddy"
        case hxStomp = "HX Stomp"
        case generic = "Generic"
        
        var icon: String {
            switch self {
            case .beatbuddy:
                return "music.note.list"
            case .hxStomp:
                return "slider.horizontal.3"
            case .generic:
                return "music.mic"
            }
        }
    }
    
    struct MIDICommandConfig {
        let commandType: MIDICommandType
        let channel: Int?
        let value1: Int
        let value2: Int?
        let delayMilliseconds: Int
        let notes: String?
    }
}

extension MIDICommandTemplate {
    /// Convert template to actual MIDICommand instances
    func createCommands(in context: NSManagedObjectContext) -> [MIDICommand] {
        return commands.enumerated().map { index, config in
            let cmd = MIDICommand(
                commandType: config.commandType,
                channel: config.channel,
                value1: config.value1,
                value2: config.value2,
                delayMilliseconds: config.delayMilliseconds,
                notes: config.notes,
                context: context
            )
            cmd.orderIndex = index
            return cmd
        }
    }
    
    // MARK: - Predefined Templates
    
    static let allTemplates: [MIDICommandTemplate] = [
        // BeatBuddy Templates
        .beatBuddyFolderAndSong,
        .beatBuddySimpleSong,
        
        // HX Stomp Templates
        .hxStompPreset,
        .hxStompSnapshot,
        .hxStompPresetWithSnapshot,
        
        // Generic Templates
        .genericProgramChange,
        .genericControlChange,
        .genericBankSelect
    ]
    
    // BeatBuddy: Select folder and song
    static let beatBuddyFolderAndSong = MIDICommandTemplate(
        name: "BeatBuddy Folder + Song",
        description: "Switch to a specific folder and select a song",
        deviceType: .beatbuddy,
        commands: [
            MIDICommandConfig(
                commandType: .bankSelectMSB,
                channel: 1,
                value1: 0,
                value2: nil,
                delayMilliseconds: 50,
                notes: "Bank MSB (usually 0)"
            ),
            MIDICommandConfig(
                commandType: .bankSelectLSB,
                channel: 1,
                value1: 0,
                value2: nil,
                delayMilliseconds: 50,
                notes: "Folder number (0-127)"
            ),
            MIDICommandConfig(
                commandType: .programChange,
                channel: 1,
                value1: 0,
                value2: nil,
                delayMilliseconds: 100,
                notes: "Song number (0-127)"
            )
        ]
    )
    
    // BeatBuddy: Simple song change
    static let beatBuddySimpleSong = MIDICommandTemplate(
        name: "BeatBuddy Song Only",
        description: "Change song in current folder",
        deviceType: .beatbuddy,
        commands: [
            MIDICommandConfig(
                commandType: .programChange,
                channel: 1,
                value1: 0,
                value2: nil,
                delayMilliseconds: 50,
                notes: "Song number (0-127)"
            )
        ]
    )
    
    // HX Stomp: Preset change
    static let hxStompPreset = MIDICommandTemplate(
        name: "HX Stomp Preset",
        description: "Load a specific preset",
        deviceType: .hxStomp,
        commands: [
            MIDICommandConfig(
                commandType: .programChange,
                channel: 1,
                value1: 0,
                value2: nil,
                delayMilliseconds: 100,
                notes: "Preset number (0-127)"
            )
        ]
    )
    
    // HX Stomp: Snapshot
    static let hxStompSnapshot = MIDICommandTemplate(
        name: "HX Stomp Snapshot",
        description: "Switch to a snapshot",
        deviceType: .hxStomp,
        commands: [
            MIDICommandConfig(
                commandType: .controlChange,
                channel: 1,
                value1: 69,
                value2: 0,
                delayMilliseconds: 50,
                notes: "Snapshot (CC 69, value 0-7)"
            )
        ]
    )
    
    // HX Stomp: Preset + Snapshot
    static let hxStompPresetWithSnapshot = MIDICommandTemplate(
        name: "HX Stomp Preset + Snapshot",
        description: "Load preset and switch to specific snapshot",
        deviceType: .hxStomp,
        commands: [
            MIDICommandConfig(
                commandType: .programChange,
                channel: 1,
                value1: 0,
                value2: nil,
                delayMilliseconds: 150,
                notes: "Preset number (0-127)"
            ),
            MIDICommandConfig(
                commandType: .controlChange,
                channel: 1,
                value1: 69,
                value2: 0,
                delayMilliseconds: 50,
                notes: "Snapshot (CC 69, value 0-7)"
            )
        ]
    )
    
    // Generic: Program Change
    static let genericProgramChange = MIDICommandTemplate(
        name: "Program Change",
        description: "Simple program change command",
        deviceType: .generic,
        commands: [
            MIDICommandConfig(
                commandType: .programChange,
                channel: 1,
                value1: 0,
                value2: nil,
                delayMilliseconds: 50,
                notes: "Program number (0-127)"
            )
        ]
    )
    
    // Generic: Control Change
    static let genericControlChange = MIDICommandTemplate(
        name: "Control Change",
        description: "Send a CC message",
        deviceType: .generic,
        commands: [
            MIDICommandConfig(
                commandType: .controlChange,
                channel: 1,
                value1: 0,
                value2: 0,
                delayMilliseconds: 50,
                notes: "CC number and value (both 0-127)"
            )
        ]
    )
    
    // Generic: Bank Select
    static let genericBankSelect = MIDICommandTemplate(
        name: "Bank Select + Program Change",
        description: "Full bank select with program change",
        deviceType: .generic,
        commands: [
            MIDICommandConfig(
                commandType: .bankSelectMSB,
                channel: 1,
                value1: 0,
                value2: nil,
                delayMilliseconds: 50,
                notes: "Bank MSB (0-127)"
            ),
            MIDICommandConfig(
                commandType: .bankSelectLSB,
                channel: 1,
                value1: 0,
                value2: nil,
                delayMilliseconds: 50,
                notes: "Bank LSB (0-127)"
            ),
            MIDICommandConfig(
                commandType: .programChange,
                channel: 1,
                value1: 0,
                value2: nil,
                delayMilliseconds: 100,
                notes: "Program number (0-127)"
            )
        ]
    )
}
