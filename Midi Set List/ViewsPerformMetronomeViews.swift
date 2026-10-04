//
//  MetronomeViews.swift
//  Midi Set List
//
//  Perform's click: a toggle that enables auto-start per song, a standalone play button,
//  and a dot-per-beat display. The dots read the same host-clock timeline the audio
//  clicks are made from.
//

import CoreData
import SwiftUI

struct MetronomeControl: View {
    @Environment(PerformanceSession.self) private var performance
    @ObservedObject var song: Song
    private let metronome = Metronome.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                // Toggle: auto-start the click when this song loads in Perform
                Toggle(isOn: clickEnabledBinding) {
                    Label("Click", systemImage: "metronome")
                        .font(.subheadline)
                }
                .toggleStyle(.button)
                .controlSize(.small)

                // Standalone play: run the click without needing auto-scroll or perform mode
                Button {
                    performance.toggleMetronome()
                } label: {
                    Image(systemName: metronome.isRunning ? "stop.fill" : "play.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(metronome.isRunning ? .red : .accentColor)

                if metronome.isRunning {
                    BeatDots()
                    if metronome.isCountIn {
                        Text("Count-in")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if metronome.isRunning, let warning = metronome.routeWarning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let error = metronome.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var clickEnabledBinding: Binding<Bool> {
        Binding(
            get: { song.clickEnabled },
            set: { enabled in
                song.clickEnabled = enabled
                try? song.managedObjectContext?.save()
                if enabled, !metronome.isRunning {
                    performance.toggleMetronome()
                } else if !enabled, metronome.isRunning {
                    metronome.stop()
                }
            }
        )
    }
}

/// One dot per beat of the bar; the current one lights briefly on the beat, beat 1 larger
struct BeatDots: View {
    private let metronome = Metronome.shared

    var body: some View {
        TimelineView(.animation) { _ in
            let now = currentBeat()
            HStack(spacing: 6) {
                ForEach(0..<metronome.beatsPerBar, id: \.self) { index in
                    let lit = now?.inBar == index && (now?.fraction ?? 1) < 0.3
                    Circle()
                        .fill(lit ? (index == 0 ? Color.orange : Color.accentColor) : Color.secondary.opacity(0.25))
                        .frame(width: index == 0 ? 12 : 9, height: index == 0 ? 12 : 9)
                }
            }
        }
        .accessibilityLabel("Beat")
        .accessibilityValue("\(metronome.bpm) BPM, \(metronome.beatsPerBar) beats per bar")
    }

    /// Where we are now: the beat within the bar, and how far through that beat
    private func currentBeat() -> (inBar: Int, fraction: Double)? {
        let now = Double(mach_absolute_time())
        let start = Double(metronome.startHostTime)
        guard now >= start, metronome.beatTicks > 0 else { return nil }
        let position = (now - start) / Double(metronome.beatTicks)
        let beat = Int(position)
        if metronome.isCountIn && beat >= metronome.beatsPerBar { return nil }
        return (beat % metronome.beatsPerBar, position - Double(beat))
    }
}
