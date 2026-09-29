//
//  AddEditDeviceView.swift
//  Midi Set List
//

import SwiftUI
import CoreData

struct AddEditDeviceView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.dismiss) private var dismiss

    var device: InstrumentDevice?

    @State private var name: String
    @State private var manufacturer: String
    @State private var midiChannel: Int

    init(device: InstrumentDevice? = nil) {
        self.device = device
        _name = State(initialValue: device?.name ?? "")
        _manufacturer = State(initialValue: device?.manufacturer ?? "")
        _midiChannel = State(initialValue: device?.midiChannel ?? 1)
    }

    var isEditing: Bool { device != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section("Device Info") {
                    TextField("Name (e.g. HX Stomp, BeatBuddy)", text: $name)
                    TextField("Manufacturer (optional)", text: $manufacturer)
                }

                Section("MIDI") {
                    Picker("Default Channel", selection: $midiChannel) {
                        ForEach(1...16, id: \.self) { ch in
                            Text("Channel \(ch)").tag(ch)
                        }
                    }
                }
            }
            .navigationTitle(isEditing ? "Edit Device" : "New Device")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedManufacturer = manufacturer.trimmingCharacters(in: .whitespaces)

        if let device {
            device.name = trimmedName
            device.manufacturer = trimmedManufacturer.isEmpty ? nil : trimmedManufacturer
            device.midiChannel = midiChannel
        } else {
            let _ = InstrumentDevice.create(
                name: trimmedName,
                manufacturer: trimmedManufacturer.isEmpty ? nil : trimmedManufacturer,
                midiChannel: midiChannel,
                in: viewContext
            )
        }
        try? viewContext.save()
        dismiss()
    }
}
