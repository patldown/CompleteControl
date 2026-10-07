//
//  VintageCompressorAU.swift
//  Midi Set List
//
//  In-process AUAudioUnit subclass wrapping VintageCompressorKernel.
//  Registered twice in AudioRoutingEngine.init() — once per model — and the
//  component subtype picks which compressor the instance runs.
//

import AVFoundation
import AudioToolbox
import Synchronization

final class VintageCompressorAudioUnit: AUAudioUnit {

    static let optoDescription = AudioComponentDescription(
        componentType: kAudioUnitType_Effect,
        componentSubType: 0x4F50544F,       // 'OPTO'
        componentManufacturer: 0x4D534C53,  // 'MSLS'
        componentFlags: 0,
        componentFlagsMask: 0
    )

    static let fetDescription = AudioComponentDescription(
        componentType: kAudioUnitType_Effect,
        componentSubType: 0x46455443,       // 'FETC'
        componentManufacturer: 0x4D534C53,  // 'MSLS'
        componentFlags: 0,
        componentFlagsMask: 0
    )

    let kernel: VintageCompressorKernel

    private var _inputBusses: AUAudioUnitBusArray!
    private var _outputBusses: AUAudioUnitBusArray!

    override init(componentDescription: AudioComponentDescription,
                  options: AudioComponentInstantiationOptions = []) throws {
        let model: VintageCompressorModel =
            componentDescription.componentSubType == Self.fetDescription.componentSubType ? .fet : .opto
        kernel = VintageCompressorKernel(model: model)
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
