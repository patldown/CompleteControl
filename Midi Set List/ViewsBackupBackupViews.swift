//
//  BackupViews.swift
//  Midi Set List
//
//  Backup / restore in Settings, a reusable "Share" button for single items,
//  and the review screen shown before anything is imported.
//

import CoreData
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - Exportable archive (built only when the user picks a destination)

/// A backup or shared item as a file. The JSON is built when the share sheet
/// asks for it, so putting this in a toolbar or menu costs nothing up front.
struct ArchiveFile: Transferable {
    /// nil = full backup
    let objectID: NSManagedObjectID?
    let fileName: String
    let title: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .json) { file in
            SentTransferredFile(try await MainActor.run { try file.write() })
        }
        .suggestedFileName { $0.fileName }
    }

    @MainActor
    private func write() throws -> URL {
        let context = PersistenceController.shared.viewContext
        let archive: DataArchive
        if let objectID {
            archive = try DataArchiveExporter.share([context.object(with: objectID)], title: title)
        } else {
            archive = try DataArchiveExporter.fullBackup(context: context)
        }
        return try DataArchiveExporter.write(archive, fileName: fileName)
    }

    static func share(_ object: NSManagedObject, kindName: String, itemName: String) -> ArchiveFile {
        ArchiveFile(objectID: object.objectID,
                    fileName: "\(kindName) - \(itemName).json",
                    title: "\(kindName): \(itemName)")
    }

    static func fullBackup() -> ArchiveFile {
        let date = Date().formatted(.iso8601.year().month().day())
        return ArchiveFile(objectID: nil, fileName: "Midi Set List Backup \(date).json", title: "Full Backup")
    }
}

// MARK: - Share one item (plus what it depends on)

/// Exports `object` and everything it needs (songs → commands → macros → instrument…)
/// to a JSON file another user can import. Works inside menus and toolbars.
struct ShareItemButton: View {
    let object: NSManagedObject
    let kindName: String      // e.g. "Set List"
    let itemName: String

    var body: some View {
        ShareLink(
            item: ArchiveFile.share(object, kindName: kindName, itemName: itemName),
            preview: SharePreview("\(kindName): \(itemName)")
        ) {
            Label("Share \(kindName)…", systemImage: "square.and.arrow.up")
        }
    }
}

// MARK: - Settings section

struct BackupSection: View {
    @State private var showingImporter = false
    @State private var pendingImport: PendingImport?
    @State private var errorMessage: String?
    @State private var isPreparingBackup = false
    @State private var readyBackup: ReadyFile?

    struct ReadyFile: Identifiable {
        let id = UUID()
        let url: URL
    }

    struct PendingImport: Identifiable {
        let id = UUID()
        let archive: DataArchive
    }

    var body: some View {
        Section {
            // Not a ShareLink: that builds the file only after the tap, on the main thread,
            // so a big library froze the screen for seconds with no sign anything happened
            Button {
                Task { await exportFullBackup() }
            } label: {
                HStack {
                    Label(isPreparingBackup ? "Preparing Backup…" : "Export Full Backup",
                          systemImage: "externaldrive.badge.plus")
                    if isPreparingBackup {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(isPreparingBackup)
            Button {
                showingImporter = true
            } label: {
                Label("Import Backup or Shared Item…", systemImage: "square.and.arrow.down")
            }
        } header: {
            Text("Backup & Sharing")
        } footer: {
            Text("A backup is one JSON file with your songs, set lists, instruments, macros, OSC devices, presets, reference files and AI memory. API keys are never included. Share a single set list, song, instrument or macro group from its own screen.")
        }
        .sheet(item: $pendingImport) { ImportReviewSheet(archive: $0.archive) }
        .sheet(item: $readyBackup) { file in
            ActivityShareSheet(items: [file.url])
                .presentationDetents([.medium, .large])
                .ignoresSafeArea()
        }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.json], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                do { pendingImport = PendingImport(archive: try DataArchiveImporter.read(url)) }
                catch { errorMessage = error.localizedDescription }
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        }
        .alert("Backup", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            if let errorMessage { Text(errorMessage) }
        }
    }

    /// Shows progress right away, gathers the data, then encodes and writes the file in the
    /// background before offering Save / Share
    private func exportFullBackup() async {
        isPreparingBackup = true
        defer { isPreparingBackup = false }
        // Let the spinner appear before the work starts
        try? await Task.sleep(for: .milliseconds(80))
        do {
            let archive = try DataArchiveExporter.fullBackup(context: PersistenceController.shared.viewContext)
            let fileName = ArchiveFile.fullBackup().fileName
            let url = try await Task.detached(priority: .userInitiated) {
                try DataArchiveExporter.write(archive, fileName: fileName)
            }.value
            readyBackup = ReadyFile(url: url)
        } catch {
            errorMessage = "Couldn't make the backup: \(error.localizedDescription)"
        }
    }
}

/// The system share sheet (Save to Files, AirDrop, Mail…) for files that are already made
struct ActivityShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

// MARK: - Import review

struct ImportReviewSheet: View {
    let archive: DataArchive

    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.dismiss) private var dismiss

    @State private var summary: DataArchiveImporter.Summary?
    @State private var confirmingReplace = false
    @State private var result: String?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Contents", value: archive.title)
                    LabeledContent("Type", value: archive.kind == .backup ? "Full backup" : "Shared item")
                    LabeledContent("Created", value: archive.createdAt.formatted(date: .abbreviated, time: .shortened))
                }

                if let summary {
                    Section {
                        ForEach(summary.lines) { line in
                            HStack {
                                Text(DataArchiveImporter.displayName(line.entity, count: line.total))
                                Spacer()
                                if line.existing > 0 {
                                    Text("\(line.existing) already here")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        if summary.fileCount > 0 {
                            Text("\(summary.fileCount) attached file\(summary.fileCount == 1 ? "" : "s") (PDFs, reference files, AI memory)")
                        }
                    } header: {
                        Text("In This File")
                    } footer: {
                        if summary.existingTotal > 0 {
                            Text("Items already on this device are updated to match the file. Nothing else is deleted.")
                        }
                    }
                }

                if let result {
                    Section {
                        Label(result, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                } else {
                    Section {
                        Button {
                            run(.merge)
                        } label: {
                            Label(archive.kind == .backup ? "Merge Into My Library" : "Import", systemImage: "square.and.arrow.down")
                                .font(.body.weight(.semibold))
                        }

                        if archive.kind == .backup {
                            Button(role: .destructive) {
                                confirmingReplace = true
                            } label: {
                                Label("Replace Everything", systemImage: "arrow.triangle.2.circlepath")
                            }
                        }
                    } footer: {
                        if archive.kind == .backup {
                            Text("Merge adds what's missing and updates matching items. Replace Everything deletes all current data first, then restores this backup exactly.")
                        }
                    }
                }
            }
            .navigationTitle("Import")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(result == nil ? "Cancel" : "Done") { dismiss() }
                }
            }
            .onAppear { summary = DataArchiveImporter.summary(of: archive, context: viewContext) }
            .confirmationDialog("Replace everything?", isPresented: $confirmingReplace, titleVisibility: .visible) {
                Button("Delete Current Data and Restore", role: .destructive) { run(.replaceAll) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("All current songs, set lists, instruments, macros, OSC devices, presets and their files will be deleted and replaced with this backup. This can't be undone — export a backup of your current data first if you might need it.")
            }
            .alert("Import Failed", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                if let errorMessage { Text("Nothing was changed. \(errorMessage)") }
            }
        }
    }

    private func run(_ mode: DataArchiveImporter.Mode) {
        do {
            let count = try DataArchiveImporter.apply(archive, mode: mode, context: viewContext)
            result = "Imported \(count) item\(count == 1 ? "" : "s")"
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
