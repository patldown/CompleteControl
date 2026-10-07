//
//  ContentView.swift
//  Midi Set List
//
//  Created by Patrick Downey on 9/25/26.
//

import SwiftUI
import CoreData

struct ContentView: View {
    @State private var navigation = AppNavigation()
    @State private var pendingImport: PendingImport?
    @State private var importError: String?
    // Observed so the Routing tab appears/disappears as the interface connects/disconnects
    private let routingStore = AudioRoutingStore.shared

    private struct PendingImport: Identifiable {
        let id = UUID()
        let archive: DataArchive
    }

    var body: some View {
        TabView(selection: $navigation.selectedTab) {
            Tab("Perform", systemImage: "play.circle", value: "perform") {
                PerformView()
            }
            .accessibilityIdentifier("tab-perform")

            if routingStore.isExternalInterfaceConnected {
                Tab("Routing", systemImage: "slider.horizontal.3", value: "routing") {
                    RoutingView()
                }
                .accessibilityIdentifier("tab-routing")
            }

            Tab("Set Lists", systemImage: "list.bullet", value: "setlists") {
                SetListsView()
            }
            .accessibilityIdentifier("tab-set-lists")

            Tab("Songs", systemImage: "music.note.list", value: "songs") {
                SongsLibraryView()
            }
            .accessibilityIdentifier("tab-songs")

            Tab("Devices", systemImage: "pianokeys", value: "devices") {
                DeviceLibraryView()
            }
            .accessibilityIdentifier("tab-devices")

            Tab("Connections", systemImage: "cable.connector", value: "connections") {
                ConnectionsView()
            }
            .accessibilityIdentifier("tab-connections")

            Tab("Activity", systemImage: "waveform", value: "activity") {
                ActivityLogView()
            }
            .accessibilityIdentifier("tab-activity")

            Tab("Help", systemImage: "questionmark.circle", value: "help") {
                HelpView()
            }
            .accessibilityIdentifier("tab-help")

            Tab("Settings", systemImage: "gear", value: "settings") {
                SettingsView()
            }
            .accessibilityIdentifier("tab-settings")
        }
        .overlay(alignment: .bottomLeading) {
            SystemStatsView()
                .padding(.leading, 8)
                .padding(.bottom, 8)
        }
        .liveFollowPrompts()
        .environment(navigation)
        .onOpenURL { url in
            Task {
                do {
                    pendingImport = PendingImport(archive: try await DataArchiveImporter.readShowingProgress(url))
                } catch {
                    importError = error.localizedDescription
                }
            }
        }
        .sheet(item: $pendingImport) { ImportReviewSheet(archive: $0.archive) }
        .alert("Couldn't Open File", isPresented: Binding(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            if let importError { Text(importError) }
        }
    }
}

#Preview {
    ContentView()
        .environment(MIDIManager())
        .environment(OSCManager())
        .environment(ActivityLog())
        .environment(PerformanceSession())
        .environment(\.managedObjectContext, PersistenceController.preview.viewContext)
}
