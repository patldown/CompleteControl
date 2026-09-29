//
//  DeviceLibraryView.swift
//  Midi Set List
//

import SwiftUI
import CoreData

struct DeviceLibraryView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @Environment(OSCManager.self) private var oscManager
    @FetchRequest(sortDescriptors: [SortDescriptor(\.name)]) private var instruments: FetchedResults<InstrumentDevice>
    @FetchRequest(sortDescriptors: [SortDescriptor(\.name)]) private var oscTargets: FetchedResults<OSCTarget>

    @State private var showingAddInstrument = false
    @State private var showingAddOSCTarget = false
    @State private var editingOSCTarget: OSCTarget?

    private var isEmpty: Bool { instruments.isEmpty && oscTargets.isEmpty }

    var body: some View {
        NavigationStack {
            Group {
                if isEmpty {
                    ContentUnavailableView(
                        "No Devices",
                        systemImage: "cable.connector",
                        description: Text("Add MIDI instruments or network OSC devices to build a macro library.")
                    )
                } else {
                    List {
                        if !oscTargets.isEmpty {
                            Section("OSC / Network") {
                                ForEach(oscTargets) { target in
                                    OSCTargetRow(target: target)
                                        .swipeActions(edge: .leading) {
                                            Button("Edit") { editingOSCTarget = target }.tint(.blue)
                                        }
                                        .swipeActions(edge: .trailing) {
                                            Button("Delete", role: .destructive) { deleteOSCTarget(target) }
                                        }
                                }
                            }
                        }

                        if !instruments.isEmpty {
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
            }
            .navigationTitle("Devices")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            showingAddOSCTarget = true
                        } label: {
                            Label("Add OSC Target", systemImage: "network.badge.shield.half.filled")
                        }
                        Button {
                            showingAddInstrument = true
                        } label: {
                            Label("Add MIDI Instrument", systemImage: "pianokeys")
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                }
                if !instruments.isEmpty {
                    ToolbarItem(placement: .navigationBarLeading) { EditButton() }
                }
            }
            .sheet(isPresented: $showingAddInstrument) {
                AddEditDeviceView()
            }
            .sheet(isPresented: $showingAddOSCTarget) {
                AddEditOSCTargetView()
            }
            .sheet(item: $editingOSCTarget) { target in
                AddEditOSCTargetView(target: target)
            }
        }
    }

    private func deleteInstruments(at offsets: IndexSet) {
        for index in offsets { viewContext.delete(instruments[index]) }
        try? viewContext.save()
    }

    private func deleteOSCTarget(_ target: OSCTarget) {
        oscManager.disconnect(from: target)
        viewContext.delete(target)
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
