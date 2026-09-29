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
    @State private var selectedTemplate: MIDICommandTemplate?
    @State private var showingTemplates = false
    @State private var showingGenrePicker = false
    
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Song Name", text: $name)
                    TextField("Artist (optional)", text: $artist)
                    Button {
                        showingGenrePicker = true
                    } label: {
                        HStack {
                            Text("Genre")
                                .foregroundStyle(.primary)
                            Spacer()
                            Text(selectedGenres.isEmpty
                                 ? "Unspecified"
                                 : selectedGenres.sorted().joined(separator: ", "))
                                .foregroundStyle(selectedGenres.isEmpty ? .secondary : .primary)
                                .multilineTextAlignment(.trailing)
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
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
    
    private func addSong() {
        let song = Song.create(
            name: name,
            artist: artist.isEmpty ? nil : artist,
            notes: notes.isEmpty ? nil : notes,
            in: viewContext
        )
        song.setGenres(Array(selectedGenres))
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
