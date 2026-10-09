//
//  ViewsRoutingChannelWizard.swift
//  Midi Set List
//
//  Auto-setup wizard that walks through every auto-configurable step for a
//  channel (Auto Gain, Level Rider target, Feedback Notch ring-out) and shows
//  timed countdowns with clear user instructions for each step.
//

import SwiftUI

// MARK: - Config (which steps apply to this channel)

struct ChannelWizardConfig {
    let channelID: UUID
    let steps: [WizardStep]
    let hasAutoGain: Bool
    let hasLevelRider: Bool
    let levelRiderSlotIndex: Int?
    let hasFeedbackNotch: Bool
    let feedbackNotchSlotIndex: Int?

    var isEmpty: Bool { steps.isEmpty }

    static func build(for channel: AudioChannel) -> ChannelWizardConfig {
        let link = MixerLink.shared
        let hasAutoGain = link.settings.showGain

        var hasLevelRider = false
        var levelRiderSlotIndex: Int?
        var hasFeedbackNotch = false
        var feedbackNotchSlotIndex: Int?

        for (i, slot) in channel.slots.enumerated() {
            guard !slot.isBypassed, let type = slot.type else { continue }
            switch type {
            case .levelRider:
                hasLevelRider = true
                levelRiderSlotIndex = i
            case .feedbackNotch:
                hasFeedbackNotch = true
                feedbackNotchSlotIndex = i
            default:
                break
            }
        }

        var steps: [WizardStep] = []
        if hasAutoGain || hasLevelRider { steps.append(.loudPlay) }
        if hasFeedbackNotch { steps.append(.ringOut) }

        return ChannelWizardConfig(
            channelID: channel.id,
            steps: steps,
            hasAutoGain: hasAutoGain,
            hasLevelRider: hasLevelRider,
            levelRiderSlotIndex: levelRiderSlotIndex,
            hasFeedbackNotch: hasFeedbackNotch,
            feedbackNotchSlotIndex: feedbackNotchSlotIndex
        )
    }
}

enum WizardStep {
    case loudPlay   // Auto Gain (OSC) + Level Rider target
    case ringOut    // Feedback Notch ring-out
}

// MARK: - Trigger button (shown on strip only when steps exist)

struct ChannelWizardButton: View {
    let channel: AudioChannel
    @Binding var isPresented: Bool

    var body: some View {
        if !ChannelWizardConfig.build(for: channel).isEmpty {
            Button { isPresented = true } label: {
                Image(systemName: "wand.and.stars")
                    .font(.caption)
                    .foregroundStyle(.purple)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Auto Setup")
        }
    }
}

// MARK: - Wizard sheet

struct ChannelWizardSheet: View {
    let channelID: UUID
    @Environment(\.dismiss) private var dismiss

    private let store = AudioRoutingStore.shared
    private let engine = AudioRoutingEngine.shared
    private let link = MixerLink.shared

    @State private var stepIndex = 0
    @State private var phase: Phase = .ready
    @State private var results: [String] = []
    @State private var ringOutAnalyzer: RingOutAnalyzer?

    private enum Phase: Equatable {
        case ready
        case countdown(Int)
        case measuring(progress: Double)
        case ringOut
        case done
    }

    private var channel: AudioChannel {
        store.channels.first { $0.id == channelID } ?? AudioChannel()
    }
    private var config: ChannelWizardConfig { ChannelWizardConfig.build(for: channel) }
    private var currentStep: WizardStep? {
        config.steps.indices.contains(stepIndex) ? config.steps[stepIndex] : nil
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 28) {
                stepDots
                Spacer()
                phaseContent
                Spacer()
                resultLog
            }
            .padding(28)
            .navigationTitle(channel.name.isEmpty ? "Auto Setup" : channel.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { ringOutAnalyzer?.stop(); dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: Step dots

    @ViewBuilder
    private var stepDots: some View {
        if config.steps.count > 1 {
            HStack(spacing: 10) {
                ForEach(config.steps.indices, id: \.self) { i in
                    Capsule()
                        .fill(i < stepIndex ? Color.green
                              : i == stepIndex ? Color.accentColor
                              : Color.secondary.opacity(0.25))
                        .frame(width: i == stepIndex ? 24 : 8, height: 8)
                        .animation(.snappy, value: stepIndex)
                }
            }
        }
    }

    // MARK: Phase content

    @ViewBuilder
    private var phaseContent: some View {
        switch phase {
        case .ready:
            readyView

        case .countdown(let n):
            VStack(spacing: 20) {
                Text("\(n)")
                    .font(.system(size: 80, weight: .bold, design: .rounded))
                    .foregroundStyle(.orange)
                    .contentTransition(.numericText(countsDown: true))
                    .animation(.spring, value: n)
                stepInstructionLabel
            }

        case .measuring(let progress):
            VStack(spacing: 20) {
                stepInstructionLabel
                ProgressView(value: progress)
                    .tint(.green)
                    .frame(maxWidth: 320)
                    .animation(.linear(duration: 0.05), value: progress)
                Text(String(format: "%.0f%%", progress * 100))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

        case .ringOut:
            ringOutView

        case .done:
            VStack(spacing: 16) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 60))
                    .foregroundStyle(.green)
                Text("All done!")
                    .font(.title2.weight(.semibold))
                Button("Close") { dismiss() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: Ready / intro

    private var readyView: some View {
        VStack(spacing: 24) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 56))
                .foregroundStyle(.purple)
            VStack(spacing: 8) {
                Text("Auto Setup")
                    .font(.title2.weight(.semibold))
                Text(wizardSummary)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button {
                Task { await runCurrentStep() }
            } label: {
                Label("Begin", systemImage: "play.fill")
                    .font(.headline)
                    .frame(maxWidth: 300)
            }
            .buttonStyle(.borderedProminent)
            .tint(.purple)
        }
    }

    // MARK: Step instruction label

    @ViewBuilder
    private var stepInstructionLabel: some View {
        switch currentStep {
        case .loudPlay:
            VStack(spacing: 6) {
                Text(loudPlaySubtitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("Play or sing your loudest part")
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
            }
        case .ringOut:
            VStack(spacing: 6) {
                Text("Feedback Notch")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("Slowly raise the gain until it rings")
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
            }
        case nil:
            EmptyView()
        }
    }

    // MARK: Ring-out view

    private var isRingOutRunning: Bool { ringOutAnalyzer?.isRunning == true }

    private var ringOutView: some View {
        VStack(spacing: 20) {
            Image(systemName: "ear")
                .font(.system(size: 52))
                .foregroundStyle(isRingOutRunning ? .orange : .secondary)
                .symbolEffect(.pulse, isActive: isRingOutRunning)

            VStack(spacing: 8) {
                Text("Feedback Notch — Ring-Out")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if isRingOutRunning {
                    Text(ringOutAnalyzer?.candidateFrequency.map {
                        "Hearing: \(FeedbackNotch.label(for: $0))"
                    } ?? "Listening — no ringing yet")
                    .font(.callout)
                    .foregroundStyle(ringOutAnalyzer?.candidateFrequency == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.orange))
                    if let action = ringOutAnalyzer?.lastAction {
                        Text(action).font(.callout.weight(.medium)).foregroundStyle(.green)
                    }
                } else {
                    Text("Raise the gain until it rings.\nEach ring frequency gets notched automatically.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }

            HStack(spacing: 12) {
                Button {
                    isRingOutRunning ? stopRingOut() : startRingOut()
                } label: {
                    Label(isRingOutRunning ? "Stop" : "Start Ring-Out",
                          systemImage: isRingOutRunning ? "stop.circle.fill" : "ear")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(isRingOutRunning ? .red : .accentColor)

                Button("Done") { advanceOrFinish() }
                    .buttonStyle(.bordered)
                    .disabled(isRingOutRunning)
            }
            .frame(maxWidth: 360)

            if isRingOutRunning {
                Text("Tip: back the gain off slightly after you're done.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Result log

    @ViewBuilder
    private var resultLog: some View {
        if !results.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(results.indices, id: \.self) { i in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.caption)
                        Text(results[i])
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
        }
    }

    // MARK: - Step execution

    private func runCurrentStep() async {
        guard let step = currentStep else { advanceOrFinish(); return }
        switch step {
        case .loudPlay: await runLoudPlayStep()
        case .ringOut:  phase = .ringOut    // user-controlled; they tap Start/Done
        }
    }

    private func runLoudPlayStep() async {
        guard engine.isRunning else {
            results.append("Audio engine not running — turn it on first")
            advanceOrFinish()
            return
        }

        // 3-second countdown
        for n in stride(from: 3, through: 1, by: -1) {
            phase = .countdown(n)
            try? await Task.sleep(for: .seconds(1))
        }

        // Measure
        let duration = link.settings.autoGainSeconds
        let tickMs = 50
        let total = Int(duration * 1000) / tickMs
        var peaks: [Float] = []
        peaks.reserveCapacity(total)

        for i in 0..<total {
            phase = .measuring(progress: Double(i) / Double(total))
            peaks.append(engine.channelInputLevel(id: channelID))
            try? await Task.sleep(for: .milliseconds(tickMs))
        }
        phase = .measuring(progress: 1.0)
        try? await Task.sleep(for: .milliseconds(200))

        let valid = peaks.filter { $0 > -80 }.sorted()

        // Auto Gain (OSC)
        if config.hasAutoGain {
            if let current = link.gainDB[channelID], !valid.isEmpty {
                let p95 = valid[min(valid.count - 1, Int(Double(valid.count) * 0.95))]
                let clipped = valid.filter { $0 > -0.5 }.count > 2
                let change = clipped
                    ? min(-6, link.settings.autoGainTargetDB - p95 - 6)
                    : link.settings.autoGainTargetDB - p95
                let newGain = min(link.settings.gainMaxDB,
                                  max(link.settings.gainMinDB, (current + change).rounded()))
                link.setGain(newGain, for: channel)
                results.append(clipped
                    ? "Gain → \(Int(newGain)) dB (was clipping — run again)"
                    : "Gain → \(Int(newGain)) dB")
            } else if link.gainDB[channelID] == nil {
                results.append("Gain: not connected to mixer — skipped")
            }
        }

        // Level Rider target
        if config.hasLevelRider, let idx = config.levelRiderSlotIndex {
            let target: Float
            if config.hasAutoGain {
                // Stay consistent: same target as the preamp we just set
                target = link.settings.autoGainTargetDB
            } else if !valid.isEmpty {
                let p50 = valid[valid.count / 2]
                target = min(-6, max(-30, p50.rounded()))
            } else {
                target = -18
            }
            var ch = channel
            ch.slots[idx].levelRider.targetLevel = target
            store.update(ch)
            engine.applySlot(ch.slots[idx], channelID: channelID, slotIndex: idx)
            results.append("Level Rider target → \(Int(target)) dBFS")
        }

        if valid.isEmpty {
            results.append("Nothing heard — check input and try again")
        }

        advanceOrFinish()
    }

    private func startRingOut() {
        guard let idx = config.feedbackNotchSlotIndex,
              let au = engine.liveAudioUnit(channelID: channelID, slotIndex: idx)
                as? FeedbackNotchAudioUnit else {
            results.append("Feedback Notch: engine not running")
            return
        }
        let analyzer = ringOutAnalyzer ?? RingOutAnalyzer(kernel: au.kernel)
        ringOutAnalyzer = analyzer
        analyzer.start(
            get: { [self] in channel.slots[idx].feedbackNotch },
            set: { [self] p in
                var ch = channel
                ch.slots[idx].feedbackNotch = p
                store.update(ch)
            }
        )
    }

    private func stopRingOut() {
        ringOutAnalyzer?.stop()
        if let action = ringOutAnalyzer?.lastAction {
            results.append("Ring-out: \(action)")
        }
    }

    private func advanceOrFinish() {
        ringOutAnalyzer?.stop()
        if stepIndex + 1 < config.steps.count {
            stepIndex += 1
            phase = .ready
            Task { await runCurrentStep() }
        } else {
            phase = .done
        }
    }

    // MARK: - Labels

    private var loudPlaySubtitle: String {
        switch (config.hasAutoGain, config.hasLevelRider) {
        case (true, true):  return "Auto Gain + Level Rider"
        case (true, false): return "Auto Gain"
        default:            return "Level Rider"
        }
    }

    private var wizardSummary: String {
        var parts: [String] = []
        if config.hasAutoGain   { parts.append("set preamp gain") }
        if config.hasLevelRider { parts.append("calibrate level rider") }
        if config.hasFeedbackNotch { parts.append("ring out feedback notches") }
        switch parts.count {
        case 0: return "Nothing to auto-configure."
        case 1: return parts[0].capitalized + "."
        case 2: return parts[0].capitalized + " and " + parts[1] + "."
        default:
            var p = parts
            let last = p.removeLast()
            return p.joined(separator: ", ").capitalized + ", and " + last + "."
        }
    }
}
