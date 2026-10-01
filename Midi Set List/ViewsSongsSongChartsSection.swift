//
//  SongChartsSection.swift
//  Midi Set List
//
//  The song editor's "Charts & Parts": the song's own chart plus any parts (a piano
//  part, drum cues…), each addressed to the band roles that should see it. Also where
//  this device can play something else on just this song.
//

import SwiftUI
import CoreData

struct SongChartsSection: View {
    @Environment(\.managedObjectContext) private var viewContext
    @ObservedObject var song: Song
    /// Opens full-screen Performance Mode
    let onPerform: () -> Void

    @ObservedObject private var band = BandSettings.shared
    @FetchRequest(sortDescriptors: [SortDescriptor(\.orderIndexRaw)]) private var roles: FetchedResults<BandRole>

    @State private var editing: EditingChart?
    @State private var addingPart = false
    @State private var newPartName = ""
    @State private var renamingPart: SongPart?
    @State private var renameText = ""
    @State private var deletingPart: SongPart?

    private struct EditingChart: Identifiable { let id: UUID }

    private static let partSuggestions = ["Piano Part", "Bass Chart", "Drum Cues", "Vocal Harmonies", "Lead Sheet"]

    var body: some View {
        Section {
            ForEach(song.chartSources, id: \.id) { chart in
                chartRow(chart)
            }

            Menu {
                ForEach(Self.partSuggestions, id: \.self) { name in
                    Button(name) { addPart(named: name) }
                }
                Divider()
                Button {
                    newPartName = ""
                    addingPart = true
                } label: {
                    Label("Custom Name…", systemImage: "character.cursor.ibeam")
                }
            } label: {
                Label("Add Part", systemImage: "plus.circle.fill")
            }

            if !roles.isEmpty {
                deviceOverrideRow
            }

            if song.hasAnyChart {
                Button(action: onPerform) {
                    Label("Performance Mode", systemImage: "play.rectangle.fill")
                        .foregroundStyle(.green)
                }
            }
        } header: {
            Text("Charts & Parts")
        } footer: {
            Text("Chart is the song's own lyrics and sheet music. Add parts for players who need something different, and pick who sees each one — share one chart between guitar and keys, give drums their own cues. Perform shows each device the parts for its roles (Settings › Band).")
        }
        .sheet(item: $editing) { item in
            if let part = song.parts.first(where: { $0.id == item.id }) {
                EditLyricsView(source: part)
            } else {
                EditLyricsView(song: song)
            }
        }
        .alert("New Part", isPresented: $addingPart) {
            TextField("e.g. Horn Lines", text: $newPartName)
            Button("Add") { addPart(named: newPartName) }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename Part", isPresented: Binding(
            get: { renamingPart != nil }, set: { if !$0 { renamingPart = nil } }
        )) {
            TextField("Name", text: $renameText)
            Button("Save") {
                let trimmed = renameText.trimmingCharacters(in: .whitespaces)
                if let part = renamingPart, !trimmed.isEmpty {
                    part.name = trimmed
                    save()
                }
                renamingPart = nil
            }
            Button("Cancel", role: .cancel) { renamingPart = nil }
        }
        .confirmationDialog(
            "Delete \(deletingPart?.name ?? "Part")?",
            isPresented: Binding(get: { deletingPart != nil }, set: { if !$0 { deletingPart = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete Part", role: .destructive) {
                if let part = deletingPart {
                    song.deletePart(part, in: viewContext)
                    save()
                }
                deletingPart = nil
            }
        } message: {
            Text("Its lyrics and sheet music are removed from this song.")
        }
    }

    // MARK: Rows

    private func chartRow(_ chart: any ChartSource) -> some View {
        let part = chart as? SongPart
        return HStack(spacing: 10) {
            Button {
                editing = EditingChart(id: chart.id)
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(chart.chartName)
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Text(chart.hasContent ? chart.contentSummary : "Empty — tap to add lyrics, a PDF or images")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !roles.isEmpty {
                seenByMenu(chart)
            }
        }
        .swipeActions(edge: .trailing) {
            if let part {
                Button(role: .destructive) { deletingPart = part } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
        .contextMenu {
            Button {
                editing = EditingChart(id: chart.id)
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            if let part {
                Button {
                    renameText = part.name
                    renamingPart = part
                } label: {
                    Label("Rename", systemImage: "character.cursor.ibeam")
                }
                Button(role: .destructive) { deletingPart = part } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }

    /// "Seen by" picker: stays open while toggling roles, so several take one visit
    private func seenByMenu(_ chart: any ChartSource) -> some View {
        let current = chart.seenBy
        let ids = Set(current.map(\.id))
        return Menu {
            Button {
                chart.setSeenBy([])
                save()
            } label: {
                if ids.isEmpty { Label("Everyone", systemImage: "checkmark") } else { Text("Everyone") }
            }
            Divider()
            ForEach(roles) { role in
                Button {
                    var updated = current
                    if ids.contains(role.id) {
                        updated.removeAll { $0.id == role.id }
                    } else {
                        updated.append(role)
                    }
                    chart.setSeenBy(updated)
                    save()
                } label: {
                    if ids.contains(role.id) { Label(role.label, systemImage: "checkmark") } else { Text(role.label) }
                }
                .menuActionDismissBehavior(.disabled)
            }
        } label: {
            Text(current.isEmpty ? "Everyone" : current.map { $0.emoji.isEmpty ? $0.name : $0.emoji }.joined(separator: " "))
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.accentColor.opacity(current.isEmpty ? 0.1 : 0.2), in: Capsule())
        }
        .accessibilityLabel("Seen by")
        .accessibilityValue(current.seenByLabel)
    }

    /// Play something else on just this song, on this device
    private var deviceOverrideRow: some View {
        let override = band.roleOverride(for: song)
        let active = override ?? band.myRoleIDs
        let activeRoles = roles.filter { active.contains($0.id) }
        return Menu {
            Button {
                band.setRoleOverride(nil, for: song)
            } label: {
                let label = "Same as Settings (\(band.showsAllParts ? "all parts" : roles.filter { band.myRoleIDs.contains($0.id) }.map(\.name).joined(separator: ", ")))"
                if override == nil { Label(label, systemImage: "checkmark") } else { Text(label) }
            }
            Divider()
            ForEach(roles) { role in
                Button {
                    var ids = override ?? band.myRoleIDs
                    if ids.contains(role.id) { ids.remove(role.id) } else { ids.insert(role.id) }
                    band.setRoleOverride(ids, for: song)
                } label: {
                    if override?.contains(role.id) == true { Label(role.label, systemImage: "checkmark") } else { Text(role.label) }
                }
                .menuActionDismissBehavior(.disabled)
            }
        } label: {
            LabeledContent {
                Text(activeRoles.isEmpty ? "All Parts" : activeRoles.map(\.name).joined(separator: ", "))
                    .foregroundStyle(override == nil ? Color.secondary : Color.accentColor)
            } label: {
                Label("On This Song I Play", systemImage: "person.crop.circle")
                    .foregroundStyle(.primary)
            }
        }
    }

    // MARK: Actions

    private func addPart(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let part = SongPart.create(name: trimmed, for: song, in: viewContext)
        // Suggested parts usually belong to one role; address them to it
        if let role = Self.suggestedRole(for: trimmed, in: Array(roles)) {
            part.setSeenBy([role])
        }
        save()
        editing = EditingChart(id: part.id)
    }

    private static func suggestedRole(for partName: String, in roles: [BandRole]) -> BandRole? {
        let lower = partName.lowercased()
        let hints: [(String, String)] = [("piano", "Keys"), ("keys", "Keys"), ("bass", "Bass"),
                                         ("drum", "Drums"), ("vocal", "Vocals"), ("guitar", "Guitar")]
        guard let match = hints.first(where: { lower.contains($0.0) }) else { return nil }
        return roles.first { $0.name.caseInsensitiveCompare(match.1) == .orderedSame }
    }

    private func save() {
        song.dateModified = Date()
        try? viewContext.save()
    }
}
