//
//  BandSettingsView.swift
//  Midi Set List
//
//  Settings › Band: which roles this device plays, how chords read, and the band's
//  roster of roles that song parts are addressed to.
//

import SwiftUI
import CoreData

struct BandSettingsView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @ObservedObject private var band = BandSettings.shared
    @FetchRequest(sortDescriptors: [SortDescriptor(\.orderIndexRaw)]) private var roles: FetchedResults<BandRole>

    @State private var editingRole: BandRole?
    @State private var addingRole = false
    @State private var deletingRole: BandRole?

    var body: some View {
        List {
            Section {
                ForEach(roles) { role in
                    Button {
                        band.toggleMyRole(role)
                    } label: {
                        HStack {
                            Text(role.label).foregroundStyle(.primary)
                            Spacer()
                            if band.myRoleIDs.contains(role.id) {
                                Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                            }
                        }
                    }
                }
            } header: {
                Text("This Device Plays")
            } footer: {
                Text(band.showsAllParts
                     ? "Nothing picked: this device shows every part of every song — handy for a band leader. Pick your roles to see only the parts addressed to you."
                     : "Perform shows the parts addressed to \(roles.filter { band.myRoleIDs.contains($0.id) }.seenByLabel), plus parts for everyone. A song can override this for the songs where you switch instruments.")
            }

            Section {
                Picker("Chords Shown As", selection: $band.chordDisplay) {
                    ForEach(ChordDisplay.allCases) { Text($0.title).tag($0) }
                }
            } footer: {
                Text("On songs with a capo: Capo Shapes shows the chords a guitarist plays; Concert Pitch shows the chords the audience hears — best for keys, bass and horns sharing a guitar chart.")
            }

            Section {
                ForEach(roles) { role in
                    Button {
                        editingRole = role
                    } label: {
                        HStack {
                            Text(role.label).foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: "pencil").font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { deletingRole = role } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
                .onMove(perform: moveRoles)

                Button {
                    addingRole = true
                } label: {
                    Label("Add Role", systemImage: "plus.circle.fill")
                }
            } header: {
                Text("Band Roster")
            } footer: {
                Text("The roles a song's parts can be addressed to. Built-in roles match on every bandmate's device, so shared parts reach the right people.")
            }
        }
        .navigationTitle("Band")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { EditButton() }
        .sheet(item: $editingRole) { role in
            RoleEditorSheet(role: role)
        }
        .sheet(isPresented: $addingRole) {
            RoleEditorSheet(role: nil)
        }
        .confirmationDialog(
            "Delete \(deletingRole?.name ?? "Role")?",
            isPresented: Binding(get: { deletingRole != nil }, set: { if !$0 { deletingRole = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let role = deletingRole { delete(role) }
                deletingRole = nil
            }
        } message: {
            Text("Parts addressed only to \(deletingRole?.name ?? "this role") will be shown to everyone.")
        }
    }

    private func moveRoles(from source: IndexSet, to destination: Int) {
        var ordered = Array(roles)
        ordered.move(fromOffsets: source, toOffset: destination)
        for (index, role) in ordered.enumerated() { role.orderIndex = index }
        try? viewContext.save()
    }

    private func delete(_ role: BandRole) {
        band.myRoleIDs.remove(role.id)
        viewContext.delete(role)
        try? viewContext.save()
    }
}

/// Add or rename a role
private struct RoleEditorSheet: View {
    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.dismiss) private var dismiss
    let role: BandRole?

    @State private var name: String
    @State private var emoji: String

    private static let emojiChoices = ["🎤", "🎸", "🎹", "🎵", "🥁", "🎺", "🎷", "🎻", "🪕", "🪘", "🎧", "🎛️"]

    init(role: BandRole?) {
        self.role = role
        _name = State(initialValue: role?.name ?? "")
        _emoji = State(initialValue: role?.emoji ?? "🎵")
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name, e.g. Horns", text: $name)
                Section("Icon") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 10) {
                        ForEach(Self.emojiChoices, id: \.self) { choice in
                            Button {
                                emoji = choice
                            } label: {
                                Text(choice)
                                    .font(.title2)
                                    .frame(width: 44, height: 44)
                                    .background(emoji == choice ? Color.accentColor.opacity(0.25) : .clear,
                                                in: RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle(role == nil ? "New Role" : "Edit Role")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if let role {
            role.name = trimmed
            role.emoji = emoji
        } else {
            let order = (BandRole.all(in: viewContext).map(\.orderIndex).max() ?? -1) + 1
            BandRole.create(name: trimmed, emoji: emoji, order: order, in: viewContext)
        }
        try? viewContext.save()
        dismiss()
    }
}
