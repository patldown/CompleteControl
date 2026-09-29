//
//  InstrumentDevice.swift
//  Midi Set List
//

import CoreData
import Foundation
import PDFKit

// MARK: - Spec file metadata (stored as JSON in specFileNamesData)

struct DeviceSpecFile: Codable, Identifiable {
    var id: String { filename }
    var filename: String    // UUID-based name stored in Documents/DeviceSpecs/
    var displayName: String // original filename shown to user
}

// MARK: - File I/O helper

enum DeviceSpecManager {

    static var specsDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("DeviceSpecs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func save(data: Data, displayName: String) throws -> DeviceSpecFile {
        let ext = URL(fileURLWithPath: displayName).pathExtension
        let filename = UUID().uuidString + (ext.isEmpty ? "" : "." + ext)
        let url = specsDirectory.appendingPathComponent(filename)
        try data.write(to: url, options: .atomic)
        return DeviceSpecFile(filename: filename, displayName: displayName)
    }

    static func delete(_ file: DeviceSpecFile) {
        try? FileManager.default.removeItem(at: specsDirectory.appendingPathComponent(file.filename))
    }

    static func fileURL(_ file: DeviceSpecFile) -> URL {
        specsDirectory.appendingPathComponent(file.filename)
    }

    static func extractText(_ file: DeviceSpecFile) -> String? {
        let url = fileURL(file)
        if file.filename.lowercased().hasSuffix(".pdf") {
            return PDFDocument(url: url)?.string
        }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// Concatenates all attached spec file text + memory, labelled by filename, ready for an AI prompt.
    /// Reference files only, without the device memory
    static func specFilesContext(for device: InstrumentDevice) -> String {
        device.specFiles.compactMap { file -> String? in
            guard let text = extractText(file),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return "=== \(file.displayName) ===\n\(text)"
        }
        .joined(separator: "\n\n")
    }

    static func specContext(for device: InstrumentDevice) -> String {
        var parts: [String] = []
        let specs = specFilesContext(for: device)
        if !specs.isEmpty { parts.append(specs) }
        let memory = memoryContent(for: device)
        if !memory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("=== Device Memory (corrections & confirmed values — trust these over spec) ===\n\(memory)")
        }
        return parts.joined(separator: "\n\n")
    }

    // MARK: - Device memory (sidecar correction file)

    static func memoryFileURL(for device: InstrumentDevice) -> URL {
        specsDirectory.appendingPathComponent("\(device.id.uuidString)_memory.md")
    }

    static func memoryContent(for device: InstrumentDevice) -> String {
        (try? String(contentsOf: memoryFileURL(for: device), encoding: .utf8)) ?? ""
    }

    static func hasMemory(for device: InstrumentDevice) -> Bool {
        let content = memoryContent(for: device)
        return !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func appendToMemory(for device: InstrumentDevice, note: String) {
        let url = memoryFileURL(for: device)
        let existing = (try? String(contentsOf: url, encoding: .utf8))
            ?? "# \(device.name) — AI Memory\n\nConfirmed corrections and learned values.\n"
        let df = DateFormatter()
        df.dateStyle = .medium; df.timeStyle = .short
        let entry = "\n## \(df.string(from: Date()))\n\(note)\n"
        try? (existing + entry).write(to: url, atomically: true, encoding: .utf8)
    }

    static func clearMemory(for device: InstrumentDevice) {
        try? FileManager.default.removeItem(at: memoryFileURL(for: device))
    }
}

// MARK: - InstrumentDevice

@objc(InstrumentDevice)
class InstrumentDevice: NSManagedObject, Identifiable {

    // ── Attributes ─────────────────────────────────────────────────────
    @NSManaged var id: UUID
    @NSManaged var name: String
    @NSManaged var manufacturer: String?
    @NSManaged var dateCreated: Date
    @NSManaged var specFileNamesData: String?

    @NSManaged private var midiChannelRaw: Int16
    var midiChannel: Int {
        get { Int(midiChannelRaw) }
        set { midiChannelRaw = Int16(newValue) }
    }

    // ── Relationships ──────────────────────────────────────────────────
    @NSManaged private var categoriesRaw: NSSet

    var categories: [MacroCategory] {
        (categoriesRaw.allObjects as? [MacroCategory]) ?? []
    }

    @objc(addCategoriesRawObject:)
    @NSManaged func addToCategoriesRaw(_ value: MacroCategory)

    @objc(removeCategoriesRawObject:)
    @NSManaged func removeFromCategoriesRaw(_ value: MacroCategory)

    // ── Factory ────────────────────────────────────────────────────────
    static func create(
        name: String,
        manufacturer: String? = nil,
        midiChannel: Int = 1,
        in context: NSManagedObjectContext
    ) -> InstrumentDevice {
        let d = InstrumentDevice(context: context)
        d.id = UUID()
        d.name = name
        d.manufacturer = manufacturer
        d.midiChannelRaw = Int16(midiChannel)
        d.dateCreated = Date()
        return d
    }

    // ── Computed properties ────────────────────────────────────────────
    var displayName: String {
        if let manufacturer, !manufacturer.isEmpty { return "\(manufacturer) \(name)" }
        return name
    }

    var sortedCategories: [MacroCategory] {
        categories.sorted { $0.orderIndex < $1.orderIndex }
    }

    // ── Spec file management ───────────────────────────────────────────

    var specFiles: [DeviceSpecFile] {
        guard let raw = specFileNamesData,
              let data = raw.data(using: .utf8),
              let files = try? JSONDecoder().decode([DeviceSpecFile].self, from: data)
        else { return [] }
        return files
    }

    func addSpecFile(_ file: DeviceSpecFile) {
        var files = specFiles
        files.append(file)
        encodeSpecFiles(files)
    }

    func removeSpecFile(_ file: DeviceSpecFile) {
        var files = specFiles
        files.removeAll { $0.filename == file.filename }
        encodeSpecFiles(files)
    }

    private func encodeSpecFiles(_ files: [DeviceSpecFile]) {
        if files.isEmpty {
            specFileNamesData = nil
        } else if let data = try? JSONEncoder().encode(files),
                  let str = String(data: data, encoding: .utf8) {
            specFileNamesData = str
        }
    }
}
