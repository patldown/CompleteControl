//
//  PitchGuideChoicesTests.swift
//  Midi Set ListTests
//
//  Pitch Guide's Speed / Flex / Amount choices: the values each sets, how they read back,
//  Custom Values, and how saves from before the choices load.
//

import Testing
import Foundation
@testable import Midi_Set_List

@Suite("Pitch Guide choices")
@MainActor
struct PitchGuideChoicesTests {

    @Test func defaultsAreNaturalTightALittleAllTheWay() {
        let p = PitchGuideParams()
        #expect(p.tuneSpeed == .naturalTight)
        #expect(p.tuneFlex == .aLittle)
        #expect(p.tuneAmount == .allTheWay)
        #expect(p.matchesChoices && !p.customCorrection)
    }

    @Test func choicesSetTheValues() {
        var p = PitchGuideParams()
        p.tuneSpeed = .hard
        p.tuneFlex = .expressive
        p.tuneAmount = .nudge
        #expect(p.retuneSpeed == 20 && p.tolerance == 25 && p.humanize == 50 && p.amount == 40)
    }

    @Test func exactPinsFlexAndAmount() {
        var p = PitchGuideParams()
        p.tuneFlex = .free
        p.tuneAmount = .nudge
        p.tuneSpeed = .exact
        #expect(p.retuneSpeed == 0 && p.tuneFlex == .locked && p.tuneAmount == .allTheWay)
    }

    @Test func offAndBackRestoresAPull() {
        var p = PitchGuideParams()
        p.tuneSpeed = .off
        #expect(p.amount == 0 && p.tuneSpeed == .off && p.matchesChoices)
        p.tuneSpeed = .naturalLoose
        #expect(p.amount == 100 && p.retuneSpeed == 150)
    }

    @Test func oddValuesMatchNoChoice() {
        var p = PitchGuideParams()
        p.retuneSpeed = 33
        #expect(p.tuneSpeed == nil && !p.matchesChoices)
    }

    @Test func snapGoesToTheNearestChoices() {
        var p = PitchGuideParams()
        p.customCorrection = true
        p.retuneSpeed = 130; p.tolerance = 22; p.humanize = 55; p.amount = 70
        p.snapToChoices()
        #expect(p.tuneSpeed == .naturalLoose && p.tuneFlex == .expressive && p.tuneAmount == .mostly)
        #expect(!p.customCorrection)
    }

    @Test func oldDefaultSavesMoveToTheChoices() throws {
        let json = #"{"retuneSpeed": 50, "tolerance": 10, "amount": 100, "humanize": 0, "retuneSpeedLands": true}"#
        let p = try JSONDecoder().decode(PitchGuideParams.self, from: Data(json.utf8))
        #expect(p.tuneSpeed == .naturalTight && p.tuneFlex == .aLittle && !p.customCorrection)
    }

    @Test func oldHandSetSavesKeepTheirValues() throws {
        let json = #"{"retuneSpeed": 25, "tolerance": 5, "amount": 90, "humanize": 10, "retuneSpeedLands": true}"#
        let p = try JSONDecoder().decode(PitchGuideParams.self, from: Data(json.utf8))
        #expect(p.retuneSpeed == 25 && p.tolerance == 5 && p.amount == 90 && p.humanize == 10)
        #expect(p.customCorrection)
    }
}
