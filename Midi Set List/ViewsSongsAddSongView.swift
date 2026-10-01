//
//  AddSongView.swift
//  Midi Set List
//
//  Created by Patrick Downey on 9/25/26.
//

import SwiftUI
import CoreData

struct AddSongView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.dismiss) private var dismiss
    
    @State private var name = ""
    @State private var artist = ""
    @State private var selectedGenres: Set<String> = []
    @State private var notes = ""
    @State private var keyRoot = ""
    @State private var keyScale: MusicalScale = .major
    @State private var bpm: Int?
    /// Starts at the Settings default, if one is set
    @State private var timeSignature = SongDefaults.timeSignature ?? ""

    private let timeSignatures = SongDefaults.timeSignatures
    @State private var selectedTemplate: MIDICommandTemplate?
    @State private var showingTemplates = false
    @State private var showingGenrePicker = false
    
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    // Laid out like the song editor: Name | Artist, Genre | BPM | Time Sig.,
                    // Key | Scale. Only the name is required.
                    HStack(alignment: .top, spacing: 12) {
                        field("Name") {
                            TextField("Song Name", text: $name)
                                .font(.headline)
                        }
                        field("Artist") {
                            TextField("Optional", text: $artist)
                        }
                    }

                    HStack(alignment: .top, spacing: 12) {
                        field("Genre") {
                            Button {
                                showingGenrePicker = true
                            } label: {
                                Text(selectedGenres.isEmpty ? "None" : selectedGenres.sorted().joined(separator: ", "))
                                    .foregroundStyle(selectedGenres.isEmpty ? .secondary : .primary)
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.borderless)
                        }
                        field("BPM") {
                            TextField("Optional", value: Binding<Int?>(
                                get: { bpm },
                                set: { bpm = $0.map { max(20, min(300, $0)) } }
                            ), format: .number)
                            .keyboardType(.numberPad)
                            .monospacedDigit()
                        }
                        field("Time Sig.") {
                            Picker("Time Signature", selection: $timeSignature) {
                                Text("—").tag("")
                                ForEach(timeSignatures, id: \.self) { Text($0).tag($0) }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                        }
                    }
                    // Key and Scale side by side, as in the song editor
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Key").font(.caption).foregroundStyle(.secondary)
                            Picker("Key", selection: $keyRoot) {
                                Text("None").tag("")
                                ForEach(NoteName.pickerRoots, id: \.self) { root in
                                    Text(root.replacingOccurrences(of: "#", with: "♯").replacingOccurrences(of: "b", with: "♭"))
                                        .tag(root)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Scale").font(.caption).foregroundStyle(.secondary)
                            Picker("Scale", selection: $keyScale) {
                                ForEach(MusicalScale.allCases) { scale in
                                    Text(scale.rawValue).tag(scale)
                                }
                            }
                            .disabled(keyRoot.isEmpty)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    TextField("Notes (optional)", text: $notes, axis: .vertical)
                        .lineLimit(3...6)
                } header: {
                    Text("Song Details")
                }
                
                Section {
                    Button {
                        showingTemplates = true
                    } label: {
                        Label("Add MIDI Commands from Template", systemImage: "doc.text")
                    }
                    
                    if let template = selectedTemplate {
                        HStack {
                            Image(systemName: template.deviceType.icon)
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(template.name)
                                    .font(.subheadline)
                                Text("\(template.commands.count) commands")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Remove") {
                                selectedTemplate = nil
                            }
                            .font(.caption)
                            .foregroundStyle(.red)
                        }
                    }
                } header: {
                    Text("MIDI Commands")
                } footer: {
                    Text("You can add commands from a template now, or add them later.")
                }
            }
            .navigationTitle("Add Song")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        addSong()
                    }
                    .disabled(name.isEmpty)
                }
            }
            .sheet(isPresented: $showingTemplates) {
                TemplatePickerView(selectedTemplate: $selectedTemplate)
            }
            .sheet(isPresented: $showingGenrePicker) {
                GenrePickerSheet(selectedGenres: $selectedGenres)
            }
        }
    }
    
    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func addSong() {
        let song = Song.create(
            name: name,
            artist: artist.isEmpty ? nil : artist,
            notes: notes.isEmpty ? nil : notes,
            in: viewContext
        )
        // Set after creating, so the tempo doesn't switch MIDI clock on; that's its own
        // switch in the song editor
        song.bpm = bpm
        song.timeSignature = timeSignature.isEmpty ? nil : timeSignature
        song.setGenres(Array(selectedGenres))
        if !keyRoot.isEmpty { song.originalKey = MusicalKey(root: keyRoot, scale: keyScale) }
        if let template = selectedTemplate {
            for command in template.createCommands(in: viewContext) {
                song.addCommand(command)
            }
        }
        try? viewContext.save()
        dismiss()
    }
}

struct TemplatePickerView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var selectedTemplate: MIDICommandTemplate?
    
    var groupedTemplates: [MIDICommandTemplate.DeviceType: [MIDICommandTemplate]] {
        Dictionary(grouping: MIDICommandTemplate.allTemplates, by: { $0.deviceType })
    }
    
    var body: some View {
        NavigationStack {
            List {
                ForEach(MIDICommandTemplate.DeviceType.allCases, id: \.self) { deviceType in
                    if let templates = groupedTemplates[deviceType] {
                        Section(deviceType.rawValue) {
                            ForEach(templates) { template in
                                Button {
                                    selectedTemplate = template
                                    dismiss()
                                } label: {
                                    HStack {
                                        Image(systemName: template.deviceType.icon)
                                            .foregroundStyle(.blue)
                                            .frame(width: 30)
                                        
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(template.name)
                                                .font(.headline)
                                                .foregroundStyle(.primary)
                                            Text(template.description)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                            Text("\(template.commands.count) commands")
                                                .font(.caption2)
                                                .foregroundStyle(.tertiary)
                                        }
                                        
                                        Spacer()
                                        
                                        if selectedTemplate?.id == template.id {
                                            Image(systemName: "checkmark")
                                                .foregroundStyle(.blue)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Choose Template")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
    }
}

#Preview {
    AddSongView()
        .environment(\.managedObjectContext, PersistenceController.preview.viewContext)
}

#Preview("Template Picker") {
    TemplatePickerView(selectedTemplate: .constant(nil))
}
