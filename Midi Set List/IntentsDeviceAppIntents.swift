//
//  DeviceAppIntents.swift
//  Midi Set List
//

import AppIntents
import CoreData
import Foundation

// MARK: - DeviceEntity

struct DeviceEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Instrument Device")
    static let defaultQuery = DeviceEntityQuery()

    var id: UUID
    var name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: LocalizedStringResource(stringLiteral: name))
    }
}

struct DeviceEntityQuery: EntityQuery {
    func entities(for identifiers: [UUID]) async throws -> [DeviceEntity] {
        try await MainActor.run {
            let ctx = PersistenceController.shared.viewContext
            let request = NSFetchRequest<InstrumentDevice>(entityName: "InstrumentDevice")
            let all = try ctx.fetch(request)
            return all.filter { identifiers.contains($0.id) }.map { DeviceEntity(id: $0.id, name: $0.name) }
        }
    }

    func suggestedEntities() async throws -> [DeviceEntity] {
        try await MainActor.run {
            let ctx = PersistenceController.shared.viewContext
            let request = NSFetchRequest<InstrumentDevice>(entityName: "InstrumentDevice")
            request.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
            return try ctx.fetch(request).map { DeviceEntity(id: $0.id, name: $0.name) }
        }
    }
}

// MARK: - MacroCategoryEntity

struct MacroCategoryEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Macro Category")
    static let defaultQuery = MacroCategoryEntityQuery()

    var id: UUID
    var name: String
    var deviceID: UUID
    var deviceName: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: LocalizedStringResource(stringLiteral: name),
            subtitle: LocalizedStringResource(stringLiteral: deviceName)
        )
    }
}

struct MacroCategoryEntityQuery: EntityQuery {
    func entities(for identifiers: [UUID]) async throws -> [MacroCategoryEntity] {
        try await MainActor.run {
            let ctx = PersistenceController.shared.viewContext
            let request = NSFetchRequest<MacroCategory>(entityName: "MacroCategory")
            let all = try ctx.fetch(request)
            return all.filter { identifiers.contains($0.id) }.map {
                MacroCategoryEntity(
                    id: $0.id,
                    name: $0.name,
                    deviceID: $0.device?.id ?? UUID(),
                    deviceName: $0.device?.name ?? "Unknown Device"
                )
            }
        }
    }

    func suggestedEntities() async throws -> [MacroCategoryEntity] {
        try await MainActor.run {
            let ctx = PersistenceController.shared.viewContext
            let request = NSFetchRequest<MacroCategory>(entityName: "MacroCategory")
            request.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
            return try ctx.fetch(request).map {
                MacroCategoryEntity(
                    id: $0.id,
                    name: $0.name,
                    deviceID: $0.device?.id ?? UUID(),
                    deviceName: $0.device?.name ?? "Unknown Device"
                )
            }
        }
    }
}

// MARK: - DeviceMacroEntity

struct DeviceMacroEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "MIDI Macro")
    static let defaultQuery = DeviceMacroEntityQuery()

    var id: UUID
    var name: String
    var categoryName: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: LocalizedStringResource(stringLiteral: name),
            subtitle: LocalizedStringResource(stringLiteral: categoryName)
        )
    }
}

struct DeviceMacroEntityQuery: EntityQuery {
    func entities(for identifiers: [UUID]) async throws -> [DeviceMacroEntity] {
        try await MainActor.run {
            let ctx = PersistenceController.shared.viewContext
            let request = NSFetchRequest<DeviceMacro>(entityName: "DeviceMacro")
            let all = try ctx.fetch(request)
            return all.filter { identifiers.contains($0.id) }.map {
                DeviceMacroEntity(id: $0.id, name: $0.name, categoryName: $0.category?.name ?? "")
            }
        }
    }
}

// MARK: - Create Instrument Device Intent

struct CreateDeviceIntent: AppIntent {
    static let title: LocalizedStringResource = "Create Instrument Device"
    static let description = IntentDescription(
        "Creates a new instrument device in your Complete Control library. You can then add macro categories and commands to it."
    )

    @Parameter(title: "Device Name", description: "e.g. HX Stomp, BeatBuddy, Roland RD-88")
    var deviceName: String

    @Parameter(title: "Manufacturer", description: "e.g. Line 6, Boss (optional)")
    var manufacturer: String?

    @Parameter(title: "MIDI Channel", description: "Channel 1–16", default: 1,
               inclusiveRange: (lowerBound: 1, upperBound: 16))
    var midiChannel: Int

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<DeviceEntity> {
        let entity = try await MainActor.run {
            let ctx = PersistenceController.shared.viewContext
            let device = InstrumentDevice.create(
                name: deviceName,
                manufacturer: manufacturer,
                midiChannel: midiChannel,
                in: ctx
            )
            try ctx.save()
            return DeviceEntity(id: device.id, name: device.name)
        }
        let manufacturerPart = manufacturer.map { " by \($0)" } ?? ""
        return .result(value: entity, dialog: "Created \(deviceName)\(manufacturerPart) on MIDI channel \(midiChannel).")
    }
}

// MARK: - Create Macro Category Intent

struct CreateMacroCategoryIntent: AppIntent {
    static let title: LocalizedStringResource = "Create Macro Category"
    static let description = IntentDescription(
        "Creates a new macro category for an existing instrument device. Use this to organise macros by type, e.g. Patches, Scenes, Loops."
    )

    @Parameter(title: "Device", description: "The instrument to add the category to.")
    var device: DeviceEntity

    @Parameter(title: "Category Name", description: "e.g. Patches, Scenes, Snapshots, Loops")
    var categoryName: String

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<MacroCategoryEntity> {
        let deviceID = device.id
        let deviceName = device.name
        let catName = categoryName

        let entity = try await MainActor.run {
            let ctx = PersistenceController.shared.viewContext
            let request = NSFetchRequest<InstrumentDevice>(entityName: "InstrumentDevice")
            request.predicate = NSPredicate(format: "id == %@", deviceID as CVarArg)
            request.fetchLimit = 1
            guard let deviceRecord = try ctx.fetch(request).first else {
                throw DeviceIntentError.deviceNotFound(deviceName)
            }
            let category = MacroCategory.create(
                name: catName,
                orderIndex: deviceRecord.categories.count,
                device: deviceRecord,
                in: ctx
            )
            try ctx.save()
            return MacroCategoryEntity(
                id: category.id,
                name: catName,
                deviceID: deviceRecord.id,
                deviceName: deviceRecord.name
            )
        }
        return .result(value: entity, dialog: "Created '\(categoryName)' in \(device.name).")
    }
}

// MARK: - Add MIDI Macro Intent (manual, no AI)

struct AddMacroIntent: AppIntent {
    static let title: LocalizedStringResource = "Add MIDI Macro"
    static let description = IntentDescription(
        "Manually adds a single MIDI macro to a category. Specify any combination of Bank Select LSB/MSB, Program Change, and Control Change. Messages are sent in that order."
    )

    @Parameter(title: "Category", description: "The category to add the macro to.")
    var category: MacroCategoryEntity

    @Parameter(title: "Macro Name", description: "e.g. Preset 1A, Clean Lead, Scene 3")
    var macroName: String

    @Parameter(title: "Bank Select LSB (0–127)", description: "CC 32 — sent first. Leave empty to skip.")
    var lsbValue: Int?

    @Parameter(title: "Bank Select MSB (0–127)", description: "CC 0 — sent after LSB. Leave empty to skip.")
    var msbValue: Int?

    @Parameter(title: "Program Change (0–127)", description: "Sent after bank selects. Leave empty to skip.")
    var pcValue: Int?

    @Parameter(title: "CC Number (0–127)", description: "Control Change number. Leave empty to skip.")
    var ccNumber: Int?

    @Parameter(title: "CC Value (0–127)", description: "Required when CC Number is set.")
    var ccValue: Int?

    @Parameter(title: "Post-Macro Delay (ms)", description: "Milliseconds to wait after sending. Default 50.", default: 50)
    var delayMilliseconds: Int

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<DeviceMacroEntity> {
        guard lsbValue != nil || msbValue != nil || pcValue != nil || ccNumber != nil else {
            throw DeviceIntentError.noCommandsSpecified
        }

        let categoryID = category.id
        let categoryName = category.name
        let macroName = macroName
        let lsb = lsbValue; let msb = msbValue; let pc = pcValue
        let ccNum = ccNumber; let ccVal = ccValue; let delay = delayMilliseconds

        let entity = try await MainActor.run {
            let ctx = PersistenceController.shared.viewContext
            let request = NSFetchRequest<MacroCategory>(entityName: "MacroCategory")
            request.predicate = NSPredicate(format: "id == %@", categoryID as CVarArg)
            request.fetchLimit = 1
            guard let categoryRecord = try ctx.fetch(request).first else {
                throw DeviceIntentError.categoryNotFound(categoryName)
            }
            let macro = DeviceMacro.create(
                name: macroName,
                channel: categoryRecord.device?.midiChannel ?? 1,
                delayMilliseconds: delay,
                orderIndex: categoryRecord.macros.count,
                msbValue: msb,
                lsbValue: lsb,
                pcValue: pc,
                ccNumber: ccNum,
                ccValue: ccVal,
                in: ctx
            )
            macro.category = categoryRecord
            try ctx.save()
            return DeviceMacroEntity(id: macro.id, name: macro.name, categoryName: categoryRecord.name)
        }
        let deviceName = category.deviceName
        return .result(value: entity, dialog: "Added '\(macroName)' to \(category.name) in \(deviceName).")
    }
}

// MARK: - Errors

enum DeviceIntentError: Error, LocalizedError {
    case deviceNotFound(String)
    case categoryNotFound(String)
    case noCommandsSpecified

    var errorDescription: String? {
        switch self {
        case .deviceNotFound(let name):
            return "No device named '\(name)' was found. Create it first using the Create Instrument shortcut or the Instruments tab."
        case .categoryNotFound(let name):
            return "No category named '\(name)' was found. Create it first using the Create Macro Category shortcut."
        case .noCommandsSpecified:
            return "At least one MIDI value (LSB, MSB, PC, or CC) must be specified."
        }
    }
}
