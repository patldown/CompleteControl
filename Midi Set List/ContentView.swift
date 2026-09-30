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

            Tab("MIDI Devices", systemImage: "cable.connector", value: "mididevices") {
                MIDIDevicesView()
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
        .floatingPerformShortcut(navigation)
        .environment(navigation)
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
