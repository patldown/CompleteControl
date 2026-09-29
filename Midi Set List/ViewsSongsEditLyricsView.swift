//
//  EditLyricsView.swift
//  Midi Set List
//
//  Created by Patrick Downey on 9/25/26.
//

import SwiftUI
import CoreData
import UniformTypeIdentifiers
import PhotosUI

struct EditLyricsView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var song: Song

    @State private var lyricsText: String
    @State private var showingFilePicker = false
    @State private var pdfError: String?
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var isImportingImages = false
    @FocusState private var isEditorFocused: Bool

    init(song: Song) {
        self.song = song
        _lyricsText = State(initialValue: song.lyrics ?? "")
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Info banner
                HStack {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(.blue)
                    Text("Add lyrics, chords, or tabs. Use monospaced font for chord alignment.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding()
                .background(Color(.systemGroupedBackground))

                // Sheet music row: one PDF, or a set of images (adding one replaces the other)
                HStack {
                    if song.pdfFileName != nil {
                        Image(systemName: "doc.fill")
                            .foregroundStyle(.red)
                        Text("Sheet music PDF attached")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if !song.chartImageNames.isEmpty {
                        Image(systemName: "photo.on.rectangle")
                            .foregroundStyle(.blue)
                        let count = song.chartImageNames.count
                        Text("Sheet music: \(count) image\(count == 1 ? "" : "s")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Image(systemName: "music.note.list")
                            .foregroundStyle(.secondary)
                        Text("Attach sheet music — PDF or images (optional)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if isImportingImages {
                        ProgressView().controlSize(.small)
                    }
                    Menu(song.hasSheetMusic ? "Change" : "Attach") {
                        PhotosPicker(selection: $photoItems, maxSelectionCount: 40, matching: .images) {
                            Label(song.chartImageNames.isEmpty ? "Images from Photos" : "Add Images from Photos",
                                  systemImage: "photo.on.rectangle")
                        }
                        Button {
                            showingFilePicker = true
                        } label: {
                            Label("PDF or Images from Files", systemImage: "folder")
                        }
                    }
                    .font(.caption)
                    if song.hasSheetMusic {
                        Button("Remove") {
                            removeSheetMusic()
                        }
                        .font(.caption)
                        .foregroundStyle(.red)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 10)
                .background(Color(.systemGroupedBackground))

                if let error = pdfError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.horizontal)
                }

                // Text editor
                TextEditor(text: $lyricsText)
                    .font(.system(size: 16, design: .monospaced))
                    .focused($isEditorFocused)
                    .padding(8)
                    .scrollContentBackground(.hidden)
                    .background(Color(.systemBackground))
            }
            .navigationTitle("Lyrics & Sheet Music")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveLyrics()
                    }
                }

                ToolbarItem(placement: .keyboard) {
                    HStack {
                        Button("Clear") {
                            lyricsText = ""
                        }
                        .foregroundStyle(.red)

                        Spacer()

                        Button("Done") {
                            isEditorFocused = false
                        }
                    }
                }
            }
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    isEditorFocused = true
                }
            }
            .fileImporter(
                isPresented: $showingFilePicker,
                allowedContentTypes: [.pdf, .image],
                allowsMultipleSelection: true
            ) { result in
                guard case .success(let urls) = result, !urls.isEmpty else { return }
                if let pdf = urls.first(where: { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .pdf) == true }) {
                    attachPDF(from: pdf)
                } else {
                    let datas = urls.compactMap { url -> Data? in
                        let accessed = url.startAccessingSecurityScopedResource()
                        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                        return try? Data(contentsOf: url)
                    }
                    addImages(datas)
                }
            }
            .onChange(of: photoItems) { _, items in
                guard !items.isEmpty else { return }
                isImportingImages = true
                Task {
                    var datas: [Data] = []
                    for item in items {  // in the order they were picked
                        if let data = try? await item.loadTransferable(type: Data.self) { datas.append(data) }
                    }
                    addImages(datas)
                    photoItems = []
                    isImportingImages = false
                }
            }
        }
    }

    private func saveLyrics() {
        song.lyrics = lyricsText.isEmpty ? nil : lyricsText
        try? viewContext.save()
        dismiss()
    }

    private func attachPDF(from sourceURL: URL) {
        let accessed = sourceURL.startAccessingSecurityScopedResource()
        defer { if accessed { sourceURL.stopAccessingSecurityScopedResource() } }

        let filename = "\(song.id.uuidString).pdf"
        guard let docDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let destURL = docDir.appendingPathComponent(filename)

        do {
            if FileManager.default.fileExists(atPath: destURL.path) {
                try FileManager.default.removeItem(at: destURL)
            }
            try FileManager.default.copyItem(at: sourceURL, to: destURL)
            removeImages()  // a PDF replaces any sheet-music images
            song.pdfFileName = filename
            pdfError = nil
            try? viewContext.save()
        } catch {
            pdfError = "Could not attach PDF: \(error.localizedDescription)"
        }
    }

    private func removePDF() {
        if let url = song.pdfFileURL {
            try? FileManager.default.removeItem(at: url)
        }
        song.pdfFileName = nil
    }

    private func removeImages() {
        song.chartImageURLs.forEach { try? FileManager.default.removeItem(at: $0) }
        song.chartImageNames = []
    }

    private func removeSheetMusic() {
        removePDF()
        removeImages()
        try? viewContext.save()
    }

    /// Saves images as sheet-music pages after any existing ones. Large photos are scaled
    /// down so pages stay sharp without filling the device.
    private func addImages(_ datas: [Data]) {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        var names = song.chartImageNames
        var failed = 0
        for data in datas {
            guard let image = UIImage(data: data), let jpeg = Self.pageJPEG(image) else { failed += 1; continue }
            let name = "\(song.id.uuidString)-page-\(UUID().uuidString).jpg"
            do {
                try jpeg.write(to: docs.appendingPathComponent(name), options: .atomic)
                names.append(name)
            } catch {
                failed += 1
            }
        }
        guard names != song.chartImageNames else {
            if failed > 0 { pdfError = "Could not add \(failed) image\(failed == 1 ? "" : "s")." }
            return
        }
        removePDF()  // images replace a sheet-music PDF
        song.chartImageNames = names
        pdfError = failed > 0 ? "\(failed) image\(failed == 1 ? "" : "s") could not be added." : nil
        try? viewContext.save()
    }

    private static func pageJPEG(_ image: UIImage, maxDimension: CGFloat = 2400) -> Data? {
        let size = image.size
        let scale = min(1, maxDimension / max(size.width, size.height))
        guard scale < 1 else { return image.jpegData(compressionQuality: 0.85) }
        let target = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return resized.jpegData(compressionQuality: 0.85)
    }
}

#Preview {
    let ctx = PersistenceController.preview.viewContext
    let song = Song.create(
        name: "Sweet Home Alabama",
        lyrics: """
        [Verse 1]
        D    C         G
        Big wheels keep on turning
        """,
        in: ctx
    )
    try? ctx.save()
    return EditLyricsView(song: song)
        .environment(\.managedObjectContext, ctx)
}
