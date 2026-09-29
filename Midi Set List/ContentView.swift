//
//  ContentView.swift
//  Midi Set List
//
//  Created by Patrick Downey on 9/25/26.
//

import SwiftUI
import CoreData

struct ContentView: View {
    @ObservedObject private var ai = AISettings.shared

    var body: some View {
        TabView {
            Tab("Perform", systemImage: "play.circle") {
                PerformView()
            }

            Tab("Set Lists", systemImage: "list.bullet") {
                SetListsView()
            }

            Tab("Songs", systemImage: "music.note.list") {
                SongsLibraryView()
            }

            Tab("Devices", systemImage: "pianokeys") {
                DeviceLibraryView()
            }

            Tab("MIDI Devices", systemImage: "cable.connector") {
                MIDIDevicesView()
            }

            Tab("Activity", systemImage: "waveform") {
                ActivityLogView()
            }

            Tab("Help", systemImage: "questionmark.circle") {
                HelpView()
            }

            Tab("Settings", systemImage: "gear") {
                SettingsView()
            }
            .badge(ai.offlineMode && ai.anyAIAvailable ? Text("Offline") : nil)
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
