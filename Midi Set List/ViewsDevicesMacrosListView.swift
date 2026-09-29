//
//  MacrosListView.swift
//  Midi Set List
//

import SwiftUI
import CoreData

// MARK: - List view

struct MacrosListView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @ObservedObject var category: MacroCategory
    let device: InstrumentDevice

    @StateObject private var chatSession = MacroChatSession()
    @ObservedObject private var ai = AISettings.shared
    @State private var showingAddMacro = false
    @State private var macroToEdit: DeviceMacro?
    @State private var macroToSync: DeviceMacro?
    @State private var showingChatView = false

    var body: some View {
        Group {
            if category.sortedMacros.isEmpty {
                ContentUnavailableView(
                    "No Macros",
                    systemImage: "waveform.badge.plus",
                    description: Text("Tap + to define your first macro for this category.")
                )
            } else {
                List {
                    ForEach(category.sortedMacros) { macro in
                        MacroRow(macro: macro,
                                 onEditTapped: { macroToEdit = macro },
                                 onSyncTapped: { macroToSync = macro })
                    }
                    .onDelete(perform: deleteMacros)
                }
            }
        }
        .navigationTitle(category.name)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showingAddMacro = true } label: { Image(systemName: "plus") }
            }
            ToolbarItem(placement: .primaryAction) {
                Button { showingChatView = true } label: {
                    Image(systemName: "wand.and.stars")
                        .foregroundStyle(ai.offlineMode ? Color.offlineMode : .accentColor)
                        .offlineModeDot(ai.offlineMode)
                }
                .accessibilityLabel(ai.offlineMode ? "Generate macros (offline, on-device)" : "Generate macros")
            }
            if !category.macros.isEmpty {
                ToolbarItem(placement: .navigationBarLeading) { EditButton() }
            }
        }
        .sheet(isPresented: $showingAddMacro) {
            AddEditMacroView(category: category, device: device)
        }
        .sheet(item: $macroToEdit) { macro in
            AddEditMacroView(category: category, device: device, macro: macro)
        }
        .sheet(item: $macroToSync) { macro in
            MacroSyncSheet(macro: macro)
        }
        .sheet(isPresented: $showingChatView) {
            MacroChatView(category: category, device: device, chatSession: chatSession)
        }
    }

    private func deleteMacros(at offsets: IndexSet) {
        let sorted = category.sortedMacros
        for index in offsets {
            viewContext.delete(sorted[index])
        }
        try? viewContext.save()
    }
}

// MARK: - Row

struct MacroRow: View {
    @ObservedObject var macro: DeviceMacro
    let onEditTapped: () -> Void
    let onSyncTapped: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(macro.name)
                    .font(.headline)
                Text(macro.displayDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fontDesign(.monospaced)
                if let notes = macro.notes, !notes.isEmpty {
                    Text(notes)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { onEditTapped() }

            Button {
                onSyncTapped()
            } label: {
                Text("Sync")
                    .font(.caption)
                    .fontWeight(.medium)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(macro.hasDrift ? Color.orange.opacity(0.15) : Color.secondary.opacity(0.08))
                    .foregroundStyle(macro.hasDrift ? .orange : .secondary)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!macro.hasDrift)
            .accessibilityLabel(macro.hasDrift
                ? "Sync \(macro.name) — references differ"
                : "\(macro.name) is up to date")
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Sync sheet

struct MacroSyncSheet: View {
    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.dismiss) private var dismiss

    @ObservedObject var macro: DeviceMacro

    @State private var selectedIDs: Set<Song.ID> = []

    var body: some View {
        NavigationStack {
            Group {
                if driftingSongs.isEmpty {
                    ContentUnavailableView(
                        "All References Up to Date",
                        systemImage: "checkmark.circle",
                        description: Text("Every song using this macro already matches its current settings.")
                    )
                } else {
                    List(driftingSongs, selection: $selectedIDs) { song in
                        SyncSongRow(song: song, isSelected: selectedIDs.contains(song.id)) {
                            toggleSelection(song)
                        }
                    }
                }
            }
            .navigationTitle("Sync \"\(macro.name)\"")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(syncButtonLabel) { applySync() }
                        .disabled(selectedIDs.isEmpty)
                        .fontWeight(.semibold)
                }
            }
            .onAppear {
                // Pre-select all drifting songs
                selectedIDs = Set(driftingSongs.map(\.id))
            }
        }
    }

    private var driftingSongs: [Song] { macro.driftingSongs }

    private var syncButtonLabel: String {
        selectedIDs.isEmpty ? "Sync" : "Sync (\(selectedIDs.count))"
    }

    private func toggleSelection(_ song: Song) {
        if selectedIDs.contains(song.id) {
            selectedIDs.remove(song.id)
        } else {
            selectedIDs.insert(song.id)
        }
    }

    private func applySync() {
        let toSync = driftingSongs.filter { selectedIDs.contains($0.id) }
        for song in toSync {
            song.applyMacroDrift(macro, in: viewContext)
        }
        try? viewContext.save()
        // If all drifting songs were synced the sheet closes naturally;
        // if some remain, dismiss so the user sees the updated Sync button state.
        dismiss()
    }
}

// MARK: - Sync song row

private struct SyncSongRow: View {
    let song: Song
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? .orange : .secondary)
                    .imageScale(.large)

                VStack(alignment: .leading, spacing: 3) {
                    Text(song.name)
                        .font(.headline)
                        .foregroundStyle(.primary)

                    if let artist = song.artist, !artist.isEmpty {
                        Text(artist)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    let setListNames = song.setLists.map(\.name).sorted()
                    if !setListNames.isEmpty {
                        Text(setListNames.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }

                Spacer()
            }
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
    }
}
