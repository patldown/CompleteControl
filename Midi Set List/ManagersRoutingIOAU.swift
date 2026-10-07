//
//  RoutingIOAU.swift
//  Midi Set List
//
//  The routing engine's input and output ends. A multichannel interface like the XR18
//  appears to iOS as ONE input bus with 18 channels and ONE output bus with 18 channels,
//  so channels can't be picked by connecting to "bus 3". These two in-process AUs do it:
//
//    • InputPickerAudioUnit — fed the whole N-channel input; outputs stereo holding the
//      chosen hardware channel (both sides) or a stereo-linked pair (L/R). The choice is
//      an atomic, so changing a channel's input or stereo link is live.
//    • OutputPackerAudioUnit — 16 stereo input busses (one per output pair) in, the whole
//      M-channel output out: bus k lands on hardware channels 2k+1 and 2k+2.
//
//  Strict real-time contract: buffers are allocated in allocateRenderResources; the
//  render blocks only copy.
//

import AVFoundation
import AudioToolbox
import Synchronization

// MARK: - Shared scratch buffers

/// Non-interleaved float buffers plus an AudioBufferList pointing at them. Allocated on the
/// main thread when render resources are; `prepare` re-points the list on the audio thread
/// (a pulled input may have swapped the mData pointers).
nonisolated final class RoutingScratch: @unchecked Sendable {
    private(set) var list: UnsafeMutableAudioBufferListPointer?
    private var storage: UnsafeMutablePointer<Float>?
    private var channels = 0
    private var capacity = 0

    func allocate(channels: Int, frames: Int) {
        deallocate()
        let ch = max(1, channels), fr = max(1, frames)
        let s = UnsafeMutablePointer<Float>.allocate(capacity: ch * fr)
        s.initialize(repeating: 0, count: ch * fr)
        let l = AudioBufferList.allocate(maximumBuffers: ch)
        storage = s; list = l; self.channels = ch; capacity = fr
        prepare(frames: fr)
    }

    func deallocate() {
        storage?.deallocate(); storage = nil
        list.map { free($0.unsafeMutablePointer) }; list = nil
        channels = 0; capacity = 0
    }

    @inline(__always) func prepare(frames: Int) {
        guard let list, let storage else { return }
        let fr = min(frames, capacity)
        for c in 0..<channels {
            list[c] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(fr * 4),
                                  mData: UnsafeMutableRawPointer(storage + c * capacity))
        }
    }

    deinit { deallocate() }
}

@inline(__always) private func samples(_ buffer: AudioBuffer) -> UnsafeMutablePointer<Float>? {
    buffer.mData?.assumingMemoryBound(to: Float.self)
}

// MARK: - Input picker

nonisolated final class InputSelection: Sendable {
    /// Hardware channel (0-based) for the left and right outputs; -1 = silence
    let left = Atomic<Int>(0)
    let right = Atomic<Int>(0)
}

final class InputPickerAudioUnit: AUAudioUnit {

    static let componentDescription = AudioComponentDescription(
        componentType: kAudioUnitType_Effect,
        componentSubType: 0x494E504B,       // 'INPK'
        componentManufacturer: 0x4D534C53,  // 'MSLS'
        componentFlags: 0,
        componentFlagsMask: 0
    )

    let selection = InputSelection()
    private let inputScratch = RoutingScratch()
    private let outputScratch = RoutingScratch()
    private var _inputBusses: AUAudioUnitBusArray!
    private var _outputBusses: AUAudioUnitBusArray!

    override init(componentDescription: AudioComponentDescription,
                  options: AudioComponentInstantiationOptions = []) throws {
        try super.init(componentDescription: componentDescription, options: options)
        let fmt = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let input = try AUAudioUnitBus(format: fmt)
        input.maximumChannelCount = 64     // takes the interface's whole input
        _inputBusses  = AUAudioUnitBusArray(audioUnit: self, busType: .input, busses: [input])
        _outputBusses = AUAudioUnitBusArray(audioUnit: self, busType: .output,
                                             busses: [try AUAudioUnitBus(format: fmt)])
    }

    /// Any number of input channels in, stereo out
    override var channelCapabilities: [NSNumber]? { [-1, 2] }
    override var inputBusses:  AUAudioUnitBusArray { _inputBusses  }
    override var outputBusses: AUAudioUnitBusArray { _outputBusses }
    override var latency: TimeInterval { 0 }

    /// Mono input `index`, or `index` and `index + 1` as a stereo pair
    func select(index: Int, stereo: Bool) {
        selection.left.store(index, ordering: .relaxed)
        selection.right.store(stereo ? index + 1 : index, ordering: .relaxed)
    }

    override func allocateRenderResources() throws {
        try super.allocateRenderResources()
        let frames = Int(maximumFramesToRender)
        inputScratch.allocate(channels: Int(inputBusses[0].format.channelCount), frames: frames)
        outputScratch.allocate(channels: 2, frames: frames)
    }

    override func deallocateRenderResources() {
        inputScratch.deallocate()
        outputScratch.deallocate()
        super.deallocateRenderResources()
    }

    override var internalRenderBlock: AUInternalRenderBlock {
        let sel = selection, inBuf = inputScratch, outBuf = outputScratch
        return { _, timestamp, frameCount, _, outputData, _, pullInput in
            guard let inList = inBuf.list, let spare = outBuf.list else { return kAudioUnitErr_Uninitialized }
            let frames = Int(frameCount)
            inBuf.prepare(frames: frames)
            var flags: AudioUnitRenderActionFlags = []
            let status = pullInput?(&flags, timestamp, frameCount, 0, inList.unsafeMutablePointer)
                ?? kAudioUnitErr_NoConnection

            outBuf.prepare(frames: frames)
            let out = UnsafeMutableAudioBufferListPointer(outputData)
            let picks = (sel.left.load(ordering: .relaxed), sel.right.load(ordering: .relaxed))
            for o in 0..<min(out.count, 2) {
                if out[o].mData == nil { out[o].mData = spare[o].mData }
                out[o].mDataByteSize = UInt32(frames * 4)
                guard let dst = samples(out[o]) else { continue }
                let src = o == 0 ? picks.0 : picks.1
                if status == noErr, src >= 0, src < inList.count, let s = samples(inList[src]) {
                    dst.update(from: s, count: frames)
                } else {
                    dst.update(repeating: 0, count: frames)
                }
            }
            return noErr
        }
    }
}

// MARK: - Output packer

final class OutputPackerAudioUnit: AUAudioUnit {

    static let componentDescription = AudioComponentDescription(
        componentType: kAudioUnitType_Effect,
        componentSubType: 0x4F555450,       // 'OUTP'
        componentManufacturer: 0x4D534C53,  // 'MSLS'
        componentFlags: 0,
        componentFlagsMask: 0
    )

    /// Output pairs supported: 32 hardware channels
    static let maxPairs = 16

    private let pairScratch = (0..<OutputPackerAudioUnit.maxPairs).map { _ in RoutingScratch() }
    private let outputScratch = RoutingScratch()
    private var _inputBusses: AUAudioUnitBusArray!
    private var _outputBusses: AUAudioUnitBusArray!

    override init(componentDescription: AudioComponentDescription,
                  options: AudioComponentInstantiationOptions = []) throws {
        try super.init(componentDescription: componentDescription, options: options)
        let fmt = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        _inputBusses  = AUAudioUnitBusArray(audioUnit: self, busType: .input,
                                             busses: try (0..<Self.maxPairs).map { _ in try AUAudioUnitBus(format: fmt) })
        let output = try AUAudioUnitBus(format: fmt)
        output.maximumChannelCount = 64    // feeds the interface's whole output
        _outputBusses = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [output])
    }

    /// Stereo in (per pair), any number of channels out
    override var channelCapabilities: [NSNumber]? { [2, -1] }
    override var inputBusses:  AUAudioUnitBusArray { _inputBusses  }
    override var outputBusses: AUAudioUnitBusArray { _outputBusses }
    override var latency: TimeInterval { 0 }

    override func allocateRenderResources() throws {
        try super.allocateRenderResources()
        let frames = Int(maximumFramesToRender)
        for s in pairScratch { s.allocate(channels: 2, frames: frames) }
        outputScratch.allocate(channels: Int(outputBusses[0].format.channelCount), frames: frames)
    }

    override func deallocateRenderResources() {
        for s in pairScratch { s.deallocate() }
        outputScratch.deallocate()
        super.deallocateRenderResources()
    }

    override var internalRenderBlock: AUInternalRenderBlock {
        let pairs = pairScratch, outBuf = outputScratch
        return { _, timestamp, frameCount, _, outputData, _, pullInput in
            guard let spare = outBuf.list else { return kAudioUnitErr_Uninitialized }
            let frames = Int(frameCount)
            outBuf.prepare(frames: frames)
            let out = UnsafeMutableAudioBufferListPointer(outputData)
            for c in 0..<out.count {
                if out[c].mData == nil, c < spare.count { out[c].mData = spare[c].mData }
                out[c].mDataByteSize = UInt32(frames * 4)
                samples(out[c])?.update(repeating: 0, count: frames)
            }

            // Bus k → hardware channels 2k, 2k+1 (0-based). Unconnected busses just fail
            // to pull and stay silent.
            for k in 0..<pairs.count where 2 * k < out.count {
                let scratch = pairs[k]
                guard let list = scratch.list else { continue }
                scratch.prepare(frames: frames)
                var flags: AudioUnitRenderActionFlags = []
                guard pullInput?(&flags, timestamp, frameCount, k, list.unsafeMutablePointer) == noErr
                else { continue }
                for side in 0..<2 where 2 * k + side < out.count && side < list.count {
                    guard let src = samples(list[side]), let dst = samples(out[2 * k + side]) else { continue }
                    for i in 0..<frames { dst[i] += src[i] }
                }
            }
            return noErr
        }
    }
}
