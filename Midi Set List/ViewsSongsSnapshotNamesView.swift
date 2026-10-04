//
//  ViewsSongsSnapshotNamesView.swift
//  Midi Set List
//
//  Sheet that presents AI-suggested snapshot names with editable text fields.
//  The user can tweak any name before tapping Apply All.
//

import SwiftUI
import CoreData

struct SnapshotNamesView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var song: Song
    @State private var names: [String]

    init(song: Song, proposed: [String]) {
        self.song = song
        _names = State(initialValue: proposed)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(0..<names.count, id: \.self) { index in
                        HStack(spacing: 10) {
                            Text(song.snapshotName(index))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .frame(minWidth: 80, alignment: .leading)
                                .lineLimit(1)
                            Image(systemName: "arrow.right")
                                .foregroundStyle(.tertiary)
                                .font(.caption)
                            TextField("Name", text: $names[index])
                        }
                    }
                } header: {
                    Text("Edit any name, then tap Apply All.")
                } footer: {
                    Text("Names are based on the macros loaded into each snapshot and the song's chord chart or lyrics.")
                }
            }
            .navigationTitle("Suggest Snapshot Names")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply All") { apply() }
                }
            }
        }
    }

    private func apply() {
        for (index, name) in names.enumerated() {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            song.renameSnapshot(index, to: trimmed)
        }
        try? viewContext.save()
        dismiss()
    }
}
