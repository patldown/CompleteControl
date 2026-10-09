//
//  OneKnobAU.swift
//  Midi Set List
//
//  In-process AUAudioUnit subclass wrapping OneKnobKernel. Registered once per effect
//  (Warmth, Air, Punch, Smart Gate) in AudioRoutingEngine.init(); the component subtype
//  picks which one the instance runs.
//

import AVFoundation
import AudioToolbox
import Synchronization

final class OneKnobAudioUnit: AUAudioUnit {

    private static func description(_ subType: OSType) -> AudioComponentDescription {
        AudioComponentDescription(componentType: kAudioUnitType_Effect, componentSubType: subType,
                                  componentManufacturer: 0x4D534C53,  // 'MSLS'
                                  componentFlags: 0, componentFlagsMask: 0)
    }

    static let warmthDescription = description(0x57524D54)   // 'WRMT'
    static let airDescription    = description(0x41495258)   // 'AIRX'
    static let punchDescription  = description(0x50554E43)   // 'PUNC'
    static let gateDescription   = description(0x53474154)   // 'SGAT'

    let kernel: OneKnobKernel

    private var _inputBusses: AUAudioUnitBusArray!
    private var _outputBusses: AUAudioUnitBusArray!

    override init(componentDescription: AudioComponentDescription,
                  options: AudioComponentInstantiationOptions = []) throws {
        let mode: OneKnobMode = switch componentDescription.componentSubType {
        case Self.airDescription.componentSubType:   .air
        case Self.punchDescription.componentSubType: .punch
        case Self.gateDescription.componentSubType:  .gate
        default:                                     .warmth
        }
        kernel = OneKnobKernel(mode: mode)
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
