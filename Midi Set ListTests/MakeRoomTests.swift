//
//  MakeRoomTests.swift
//  Midi Set ListTests
//
//  Make Room: when a band dips and by how much, Tone listening for it, and the kernel
//  stepping aside only while a key channel is playing.
//

import Testing
import Foundation
import AVFoundation
@testable import Midi_Set_List

@Suite("Make Room")
struct MakeRoomTests {

    @Test func dipsOnlyWhenTheKeyIsPresentAndCovered() {
        // Key singing at -20 in this band, us at -20: full dip
        #expect(MakeRoomKernel.wantedCut(keyDB: -20, ownDB: -20, weight: 1, maxCut: 4) == 4)
        // Key silent (bleed level): no dip, however loud we are
        #expect(MakeRoomKernel.wantedCut(keyDB: -60, ownDB: -10, weight: 1, maxCut: 4) == 0)
        // We're far below the key there: we aren't covering it, no dip
        #expect(MakeRoomKernel.wantedCut(keyDB: -20, ownDB: -40, weight: 1, maxCut: 4) == 0)
        // A band that doesn't matter to the key: no dip
        #expect(MakeRoomKernel.wantedCut(keyDB: -20, ownDB: -20, weight: 0, maxCut: 4) == 0)
        // Never more than Amount
        #expect(MakeRoomKernel.wantedCut(keyDB: -10, ownDB: 0, weight: 1, maxCut: 2) == 2)
    }

    @Test @MainActor func toneWithNoInstrumentStillListens() throws {
        let row = KeyBandTable.maxKeys - 1
        KeyBandTable.clear(key: row)
        let tone = ToneKernel()
        tone.setSampleRate(48_000)
        tone.applyParams(instrument: nil, amount: 70)
        tone.keySlot.store(row, ordering: .relaxed)

        let frames = 48_000
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        for ch in 0..<2 {
            let d = buffer.floatChannelData![ch]
            for i in 0..<frames { d[i] = Float(0.5 * sin(2 * Double.pi * 1_000 * Double(i) / 48_000)) }
        }
        let before = buffer.floatChannelData![0][1_000]
        tone.process(buffer.mutableAudioBufferList, frameCount: frames)

        let levels = (0..<MakeRoomBands.count).map { KeyBandTable.level(key: row, band: $0) }
        let loudest = levels.indices.max { levels[$0] < levels[$1] }
        #expect(loudest == 3)                                  // 1 kHz
        #expect(abs(levels[3] - 20 * log10(0.5)) < 1.5)
        #expect(buffer.floatChannelData![0][1_000] == before)  // listening only: sound untouched
        KeyBandTable.clear(key: row)
    }

    @Test @MainActor func kernelStepsAsideOnlyWhileTheKeyPlays() throws {
        let row = KeyBandTable.maxKeys - 2
        KeyBandTable.clear(key: row)
        let k = MakeRoomKernel()
        k.setSampleRate(48_000)
        k.apply(maxCutDB: 4, keys: [(row, [Float](repeating: 1, count: MakeRoomBands.count))])

        let frames = 4_800
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        func run() {
            for ch in 0..<2 {
                let d = buffer.floatChannelData![ch]
                for i in 0..<frames { d[i] = Float(0.3 * sin(2 * Double.pi * 1_000 * Double(i) / 48_000)) }
            }
            k.process(buffer.mutableAudioBufferList, frameCount: frames)
        }

        // Key silent: no dip
        run()
        #expect(k.cutDB(band: 3) < 0.1)

        // Key singing in the 1 kHz band: that band dips, close to the full 4 dB
        KeyBandTable.levels[row * MakeRoomBands.count + 3] = -15
        for _ in 0..<3 { run() }
        #expect(k.cutDB(band: 3) > 3)
        #expect(k.cutDB(band: 0) < 0.1)   // 125 Hz: nothing of ours there

        // Key stops: it lets go
        KeyBandTable.clear(key: row)
        for _ in 0..<20 { run() }
        #expect(k.cutDB(band: 3) < 0.2)
    }

    @Test func toneWeightsCoverEveryBand() {
        for instrument in ToneInstrument.allCases {
            #expect(MakeRoomParams.bandWeights(for: instrument).count == MakeRoomBands.count)
        }
        #expect(MakeRoomParams.bandWeights(for: nil).count == MakeRoomBands.count)
    }
}
