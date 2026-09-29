//
//  ExportCommandsView.swift
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

struct ExportCommandsView: View {
    @Environment(\.dismiss) private var dismiss
    let commands: [MIDICommand]

    @State private var exportFormat: ExportFormat = .json
    @State private var exportedContent = ""
    @State private var showingShareSheet = false

    enum ExportFormat: String, CaseIterable {
        case json = "JSON"
        case text = "Plain Text"

        var fileExtension: String {
            switch self {
            case .json: return "json"
            case .text: return "txt"
            }
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Format", selection: $exportFormat) {
                    ForEach(ExportFormat.allCases, id: \.self) { format in
                        Text(format.rawValue).tag(format)
                    }
                }
                .pickerStyle(.segmented)
                .padding()

                ScrollView {
                    Text(exportedContent)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .background(Color(.systemGroupedBackground))
            }
            .navigationTitle("Export Commands")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .primaryAction) {
                    ShareLink(
                        item: exportedContent,
                        preview: SharePreview(
                            "MIDI Commands",
                            image: Image(systemName: "music.note.list")
                        )
                    ) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                }

                ToolbarItem(placement: .secondaryAction) {
                    Button {
                        #if canImport(UIKit)
                        UIPasteboard.general.string = exportedContent
                        #endif
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                }
            }
            .onAppear {
                updateExportedContent()
            }
            .onChange(of: exportFormat) { oldValue, newValue in
                updateExportedContent()
            }
        }
    }

    private func updateExportedContent() {
        switch exportFormat {
        case .json:
            if let data = CommandExporter.exportCommands(commands),
               let jsonString = String(data: data, encoding: .utf8) {
                exportedContent = jsonString
            } else {
                exportedContent = "Error exporting commands"
            }
        case .text:
            exportedContent = CommandExporter.exportAsText(commands)
        }
    }
}

#Preview {
    let ctx = PersistenceController.preview.viewContext
    let cmd1 = MIDICommand(commandType: .bankSelectLSB, channel: 1, value1: 2,
                           delayMilliseconds: 50, notes: "BeatBuddy folder 2", context: ctx)
    let cmd2 = MIDICommand(commandType: .programChange, channel: 1, value1: 5,
                           delayMilliseconds: 100, notes: "Song 5", context: ctx)
    ExportCommandsView(commands: [cmd1, cmd2])
}
