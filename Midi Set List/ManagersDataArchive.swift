//
//  DataArchive.swift
//  Midi Set List
//
//  Export / import of app data as one JSON file — a full backup, or a single
//  item (set list, song, instrument, macro group, macro…) plus everything it
//  depends on, for sharing with another user.
//
//  Records are written generically from the Core Data model, so new entities
//  and attributes are included automatically. Attached files (song PDFs,
//  reference files, device AI memory) travel inside the JSON as base64.
//  API keys and other secrets are never exported.
//

import CoreData
import Foundation

// MARK: - File format

/// Plain data, so a large archive can be encoded and written off the main thread
nonisolated struct DataArchive: Codable {
    static let formatID = "midisetlist-archive"
    static let currentVersion = 1

    nonisolated enum Kind: String, Codable { case backup, share }

    var format = DataArchive.formatID
    var version = DataArchive.currentVersion
    var kind: Kind
    var title: String
    var createdAt: Date
    var appVersion: String?
    var records: [Record]
    var files: [FileEntry]

    nonisolated struct Record: Codable {
        var entity: String
        var id: UUID
        var attributes: [String: Value]
        /// Relationship name → related record IDs (to-one relationships hold 0 or 1 ID)
        var relationships: [String: [UUID]]
    }

    nonisolated struct FileEntry: Codable {
        nonisolated enum Kind: String, Codable { case songPDF, specFile, deviceMemory }
        var kind: Kind
        /// Song or InstrumentDevice the file belongs to
        var ownerID: UUID
        /// Stored file name (song PDF / spec file); nil for device memory
        var filename: String?
        var data: Data
    }

    /// JSON-friendly attribute value
    nonisolated enum Value: Codable {
        case string(String), int(Int64), double(Double), bool(Bool)

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let b = try? c.decode(Bool.self) { self = .bool(b) }
            else if let i = try? c.decode(Int64.self) { self = .int(i) }
            else if let d = try? c.decode(Double.self) { self = .double(d) }
            else { self = .string(try c.decode(String.self)) }
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .string(let s): try c.encode(s)
            case .int(let i):    try c.encode(i)
            case .double(let d): try c.encode(d)
            case .bool(let b):   try c.encode(b)
            }
        }
    }
}

enum DataArchiveError: LocalizedError {
    case notAnArchive
    case newerVersion(Int)
    case noObjects

    var errorDescription: String? {
        switch self {
        case .notAnArchive:          return "This file isn't a Midi Set List backup or shared item."
        case .newerVersion(let v):   return "This file was made by a newer version of the app (format \(v)). Update the app to import it."
        case .noObjects:             return "Nothing to export."
        }
    }
}

// MARK: - Export

enum DataArchiveExporter {

    /// Every object in the store, plus all attached files
    static func fullBackup(context: NSManagedObjectContext) throws -> DataArchive {
        var objects: [NSManagedObject] = []
        for entity in context.persistentStoreCoordinator?.managedObjectModel.entities ?? [] {
            guard let name = entity.name else { continue }
            objects += try context.fetch(NSFetchRequest<NSManagedObject>(entityName: name))
        }
        return makeArchive(kind: .backup, title: "Full Backup", objects: objects)
    }

    /// `roots` plus everything they depend on (see `follows`)
    static func share(_ roots: [NSManagedObject], title: String) throws -> DataArchive {
        guard !roots.isEmpty else { throw DataArchiveError.noObjects }
        var included: [NSManagedObjectID: NSManagedObject] = [:]
        var expanded = Set<NSManagedObjectID>()
        var queue: [(NSManagedObject, Bool)] = roots.map { ($0, true) }

        while !queue.isEmpty {
            let (object, expand) = queue.removeFirst()
            let alreadyIncluded = included[object.objectID] != nil
            // Revisit only if this visit expands an object we'd included as a dependency
            if alreadyIncluded && (!expand || expanded.contains(object.objectID)) { continue }
            included[object.objectID] = object
            if expand { expanded.insert(object.objectID) }

            let entityName = object.entity.name ?? ""
            for (relName, _) in object.entity.relationshipsByName {
                switch follows(entityName, relName) {
                case .never:
                    continue
                case .dependency:
                    related(object, relName).forEach { queue.append(($0, false)) }
                case .owned where expand:
                    related(object, relName).forEach { queue.append(($0, true)) }
                case .owned:
                    continue
                }
            }
        }
        return makeArchive(kind: .share, title: title, objects: Array(included.values))
    }

    // What travels with a shared item.
    //  dependency — always included (it's needed for the item to work)
    //  owned      — included only when the parent is being shared in full
    //  never      — back-references (e.g. a song's other set lists)
    private enum Follow { case dependency, owned, never }

    private static func follows(_ entity: String, _ relationship: String) -> Follow {
        switch (entity, relationship) {
        case ("SetList", "songsRaw"),
             ("Song", "commandsRaw"),
             ("Song", "partsRaw"),
             ("Song", "chartRolesRaw"),
             ("SongPart", "rolesRaw"),
             ("MIDICommand", "sourceMacro"),
             ("DeviceMacro", "category"),
             ("DeviceMacro", "childMacrosRaw"),
             ("MacroCategory", "device"):
            return .dependency
        case ("InstrumentDevice", "categoriesRaw"),
             ("MacroCategory", "macrosRaw"):
            return .owned
        default:
            return .never
        }
    }

    private static func related(_ object: NSManagedObject, _ relationship: String) -> [NSManagedObject] {
        let value = object.value(forKey: relationship)
        if let set = value as? NSSet { return set.allObjects.compactMap { $0 as? NSManagedObject } }
        if let one = value as? NSManagedObject { return [one] }
        return []
    }

    private static func makeArchive(kind: DataArchive.Kind, title: String, objects: [NSManagedObject]) -> DataArchive {
        let includedIDs = Set(objects.compactMap { $0.value(forKey: "id") as? UUID })
        var records: [DataArchive.Record] = []
        var files: [DataArchive.FileEntry] = []

        for object in objects {
            guard let entityName = object.entity.name, let id = object.value(forKey: "id") as? UUID else { continue }

            var attributes: [String: DataArchive.Value] = [:]
            for (name, description) in object.entity.attributesByName {
                if let value = encode(object.value(forKey: name), type: description.attributeType) {
                    attributes[name] = value
                }
            }

            var relationships: [String: [UUID]] = [:]
            for name in object.entity.relationshipsByName.keys {
                // Only reference objects that are in this file
                let ids = related(object, name).compactMap { $0.value(forKey: "id") as? UUID }.filter(includedIDs.contains)
                if !ids.isEmpty { relationships[name] = ids.sorted { $0.uuidString < $1.uuidString } }
            }
            records.append(.init(entity: entityName, id: id, attributes: attributes, relationships: relationships))

            files += attachedFiles(for: object, id: id)
        }

        // Stable order makes exports diff-friendly
        records.sort { ($0.entity, $0.id.uuidString) < ($1.entity, $1.id.uuidString) }

        return DataArchive(
            kind: kind,
            title: title,
            createdAt: Date(),
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
            records: records,
            files: files
        )
    }

    private static func attachedFiles(for object: NSManagedObject, id: UUID) -> [DataArchive.FileEntry] {
        var files: [DataArchive.FileEntry] = []
        // A song's own chart, or one of its parts
        if let chart = object as? ChartSource, let url = chart.pdfFileURL, let filename = chart.pdfFileName,
           let data = try? Data(contentsOf: url) {
            files.append(.init(kind: .songPDF, ownerID: id, filename: filename, data: data))
        }
        // Sheet-music images use the same kind: every app version restores a .songPDF entry by
        // writing it to Documents under its name, so older builds can still read these backups
        if let chart = object as? ChartSource {
            for (name, url) in zip(chart.chartImageNames, chart.chartImageURLs) {
                if let data = try? Data(contentsOf: url) {
                    files.append(.init(kind: .songPDF, ownerID: id, filename: name, data: data))
                }
            }
        }
        if let device = object as? InstrumentDevice {
            for spec in device.specFiles {
                if let data = try? Data(contentsOf: DeviceSpecManager.fileURL(spec)) {
                    files.append(.init(kind: .specFile, ownerID: id, filename: spec.filename, data: data))
                }
            }
            if let data = try? Data(contentsOf: DeviceSpecManager.memoryFileURL(for: device)) {
                files.append(.init(kind: .deviceMemory, ownerID: id, filename: nil, data: data))
            }
        }
        return files
    }

    private static func encode(_ value: Any?, type: NSAttributeType) -> DataArchive.Value? {
        guard let value else { return nil }
        switch type {
        case .UUIDAttributeType:       return (value as? UUID).map { .string($0.uuidString) }
        case .dateAttributeType:       return (value as? Date).map { .string(isoFormatter.string(from: $0)) }
        case .binaryDataAttributeType: return (value as? Data).map { .string($0.base64EncodedString()) }
        case .booleanAttributeType:    return (value as? Bool).map { .bool($0) }
        case .integer16AttributeType, .integer32AttributeType, .integer64AttributeType:
            return (value as? NSNumber).map { .int($0.int64Value) }
        case .doubleAttributeType, .floatAttributeType, .decimalAttributeType:
            return (value as? NSNumber).map { .double($0.doubleValue) }
        case .stringAttributeType:     return (value as? String).map { .string($0) }
        default:                       return nil
        }
    }

    static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    // MARK: File output

    /// Safe to call off the main thread — encoding a full backup with its files is the slow part
    nonisolated static func write(_ archive: DataArchive, fileName: String) throws -> URL {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(archive)
        let safeName = fileName.replacingOccurrences(of: "/", with: "-")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(safeName)
        try data.write(to: url, options: .atomic)
        return url
    }
}

// MARK: - Import

enum DataArchiveImporter {

    enum Mode {
        /// Add new items and update matching ones; never deletes anything
        case merge
        /// Delete everything first, then restore the archive exactly
        case replaceAll
        /// Add what's new; leave anything that's already here exactly as it is
        case addNewOnly
    }

    struct Summary {
        struct Line: Identifiable {
            let entity: String
            let total: Int
            let existing: Int
            var id: String { entity }
        }
        let lines: [Line]
        let fileCount: Int
        var existingTotal: Int { lines.reduce(0) { $0 + $1.existing } }
    }

    static func read(_ url: URL) throws -> DataArchive {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let archive = try? decoder.decode(DataArchive.self, from: data),
              archive.format == DataArchive.formatID
        else { throw DataArchiveError.notAnArchive }
        guard archive.version <= DataArchive.currentVersion else { throw DataArchiveError.newerVersion(archive.version) }
        return archive
    }

    /// What's in the file, and how much of it already exists here
    static func summary(of archive: DataArchive, context: NSManagedObjectContext) -> Summary {
        let grouped = Dictionary(grouping: archive.records, by: \.entity)
        let lines = grouped.keys.sorted { displayOrder($0) < displayOrder($1) }.map { entity -> Summary.Line in
            let ids = grouped[entity]?.map(\.id) ?? []
            let request = NSFetchRequest<NSManagedObject>(entityName: entity)
            request.predicate = NSPredicate(format: "id IN %@", ids)
            let existing = (try? context.count(for: request)) ?? 0
            return .init(entity: entity, total: ids.count, existing: existing)
        }
        return Summary(lines: lines, fileCount: archive.files.count)
    }

    @discardableResult
    static func apply(_ archive: DataArchive, mode: Mode, context: NSManagedObjectContext) throws -> Int {
        let model = context.persistentStoreCoordinator?.managedObjectModel
        do {
            // Old files are only removed after the new data is safely saved
            let replacedFiles = mode == .replaceAll ? try deleteEverything(context: context) : []

            // Pass 1: create or update objects and their attributes
            var objects: [UUID: NSManagedObject] = [:]
            var untouched = Set<UUID>()   // existing records kept as they are (addNewOnly)
            var previousSpecFiles: [UUID: [DeviceSpecFile]] = [:]
            for record in archive.records {
                guard let entity = model?.entitiesByName[record.entity] else { continue }   // unknown entity: skip
                // insertNewObject instantiates the app's subclass (Song, SetList…)
                var found = try existing(record.entity, id: record.id, context: context)
                // A custom role someone else made ("Horns") is the same as ours of that name
                var keepLocalID = false
                if found == nil, record.entity == "BandRole", case .string(let name)? = record.attributes["name"],
                   let match = try existingRole(named: name, context: context) {
                    found = match
                    keepLocalID = true
                }
                let isNew = found == nil
                if let found, mode == .addNewOnly {
                    objects[record.id] = found
                    untouched.insert(record.id)
                    continue
                }
                let object = found ?? NSEntityDescription.insertNewObject(forEntityName: record.entity, into: context)
                if let device = object as? InstrumentDevice, !device.isInserted {
                    previousSpecFiles[record.id] = device.specFiles
                }
                for (name, description) in entity.attributesByName {
                    if keepLocalID && (name == "id" || name == "orderIndexRaw") { continue }
                    // Keep the local order of roles already here; it's this band's roster order
                    if record.entity == "BandRole" && !isNew && name == "orderIndexRaw" { continue }
                    if let raw = record.attributes[name], let value = decode(raw, type: description.attributeType) {
                        object.setValue(value, forKey: name)
                    } else if description.isOptional {
                        object.setValue(nil, forKey: name)
                    }
                    // Missing required attribute: keep the existing/default value
                }
                sanitizeFileReferences(object)
                objects[record.id] = object
            }

            // Pass 2: relationships (to-many links are added, never removed)
            for record in archive.records {
                guard let object = objects[record.id], !untouched.contains(record.id) else { continue }
                for (name, description) in object.entity.relationshipsByName {
                    guard let ids = record.relationships[name], let destination = description.destinationEntity?.name else { continue }
                    let targets = try ids.compactMap { id in
                        try objects[id] ?? existing(destination, id: id, context: context)
                    }
                    if description.isToMany {
                        let set = object.mutableSetValue(forKey: name)
                        targets.forEach { set.add($0) }
                    } else if let target = targets.first {
                        object.setValue(target, forKey: name)
                    }
                }
            }

            // Keep reference files that were already attached to a merged device
            for (id, previous) in previousSpecFiles {
                guard let device = objects[id] as? InstrumentDevice else { continue }
                let current = Set(device.specFiles.map(\.filename))
                previous.filter { !current.contains($0.filename) }.forEach(device.addSpecFile)
            }

            // Kept records keep their files too
            let files = archive.files.filter { !untouched.contains($0.ownerID) }
            let written = try writeFiles(files, objects: objects, overwriteMemory: mode == .replaceAll)
            try context.save()
            // A backup from before band roles existed restores none; put the built-ins back
            BandRole.seedDefaultsIfNeeded(in: context)
            for url in replacedFiles where !written.contains(url.standardizedFileURL) {
                try? FileManager.default.removeItem(at: url)
            }
            return archive.records.count
        } catch {
            context.rollback()
            throw error
        }
    }

    // MARK: Helpers

    private static func existingRole(named name: String, context: NSManagedObjectContext) throws -> NSManagedObject? {
        let request = NSFetchRequest<NSManagedObject>(entityName: "BandRole")
        request.predicate = NSPredicate(format: "name ==[c] %@", name)
        request.fetchLimit = 1
        return try context.fetch(request).first
    }

    private static func existing(_ entity: String, id: UUID, context: NSManagedObjectContext) throws -> NSManagedObject? {
        let request = NSFetchRequest<NSManagedObject>(entityName: entity)
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        request.fetchLimit = 1
        return try context.fetch(request).first
    }

    /// Deletes every object (unsaved until the caller saves) and returns the
    /// attached files that belonged to them.
    private static func deleteEverything(context: NSManagedObjectContext) throws -> [URL] {
        var files: [URL] = []
        for entity in context.persistentStoreCoordinator?.managedObjectModel.entities ?? [] {
            guard let name = entity.name else { continue }
            for object in try context.fetch(NSFetchRequest<NSManagedObject>(entityName: name)) {
                if let chart = object as? ChartSource {
                    files += [chart.pdfFileURL].compactMap { $0 } + chart.chartImageURLs
                }
                if let device = object as? InstrumentDevice {
                    files += device.specFiles.map(DeviceSpecManager.fileURL)
                    files.append(DeviceSpecManager.memoryFileURL(for: device))
                }
                context.delete(object)
            }
        }
        return files
    }

    /// Returns the (standardized) URLs written
    private static func writeFiles(_ files: [DataArchive.FileEntry], objects: [UUID: NSManagedObject], overwriteMemory: Bool) throws -> Set<URL> {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        var written = Set<URL>()
        for file in files {
            switch file.kind {
            case .songPDF:
                guard let name = safeFilename(file.filename) else { continue }
                let url = docs.appendingPathComponent(name)
                try file.data.write(to: url, options: .atomic)
                written.insert(url.standardizedFileURL)
            case .specFile:
                guard let name = safeFilename(file.filename) else { continue }
                let url = DeviceSpecManager.specsDirectory.appendingPathComponent(name)
                try file.data.write(to: url, options: .atomic)
                written.insert(url.standardizedFileURL)
            case .deviceMemory:
                guard let device = objects[file.ownerID] as? InstrumentDevice,
                      let incoming = String(data: file.data, encoding: .utf8) else { continue }
                let current = DeviceSpecManager.memoryContent(for: device)
                let url = DeviceSpecManager.memoryFileURL(for: device)
                written.insert(url.standardizedFileURL)
                if overwriteMemory || current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    try incoming.write(to: url, atomically: true, encoding: .utf8)
                } else if !current.contains(incoming.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    // Keep local corrections; add the imported ones underneath
                    try (current + "\n\n## Imported\n" + incoming).write(to: url, atomically: true, encoding: .utf8)
                }
            }
        }
        return written
    }

    /// Stored file names are later used to read and delete files, so an imported
    /// name must never point outside the app's folders.
    private static func sanitizeFileReferences(_ object: NSManagedObject) {
        if let chart = object as? ChartSource, let name = chart.pdfFileName {
            chart.pdfFileName = safeFilename(name)
        }
        if let chart = object as? ChartSource, !chart.chartImageNames.isEmpty {
            chart.chartImageNames = chart.chartImageNames.compactMap { safeFilename($0) }
        }
        if let device = object as? InstrumentDevice,
           let raw = device.specFileNamesData,
           let data = raw.data(using: .utf8),
           let files = try? JSONDecoder().decode([DeviceSpecFile].self, from: data) {
            let cleaned = files.compactMap { file -> DeviceSpecFile? in
                safeFilename(file.filename).map { DeviceSpecFile(filename: $0, displayName: file.displayName) }
            }
            device.specFileNamesData = (try? JSONEncoder().encode(cleaned)).flatMap { String(data: $0, encoding: .utf8) }
        }
    }

    /// Files come from other people — never let a name escape its folder
    private static func safeFilename(_ name: String?) -> String? {
        guard let name else { return nil }
        let last = URL(fileURLWithPath: name).lastPathComponent
        guard !last.isEmpty, last != ".", last != "..", !last.hasPrefix(".") else { return nil }
        return last
    }

    private static func decode(_ value: DataArchive.Value, type: NSAttributeType) -> Any? {
        switch (type, value) {
        case (.UUIDAttributeType, .string(let s)):       return UUID(uuidString: s)
        case (.dateAttributeType, .string(let s)):       return DataArchiveExporter.isoFormatter.date(from: s)
        case (.binaryDataAttributeType, .string(let s)): return Data(base64Encoded: s)
        case (.stringAttributeType, .string(let s)):     return s
        case (.booleanAttributeType, .bool(let b)):      return b
        case (.booleanAttributeType, .int(let i)):       return i != 0
        case (.integer16AttributeType, .int(let i)):     return NSNumber(value: Int16(clamping: i))
        case (.integer32AttributeType, .int(let i)):     return NSNumber(value: Int32(clamping: i))
        case (.integer64AttributeType, .int(let i)):     return NSNumber(value: i)
        case (.doubleAttributeType, .double(let d)),
             (.floatAttributeType, .double(let d)),
             (.decimalAttributeType, .double(let d)):    return NSNumber(value: d)
        case (.doubleAttributeType, .int(let i)),
             (.floatAttributeType, .int(let i)),
             (.decimalAttributeType, .int(let i)):       return NSNumber(value: Double(i))
        default:                                         return nil
        }
    }

    // MARK: Display names

    static func displayName(_ entity: String, count: Int) -> String {
        let (one, many): (String, String)
        switch entity {
        case "SetList":          (one, many) = ("set list", "set lists")
        case "Song":             (one, many) = ("song", "songs")
        case "MIDICommand":      (one, many) = ("song command", "song commands")
        case "InstrumentDevice": (one, many) = ("instrument", "instruments")
        case "MacroCategory":    (one, many) = ("macro group", "macro groups")
        case "DeviceMacro":      (one, many) = ("macro", "macros")
        case "OSCTarget":        (one, many) = ("OSC device", "OSC devices")
        case "SavedPreset":      (one, many) = ("saved preset", "saved presets")
        case "SongPart":         (one, many) = ("song part", "song parts")
        case "BandRole":         (one, many) = ("band role", "band roles")
        default:                 (one, many) = (entity, entity)
        }
        return "\(count) \(count == 1 ? one : many)"
    }

    private static func displayOrder(_ entity: String) -> Int {
        ["SetList", "Song", "SongPart", "BandRole", "MIDICommand", "InstrumentDevice", "MacroCategory", "DeviceMacro", "OSCTarget", "SavedPreset"]
            .firstIndex(of: entity) ?? 99
    }
}
