//
//  OSCTargetsView.swift
//  Midi Set List
//

import SwiftUI
import CoreData

struct OSCTargetsView: View {
    @Environment(OSCManager.self) private var oscManager
    @Environment(\.managedObjectContext) private var viewContext
    @FetchRequest(sortDescriptors: [SortDescriptor(\.name)]) private var targets: FetchedResults<OSCTarget>

    @State private var showingAddTarget = false
    @State private var editingTarget: OSCTarget?

    var body: some View {
        NavigationStack {
            List {
                if targets.isEmpty {
                    ContentUnavailableView(
                        "No OSC Targets",
                        systemImage: "network",
                        description: Text("Add a network device such as a Behringer XR18 or X32.")
                    )
                } else {
                    Section {
                        ForEach(targets) { target in
                            OSCTargetRow(target: target)
                                .swipeActions(edge: .leading) {
                                    Button("Edit") { editingTarget = target }.tint(.blue)
                                }
                                .swipeActions(edge: .trailing) {
                                    Button("Delete", role: .destructive) { delete(target) }
                                }
                        }
                    } footer: {
                        if let addr = oscManager.lastSentAddress {
                            Label("Last sent: \(addr)", systemImage: "arrow.up.circle")
                                .font(.caption)
                        }
                    }
                }
            }
            .navigationTitle("OSC Targets")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showingAddTarget = true } label: { Image(systemName: "plus") }
                }
            }
            .sheet(isPresented: $showingAddTarget) {
                AddEditOSCTargetView()
            }
            .sheet(item: $editingTarget) { target in
                AddEditOSCTargetView(target: target)
            }
        }
    }

    private func delete(_ target: OSCTarget) {
        oscManager.disconnect(from: target)
        viewContext.delete(target)
        try? viewContext.save()
    }
}

// MARK: - Row

struct OSCTargetRow: View {
    @Environment(OSCManager.self) private var oscManager
    let target: OSCTarget

    var isConnected: Bool { oscManager.isConnected(target) }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isConnected ? "network" : "network.slash")
                .font(.title3)
                .foregroundStyle(isConnected ? .green : .secondary)
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text(target.name).font(.headline)
                Text(target.displayAddress)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fontDesign(.monospaced)
            }

            Spacer()

            Button {
                oscManager.toggleConnection(for: target)
            } label: {
                Image(systemName: isConnected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isConnected ? .green : .secondary)
                    .imageScale(.large)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
        .contextMenu {
            if isConnected {
                Button {
                    oscManager.sendTest(address: "/xinfo", to: target)
                } label: {
                    Label("Send /xinfo (Test)", systemImage: "antenna.radiowaves.left.and.right")
                }
                Button {
                    oscManager.sendTest(address: "/xremote", to: target)
                } label: {
                    Label("Send /xremote Now", systemImage: "clock.arrow.2.circlepath")
                }
            }
        }
    }
}
