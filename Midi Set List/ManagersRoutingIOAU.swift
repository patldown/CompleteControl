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
//    • OutputPackerAudioUnit — one stereo input bus per routing channel in, the whole
//      M-channel output out. Each bus is placed on one output (summed to mono) or a pair
//      (L/R); the placement is an atomic, so changing a channel's output is live.
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
    /// Peak dBFS of the selected input channel, audio thread → main thread
    let levelBits = Atomic<UInt32>(Float(-120).bitPattern)
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
    /// Measures this channel for any Make Room keyed to it (idle unless one is)
    let analyzer = BandAnalyzer()
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
        analyzer.setSampleRate(outputBusses[0].format.sampleRate)
    }

    override func deallocateRenderResources() {
        inputScratch.deallocate()
        outputScratch.deallocate()
        super.deallocateRenderResources()
    }

    override var internalRenderBlock: AUInternalRenderBlock {
        let sel = selection, inBuf = inputScratch, outBuf = outputScratch, bands = analyzer
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
            // Compute input peak dBFS from left output channel for the level meter
            if out.count > 0, let s = samples(out[0]) {
                var peak: Float = 0
                for i in 0..<frames { let v = abs(s[i]); if v > peak { peak = v } }
                sel.levelBits.store((peak > 1e-7 ? 20 * log10f(peak) : -120).bitPattern, ordering: .relaxed)
            }
            // Before this channel's effects, so its own carving never changes what it measures
            if out.count > 1, let l = samples(out[0]), let r = samples(out[1]) {
                bands.process(left: l, right: r, frames: frames)
            }
            return noErr
        }
    }
}

// MARK: - Output packer

/// Where each packer input bus goes. One Int32 per bus, written on the main thread and read
/// by the render block (aligned 32-bit loads/stores don't tear): -1 = off, otherwise
/// start channel × 2 + (1 if stereo).
nonisolated final class OutputRoutes: @unchecked Sendable {
    let count: Int
    private let codes: UnsafeMutablePointer<Int32>
    private let levelBitsPtr: UnsafeMutablePointer<UInt32>

    init(count: Int) {
        self.count = count
        codes = .allocate(capacity: count)
        codes.initialize(repeating: -1, count: count)
        levelBitsPtr = .allocate(capacity: count)
        levelBitsPtr.initialize(repeating: Float(-120).bitPattern, count: count)
    }

    deinit { codes.deallocate(); levelBitsPtr.deallocate() }

    func set(bus: Int, channel: Int, stereo: Bool) {
        guard bus >= 0, bus < count else { return }
        codes[bus] = Int32(channel * 2 + (stereo ? 1 : 0))
    }

    func clear(bus: Int) {
        guard bus >= 0, bus < count else { return }
        codes[bus] = -1
    }

    @inline(__always) func code(_ bus: Int) -> Int32 { codes[bus] }

    func level(_ bus: Int) -> Float {
        guard bus >= 0, bus < count else { return -120 }
        return Float(bitPattern: levelBitsPtr[bus])
    }

    @inline(__always) func storeLevel(_ bus: Int, bits: UInt32) {
        guard bus >= 0, bus < count else { return }
        levelBitsPtr[bus] = bits
    }
}

final class OutputPackerAudioUnit: AUAudioUnit {

    static let componentDescription = AudioComponentDescription(
        componentType: kAudioUnitType_Effect,
        componentSubType: 0x4F555450,       // 'OUTP'
        componentManufacturer: 0x4D534C53,  // 'MSLS'
        componentFlags: 0,
        componentFlagsMask: 0
    )

    /// One input bus per routing channel
    static let maxChannels = 32

    /// Each channel's destination: stereo L/R onto two outputs, or summed onto one
    let routes = OutputRoutes(count: OutputPackerAudioUnit.maxChannels)
    private let busScratch = (0..<OutputPackerAudioUnit.maxChannels).map { _ in RoutingScratch() }
    private let outputScratch = RoutingScratch()
    private var _inputBusses: AUAudioUnitBusArray!
    private var _outputBusses: AUAudioUnitBusArray!

    override init(componentDescription: AudioComponentDescription,
                  options: AudioComponentInstantiationOptions = []) throws {
        try super.init(componentDescription: componentDescription, options: options)
        let fmt = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        _inputBusses  = AUAudioUnitBusArray(audioUnit: self, busType: .input,
                                             busses: try (0..<Self.maxChannels).map { _ in try AUAudioUnitBus(format: fmt) })
        let output = try AUAudioUnitBus(format: fmt)
        output.maximumChannelCount = 64    // feeds the interface's whole output
        _outputBusses = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [output])
    }

    /// Stereo in (per channel), any number of channels out
    override var channelCapabilities: [NSNumber]? { [2, -1] }
    override var inputBusses:  AUAudioUnitBusArray { _inputBusses  }
    override var outputBusses: AUAudioUnitBusArray { _outputBusses }
    override var latency: TimeInterval { 0 }

    override func allocateRenderResources() throws {
        try super.allocateRenderResources()
        let frames = Int(maximumFramesToRender)
        for s in busScratch { s.allocate(channels: 2, frames: frames) }
        outputScratch.allocate(channels: Int(outputBusses[0].format.channelCount), frames: frames)
    }

    override func deallocateRenderResources() {
        for s in busScratch { s.deallocate() }
        outputScratch.deallocate()
        super.deallocateRenderResources()
    }

    override var internalRenderBlock: AUInternalRenderBlock {
        let scratch = busScratch, outBuf = outputScratch, routes = routes
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

            for bus in 0..<routes.count {
                let code = Int(routes.code(bus))
                guard code >= 0 else { continue }          // no channel on this bus
                let start = code >> 1, stereo = code & 1 == 1
                guard start < out.count, let list = scratch[bus].list else { continue }
                scratch[bus].prepare(frames: frames)
                var flags: AudioUnitRenderActionFlags = []
                guard pullInput?(&flags, timestamp, frameCount, bus, list.unsafeMutablePointer) == noErr,
                      let left = samples(list[0])
                else { continue }
                let right = (list.count > 1 ? samples(list[1]) : nil) ?? left

                // Compute per-bus peak dBFS for the channel output level meter
                var peak: Float = 0
                for i in 0..<frames { let v = abs(left[i]); if v > peak { peak = v } }
                routes.storeLevel(bus, bits: (peak > 1e-7 ? 20 * log10f(peak) : Float(-120)).bitPattern)

                if stereo {
                    if let dst = samples(out[start]) { for i in 0..<frames { dst[i] += left[i] } }
                    if start + 1 < out.count, let dst = samples(out[start + 1]) {
                        for i in 0..<frames { dst[i] += right[i] }
                    }
                } else if let dst = samples(out[start]) {
                    // Mono output: sum to mono (a centred mono source keeps its level)
                    for i in 0..<frames { dst[i] += 0.5 * (left[i] + right[i]) }
                }
            }
            return noErr
        }
    }
}
