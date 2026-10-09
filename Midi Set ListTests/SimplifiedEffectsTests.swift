//
//  SimplifiedEffectsTests.swift
//  Midi Set ListTests
//
//  Level Rider's Style, the Compressor's Amount, and Harmony taking its key and detection
//  from the channel's Pitch Guide: what each choice sets, and how older saves load.
//

import Testing
import Foundation
import AVFoundation
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

@Suite("Compressor sidechain")
@MainActor
struct CompressorSidechainTests {

    private func run(_ k: VintageCompressorKernel, level: Float) throws -> Float {
        let frames = 9_600
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        for ch in 0..<2 {
            let d = buffer.floatChannelData![ch]
            for i in 0..<frames { d[i] = level * Float(sin(2 * Double.pi * 220 * Double(i) / 48_000)) }
        }
        k.process(buffer.mutableAudioBufferList, frameCount: frames)
        return Float(bitPattern: k.gainReductionBits.load(ordering: .relaxed))
    }

    @Test func followsTheKeyNotItself() throws {
        let row = ChannelLevelTable.count - 1
        let k = VintageCompressorKernel(model: .opto)
        k.setSampleRate(48_000)
        k.applyParams(OptoCompParams())          // Medium
        k.applySidechain(rows: [row], post: false)

        // Loud here, key silent: no compression
        ChannelLevelTable.pre[row] = -120
        #expect(try run(k, level: 0.5) < 0.1)

        // Quiet here, key loud: this channel is turned down
        ChannelLevelTable.pre[row] = -6
        #expect(try run(k, level: 0.05) > 3)

        // Post reads the other table
        k.applySidechain(rows: [row], post: true)
        ChannelLevelTable.post[row] = -120
        // (the opto's slow stage holds some reduction for a couple of seconds, like the hardware)
        for _ in 0..<25 { _ = try run(k, level: 0.05) }
        #expect(try run(k, level: 0.05) < 0.5)

        ChannelLevelTable.pre[row] = -120
    }

    @Test func noKeysMeansItsOwnSignal() throws {
        let k = VintageCompressorKernel(model: .opto)
        k.setSampleRate(48_000)
        k.applyParams(OptoCompParams())
        k.applySidechain(rows: [], post: false)
        #expect(try run(k, level: 0.5) > 3)
    }

    @Test func oldSlotsHaveNoSidechain() throws {
        let slot = try JSONDecoder().decode(ChannelFXSlot.self, from: Data(#"{"type": "optoComp"}"#.utf8))
        #expect(!slot.sidechain.enabled && slot.sidechain.keyChannels.isEmpty && !slot.sidechain.post)
    }
}
