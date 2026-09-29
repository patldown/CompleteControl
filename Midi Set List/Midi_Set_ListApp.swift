//
//  Midi_Set_ListApp.swift
//  Midi Set List
//

import SwiftUI
import CoreData
import AppIntents

@main
struct Midi_Set_ListApp: App {
    @State private var midiManager = MIDIManager()
    @State private var oscManager = OSCManager()
    @State private var activityLog = ActivityLog()
    @State private var performance = PerformanceSession()

    private let persistence = PersistenceController.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(midiManager)
                .environment(oscManager)
                .environment(activityLog)
                .environment(performance)
                .environment(\.managedObjectContext, persistence.viewContext)
                .onAppear {
                    midiManager.oscManager = oscManager
                    midiManager.activityLog = activityLog
                    oscManager.activityLog = activityLog
                    performance.midiManager = midiManager
                    performance.activityLog = activityLog
                    let session = performance
                    midiManager.onRemoteMessage = { message in session.handle(message) }
                    MidiSetListShortcuts.updateAppShortcutParameters()
                }
        }
    }
}
