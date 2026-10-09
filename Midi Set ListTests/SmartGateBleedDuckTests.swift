//
//  SmartGateBleedDuckTests.swift
//  Midi Set ListTests
//
//  Bleed Duck moving from Pitch Guide to Smart Gate: the saved-chain migration, and the
//  voice detector that lets the gate tell singing from bleed.
//

import Testing
import Foundation
@testable import Midi_Set_List

@MainActor
private func slot(_ type: BuiltInFXType?, duck: Float = 0) -> ChannelFXSlot {
    var s = ChannelFXSlot()
    s.type = type
    s.pitchGuide.bleedDuck = duck
    return s
}

@Suite("Bleed Duck migration")
@MainActor
struct BleedDuckMigrationTests {

    @Test func addsGateRightAfterPitchGuide() throws {
        var slots = [slot(.eq3Band), slot(.pitchGuide, duck: -9), slot(.optoComp), slot(nil), slot(.air), slot(nil)]
        let moved = try #require(slots.moveBleedDuckToSmartGate())
        #expect(slots.map(\.type) == [.eq3Band, .pitchGuide, .smartGate, .optoComp, .air, nil])
        #expect(slots[1].pitchGuide.bleedDuck == 0)
        #expect(slots[2].smartGate.bleedDuck)
        #expect(slots[2].smartGate.depth == 9)
        #expect(moved.added == [2])
        #expect(moved.newIndex[2] == 3)   // the compressor moved down one
    }

    @Test func usesAnEarlierFreeSlotWhenNoLaterOne() throws {
        var slots = [slot(nil), slot(.eq3Band), slot(.optoComp), slot(.air), slot(.warmth), slot(.pitchGuide, duck: -6)]
        let moved = try #require(slots.moveBleedDuckToSmartGate())
        #expect(slots.map(\.type) == [.eq3Band, .optoComp, .air, .warmth, .pitchGuide, .smartGate])
        #expect(moved.added == [5])
        #expect(moved.newIndex[5] == 4)
    }

    @Test func turnsOnAnExistingGate() throws {
        var slots = [slot(.smartGate), slot(.pitchGuide, duck: -6), slot(nil), slot(nil), slot(nil), slot(nil)]
        let moved = try #require(slots.moveBleedDuckToSmartGate())
        #expect(slots.map(\.type) == [.smartGate, .pitchGuide, nil, nil, nil, nil])
        #expect(slots[0].smartGate.bleedDuck)
        #expect(slots[0].smartGate.depth == SmartGateParams().depth)   // its own depth is kept
        #expect(slots[1].pitchGuide.bleedDuck == 0)
        #expect(moved.added.isEmpty)
    }

    @Test func fullChainKeepsTheDuck() {
        var slots = [slot(.gain), slot(.eq3Band), slot(.optoComp), slot(.air), slot(.warmth), slot(.pitchGuide, duck: -6)]
        let moved = slots.moveBleedDuckToSmartGate()
        #expect(moved == nil)
        #expect(slots[5].pitchGuide.bleedDuck == -6)
    }

    @Test func nothingToMove() {
        var slots = [slot(.pitchGuide), slot(nil), slot(nil), slot(nil), slot(nil), slot(nil)]
        let moved = slots.moveBleedDuckToSmartGate()
        #expect(moved == nil)
    }

    @Test func bypassedPitchGuideGivesBypassedGate() throws {
        var slots = [slot(.pitchGuide, duck: -6), slot(nil), slot(nil), slot(nil), slot(nil), slot(nil)]
        slots[0].isBypassed = true
        _ = try #require(slots.moveBleedDuckToSmartGate())
        #expect(slots[1].type == .smartGate)
        #expect(slots[1].isBypassed)
    }

    @Test func oldGateSavesDecodeWithBleedDuckOff() throws {
        let json = #"{"sensitivity": 60, "depth": 30}"#.data(using: .utf8)!
        let p = try JSONDecoder().decode(SmartGateParams.self, from: json)
        #expect(p.sensitivity == 60 && p.depth == 30 && !p.bleedDuck)
    }
}

@Suite("Voice detector")
struct VoiceDetectorTests {

    /// Feeds one second and reports whether the last analysis heard voice
    private func voiced(_ sample: (Int) -> Float) -> Bool {
        let d = VoiceDetector()
        d.reset(sampleRate: 48_000)
        for i in 0..<48_000 { d.push(sample(i), worthChecking: true) }
        return d.isVoiced
    }

    @Test func hearsASungPitch() {
        #expect(voiced { 0.3 * sin(2 * .pi * 220 * Float($0) / 48_000) })
    }

    @Test func ignoresNoise() {
        var rng = SystemRandomNumberGenerator()
        #expect(!voiced { _ in Float.random(in: -0.3...0.3, using: &rng) })
    }

    @Test func skipsWhenNotWorthChecking() {
        let d = VoiceDetector()
        d.reset(sampleRate: 48_000)
        for i in 0..<48_000 { d.push(0.3 * sin(2 * .pi * 220 * Float(i) / 48_000), worthChecking: false) }
        #expect(!d.isVoiced)
    }
}
