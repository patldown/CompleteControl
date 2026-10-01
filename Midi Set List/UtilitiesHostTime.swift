//
//  HostTime.swift
//  Midi Set List
//
//  The system's high-resolution clock (mach ticks), shared by MIDI clock, the metronome
//  and the beat display so they all count beats from the same moments.
//

import Darwin

nonisolated enum HostTime {
    static let ticksPerSecond: Double = {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return 1_000_000_000 * Double(timebase.denom) / Double(timebase.numer)
    }()

    static func ticks(seconds: Double) -> UInt64 {
        UInt64((seconds * ticksPerSecond).rounded())
    }

    static func seconds(ticks: Double) -> Double {
        ticks / ticksPerSecond
    }

    /// One MIDI clock pulse (1/24 beat) in whole ticks. The metronome uses 24 of these as
    /// its beat, so clicks and clock pulses can never drift apart, however long they run.
    static func clockPulseTicks(bpm: Int) -> UInt64 {
        ticks(seconds: 60.0 / Double(max(bpm, 1) * 24))
    }

    static func beatTicks(bpm: Int) -> UInt64 {
        clockPulseTicks(bpm: bpm) * 24
    }
}
