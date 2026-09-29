//
//  EditLyricsView.swift
//  Midi Set List
//
//  Created by Patrick Downey on 9/25/26.
//

import SwiftUI
import CoreData
import UniformTypeIdentifiers

struct EditLyricsView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var song: Song

    @State private var lyricsText: String
    @State private var showingFilePicker = false
    @State private var pdfError: String?
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

                // PDF attachment row
                HStack {
                    if song.pdfFileName != nil {
                        Image(systemName: "doc.fill")
                            .foregroundStyle(.red)
                        Text("PDF attached — shown in performance view")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Remove") {
                            removePDF()
                        }
                        .font(.caption)
                        .foregroundStyle(.red)
                    } else {
                        Image(systemName: "doc")
                            .foregroundStyle(.secondary)
                        Text("Attach sheet music PDF (optional)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Attach PDF") {
                            showingFilePicker = true
                        }
                        .font(.caption)
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
            .navigationTitle("Edit Lyrics / Tabs")
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
                allowedContentTypes: [.pdf],
                allowsMultipleSelection: false
            ) { result in
                guard case .success(let urls) = result, let url = urls.first else { return }
                attachPDF(from: url)
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
        try? viewContext.save()
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
