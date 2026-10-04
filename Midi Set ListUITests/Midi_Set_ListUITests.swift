//
//  Midi_Set_ListUITests.swift
//  Midi Set ListUITests
//
//  Smoke tests: the app launches on an empty in-memory store (-ui-testing) and the main
//  screens open. They catch crashes and broken navigation, not visual details.
//

import XCTest

final class Midi_Set_ListUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-ui-testing"]
        app.launch()
    }

    /// Taps a tab by name. iOS 26's floating tab bar no longer appears as XCUIElement.tabBar
    /// and its items have automation-type mismatches (legacy=Button, modern=Cell). Searching
    /// by identifier avoids type dependencies entirely; the label-based button search is a
    /// fallback for older iOS.
    @MainActor
    private func openTab(_ name: String) {
        let id = "tab-\(name.lowercased().replacingOccurrences(of: " ", with: "-"))"
        let byID = app.descendants(matching: .any).matching(identifier: id).firstMatch
        if byID.waitForExistence(timeout: 5) { byID.tap(); return }

        // Older iOS: tab bar buttons match by label.
        let byLabel = app.buttons[name].firstMatch
        if byLabel.waitForExistence(timeout: 5) { byLabel.tap(); return }

        // Compact / "More" overflow (iPhone / compact width).
        let more = app.buttons["More"].firstMatch
        if more.waitForExistence(timeout: 2) {
            more.tap()
            // Type-agnostic search for the menu item label.
            let item = app.descendants(matching: .any)
                .matching(NSPredicate(format: "label == %@", name))
                .firstMatch
            if item.waitForExistence(timeout: 3) { item.tap() }
        }
    }

    @MainActor
    func testLaunchesToPerform() throws {
        XCTAssertTrue(app.navigationBars["Perform"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Play"].exists)
    }

    @MainActor
    func testMainTabsOpen() throws {
        for (tab, title) in [("Set Lists", "Set Lists"), ("Songs", "Songs"), ("Settings", "Settings")] {
            openTab(tab)
            XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 5), "\(tab) didn't open")
        }
    }

    @MainActor
    func testBandSettingsListBuiltInRoles() throws {
        openTab("Settings")
        let bandRow = app.descendants(matching: .any).matching(identifier: "settings-band-row").firstMatch
        XCTAssertTrue(bandRow.waitForExistence(timeout: 5), "Band row not found in Settings")
        bandRow.tap()
        XCTAssertTrue(app.navigationBars["Band"].waitForExistence(timeout: 5))
        for role in ["Vocals", "Guitar", "Keys", "Bass", "Drums"] {
            XCTAssertTrue(app.buttons.containing(NSPredicate(format: "label CONTAINS %@", role)).firstMatch.exists,
                          "\(role) missing from the roster")
        }
    }

    @MainActor
    func testLiveFollowSheetOpens() throws {
        // The Band toolbar button has accessibilityIdentifier "live-follow".
        // Searching by identifier is more robust than label across iOS versions.
        let band = app.buttons.matching(identifier: "live-follow").firstMatch
        XCTAssertTrue(band.waitForExistence(timeout: 10))
        band.tap()
        XCTAssertTrue(app.navigationBars["Live Follow"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Lead the Band"].exists)
        XCTAssertTrue(app.buttons["Follow a Leader"].exists)
    }

    @MainActor
    func testLaunchPerformance() throws {
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            let app = XCUIApplication()
            app.launchArguments = ["-ui-testing"]
            app.launch()
        }
    }
}
