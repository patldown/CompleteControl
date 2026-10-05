//
//  PersistenceController.swift
//  Midi Set List
//
//  CloudKit sync is ready but disabled until an Apple Developer membership is active.
//  To enable: add the iCloud + Background Modes capabilities in Xcode Signing & Capabilities,
//  then change NSPersistentContainer → NSPersistentCloudKitContainer and uncomment the
//  two store-description blocks in init(inMemory:).
//

import CloudKit
import CoreData
import Foundation

final class PersistenceController {

    /// UI tests launch with -ui-testing: a fresh in-memory store each run, so they never
    /// touch (or depend on) real data
    static let shared = PersistenceController(inMemory: ProcessInfo.processInfo.arguments.contains("-ui-testing"))

    static let preview: PersistenceController = { PersistenceController(inMemory: true) }()

    static let cloudKitContainerID = "iCloud.Patrick-Downey.Midi-Set-List"

    let container: NSPersistentCloudKitContainer

    var viewContext: NSManagedObjectContext { container.viewContext }

    /// Non-nil only when CloudKit shared-database sync is active.
    private(set) var sharedPersistentStore: NSPersistentStore?

    init(inMemory: Bool = false) {
        let c = NSPersistentCloudKitContainer(name: "MidiSetList",
                                             managedObjectModel: Self.model)

        if inMemory {
            c.persistentStoreDescriptions.first!.url = URL(fileURLWithPath: "/dev/null")
        } else {
            let baseURL = NSPersistentContainer.defaultDirectoryURL()

            let privateDesc = NSPersistentStoreDescription(
                url: baseURL.appendingPathComponent("MidiSetList.sqlite")
            )
            privateDesc.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
            privateDesc.setOption(true as NSNumber,
                                  forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
            let privateOpts = NSPersistentCloudKitContainerOptions(
                containerIdentifier: Self.cloudKitContainerID
            )
            privateOpts.databaseScope = .private
            privateDesc.cloudKitContainerOptions = privateOpts

            let sharedDesc = NSPersistentStoreDescription(
                url: baseURL.appendingPathComponent("MidiSetListShared.sqlite")
            )
            sharedDesc.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
            sharedDesc.setOption(true as NSNumber,
                                 forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
            let sharedOpts = NSPersistentCloudKitContainerOptions(
                containerIdentifier: Self.cloudKitContainerID
            )
            sharedOpts.databaseScope = .shared
            sharedDesc.cloudKitContainerOptions = sharedOpts

            c.persistentStoreDescriptions = [privateDesc, sharedDesc]
        }

        self.container = c

        // Enable lightweight migration so adding new optional attributes doesn't crash
        if let desc = c.persistentStoreDescriptions.first {
            desc.setOption(true as NSNumber, forKey: NSMigratePersistentStoresAutomaticallyOption)
            desc.setOption(true as NSNumber, forKey: NSInferMappingModelAutomaticallyOption)
        }

        c.loadPersistentStores { _, error in
            if let error { fatalError("Core Data load failed: \(error)") }
        }

        sharedPersistentStore = c.persistentStoreCoordinator.persistentStores.first {
            $0.url?.lastPathComponent.contains("Shared") == true
        }

        c.viewContext.automaticallyMergesChangesFromParent = true
        c.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy

        BandRole.seedDefaultsIfNeeded(in: c.viewContext)
    }

    func save() {
        let ctx = container.viewContext
        guard ctx.hasChanges else { return }
        try? ctx.save()
    }

    func newBackgroundContext() -> NSManagedObjectContext {
        let ctx = container.newBackgroundContext()
        ctx.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        return ctx
    }

    // MARK: - Sharing helpers

    func isSharedByOther(_ object: NSManagedObject) -> Bool {
        guard let sharedStore = sharedPersistentStore else { return false }
        return object.objectID.persistentStore == sharedStore
    }

    func isOwned(_ object: NSManagedObject) -> Bool {
        !isSharedByOther(object)
    }

    // MARK: - Programmatic Core Data Model

    /// Built once and shared: with several stores open (previews, tests), separate model
    /// copies would each claim Song, SetList… and Core Data couldn't tell which to use
    static let model: NSManagedObjectModel = makeModel()

    static func makeModel() -> NSManagedObjectModel {

        let songE     = ent("Song")
        let commandE  = ent("MIDICommand")
        let setListE  = ent("SetList")
        let deviceE   = ent("InstrumentDevice")
        let categoryE = ent("MacroCategory")
        let macroE    = ent("DeviceMacro")
        let oscTargE  = ent("OSCTarget")
        let presetE   = ent("SavedPreset")
        let partE     = ent("SongPart")
        let roleE     = ent("BandRole")

        songE.properties = [
            attr("id",            .UUIDAttributeType,      optional: true),
            attr("canonicalID",   .UUIDAttributeType,      optional: true),
            attr("name",          .stringAttributeType,    defaultValue: ""),
            attr("artist",        .stringAttributeType,    optional: true),
            attr("genre",         .stringAttributeType,    optional: true),
            attr("notes",         .stringAttributeType,    optional: true),
            attr("lyrics",        .stringAttributeType,    optional: true),
            attr("pdfFileName",   .stringAttributeType,    optional: true),
            attr("chartImageNamesData", .stringAttributeType, optional: true),
            attr("bpmRaw",        .integer32AttributeType, optional: true),
            attr("midiClockEnabled", .booleanAttributeType, defaultValue: true),
            attr("clickEnabled",  .booleanAttributeType,   defaultValue: false),
            attr("timeSignature", .stringAttributeType,    optional: true),
            attr("snapshotNamesData", .stringAttributeType, optional: true),
            attr("referenceTrackID",     .stringAttributeType, optional: true),
            attr("referenceTrackTitle",  .stringAttributeType, optional: true),
            attr("referenceTrackArtist", .stringAttributeType, optional: true),
            attr("referenceTrackURL",    .stringAttributeType, optional: true),
            attr("referenceTrackDurationRaw", .doubleAttributeType, optional: true),
            attr("keyRoot",       .stringAttributeType,    optional: true),
            attr("keyScaleRaw",   .stringAttributeType,    optional: true),
            attr("transposeRaw",  .integer16AttributeType, defaultValue: Int16(0)),
            attr("capoEnabled",   .booleanAttributeType,   defaultValue: false),
            attr("capoKeepsKey",  .booleanAttributeType,   defaultValue: true),
            attr("sendsSnapshotOnLoad", .booleanAttributeType, defaultValue: true),
            attr("capoRaw",       .integer16AttributeType, defaultValue: Int16(0)),
            attr("dateCreated",   .dateAttributeType,      optional: true),
            attr("dateModified",  .dateAttributeType,      optional: true),
        ]

        commandE.properties = [
            attr("id",                   .UUIDAttributeType, optional: true),
            attr("orderIndexRaw",        .integer32AttributeType, defaultValue: 0),
            attr("commandTypeRaw",       .stringAttributeType,    defaultValue: "Program Change"),
            attr("channelRaw",           .integer16AttributeType, optional: true),
            attr("value1Raw",            .integer32AttributeType, defaultValue: 0),
            attr("value2Raw",            .integer16AttributeType, optional: true),
            attr("delayMillisecondsRaw", .integer32AttributeType, defaultValue: 50),
            attr("notes",                .stringAttributeType,    optional: true),
            attr("oscAddress",           .stringAttributeType,    optional: true),
            attr("oscFloatArgRaw",       .doubleAttributeType,    optional: true),
            attr("oscFormula",           .stringAttributeType,    optional: true),
            attr("value1Formula",        .stringAttributeType,    optional: true),
            attr("value2Formula",        .stringAttributeType,    optional: true),
            attr("snapshotIndexRaw",     .integer16AttributeType, defaultValue: Int16(0)),
            attr("sourceGroupInstanceID",.stringAttributeType,    optional: true),
        ]

        setListE.properties = [
            attr("id",            .UUIDAttributeType,   optional: true),
            attr("name",          .stringAttributeType, defaultValue: ""),
            attr("dateCreated",   .dateAttributeType,   optional: true),
            attr("dateModified",  .dateAttributeType,   optional: true),
            attr("notes",         .stringAttributeType, optional: true),
            attr("songOrderData", .stringAttributeType, optional: true),
        ]

        deviceE.properties = [
            attr("id",                .UUIDAttributeType,      optional: true),
            attr("name",              .stringAttributeType,    defaultValue: ""),
            attr("manufacturer",      .stringAttributeType,    optional: true),
            attr("midiChannelRaw",    .integer16AttributeType, defaultValue: Int16(1)),
            attr("dateCreated",       .dateAttributeType,      optional: true),
            attr("specFileNamesData", .stringAttributeType,    optional: true),
        ]

        categoryE.properties = [
            attr("id",            .UUIDAttributeType,   optional: true),
            attr("name",          .stringAttributeType, defaultValue: ""),
            attr("orderIndexRaw", .integer32AttributeType, defaultValue: 0),
        ]

        macroE.properties = [
            attr("id",                   .UUIDAttributeType,   optional: true),
            attr("name",                 .stringAttributeType, defaultValue: ""),
            attr("notes",                .stringAttributeType,    optional: true),
            attr("channelRaw",           .integer16AttributeType, defaultValue: Int16(1)),
            attr("delayMillisecondsRaw", .integer32AttributeType, defaultValue: Int32(50)),
            attr("orderIndexRaw",        .integer32AttributeType, defaultValue: 0),
            attr("msbValueRaw",          .integer16AttributeType, optional: true),
            attr("lsbValueRaw",          .integer16AttributeType, optional: true),
            attr("pcValueRaw",           .integer16AttributeType, optional: true),
            attr("ccNumberRaw",          .integer16AttributeType, optional: true),
            attr("ccValueRaw",           .integer16AttributeType, optional: true),
            attr("isOSC",                .booleanAttributeType,   defaultValue: false),
            attr("isGroup",              .booleanAttributeType,   defaultValue: false),
            attr("oscAddress",           .stringAttributeType,    optional: true),
            attr("oscFloatArgRaw",       .doubleAttributeType,    optional: true),
            attr("oscFormula",           .stringAttributeType,    optional: true),
            attr("ccValueFormula",       .stringAttributeType,    optional: true),
            attr("pcValueFormula",       .stringAttributeType,    optional: true),
            attr("groupMacroOrderData",  .stringAttributeType,    optional: true),
        ]

        oscTargE.properties = [
            attr("id",                   .UUIDAttributeType,      optional: true),
            attr("name",                 .stringAttributeType,    defaultValue: ""),
            attr("host",                 .stringAttributeType,    defaultValue: ""),
            attr("portRaw",              .integer32AttributeType, defaultValue: Int32(10024)),
            attr("receivePortRaw",       .integer32AttributeType, defaultValue: Int32(10024)),
            attr("keepaliveAddress",     .stringAttributeType,    optional: true),
            attr("keepaliveIntervalRaw", .integer32AttributeType, defaultValue: Int32(8)),
            attr("dateCreated",          .dateAttributeType,      optional: true),
        ]

        presetE.properties = [
            attr("id",           .UUIDAttributeType,      optional: true),
            attr("name",         .stringAttributeType,    defaultValue: ""),
            attr("category",     .stringAttributeType,    defaultValue: "Custom"),
            attr("dateCreated",  .dateAttributeType,      optional: true),
            attr("commandsData", .binaryDataAttributeType, optional: true),
        ]

        partE.properties = [
            attr("id",                  .UUIDAttributeType,      optional: true),
            attr("name",                .stringAttributeType,    defaultValue: ""),
            attr("lyrics",              .stringAttributeType,    optional: true),
            attr("pdfFileName",         .stringAttributeType,    optional: true),
            attr("chartImageNamesData", .stringAttributeType,    optional: true),
            attr("orderIndexRaw",       .integer32AttributeType, defaultValue: Int32(0)),
            attr("dateCreated",         .dateAttributeType,      optional: true),
        ]

        roleE.properties = [
            attr("id",            .UUIDAttributeType,   optional: true),
            attr("name",          .stringAttributeType, defaultValue: ""),
            attr("emoji",         .stringAttributeType,    defaultValue: ""),
            attr("orderIndexRaw", .integer32AttributeType, defaultValue: Int32(0)),
        ]

        // Song.commandsRaw ↔ MIDICommand.song
        let songCmds = rel("commandsRaw", to: commandE, toMany: true,  delete: .cascadeDeleteRule)
        let cmdSong  = rel("song",         to: songE,    toMany: false, delete: .nullifyDeleteRule)
        link(songCmds, cmdSong)

        // SetList.songsRaw ↔ Song.setListsRaw
        let slSongs    = rel("songsRaw",    to: songE,    toMany: true, delete: .nullifyDeleteRule)
        let songSLists = rel("setListsRaw", to: setListE, toMany: true, delete: .nullifyDeleteRule)
        link(slSongs, songSLists)

        // InstrumentDevice.categoriesRaw ↔ MacroCategory.device
        let devCats = rel("categoriesRaw", to: categoryE, toMany: true,  delete: .cascadeDeleteRule)
        let catDev  = rel("device",         to: deviceE,   toMany: false, delete: .nullifyDeleteRule)
        link(devCats, catDev)

        // MacroCategory.macrosRaw ↔ DeviceMacro.category
        let catMacros = rel("macrosRaw", to: macroE,    toMany: true,  delete: .cascadeDeleteRule)
        let macroCat  = rel("category",  to: categoryE, toMany: false, delete: .nullifyDeleteRule)
        link(catMacros, macroCat)

        // DeviceMacro.generatedCommandsRaw ↔ MIDICommand.sourceMacro
        let macroGenCmds = rel("generatedCommandsRaw", to: commandE, toMany: true,  delete: .nullifyDeleteRule)
        let cmdSrcMacro  = rel("sourceMacro",           to: macroE,  toMany: false, delete: .nullifyDeleteRule)
        link(macroGenCmds, cmdSrcMacro)

        // DeviceMacro self-referential: group children ↔ parent groups
        let macroChildren = rel("childMacrosRaw",  to: macroE, toMany: true, delete: .nullifyDeleteRule)
        let macroParents  = rel("parentGroupsRaw", to: macroE, toMany: true, delete: .nullifyDeleteRule)
        link(macroChildren, macroParents)

        // Song.partsRaw ↔ SongPart.song — a song's extra charts go with it
        let songParts = rel("partsRaw", to: partE, toMany: true,  delete: .cascadeDeleteRule)
        let partSong  = rel("song",     to: songE, toMany: false, delete: .nullifyDeleteRule)
        link(songParts, partSong)

        // SongPart.rolesRaw ↔ BandRole.partsRaw — who sees a part (none = everyone)
        let partRoles = rel("rolesRaw", to: roleE, toMany: true, delete: .nullifyDeleteRule)
        let roleParts = rel("partsRaw", to: partE, toMany: true, delete: .nullifyDeleteRule)
        link(partRoles, roleParts)

        // Song.chartRolesRaw ↔ BandRole.chartSongsRaw — who sees the built-in chart
        let songChartRoles = rel("chartRolesRaw", to: roleE, toMany: true, delete: .nullifyDeleteRule)
        let roleChartSongs = rel("chartSongsRaw", to: songE, toMany: true, delete: .nullifyDeleteRule)
        link(songChartRoles, roleChartSongs)

        songE.properties     += [songCmds, songSLists, songParts, songChartRoles]
        partE.properties     += [partSong, partRoles]
        roleE.properties     += [roleParts, roleChartSongs]
        commandE.properties  += [cmdSong, cmdSrcMacro]
        setListE.properties  += [slSongs]
        deviceE.properties   += [devCats]
        categoryE.properties += [catDev, catMacros]
        macroE.properties    += [macroCat, macroGenCmds, macroChildren, macroParents]

        let model = NSManagedObjectModel()
        model.entities = [songE, commandE, setListE, deviceE,
                          categoryE, macroE, oscTargE, presetE, partE, roleE]
        return model
    }

    // MARK: - Builder helpers

    private static func ent(_ name: String) -> NSEntityDescription {
        let e = NSEntityDescription()
        e.name = name
        e.managedObjectClassName = name
        return e
    }

    private static func attr(
        _ name: String,
        _ type: NSAttributeType,
        optional: Bool = false,
        defaultValue: Any? = nil
    ) -> NSAttributeDescription {
        let a = NSAttributeDescription()
        a.name = name
        a.attributeType = type
        a.isOptional = optional
        if let defaultValue { a.defaultValue = defaultValue }
        return a
    }

    private static func rel(
        _ name: String,
        to dest: NSEntityDescription,
        toMany: Bool,
        optional: Bool = true,
        delete: NSDeleteRule = .nullifyDeleteRule
    ) -> NSRelationshipDescription {
        let r = NSRelationshipDescription()
        r.name = name
        r.destinationEntity = dest
        r.isOptional = optional
        r.deleteRule = delete
        r.minCount = 0
        r.maxCount = toMany ? 0 : 1
        return r
    }

    private static func link(_ a: NSRelationshipDescription,
                              _ b: NSRelationshipDescription) {
        a.inverseRelationship = b
        b.inverseRelationship = a
    }
}
