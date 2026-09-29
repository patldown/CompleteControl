//
//  ImportCommandsView.swift
//  Midi Set List
//
//  Created by Patrick Downey on 9/25/26.
//

import SwiftUI
import CoreData
import UniformTypeIdentifiers

#if canImport(UIKit)
import UIKit
#endif

struct ImportCommandsView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.dismiss) private var dismiss
    let song: Song

    @State private var importText = ""
    @State private var importedCommands: [MIDICommand] = []
    @State private var showingError = false
    @State private var errorMessage = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text("Paste JSON Command Data")
                    .font(.headline)
                    .padding(.top)

                TextEditor(text: $importText)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 200)
                    .padding(8)
                    .background(Color(.systemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                    )
                    .padding(.horizontal)

                if !importedCommands.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text("Successfully parsed \(importedCommands.count) command(s)")
                                .font(.subheadline)
                        }

                        ScrollView {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(importedCommands) { command in
                                    HStack {
                                        Text("•")
                                        Text(command.displayDescription)
                                            .font(.caption)
                                    }
                                }
                            }
                        }
                        .frame(maxHeight: 150)
                    }
                    .padding()
                    .background(Color.green.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .padding(.horizontal)
                }

                Button {
                    parseImportedData()
                } label: {
                    Label("Parse JSON", systemImage: "doc.text.magnifyingglass")
                }
                .buttonStyle(.bordered)
                .disabled(importText.isEmpty)

                Spacer()
            }
            .navigationTitle("Import Commands")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        for cmd in importedCommands { viewContext.delete(cmd) }
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") {
                        importCommands()
                    }
                    .disabled(importedCommands.isEmpty)
                }
            }
            .alert("Import Error", isPresented: $showingError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage)
            }
            .onAppear {
                #if canImport(UIKit)
                if let clipboardString = UIPasteboard.general.string,
                   clipboardString.contains("{") || clipboardString.contains("[") {
                    importText = clipboardString
                }
                #endif
            }
        }
    }

    private func parseImportedData() {
        guard let data = importText.data(using: .utf8) else {
            errorMessage = "Invalid text encoding"
            showingError = true
            return
        }

        // Delete previously parsed (unsaved) commands before re-parsing
        for cmd in importedCommands { viewContext.delete(cmd) }

        guard let commands = CommandExporter.importCommands(from: data, in: viewContext) else {
            errorMessage = "Failed to parse JSON. Make sure the format is correct."
            showingError = true
            importedCommands = []
            return
        }

        importedCommands = commands
    }

    private func importCommands() {
        for command in importedCommands {
            song.addCommand(command)
        }
        try? viewContext.save()
        dismiss()
    }
}

#Preview {
    let ctx = PersistenceController.preview.viewContext
    let song = Song.create(name: "Test Song", in: ctx)
    let _ = try? ctx.save()
    ImportCommandsView(song: song)
        .environment(\.managedObjectContext, ctx)
}
