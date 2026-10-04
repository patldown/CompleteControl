//
//  SongSnapshotsSection.swift
//  Midi Set List
//
//  One container for a song's snapshots: the strip of snapshot cards on top, and
//  under it whatever the caller passes as `content` — the selected snapshot's
//  macros / commands and the buttons to add or send them.
//

import SwiftUI
import CoreData

struct SongSnapshotsSection<Content: View>: View {
    @Environment(\.managedObjectContext) private var viewContext
    @Environment(PerformanceSession.self) private var performance
    @ObservedObject var song: Song
    @Binding var selected: Int
    /// Replaces the usual hint under the section (e.g. while selecting commands)
    var footerOverride: String?
    @ViewBuilder var content: Content
    @ObservedObject private var remote = MIDIRemoteSettings.shared

    @State private var renamingIndex: Int?
    @State private var renameText = ""
    @State private var deletingIndex: Int?
    @State private var isLoadingNames = false
    @State private var suggestedNames: [String] = []
    @State private var showingNamesSheet = false
    @State private var namesError: String?
    @State private var showingNamesError = false

    var body: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(0..<song.snapshotCount, id: \.self) { index in
                        chip(index)
                    }
                    if song.snapshotCount < Song.maxSnapshots {
                        addChip
                    }
                }
                .padding(.vertical, 4)
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))

            content
        } header: {
            HStack {
                Text("Snapshots")
                Spacer()
                if AISettings.shared.anyAIAvailable && song.snapshotCount > 0 {
                    if isLoadingNames {
                        ProgressView().padding(.trailing, 6)
                    } else {
                        Button { suggestNames() } label: {
                            Label("Suggest Names", systemImage: "sparkles")
                                .labelStyle(.iconOnly)
                        }
                        .foregroundStyle(.tint)
                        .padding(.trailing, 6)
                    }
                }
                Text("\(song.snapshotCount) of \(Song.maxSnapshots)")
                    .foregroundStyle(.secondary)
            }
        } footer: {
            Text(footerOverride ?? footerText)
        }
        .alert("Rename Snapshot", isPresented: Binding(
            get: { renamingIndex != nil },
            set: { if !$0 { renamingIndex = nil } }
        )) {
            TextField("Name", text: $renameText)
            Button("Save") {
                if let index = renamingIndex {
                    song.renameSnapshot(index, to: renameText)
                    try? viewContext.save()
                }
                renamingIndex = nil
            }
            Button("Cancel", role: .cancel) { renamingIndex = nil }
        }
        .confirmationDialog(
            "Delete \(deletingIndex.map { song.snapshotName($0) } ?? "Snapshot")?",
            isPresented: Binding(
                get: { deletingIndex != nil },
                set: { if !$0 { deletingIndex = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let index = deletingIndex { delete(index) }
                deletingIndex = nil
            }
        } message: {
            if let index = deletingIndex {
                let count = song.commands(inSnapshot: index).count
                Text("Its \(count) command\(count == 1 ? "" : "s") will be removed. Later snapshots move up one place\(remote.isEnabled ? " — and onto the MIDI number before them" : "").")
            }
        }
        .onChange(of: song.snapshotCount) { _, count in
            if selected >= count { selected = max(0, count - 1) }
        }
        // Don't leave a snapshot Learn waiting after leaving the song
        .onDisappear {
            if case .snapshot = performance.learnTarget { performance.learnTarget = nil }
        }
        .sheet(isPresented: $showingNamesSheet) {
            SnapshotNamesView(song: song, proposed: suggestedNames)
        }
        .alert("Couldn't Suggest Names", isPresented: $showingNamesError) {
            Button("OK", role: .cancel) {}
        } message: {
            if let namesError { Text(namesError) }
        }
    }

    private func suggestNames() {
        guard !isLoadingNames else { return }
        isLoadingNames = true
        Task {
            do {
                suggestedNames = try await SnapshotNamesAI.suggest(for: song)
                showingNamesSheet = true
            } catch {
                namesError = error.localizedDescription
                showingNamesError = true
            }
            isLoadingNames = false
        }
    }

    private var footerText: String {
        var text = "Tap a snapshot to see its commands. Long-press it to rename, duplicate, delete or learn its MIDI pedal. Commands send top to bottom; drag to reorder."
        if !song.canAddSnapshot && song.snapshotCount < Song.maxSnapshots {
            text += " Add something to Snapshot 1 to unlock more snapshots."
        }
        if remote.isEnabled {
            text += " MIDI: \(remote.snapshotRangeLabel) on \(remote.receiveChannelLabel)."
        }
        return text
    }

    // MARK: Chips

    private func chip(_ index: Int) -> some View {
        let isSelected = selected == index
        let isLive = performance.isActive(snapshot: index, of: song)
        let count = song.commands(inSnapshot: index).count

        // A Menu with a primary action, not a Button with .contextMenu: the whole strip is one
        // List row, and a context menu inside a row lifts the entire row and can open the
        // first chip's menu instead of the pressed one. Each Menu owns its own long-press.
        return Menu {
            chipMenu(index, count: count)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    if isLive {
                        Circle().fill(.green).frame(width: 7, height: 7)
                    }
                    Text(song.snapshotName(index))
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                }
                HStack(spacing: 6) {
                    Text("\(count) cmd")
                    if performance.learnTarget == .snapshot(index) {
                        Text("Press a pedal…")
                    } else if remote.isEnabled, let binding = remote.snapshotBinding(for: index) {
                        Text(binding.label)
                    }
                }
                .font(.caption2.monospacedDigit())
                .opacity(0.8)
            }
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(minWidth: 96, alignment: .leading)
            .background(isSelected ? Color.accentColor : Color(.tertiarySystemFill),
                        in: RoundedRectangle(cornerRadius: 10))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        } primaryAction: {
            selected = index
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
    }

    @ViewBuilder
    private func chipMenu(_ index: Int, count: Int) -> some View {
        Button {
            renameText = song.snapshotName(index)
            renamingIndex = index
        } label: {
            Label("Rename", systemImage: "pencil")
        }
        if song.canAddSnapshot {
            Button {
                if let newIndex = song.duplicateSnapshot(index, in: viewContext) {
                    try? viewContext.save()
                    selected = newIndex
                }
            } label: {
                Label("Duplicate", systemImage: "plus.square.on.square")
            }
        }
        if remote.isEnabled {
            Button {
                performance.learnTarget = .snapshot(index)
            } label: {
                Label("Learn MIDI Trigger", systemImage: "ear")
            }
            if remote.hasOverride(forSnapshot: index) {
                Button {
                    remote.setBinding(nil, for: .snapshot(index))
                } label: {
                    Label("Use Counted MIDI Number", systemImage: "arrow.uturn.backward")
                }
            }
        }
        if count > 0 {
            Button {
                performance.focus(song)
                performance.selectSnapshot(index)
            } label: {
                Label("Send Now", systemImage: "paperplane")
            }
        }
        if song.snapshotCount > 1 {
            Divider()
            Button(role: .destructive) {
                deletingIndex = index
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private var addChip: some View {
        Button {
            if let index = song.addSnapshot() {
                try? viewContext.save()
                selected = index
            }
        } label: {
            Label("Add", systemImage: "plus")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(minHeight: 44)
                .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .foregroundStyle(song.canAddSnapshot ? Color.accentColor : Color.secondary)
        .disabled(!song.canAddSnapshot)
    }

    private func delete(_ index: Int) {
        song.deleteSnapshot(index, in: viewContext)
        try? viewContext.save()
        if selected >= index && selected > 0 { selected -= 1 }
    }
}
