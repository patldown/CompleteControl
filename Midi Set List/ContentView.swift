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

    private struct PendingImport: Identifiable {
        let id = UUID()
        let archive: DataArchive
    }

    var body: some View {
        TabView(selection: $navigation.selectedTab) {
            Tab("Perform", systemImage: "play.circle", value: "perform") {
                PerformView()
            }

            Tab("Set Lists", systemImage: "list.bullet", value: "setlists") {
                SetListsView()
            }

            Tab("Songs", systemImage: "music.note.list", value: "songs") {
                SongsLibraryView()
            }

            Tab("Devices", systemImage: "pianokeys", value: "devices") {
                DeviceLibraryView()
            }

            Tab("Connections", systemImage: "cable.connector", value: "connections") {
                ConnectionsView()
            }

            Tab("Activity", systemImage: "waveform", value: "activity") {
                ActivityLogView()
            }

            Tab("Help", systemImage: "questionmark.circle", value: "help") {
                HelpView()
            }

            Tab("Settings", systemImage: "gear", value: "settings") {
                SettingsView()
            }
        }
        .buttonStyle(.plain)
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
