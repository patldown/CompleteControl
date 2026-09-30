//
//  AppConfigurationTests.swift
//  Midi Set ListTests
//
//  Guards Info.plist settings that break the app quietly when lost — e.g. without a
//  launch screen iOS runs the app letterboxed, with borders down the sides on iPad.
//  The tests run inside the app, so Bundle.main is the app's own bundle.
//

import Testing
import Foundation

@Suite("App configuration")
struct AppConfigurationTests {
    private let info = Bundle.main.infoDictionary ?? [:]

    @Test func hasLaunchScreen_soTheAppFillsTheScreen() {
        let launchScreen = info["UILaunchScreen"] as? [String: Any]
        #expect(launchScreen != nil || info["UILaunchStoryboardName"] != nil,
                "No launch screen: iOS would run the app letterboxed")
        #expect(launchScreen?["UIImageName"] as? String == "LaunchLogo")
    }

    @Test(arguments: [
        "NSLocalNetworkUsageDescription",   // MIDI network sessions, OSC, Live Follow
        "NSBluetoothAlwaysUsageDescription", // Bluetooth MIDI
        "NSMicrophoneUsageDescription",      // dictation
        "NSAppleMusicUsageDescription",      // reference tracks and playlists
    ])
    func hasPermissionText(key: String) {
        // A missing permission text crashes the app the first time it asks
        let text = info[key] as? String ?? ""
        #expect(!text.trimmingCharacters(in: .whitespaces).isEmpty, "\(key) is missing")
    }

    @Test func declaresNetworkServices() {
        let services = info["NSBonjourServices"] as? [String] ?? []
        #expect(services.contains("_apple-midi._udp"))
        // Live Follow can't find other devices without these
        #expect(services.contains("_msl-live._tcp"))
        #expect(services.contains("_msl-live._udp"))
    }
}
