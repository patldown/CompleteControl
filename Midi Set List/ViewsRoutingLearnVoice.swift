//
//  LearnVoice.swift
//  Midi Set List
//
//  "Learn Voice": a guided pre-show check, like ring-out, that measures one mic three
//  ways — bleed (band playing, singer quiet), the singer's softest line and their
//  loudest — and turns that into gate and level-rider settings.
//

import SwiftUI

/// What Learn Voice measured, in dBFS RMS
struct VoiceLevels: Equatable {
    var bleed: Float        // loudest the bleed gets (95th percentile)
    var softest: Float      // quietest real singing
    var loudest: Float      // peak singing

    /// How far the softest singing sits above the bleed
    var gap: Float { softest - bleed }
    /// Under ~3 dB no threshold can tell voice from bleed
    var separable: Bool { gap >= 3 }

    /// Halfway between bleed and the softest singing (or just above the bleed when they overlap)
    var gate: Float { separable ? bleed + gap / 2 : bleed + 1 }
}

@Observable
final class VoiceCalibrator {
    enum Step: Int, CaseIterable, Identifiable {
        case bleed, softest, loudest
        var id: Int { rawValue }

        var title: String {
            switch self {
            case .bleed:   "Bleed"
            case .softest: "Softest"
            case .loudest: "Loudest"
            }
        }

        var instruction: String {
            switch self {
            case .bleed:   "Band plays as loud as the show, singer stays quiet."
            case .softest: "Sing your quietest line, the way you would on stage."
            case .loudest: "Sing your loudest line."
            }
        }
    }

    static let seconds: Double = 8

    private(set) var recording: Step?
    private(set) var progress: Double = 0
    private(set) var readings: [Step: [Float]] = [:]

    @ObservationIgnored private let readLevel: () -> Float
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var started = Date()

    init(readLevel: @escaping () -> Float) {
        self.readLevel = readLevel
    }

    func isDone(_ step: Step) -> Bool { readings[step]?.isEmpty == false }

    func record(_ step: Step) {
        timer?.invalidate()
        readings[step] = []
        recording = step
        progress = 0
        started = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self else { t.invalidate(); return }
                self.tick()
            }
        }
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
        recording = nil
    }

    private func tick() {
        guard let step = recording else { return }
        let level = readLevel()
        if level > -119 { readings[step, default: []].append(level) }
        progress = min(1, Date().timeIntervalSince(started) / Self.seconds)
        if progress >= 1 { cancel() }
    }

    /// Results once all three steps are recorded
    var levels: VoiceLevels? {
        guard let bleed = readings[.bleed], let soft = readings[.softest], let loud = readings[.loudest],
              !bleed.isEmpty, !soft.isEmpty, !loud.isEmpty else { return nil }
        return VoiceLevels(
            bleed: Self.percentile(bleed, 0.95),
            // A sung line has gaps between words; the 45th percentile skips most of them
            // while still landing on the quiet syllables
            softest: Self.percentile(soft, 0.45),
            loudest: Self.percentile(loud, 0.98)
        )
    }

    private static func percentile(_ values: [Float], _ p: Double) -> Float {
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, max(0, Int(Double(sorted.count - 1) * p)))]
    }
}

/// The Learn Voice section for an effect editor. `describe` says what Apply will set.
struct LearnVoiceSection: View {
    @State private var calibrator: VoiceCalibrator
    let describe: (VoiceLevels) -> String
    let apply: (VoiceLevels) -> Void
    @State private var applied = false

    init(readLevel: @escaping () -> Float,
         describe: @escaping (VoiceLevels) -> String,
         apply: @escaping (VoiceLevels) -> Void) {
        _calibrator = State(initialValue: VoiceCalibrator(readLevel: readLevel))
        self.describe = describe
        self.apply = apply
    }

    var body: some View {
        Section {
            ForEach(VoiceCalibrator.Step.allCases) { step in
                stepRow(step)
            }
            if let levels = calibrator.levels {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Bleed up to \(Int(levels.bleed)) dB · softest \(Int(levels.softest)) dB · loudest \(Int(levels.loudest)) dB")
                        .font(.caption).monospacedDigit()
                    if levels.separable {
                        Text(describe(levels)).font(.callout)
                    } else {
                        Label("The bleed is as loud as your softest singing, so no setting can tell them apart. Move the mic closer, use a tighter pattern, or gate on the XR18.",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.callout).foregroundStyle(.orange)
                    }
                }
                Button(applied ? "Applied ✓" : "Apply") {
                    apply(levels)
                    applied = true
                }
                .disabled(applied)
            }
        } header: {
            Text("Learn Voice")
        } footer: {
            Text("Record each step for \(Int(VoiceCalibrator.seconds)) seconds with the band at show volume. Redo any step by tapping it again.")
        }
        .onChange(of: calibrator.levels) { applied = false }
        .onDisappear { calibrator.cancel() }
    }

    @ViewBuilder
    private func stepRow(_ step: VoiceCalibrator.Step) -> some View {
        let isRecording = calibrator.recording == step
        let previousDone = step == .bleed || calibrator.isDone(VoiceCalibrator.Step(rawValue: step.rawValue - 1)!)
        VStack(alignment: .leading, spacing: 6) {
            Button {
                isRecording ? calibrator.cancel() : calibrator.record(step)
            } label: {
                HStack {
                    Image(systemName: isRecording ? "stop.circle.fill"
                          : calibrator.isDone(step) ? "checkmark.circle.fill" : "record.circle")
                        .foregroundStyle(isRecording ? Color.red : calibrator.isDone(step) ? Color.green : Color.accentColor)
                    Text("\(step.rawValue + 1). \(step.title)")
                    Spacer()
                }
            }
            .disabled(!previousDone || (calibrator.recording != nil && !isRecording))
            Text(step.instruction).font(.caption).foregroundStyle(.secondary)
            if isRecording {
                ProgressView(value: calibrator.progress)
            }
        }
    }
}
