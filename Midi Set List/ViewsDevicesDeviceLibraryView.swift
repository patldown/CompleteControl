//
//  DeviceLibraryView.swift
//  Midi Set List
//

import SwiftUI
import CoreData

/// The instrument & macro library. How gear is connected (MIDI, Bluetooth, OSC mixers)
/// lives in the Connections tab.
struct DeviceLibraryView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @FetchRequest(sortDescriptors: [SortDescriptor(\.name)]) private var instruments: FetchedResults<InstrumentDevice>

    @State private var showingAddInstrument = false

    var body: some View {
        NavigationStack {
            Group {
                if instruments.isEmpty {
                    ContentUnavailableView {
                        Label("No Devices", systemImage: "pianokeys")
                    } description: {
                        Text("Add your MIDI instruments to build a macro library. Mixers and other OSC gear are in the Connections tab.")
                    } actions: {
                        Button("Add MIDI Instrument") { showingAddInstrument = true }
                            .buttonStyle(.bordered)
                    }
                } else {
                    List {
                        Section("MIDI Instruments") {
                            ForEach(instruments) { device in
                                NavigationLink(destination: DeviceDetailView(device: device)) {
                                    DeviceRow(device: device)
                                }
                            }
                            .onDelete(perform: deleteInstruments)
                        }
                    }
                }
            }
            .navigationTitle("Devices")
            .offlineStatusBadge()
            .performShortcut()
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingAddInstrument = true
                    } label: {
                        Label("Add MIDI Instrument", systemImage: "plus")
                    }
                }
                if !instruments.isEmpty {
                    ToolbarItem(placement: .navigationBarLeading) { EditButton() }
                }
            }
            .sheet(isPresented: $showingAddInstrument) {
                AddEditDeviceView()
            }
        }
    }

    private func deleteInstruments(at offsets: IndexSet) {
        for index in offsets { viewContext.delete(instruments[index]) }
        try? viewContext.save()
    }
}

struct DeviceRow: View {
    let device: InstrumentDevice

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "pianokeys")
                .font(.title2)
                .foregroundStyle(.blue)
                .frame(width: 36)

            VStack(alignment: .leading, spacing: 3) {
                Text(device.name)
                    .font(.headline)
                if let manufacturer = device.manufacturer, !manufacturer.isEmpty {
                    Text(manufacturer)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                let catCount = device.categories.count
                let macroCount = device.categories.reduce(0) { $0 + $1.macros.count }
                Text("Ch \(device.midiChannel) · \(catCount) categor\(catCount == 1 ? "y" : "ies") · \(macroCount) macro\(macroCount == 1 ? "" : "s")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

#Preview {
    let ctx = PersistenceController.preview.viewContext
    let _ = InstrumentDevice.create(name: "HX Stomp", manufacturer: "Line 6", midiChannel: 1, in: ctx)
    let _ = OSCTarget.create(name: "XR18", host: "192.168.1.100", in: ctx)
    try? ctx.save()
    return DeviceLibraryView()
        .environment(\.managedObjectContext, ctx)
        .environment(OSCManager())
}
