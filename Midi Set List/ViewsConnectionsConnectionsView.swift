//
//  ConnectionsView.swift
//  Midi Set List
//
//  Created by Patrick Downey on 9/25/26.
//
//  Everything about how gear is connected, in one tab: MIDI (status, inputs, then
//  outputs), Bluetooth pairing and pedals, and OSC / network devices such as mixers.
//

import SwiftUI
import CoreData
import CoreAudioKit

struct ConnectionsView: View {
    @Environment(MIDIManager.self) private var midiManager
    @Environment(OSCManager.self) private var oscManager
    @Environment(\.managedObjectContext) private var viewContext
    @FetchRequest(sortDescriptors: [SortDescriptor(\.name)]) private var oscTargets: FetchedResults<OSCTarget>
    @ObservedObject private var pedals = PedalSettings.shared

    @State private var showingAddOSCTarget = false
    @State private var editingOSCTarget: OSCTarget?
    @State private var showingTestSheet = false
    @State private var showingBTMIDI = false
    @State private var lastError: String?
    @State private var showingError = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if midiManager.isInitialized {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text("MIDI System Ready")
                        }
                    } else {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text("MIDI System Error")
                        }
                        
                        if let error = midiManager.lastError {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    
                    if !midiManager.connectedDevices.isEmpty {
                        Button {
                            showingTestSheet = true
                        } label: {
                            Label("Test Connection", systemImage: "waveform")
                        }
                    }

                    if let lastCommand = midiManager.lastSentCommand {
                        LabeledContent("Last Sent") {
                            Text(lastCommand)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("MIDI")
                }

                Section {
                    ForEach(midiManager.availableSources) { source in
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(source.displayName)
                                if let manufacturer = source.manufacturer {
                                    Text(manufacturer)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        } icon: {
                            Image(systemName: "arrow.down.circle")
                                .foregroundStyle(.green)
                        }
                    }
                    if midiManager.availableSources.isEmpty {
                        Text("No MIDI inputs found")
                            .foregroundStyle(.secondary)
                    }
                    NavigationLink {
                        MIDIRemoteSettingsView()
                    } label: {
                        Label("MIDI Receive & Control", systemImage: "slider.horizontal.below.rectangle")
                    }
                } header: {
                    HStack {
                        Text("MIDI Inputs")
                        Spacer()
                        Text("\(midiManager.availableSources.count)")
                            .foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("The app listens to every input — foot controllers, keyboards, Bluetooth MIDI.")
                }

                Section {
                    ForEach(midiManager.availableDevices) { device in
                        DeviceRowView(
                            device: device,
                            isConnected: midiManager.isConnected(device)
                        ) {
                            midiManager.toggleConnection(for: device)
                        }
                    }
                    
                    if midiManager.availableDevices.isEmpty {
                        ContentUnavailableView {
                            Label("No Devices Found", systemImage: "cable.connector")
                        } description: {
                            Text("Make sure your MIDI devices are connected and powered on")
                        } actions: {
                            Button("Scan Again") {
                                midiManager.scanForDevices()
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                } header: {
                    HStack {
                        Text("MIDI Outputs")
                        Spacer()
                        Text("\(midiManager.availableDevices.count)")
                            .foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("Tap a device to connect or disconnect. Connected devices receive MIDI commands.")
                }

                Section {
                    Button {
                        showingBTMIDI = true
                    } label: {
                        Label("Pair Bluetooth MIDI Device", systemImage: "wave.3.right")
                    }
                    NavigationLink {
                        PedalSettingsView()
                    } label: {
                        LabeledContent {
                            Text(pedals.isEnabled ? "On" : "Off")
                        } label: {
                            Label("Page-Turner Pedals", systemImage: "shoe.2")
                        }
                    }
                } header: {
                    Text("Bluetooth")
                } footer: {
                    Text("Bluetooth MIDI gear — foot controllers, keyboards — pairs here, then shows under MIDI Inputs and Outputs above. Page-turner pedals pair in the device's Bluetooth settings.")
                }

                Section {
                    ForEach(oscTargets) { target in
                        OSCTargetRow(target: target)
                            .swipeActions(edge: .leading) {
                                Button("Edit") { editingOSCTarget = target }.tint(.blue)
                            }
                            .swipeActions(edge: .trailing) {
                                Button("Delete", role: .destructive) { deleteOSCTarget(target) }
                            }
                    }
                    Button {
                        showingAddOSCTarget = true
                    } label: {
                        Label("Add OSC Device", systemImage: "plus.circle")
                    }
                } header: {
                    HStack {
                        Text("OSC / Network")
                        Spacer()
                        Text("\(oscTargets.count)")
                            .foregroundStyle(.secondary)
                    }
                } footer: {
                    if let address = oscManager.lastSentAddress {
                        Text("Mixers and other network gear, such as a Behringer XR18 or X32. Last sent: \(address)")
                    } else {
                        Text("Mixers and other network gear, such as a Behringer XR18 or X32. Swipe a device to edit or delete it.")
                    }
                }
            }
            .navigationTitle("Connections")
            .offlineStatusBadge()
            .performShortcut()
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        midiManager.scanForDevices()
                    } label: {
                        Label("Scan", systemImage: "arrow.clockwise")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            showingBTMIDI = true
                        } label: {
                            Label("Pair Bluetooth MIDI Device", systemImage: "wave.3.right")
                        }
                        Button {
                            showingAddOSCTarget = true
                        } label: {
                            Label("Add OSC Device", systemImage: "network")
                        }
                    } label: {
                        Label("Add Connection", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingBTMIDI) {
                BTMIDIConnectSheet()
            }
            .sheet(isPresented: $showingTestSheet) {
                MIDITestView()
            }
            .sheet(isPresented: $showingAddOSCTarget) {
                AddEditOSCTargetView()
            }
            .sheet(item: $editingOSCTarget) { target in
                AddEditOSCTargetView(target: target)
            }
            .alert("MIDI Error", isPresented: $showingError) {
                Button("OK", role: .cancel) {}
            } message: {
                if let error = lastError {
                    Text(error)
                }
            }
            .refreshable {
                midiManager.scanForDevices()
            }
        }
    }

    private func deleteOSCTarget(_ target: OSCTarget) {
        oscManager.disconnect(from: target)
        viewContext.delete(target)
        try? viewContext.save()
    }
}

struct DeviceRowView: View {
    let device: MIDIDevice
    let isConnected: Bool
    let onToggle: () -> Void
    
    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 12) {
                // Connection status indicator
                Circle()
                    .fill(isConnected ? Color.green : Color.secondary.opacity(0.3))
                    .frame(width: 12, height: 12)
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(device.displayName)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    
                    if let manufacturer = device.manufacturer {
                        Text(manufacturer)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    
                    Text("ID: \(device.id)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                
                Spacer()
                
                if isConnected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .imageScale(.large)
                } else {
                    Image(systemName: "circle")
                        .foregroundStyle(.secondary)
                        .imageScale(.large)
                }
            }
            .padding(.vertical, 4)
        }
    }
}

// MARK: - Bluetooth MIDI connect sheet

struct BTMIDIConnectSheet: UIViewControllerRepresentable {
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator { Coordinator(dismiss: dismiss) }

    func makeUIViewController(context: Context) -> UINavigationController {
        let nav = UINavigationController(rootViewController: CABTMIDICentralViewController())
        return nav
    }

    func updateUIViewController(_ nav: UINavigationController, context: Context) {
        guard let btVC = nav.viewControllers.first as? CABTMIDICentralViewController else { return }
        // CABTMIDICentralViewController claims rightBarButtonItem ("Edit"), so put Done on the left.
        // Re-apply on every update in case the VC resets it during viewWillAppear.
        btVC.navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .close,
            target: context.coordinator,
            action: #selector(Coordinator.done)
        )
    }

    final class Coordinator: NSObject {
        let dismiss: DismissAction
        init(dismiss: DismissAction) { self.dismiss = dismiss }
        @objc func done() { dismiss() }
    }
}

#Preview {
    NavigationStack {
        ConnectionsView()
    }
    .environment(MIDIManager())
    .environment(PerformanceSession())
}
