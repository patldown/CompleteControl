//
//  AUBypassFlag.swift
//  Midi Set List
//
//  In-house AUAudioUnit subclasses must honour bypass themselves: AVAudioUnitEffect.bypass
//  only sets shouldBypassEffect. Each one keeps it here, where the render block can read it
//  without touching the main-thread AU object.
//

import Synchronization

nonisolated final class AUBypassFlag: Sendable {
    let isOn = Atomic<Bool>(false)
}
