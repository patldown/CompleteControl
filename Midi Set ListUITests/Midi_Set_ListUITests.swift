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
        // The Play button at the bottom of PerformSetListPicker is more stable than
        // navigationBars["Perform"] under iOS 26's Liquid Glass navigation rendering.
        XCTAssertTrue(app.buttons["Play"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testMainTabsOpen() throws {
        for (tab, title) in [("Set Lists", "Set Lists"), ("Songs", "Songs"), ("Settings", "Settings")] {
            openTab(tab)
            // iOS 26: navigationBars[title] may not resolve under Liquid Glass;
            // the title text is always present as a staticText in the nav bar area.
            let titleText = app.staticTexts.matching(NSPredicate(format: "label == %@", title)).firstMatch
            XCTAssertTrue(titleText.waitForExistence(timeout: 8), "\(tab) didn't open")
        }
    }

    @MainActor
    func testBandSettingsListBuiltInRoles() throws {
        openTab("Settings")
        let bandRow = app.descendants(matching: .any).matching(identifier: "settings-band-row").firstMatch
        XCTAssertTrue(bandRow.waitForExistence(timeout: 8), "Band row not found in Settings")
        bandRow.tap()
        // Title text is reliable; navigationBars["Band"] may not resolve on iOS 26.
        XCTAssertTrue(app.staticTexts["Band"].firstMatch.waitForExistence(timeout: 5))
        for role in ["Vocals", "Guitar", "Keys", "Bass", "Drums"] {
            XCTAssertTrue(app.descendants(matching: .any)
                .containing(NSPredicate(format: "label CONTAINS %@", role)).firstMatch.exists,
                          "\(role) missing from the roster")
        }
    }

    @MainActor
    func testLiveFollowSheetOpens() throws {
        // iOS 26 toolbar items may have type Cell rather than Button; search all descendants.
        let band = app.descendants(matching: .any).matching(identifier: "live-follow").firstMatch
        XCTAssertTrue(band.waitForExistence(timeout: 10))
        band.tap()
        // Check for the sheet's title text rather than navigationBars["Live Follow"].
        XCTAssertTrue(app.staticTexts["Live Follow"].firstMatch.waitForExistence(timeout: 5))
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
