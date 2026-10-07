//
//  RoutingView.swift
//  Midi Set List
//
//  Routing tab: user-added mono channel strips, each with a 4-slot built-in FX chain,
//  per-channel output assignment, and named per-channel macros (saved presets).
//  Only shown when an external audio interface is connected.
//

import AVFoundation
import SwiftUI
import Synchronization

// MARK: - Top-level tab view

struct RoutingView: View {
    private let store = AudioRoutingStore.shared
    private let engine = AudioRoutingEngine.shared
    @State private var showingAddChannel = false

    var body: some View {
        NavigationStack {
            Group {
                if !store.isExternalInterfaceConnected {
                    noInterfaceView
                } else if store.channels.isEmpty {
                    emptyStateView
                } else {
                    channelScrollView
                }
            }
            .navigationTitle("Routing")
            .toolbar { toolbar }
            .sheet(isPresented: $showingAddChannel) { AddChannelSheet() }
            .task { store.enableInputEnumeration() }
            .safeAreaInset(edge: .top) {
                if engine.needsRestart && engine.isRunning { restartBanner }
            }
            .safeAreaInset(edge: .bottom) {
                if store.isExternalInterfaceConnected { latencyBar }
            }
        }
    }

    private var latencyBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "timer").foregroundStyle(.secondary)
            if let latency = engine.roundTripLatency {
                let ms = latency * 1000
                Text("Latency ≈ \(String(format: "%.1f", ms)) ms")
                    .monospacedDigit()
                    .foregroundStyle(ms <= 10 ? Color.green : ms <= 20 ? Color.orange : Color.red)
                if let granted = engine.actualBufferFrames, granted != engine.bufferFrames {
                    Text("(iOS gave \(granted))").foregroundStyle(.secondary)
                }
            } else {
                Text("Start the engine to measure latency").foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                Picker("Buffer Size", selection: Binding(
                    get: { engine.bufferFrames },
                    set: { engine.bufferFrames = $0 }
                )) {
                    ForEach(AudioRoutingEngine.bufferSizeOptions, id: \.self) { frames in
                        Text(Self.bufferLabel(frames)).tag(frames)
                    }
                }
            } label: {
                Label("Buffer \(engine.bufferFrames)", systemImage: "slider.horizontal.below.rectangle")
            }
        }
        .font(.caption)
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.regularMaterial, in: Rectangle())
    }

    private static func bufferLabel(_ frames: Int) -> String {
        switch frames {
        case 64:  "64 samples (lowest latency, may crackle)"
        case 128: "128 samples (recommended)"
        case 512: "512 samples (safest, most latency)"
        default:  "\(frames) samples"
        }
    }

    private var noInterfaceView: some View {
        ContentUnavailableView(
            "No Interface Connected",
            systemImage: "cable.connector",
            description: Text("Connect an audio interface to use the routing engine.")
        )
    }

    private var emptyStateView: some View {
        ContentUnavailableView {
            Label("No Channels", systemImage: "slider.horizontal.3")
        } description: {
            Text("Tap + to add an audio input channel with its own FX chain and output routing.")
        } actions: {
            Button("Add Channel") { showingAddChannel = true }.buttonStyle(.bordered)
        }
    }

    private var channelScrollView: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(store.channels) { ch in ChannelStripView(channelID: ch.id) }
                MetronomeStripView()
            }
            .padding(16)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button { showingAddChannel = true } label: {
                Label("Add Channel", systemImage: "plus")
            }
        }
        ToolbarItem(placement: .secondaryAction) {
            Button {
                Task {
                    if engine.isRunning { engine.stop() } else { await engine.start() }
                }
            } label: {
                Label(
                    engine.isRunning ? "Stop Engine" : "Start Engine",
                    systemImage: engine.isRunning ? "stop.fill" : "play.fill"
                )
            }
            .tint(engine.isRunning ? .red : .accentColor)
        }
    }

    private var restartBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text("FX type changed — restart to apply.").font(.caption)
            Spacer()
            Button("Restart") { Task { await engine.start() } }.font(.caption.bold())
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.regularMaterial, in: Rectangle())
    }
}

// MARK: - Channel strip

private struct FXEditTarget: Identifiable {
    let id = UUID()
    let slotIndex: Int
}

struct ChannelStripView: View {
    let channelID: UUID
    @State private var fxEditTarget: FXEditTarget?
    @State private var showingMacroSave = false
    @State private var newMacroName = ""

    private let store = AudioRoutingStore.shared
    private let engine = AudioRoutingEngine.shared

    private var channel: AudioChannel {
        store.channels.first { $0.id == channelID } ?? AudioChannel()
    }

    private func commit(_ updated: AudioChannel) {
        store.update(updated)
        if engine.isRunning { engine.applyVolume(of: updated) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            stripHeader
            Divider()
            fxSlots
            Divider()
            stripFooter
            Divider()
            macroSection
        }
        .frame(width: 185)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
        .sheet(item: $fxEditTarget) { target in
            FXSlotEditorSheet(
                slot: channel.slots[target.slotIndex],
                liveUnit: engine.liveAudioUnit(channelID: channelID, slotIndex: target.slotIndex)
            ) { updatedSlot in
                let typeChanged = updatedSlot.type != channel.slots[target.slotIndex].type
                var c = channel
                c.slots[target.slotIndex] = updatedSlot
                store.update(c)
                guard engine.isRunning else { return }
                if typeChanged {
                    engine.needsRestart = true
                } else {
                    engine.applyMacro(
                        ChannelMacro(slots: c.slots, outputBus: c.outputBus,
                                     volume: c.volume, isMuted: c.isMuted),
                        to: channelID
                    )
                }
            }
        }
        .alert("Save Preset", isPresented: $showingMacroSave) {
            TextField("Name", text: $newMacroName)
            Button("Save") { saveMacro() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saves the current FX settings as a named preset for this channel.")
        }
    }

    // MARK: Header

    private var stripHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("Name", text: Binding(
                    get: { channel.name },
                    set: { var c = channel; c.name = $0; commit(c) }
                ))
                .font(.headline).textFieldStyle(.plain)

                Button(role: .destructive) {
                    store.remove(channel)
                    if engine.isRunning { Task { await engine.start() } }
                } label: {
                    Image(systemName: "minus.circle.fill").foregroundStyle(.red)
                }
            }

            Text(store.inputPort(for: channel)?.displayName ?? "Input \(channel.inputIndex + 1)")
                .font(.caption).foregroundStyle(.secondary)

            let nextExists = store.availableInputs.contains {
                $0.monoIndex == channel.inputIndex + 1
            }
            if nextExists {
                Toggle("Stereo Link", isOn: Binding(
                    get: { channel.isStereoLinked },
                    set: { val in
                        var c = channel; c.isStereoLinked = val; store.update(c)
                        if engine.isRunning { Task { await engine.start() } }
                    }
                ))
                .font(.caption).toggleStyle(.button).buttonStyle(.bordered).controlSize(.mini)
            }
        }
        .padding(10)
    }

    // MARK: FX slots

    private var fxSlots: some View {
        VStack(spacing: 0) {
            ForEach(0..<4, id: \.self) { i in
                FXSlotRowView(slot: channel.slots[i]) {
                    fxEditTarget = FXEditTarget(slotIndex: i)
                } onBypassToggle: {
                    var c = channel
                    c.slots[i].isBypassed.toggle()
                    store.update(c)
                    if engine.isRunning {
                        engine.applyMacro(
                            ChannelMacro(slots: c.slots, outputBus: c.outputBus,
                                         volume: c.volume, isMuted: c.isMuted),
                            to: channelID
                        )
                    }
                }
                if i < 3 { Divider() }
            }
        }
    }

    // MARK: Footer

    private var stripFooter: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Out").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Picker("Output", selection: Binding(
                    get: { channel.outputBus },
                    set: { val in
                        var c = channel; c.outputBus = val; store.update(c)
                        if engine.isRunning { Task { await engine.start() } }
                    }
                )) {
                    ForEach(0..<store.availableOutputBusPairCount, id: \.self) { bus in
                        Text(store.outputBusLabel(bus)).tag(bus)
                    }
                }
                .pickerStyle(.menu).font(.caption)
            }

            HStack(spacing: 6) {
                Image(systemName: "speaker.fill").font(.caption).foregroundStyle(.secondary)
                Slider(value: Binding(
                    get: { Double(channel.volume) },
                    set: { val in var c = channel; c.volume = Float(val); commit(c) }
                ), in: 0...1)
                Button {
                    var c = channel; c.isMuted.toggle(); commit(c)
                } label: {
                    Image(systemName: channel.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .foregroundStyle(channel.isMuted ? .red : .secondary).font(.caption)
                }
            }
        }
        .padding(10)
    }

    // MARK: Macros

    private var macroSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("PRESETS")
                    .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button {
                    newMacroName = "Preset \(channel.macros.count + 1)"
                    showingMacroSave = true
                } label: {
                    Image(systemName: "plus.circle").font(.caption)
                }
            }

            if channel.macros.isEmpty {
                Text("No presets yet").font(.caption).foregroundStyle(.tertiary)
            } else {
                ForEach(channel.macros) { macro in
                    HStack {
                        Button {
                            engine.applyMacro(macro, to: channelID)
                        } label: {
                            Text(macro.name)
                                .font(.caption).lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Button(role: .destructive) {
                            var c = channel
                            c.macros.removeAll { $0.id == macro.id }
                            store.update(c)
                        } label: {
                            Image(systemName: "xmark").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .padding(10)
    }

    private func saveMacro() {
        guard !newMacroName.isEmpty else { return }
        let c = channel
        let macro = ChannelMacro(
            name: newMacroName,
            slots: c.slots, outputBus: c.outputBus,
            volume: c.volume, isMuted: c.isMuted
        )
        var updated = c
        updated.macros.append(macro)
        store.update(updated)
        newMacroName = ""
    }
}

// MARK: - FX slot row (compact display in strip)

struct FXSlotRowView: View {
    let slot: ChannelFXSlot
    let onTap: () -> Void
    let onBypassToggle: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onTap) {
                HStack(spacing: 6) {
                    if let type = slot.type {
                        Image(systemName: type.systemImage)
                            .foregroundStyle(Color.accentColor).font(.caption2).frame(width: 14)
                        Text(type.displayName)
                            .font(.caption)
                            .foregroundStyle(slot.isBypassed ? .tertiary : .primary)
                    } else {
                        Image(systemName: "plus").foregroundStyle(.tertiary)
                            .font(.caption2).frame(width: 14)
                        Text("Empty").font(.caption).foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)

            if slot.type != nil {
                Button(action: onBypassToggle) {
                    Text("B")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(slot.isBypassed ? .orange : .secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}

// MARK: - FX slot editor (full sheet)

struct FXSlotEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var slot: ChannelFXSlot
    private let original: ChannelFXSlot
    /// The slot's running AU (Feedback Notch ring-out, Pitch Guide live tuning and meter)
    let liveUnit: AUAudioUnit?
    let onSave: (ChannelFXSlot) -> Void

    init(slot: ChannelFXSlot, liveUnit: AUAudioUnit? = nil,
         onSave: @escaping (ChannelFXSlot) -> Void) {
        _slot = State(initialValue: slot)
        original = slot
        self.liveUnit = liveUnit
        self.onSave = onSave
    }

    /// Only hand the live unit to an editor of the same type it was built for
    private func live<T: AUAudioUnit>(_: T.Type) -> T? {
        slot.type == original.type ? liveUnit as? T : nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Effect") {
                    Picker("Type", selection: $slot.type) {
                        Text("None").tag(Optional<BuiltInFXType>.none)
                        ForEach(BuiltInFXType.allCases) { type in
                            Label(type.displayName, systemImage: type.systemImage)
                                .tag(Optional(type))
                        }
                    }
                    if slot.type != nil {
                        Toggle("Bypassed", isOn: $slot.isBypassed)
                    }
                }
                if let type = slot.type, !slot.isBypassed {
                    switch type {
                    case .gain:       GainEditor(params: $slot.gain)
                    case .eq3Band:    EQ3BandEditor(params: $slot.eq)
                    case .reverb:     ReverbEditor(params: $slot.reverb)
                    case .delay:      DelayEditor(params: $slot.delay)
                    case .levelRider: LevelRiderEditor(params: $slot.levelRider)
                    case .optoComp:   OptoCompEditor(params: $slot.optoComp)
                    case .fetComp:    FETCompEditor(params: $slot.fetComp)
                    case .feedbackNotch:
                        FeedbackNotchEditor(params: $slot.feedbackNotch,
                                            kernel: live(FeedbackNotchAudioUnit.self)?.kernel)
                    case .pitchGuide:
                        PitchGuideEditor(params: $slot.pitchGuide,
                                         kernel: live(PitchGuideAudioUnit.self)?.kernel)
                    }
                }
            }
            .navigationTitle("FX Slot")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) {
                        // Ring-out and pitch tweaks change the running effect live; put them back
                        (liveUnit as? FeedbackNotchAudioUnit)?.kernel.applyParams(original.feedbackNotch)
                        (liveUnit as? PitchGuideAudioUnit)?.kernel
                            .applyParams(original.pitchGuide.resolved(songKey: AudioRoutingEngine.shared.songKey))
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { onSave(slot); dismiss() } }
            }
        }
    }
}

// MARK: - FX parameter editors

private struct GainEditor: View {
    @Binding var params: GainParams
    var body: some View {
        Section("Gain / Pan") {
            LabeledContent("Volume: \(Int(params.volume * 100))%") {
                Slider(value: $params.volume, in: 0.0...2.0)
            }
            LabeledContent("Pan: \(params.pan >= 0 ? "R" : "L")\(Int(abs(params.pan) * 100))") {
                Slider(value: $params.pan, in: -1.0...1.0)
            }
        }
    }
}

private struct EQ3BandEditor: View {
    @Binding var params: EQ3BandParams
    var body: some View {
        Section("Low Shelf") {
            LabeledContent("Gain: \(String(format: "%+.1f", params.lowShelfGain)) dB") {
                Slider(value: $params.lowShelfGain, in: -24.0...24.0)
            }
            LabeledContent("Freq: \(Int(params.lowShelfFrequency)) Hz") {
                Slider(value: $params.lowShelfFrequency, in: 20.0...500.0)
            }
        }
        Section("Mid") {
            LabeledContent("Gain: \(String(format: "%+.1f", params.midGain)) dB") {
                Slider(value: $params.midGain, in: -24.0...24.0)
            }
            LabeledContent("Freq: \(Int(params.midFrequency)) Hz") {
                Slider(value: $params.midFrequency, in: 100.0...8_000.0)
            }
            LabeledContent("Width: \(String(format: "%.1f", params.midBandwidth)) oct") {
                Slider(value: $params.midBandwidth, in: 0.05...5.0)
            }
        }
        Section("High Shelf") {
            LabeledContent("Gain: \(String(format: "%+.1f", params.highShelfGain)) dB") {
                Slider(value: $params.highShelfGain, in: -24.0...24.0)
            }
            LabeledContent("Freq: \(Int(params.highShelfFrequency)) Hz") {
                Slider(value: $params.highShelfFrequency, in: 1_000.0...20_000.0)
            }
        }
    }
}

private struct ReverbEditor: View {
    @Binding var params: ReverbParams
    var body: some View {
        Section("Reverb") {
            Picker("Room", selection: $params.roomPreset) {
                ForEach(Array(ReverbParams.presetNames.enumerated()), id: \.offset) { i, name in
                    Text(name).tag(i)
                }
            }
            LabeledContent("Wet/Dry: \(Int(params.wetDryMix))%") {
                Slider(value: $params.wetDryMix, in: 0.0...100.0)
            }
        }
    }
}

private struct DelayEditor: View {
    @Binding var params: DelayParams
    var body: some View {
        Section("Delay") {
            LabeledContent("Time: \(String(format: "%.2f", params.delayTime)) s") {
                Slider(value: $params.delayTime, in: 0.0...2.0)
            }
            LabeledContent("Feedback: \(Int(params.feedback))%") {
                Slider(value: $params.feedback, in: -100.0...100.0)
            }
            LabeledContent("LP Cutoff: \(Int(params.lowPassCutoff)) Hz") {
                Slider(value: $params.lowPassCutoff, in: 10.0...22_050.0)
            }
            LabeledContent("Wet/Dry: \(Int(params.wetDryMix))%") {
                Slider(value: $params.wetDryMix, in: 0.0...100.0)
            }
        }
    }
}

private struct LevelRiderEditor: View {
    @Binding var params: LevelRiderParams
    var body: some View {
        Section("Input") {
            LabeledContent("Trim: \(String(format: "%+.1f", params.inputTrim)) dB") {
                Slider(value: $params.inputTrim, in: -12.0...12.0)
            }
        }
        Section("Level Rider") {
            LabeledContent("Target: \(Int(params.targetLevel)) dBFS") {
                Slider(value: $params.targetLevel, in: -30.0...(-6.0))
            }
            LabeledContent("Max Cut: \(Int(params.maxCut)) dB") {
                Slider(value: $params.maxCut, in: -18.0...0.0)
            }
            LabeledContent("Max Boost: +\(Int(params.maxBoost)) dB") {
                Slider(value: $params.maxBoost, in: 0.0...9.0)
            }
            LabeledContent("Cut Speed: \(Int(params.cutSpeed)) ms") {
                Slider(value: $params.cutSpeed, in: 20.0...300.0)
            }
            LabeledContent("Boost Speed: \(Int(params.boostSpeed)) ms") {
                Slider(value: $params.boostSpeed, in: 200.0...2000.0)
            }
        }
        Section("Noise Gate") {
            LabeledContent("Threshold: \(Int(params.gateThreshold)) dBFS") {
                Slider(value: $params.gateThreshold, in: -60.0...(-20.0))
            }
        }
        Section("Output") {
            LabeledContent("Trim: \(String(format: "%+.1f", params.outputTrim)) dB") {
                Slider(value: $params.outputTrim, in: -12.0...12.0)
            }
        }
    }
}

private struct OptoCompEditor: View {
    @Binding var params: OptoCompParams
    var body: some View {
        Section {
            Picker("Mode", selection: $params.limitMode) {
                Text("Compress").tag(false)
                Text("Limit").tag(true)
            }
            .pickerStyle(.segmented)
            LabeledContent("Peak Reduction: \(Int(params.peakReduction))") {
                Slider(value: $params.peakReduction, in: 0.0...100.0)
            }
            LabeledContent("Gain: +\(Int(params.gain)) dB") {
                Slider(value: $params.gain, in: 0.0...40.0)
            }
        } header: {
            Text("Opto Compressor")
        } footer: {
            Text("Smooth, slow-releasing leveling. Turn up Peak Reduction for more squeeze, then Gain to make up level.")
        }
    }
}

private struct FETCompEditor: View {
    @Binding var params: FETCompParams
    var body: some View {
        Section {
            Picker("Ratio", selection: $params.ratio) {
                ForEach(FETCompParams.Ratio.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            LabeledContent("Input: \(Int(params.input)) dB") {
                Slider(value: $params.input, in: 0.0...48.0)
            }
            LabeledContent("Output: \(String(format: "%+.0f", params.output)) dB") {
                Slider(value: $params.output, in: -24.0...12.0)
            }
            LabeledContent("Attack: \(Int(params.attack))") {
                Slider(value: $params.attack, in: 1.0...7.0, step: 1)
            }
            LabeledContent("Release: \(Int(params.release))") {
                Slider(value: $params.release, in: 1.0...7.0, step: 1)
            }
        } header: {
            Text("FET Compressor")
        } footer: {
            Text("Fast and punchy. More Input = more compression; use Output to match level. Attack and Release: 7 is fastest. \"All\" is the aggressive all-buttons-in sound.")
        }
    }
}

private struct FeedbackNotchEditor: View {
    @Binding var params: FeedbackNotchParams
    let kernel: FeedbackNotchKernel?
    @State private var analyzer: RingOutAnalyzer?

    var body: some View {
        Section {
            if let kernel {
                let running = analyzer?.isRunning == true
                Button {
                    if running {
                        analyzer?.stop()
                    } else {
                        let a = analyzer ?? RingOutAnalyzer(kernel: kernel)
                        analyzer = a
                        a.start(get: { params }, set: { params = $0 })
                    }
                } label: {
                    Label(running ? "Stop Ring-Out" : "Start Ring-Out",
                          systemImage: running ? "stop.circle.fill" : "ear")
                }
                .tint(running ? .red : .accentColor)

                if running {
                    LabeledContent("Listening") {
                        Text(analyzer?.candidateFrequency.map { "ringing near \(FeedbackNotch.label(for: $0))" }
                             ?? "no ringing")
                            .foregroundStyle(analyzer?.candidateFrequency == nil ? .secondary : Color.orange)
                    }
                }
                if let action = analyzer?.lastAction {
                    Text(action).font(.callout)
                }
            } else {
                Text("Tap Done, start the engine (restart it if asked), then reopen this slot to ring out.")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Ring-Out")
        } footer: {
            Text("With the band quiet and the mic in its show position, start ring-out and slowly raise the channel's gain on the XR18 until it rings. Each ring gets notched; keep going until you've gained a few dB, then stop and back off a little. Put this effect first in the chain.")
        }

        Section("Detection") {
            LabeledContent("Sensitivity: \(Int(params.sensitivity))") {
                Slider(value: $params.sensitivity, in: 0.0...100.0)
            }
            LabeledContent("Max Depth: \(Int(params.maxDepth)) dB") {
                Slider(value: $params.maxDepth, in: -18.0...(-6.0), step: 1)
            }
        }

        Section {
            if params.notches.isEmpty {
                Text("No notches yet").foregroundStyle(.secondary)
            } else {
                ForEach(params.notches) { notch in
                    LabeledContent(notch.label) {
                        Text("\(Int(notch.depth)) dB").monospacedDigit()
                    }
                }
                .onDelete { params.notches.remove(atOffsets: $0) }
                Button("Clear All Notches", role: .destructive) { params.notches.removeAll() }
            }
        } header: {
            Text("Notches (\(params.notches.count)/\(FeedbackNotchKernel.maxNotches))")
        }
        // Deleting or clearing notches takes effect immediately. Ring-out stops by itself
        // when the sheet closes: the analyzer is released and its timer invalidates.
        .onChange(of: params) { kernel?.applyParams(params) }
    }
}

private struct PitchGuideEditor: View {
    @Binding var params: PitchGuideParams
    let kernel: PitchGuideKernel?

    var body: some View {
        Section {
            if let kernel {
                TimelineView(.animation(minimumInterval: 0.05)) { _ in
                    PitchMeter(kernel: kernel)
                }
            } else {
                Text("Tap Done and start the engine (restart it if asked), then reopen this slot to see what it hears.")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Live")
        } footer: {
            Text("Mono: corrects the first input of the channel. Put it before reverb and delay.")
        }

        Section {
            Toggle("Follow Song Key", isOn: $params.songKeyDrive)
            if params.songKeyDrive {
                LabeledContent("Now") {
                    Text(songKeyLabel).foregroundStyle(.secondary)
                }
            }
            Picker(params.songKeyDrive ? "Fallback Key" : "Key", selection: $params.key) {
                ForEach(0..<12, id: \.self) { Text(PitchGuideParams.noteNames[$0]).tag($0) }
            }
            Picker(params.songKeyDrive ? "Fallback Scale" : "Scale", selection: $params.scale) {
                ForEach(PitchScale.allCases) { Text($0.displayName).tag($0) }
            }
            Picker("Voice Range", selection: $params.voiceRange) {
                ForEach(VoiceRange.allCases) { Text($0.displayName).tag($0) }
            }
        } header: {
            Text("Key")
        } footer: {
            Text(params.songKeyDrive
                 ? "The song's key is what the audience hears; with Transpose on, the voice is tuned in the song key minus the transpose. The fallback is used when the song has no key set."
                 : "The key the singer sings in. Only notes in this key and scale are targets.")
        }

        Section {
            Stepper(value: $params.transpose, in: -12...12) {
                LabeledContent("Transpose") {
                    Text(params.transpose == 0 ? "Off" : String(format: "%+d st", params.transpose))
                        .monospacedDigit()
                }
            }
        } header: {
            Text("Transpose")
        } footer: {
            Text("Shifts the voice by whole semitones in the same pass as the tuning, so it adds no extra latency. The voice is tuned in the key it's sung in, then moved: sung in D with +2 comes out in E. Set Amount to 0% for transpose only.")
        }

        Section {
            Toggle("Auto Formant Correction", isOn: $params.preserveFormants)
            LabeledContent("Formant: \(Self.formantLabel(params.formantShift))") {
                Slider(value: $params.formantShift, in: -6.0...6.0, step: 0.5)
            }
        } header: {
            Text("Voice Character")
        } footer: {
            Text(Self.formantFooter(params))
        }

        Section {
            LabeledContent("Retune Speed: \(params.retuneSpeed < 1 ? "Instant" : "\(Int(params.retuneSpeed)) ms")") {
                Slider(value: $params.retuneSpeed, in: 0.0...400.0, step: 5)
            }
            LabeledContent("Amount: \(Int(params.amount))%") {
                Slider(value: $params.amount, in: 0.0...100.0, step: 1)
            }
            LabeledContent("Humanize: \(Int(params.humanize))%") {
                Slider(value: $params.humanize, in: 0.0...100.0, step: 1)
            }
            LabeledContent("Tolerance: ±\(Int(params.tolerance)) cents") {
                Slider(value: $params.tolerance, in: 0.0...50.0, step: 1)
            }
        } header: {
            Text("Correction")
        } footer: {
            Text("Tolerance: notes within this many cents are left alone; past it, correction kicks in. Amount: how far toward the note it pulls. Humanize: loosens the retune on long held notes.")
        }

        Section {
            LabeledContent("Pickiness: \(Int(params.pickiness))%") {
                Slider(value: $params.pickiness, in: 0.0...100.0, step: 1)
            }
            LabeledContent("Gate: \(Int(params.gateThreshold)) dBFS") {
                Slider(value: $params.gateThreshold, in: -70.0...(-20.0), step: 1)
            }
        } header: {
            Text("Only Correct Real Notes")
        } footer: {
            Text("Higher Pickiness only corrects clear, steady sung notes. Raise the Gate until bleed from other instruments stops showing up in the Live meter.")
        }
        .onChange(of: params) {
            kernel?.applyParams(params.resolved(songKey: AudioRoutingEngine.shared.songKey))
        }
    }

    private static func formantLabel(_ semis: Float) -> String {
        semis == 0 ? "0" : String(format: "%+.1f st", semis)
    }

    private static func formantFooter(_ p: PitchGuideParams) -> String {
        let knob = "Formant + makes the voice smaller and brighter, − bigger and darker."
        if p.preserveFormants {
            return "The singer keeps their natural tone however far the pitch moves; the Formant knob adds or subtracts from there. \(knob) Latency ≈ two pitch cycles."
        }
        if p.formantShift == 0 {
            return "Lowest latency (one pitch cycle). Tone moves along with the pitch, like speeding up a tape. \(knob)"
        }
        return "Tone moves along with the pitch, then the Formant knob shifts it by a set amount. \(knob) Latency ≈ two pitch cycles while the knob is off zero."
    }

    private var songKeyLabel: String {
        guard let key = AudioRoutingEngine.shared.songKey, key.pitchClass != nil else {
            return "No song key — using fallback"
        }
        let heard = "\(key.root) \(key.scale.rawValue)"
        guard params.transpose != 0, let pc = key.pitchClass else { return heard }
        let sung = PitchGuideParams.noteNames[((pc - params.transpose) % 12 + 12) % 12]
        return "\(heard) (sung in \(sung))"
    }
}

/// What the pitch kernel hears and what it's doing about it
private struct PitchMeter: View {
    let kernel: PitchGuideKernel

    var body: some View {
        let detected = Float(bitPattern: kernel.detectedMidiBits.load(ordering: .relaxed))
        let target = Float(bitPattern: kernel.targetMidiBits.load(ordering: .relaxed))
        let cents = Float(bitPattern: kernel.correctionBits.load(ordering: .relaxed))
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent("Hearing") {
                Text(detected < 0 ? "—" : Self.describe(detected))
                    .monospacedDigit()
                    .foregroundStyle(detected < 0 ? .secondary : .primary)
            }
            LabeledContent("Latency") {
                Text(String(format: "%.1f ms", Float(bitPattern: kernel.latencyMsBits.load(ordering: .relaxed))))
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            LabeledContent("Correcting") {
                Text(target < 0 ? "No" : "→ \(Self.noteName(Int(target)))  \(String(format: "%+.0f", cents))¢")
                    .monospacedDigit()
                    .foregroundStyle(target < 0 ? Color.secondary : Color.orange)
            }
        }
    }

    static func noteName(_ midi: Int) -> String {
        PitchGuideParams.noteNames[((midi % 12) + 12) % 12] + "\(midi / 12 - 1)"
    }

    /// e.g. "A3 −12¢"
    static func describe(_ midi: Float) -> String {
        let nearest = Int(midi.rounded())
        return "\(noteName(nearest))  \(String(format: "%+.0f", (midi - Float(nearest)) * 100))¢"
    }
}

// MARK: - Metronome strip (special non-removable channel)

struct MetronomeStripView: View {
    private let metronome = Metronome.shared
    private let prefs = UserPreferences.shared
    private let store = AudioRoutingStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "metronome").font(.caption).foregroundStyle(Color.accentColor)
                Text("Metronome").font(.headline)
                Spacer()
                Circle()
                    .fill(metronome.isRunning ? Color.green : Color.secondary.opacity(0.3))
                    .frame(width: 8, height: 8)
            }
            .padding(10)

            Divider()

            Text("Click channel — no FX in this version.")
                .font(.caption).foregroundStyle(.tertiary)
                .padding(10)

            Divider()

            VStack(spacing: 8) {
                HStack {
                    Text("Out").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Picker("Output", selection: Binding(
                        get: { prefs.metronomeOutputBus },
                        set: { prefs.metronomeOutputBus = $0 }
                    )) {
                        ForEach(0..<store.availableOutputBusPairCount, id: \.self) { bus in
                            Text(store.outputBusLabel(bus)).tag(bus)
                        }
                    }
                    .pickerStyle(.menu).font(.caption)
                }

                HStack(spacing: 6) {
                    Image(systemName: "speaker.fill").font(.caption).foregroundStyle(.secondary)
                    Slider(value: Binding(
                        get: { prefs.metronomeVolume },
                        set: { prefs.metronomeVolume = $0; metronome.applyVolume() }
                    ), in: 0...1)
                }
            }
            .padding(10)
        }
        .frame(width: 185)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Add channel sheet

struct AddChannelSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var selectedMonoIndex = 0
    @State private var stereoLink = false

    private let store = AudioRoutingStore.shared
    private let engine = AudioRoutingEngine.shared

    var body: some View {
        NavigationStack {
            Form {
                Section("Channel Name") {
                    TextField("e.g. Keys L, Vox, Guitar", text: $name)
                }

                Section("Hardware Input") {
                    if store.availableInputs.isEmpty {
                        Text("No inputs detected. Connect an interface and try again.")
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Input", selection: $selectedMonoIndex) {
                            ForEach(store.availableInputs) { port in
                                Text(port.displayName).tag(port.monoIndex)
                            }
                        }
                        .pickerStyle(.inline).labelsHidden()
                    }
                }

                if store.availableInputs.contains(where: { $0.monoIndex == selectedMonoIndex + 1 }) {
                    let nextName = store.availableInputs
                        .first { $0.monoIndex == selectedMonoIndex + 1 }?.displayName ?? "next input"
                    Section {
                        Toggle("Link with \(nextName) as stereo pair", isOn: $stereoLink)
                    } footer: {
                        Text("Routes both inputs through the same FX chain. Use for L/R instruments.")
                    }
                }
            }
            .navigationTitle("Add Channel")
            .navigationBarTitleDisplayMode(.inline)
            .task { store.enableInputEnumeration() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        let ch = AudioChannel(
                            name: name,
                            inputIndex: selectedMonoIndex,
                            isStereoLinked: stereoLink
                        )
                        store.add(ch)
                        if engine.isRunning { Task { await engine.start() } }
                        dismiss()
                    }
                    .disabled(store.availableInputs.isEmpty)
                }
            }
        }
    }
}
