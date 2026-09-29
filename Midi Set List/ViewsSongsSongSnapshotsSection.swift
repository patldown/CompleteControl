//
//  SongSnapshotsSection.swift
//  Midi Set List
//
//  The snapshot strip at the top of a song's command list. Each snapshot is its
//  own group of macros / macro groups / commands; the list below shows whichever
//  snapshot is selected here.
//

import SwiftUI
import CoreData

struct SongSnapshotsSection: View {
    @Environment(\.managedObjectContext) private var viewContext
    @Environment(PerformanceSession.self) private var performance
    @ObservedObject var song: Song
    @Binding var selected: Int
    @ObservedObject private var remote = MIDIRemoteSettings.shared

    @State private var renamingIndex: Int?
    @State private var renameText = ""
    @State private var deletingIndex: Int?

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
        } header: {
            HStack {
                Text("Snapshots")
                Spacer()
                Text("\(song.snapshotCount) of \(Song.maxSnapshots)")
                    .foregroundStyle(.secondary)
            }
        } footer: {
            Text(footerText)
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
    }

    private var footerText: String {
        var text = "Snapshot 1 is sent when the song loads. Tap a snapshot to edit it; long-press to rename, duplicate or delete."
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

        return Button {
            selected = index
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
                    if remote.isEnabled, let binding = remote.snapshotBinding(for: index) {
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
        }
        .buttonStyle(.plain)
        .contextMenu {
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
