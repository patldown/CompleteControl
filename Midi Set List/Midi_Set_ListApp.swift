//
//  Midi_Set_ListApp.swift
//  Midi Set List
//

import CloudKit
import CoreData
import AppIntents
import SwiftUI

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     userDidAcceptCloudKitShareWith cloudKitShareMetadata: CKShare.Metadata) {
        let persistence = PersistenceController.shared
        guard let sharedStore = persistence.sharedPersistentStore else { return }
        persistence.container.acceptShareInvitations(from: [cloudKitShareMetadata],
                                                     into: sharedStore) { _, error in
            if let error { print("Accept share invitation failed: \(error)") }
        }
    }
}

@main
struct Midi_Set_ListApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var midiManager = MIDIManager()
    @State private var oscManager = OSCManager()
    @State private var activityLog = ActivityLog()
    @State private var performance = PerformanceSession()

    private let persistence = PersistenceController.shared

    /// Converts any master songs linked directly to set lists into per-set-list copies.
    /// Runs once on first launch after the per-set-list copy model was introduced.
    private func migrateToPerSetListSongs(context: NSManagedObjectContext) {
        let key = "perSetListSongCopiesMigrated_v1"
        guard !UserDefaults.standard.bool(forKey: key) else { return }

        let request = NSFetchRequest<SetList>(entityName: "SetList")
        let setLists = (try? context.fetch(request)) ?? []
        for setList in setLists {
            for master in setList.songs.filter({ $0.isMaster }) {
                setList.migrateDirectSong(master, in: context)
            }
        }

        try? context.save()
        UserDefaults.standard.set(true, forKey: key)
    }

    var body: some Scene {
        WindowGroup {
            LaunchContainer {
                ContentView()
            }
                .environment(midiManager)
                .environment(oscManager)
                .environment(activityLog)
                .environment(performance)
                .environment(\.managedObjectContext, persistence.viewContext)
                .onAppear {
                    midiManager.oscManager = oscManager
                    midiManager.activityLog = activityLog
                    oscManager.activityLog = activityLog
                    MixerLink.shared.oscManager = oscManager
                    AudioRoutingEngine.shared.activityLog = activityLog
                    performance.midiManager = midiManager
                    performance.activityLog = activityLog
                    let session = performance
                    midiManager.onRemoteMessage = { message in session.handle(message) }
                    // Live Follow: the leader broadcasts every song / snapshot change
                    LiveFollowSession.shared.performance = performance
                    performance.onStateChange = { LiveFollowSession.shared.leaderStateChanged() }
                    CompleteControlShortcuts.updateAppShortcutParameters()
                    // Restore OSC connections from last session
                    let oscRequest = NSFetchRequest<OSCTarget>(entityName: "OSCTarget")
                    let targets = (try? persistence.viewContext.fetch(oscRequest)) ?? []
                    oscManager.targetsProvider = { (try? persistence.viewContext.fetch(oscRequest)) ?? [] }
                    oscManager.restoreConnections(from: targets)

                    migrateToPerSetListSongs(context: persistence.viewContext)
                }
        }
    }
}
