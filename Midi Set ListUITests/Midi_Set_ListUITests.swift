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

    /// Taps a tab, going through More when the tab bar can't fit it (iPhone)
    @MainActor
    private func openTab(_ name: String) {
        let tab = app.tabBars.buttons[name]
        if tab.waitForExistence(timeout: 5) {
            tab.tap()
            return
        }
        app.tabBars.buttons["More"].tap()
        app.cells.staticTexts[name].firstMatch.tap()
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
        app.staticTexts["This Device Plays"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Band"].waitForExistence(timeout: 5))
        for role in ["Vocals", "Guitar", "Keys", "Bass", "Drums"] {
            XCTAssertTrue(app.buttons.containing(NSPredicate(format: "label CONTAINS %@", role)).firstMatch.exists,
                          "\(role) missing from the roster")
        }
    }

    @MainActor
    func testLiveFollowSheetOpens() throws {
        let band = app.buttons["Band"].firstMatch
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
