//
//  SimplifiedEffectsTests.swift
//  Midi Set ListTests
//
//  Level Rider's Style, the Compressor's Amount, and Harmony taking its key and detection
//  from the channel's Pitch Guide: what each choice sets, and how older saves load.
//

import Testing
import Foundation
@testable import Midi_Set_List

@Suite("Level Rider style")
@MainActor
struct LevelRiderStyleTests {

    @Test func defaultsAreSteady() {
        let p = LevelRiderParams()
        #expect(p.style == .steady && p.matchesStyle && !p.custom)
    }

    @Test func styleSetsRangeAndSpeeds() {
        var p = LevelRiderParams()
        p.style = .firm
        #expect(p.maxCut == -12 && p.maxBoost == 6 && p.cutSpeed == 40 && p.boostSpeed == 400)
    }

    @Test func trimsMeanCustom() {
        var p = LevelRiderParams()
        p.inputTrim = 3
        #expect(!p.matchesStyle)
        p.snapToStyle()
        #expect(p.inputTrim == 0 && p.matchesStyle && !p.custom)
    }

    @Test func oldHandSetSavesStayExact() throws {
        let json = #"{"maxCut": -14, "maxBoost": 7, "cutSpeed": 30, "boostSpeed": 900, "targetLevel": -20}"#
        let p = try JSONDecoder().decode(LevelRiderParams.self, from: Data(json.utf8))
        #expect(p.maxCut == -14 && p.cutSpeed == 30 && p.custom)
    }

    @Test func oldDefaultSavesShowTheStyle() throws {
        let p = try JSONDecoder().decode(LevelRiderParams.self, from: Data("{}".utf8))
        #expect(p.style == .steady && !p.custom)
    }
}

@Suite("Compressor amount")
@MainActor
struct CompressorAmountTests {

    @Test func defaultsAreMedium() {
        #expect(OptoCompParams().amount == .medium)
        #expect(FETCompParams().amount == .medium)
    }

    @Test func amountSetsEachEngine() {
        var o = OptoCompParams()
        o.amount = .heavy
        #expect(o.peakReduction == 83 && o.gain == 8 && o.limitMode)
        var f = FETCompParams()
        f.amount = .light
        #expect(f.input == 0 && f.output == 3 && f.ratio == .r4)
    }

    @Test func oldSavesKeepTheirSound() throws {
        // The old defaults: not one of the Amounts, so they load exactly, as knobs
        let o = try JSONDecoder().decode(OptoCompParams.self, from: Data("{}".utf8))
        #expect(o.peakReduction == 40 && o.gain == 6 && o.custom)
        let f = try JSONDecoder().decode(FETCompParams.self, from: Data("{}".utf8))
        #expect(f.input == 6 && f.output == 0 && f.ratio == .r4 && f.custom)
    }

    @Test func snapGoesToTheNearestAmount() {
        var o = OptoCompParams()
        o.custom = true
        o.peakReduction = 80
        o.snapToAmount()
        #expect(o.amount == .heavy && !o.custom)
    }
}

@Suite("Harmony follows Pitch Guide")
@MainActor
struct HarmonyFollowsPitchGuideTests {

    private func chain(harmony: HarmonyParams = HarmonyParams()) -> [ChannelFXSlot] {
        var guide = ChannelFXSlot()
        guide.type = .pitchGuide
        guide.pitchGuide.gateThreshold = -38
        guide.pitchGuide.voiceRange = .high
        guide.pitchGuide.songKeyDrive = false
        guide.pitchGuide.key = 7
        var harm = ChannelFXSlot()
        harm.type = .harmony
        harm.harmony = harmony
        return [guide, harm, ChannelFXSlot(), ChannelFXSlot(), ChannelFXSlot(), ChannelFXSlot()]
    }

    @Test func copiesKeyAndDetection() {
        var slots = chain()
        let changed = slots.syncHarmonyWithPitchGuide()
        let h = slots[1].harmony
        #expect(changed)
        #expect(h.gateThreshold == -38 && h.voiceRange == .high && !h.songKeyDrive && h.key == 7)
    }

    @Test func leavesAnUnlinkedHarmonyAlone() {
        var own = HarmonyParams()
        own.usePitchGuide = false
        own.gateThreshold = -60
        var slots = chain(harmony: own)
        let changed = slots.syncHarmonyWithPitchGuide()
        #expect(!changed && slots[1].harmony.gateThreshold == -60)
    }

    @Test func noPitchGuideNoChange() {
        var slots = chain()
        slots[0] = ChannelFXSlot()
        let changed = slots.syncHarmonyWithPitchGuide()
        #expect(!changed)
    }

    @Test func oldHandSetHarmonyStaysUnlinked() throws {
        let json = #"{"gateThreshold": -55}"#
        let h = try JSONDecoder().decode(HarmonyParams.self, from: Data(json.utf8))
        #expect(!h.usePitchGuide)
        let plain = try JSONDecoder().decode(HarmonyParams.self, from: Data("{}".utf8))
        #expect(plain.usePitchGuide)
    }

    @Test func feelSetsHumanize() {
        var h = HarmonyParams()
        #expect(h.feel == .natural)
        h.feel = .loose
        #expect(h.humanize == 65)
    }
}
