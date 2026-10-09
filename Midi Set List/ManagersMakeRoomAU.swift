//
//  MakeRoomAU.swift
//  Midi Set List
//
//  In-process AUAudioUnit subclass wrapping MakeRoomKernel. Registered in
//  AudioRoutingEngine.init(); the engine points it at its key channels' analyzers.
//

import AVFoundation
import AudioToolbox
import Synchronization

final class MakeRoomAudioUnit: AUAudioUnit {

    static let componentDescription = AudioComponentDescription(
        componentType: kAudioUnitType_Effect,
        componentSubType: 0x4D524F4D,       // 'MROM'
        componentManufacturer: 0x4D534C53,  // 'MSLS'
        componentFlags: 0,
        componentFlagsMask: 0
    )

    let kernel = MakeRoomKernel()

    private var _inputBusses: AUAudioUnitBusArray!
    private var _outputBusses: AUAudioUnitBusArray!

    override init(componentDescription: AudioComponentDescription,
                  options: AudioComponentInstantiationOptions = []) throws {
        try super.init(componentDescription: componentDescription, options: options)
        let fmt = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        _inputBusses  = AUAudioUnitBusArray(audioUnit: self, busType: .input,
                                             busses: [try AUAudioUnitBus(format: fmt)])
        _outputBusses = AUAudioUnitBusArray(audioUnit: self, busType: .output,
                                             busses: [try AUAudioUnitBus(format: fmt)])
    }

    override var inputBusses:  AUAudioUnitBusArray { _inputBusses  }
    override var outputBusses: AUAudioUnitBusArray { _outputBusses }
    override var latency: TimeInterval { 0 }

    override func allocateRenderResources() throws {
        try super.allocateRenderResources()
        kernel.setSampleRate(outputBusses[0].format.sampleRate)
    }

    private let bypassFlag = AUBypassFlag()

    // Set by AVAudioUnitEffect.bypass; the render block passes audio straight through
    override var shouldBypassEffect: Bool {
        get { bypassFlag.isOn.load(ordering: .relaxed) }
        set { bypassFlag.isOn.store(newValue, ordering: .relaxed) }
    }

    override var internalRenderBlock: AUInternalRenderBlock {
        let k = kernel
        let bypass = bypassFlag
        return { actionFlags, timestamp, frameCount, outputBus, outputData, eventList, pullInput in
            var renderFlags: AudioUnitRenderActionFlags = []
            let status = pullInput?(&renderFlags, timestamp, frameCount, 0, outputData) ?? noErr
            guard status == noErr else { return status }
            if bypass.isOn.load(ordering: .relaxed) { return noErr }
            k.process(outputData, frameCount: Int(frameCount))
            return noErr
        }
    }
}
