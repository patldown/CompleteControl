//
//  RoutingView.swift
//  Midi Set List
//
//  Routing tab: user-added mono channel strips, each with a 4-slot built-in FX chain,
//  per-channel output assignment, and named per-channel macros (saved presets).
//  Only shown when an external audio interface is connected.
//

import AVFoundation
import CoreData
import SwiftUI
import Synchronization

// MARK: - Top-level tab view

struct RoutingView: View {
    private let store = AudioRoutingStore.shared
    private let engine = AudioRoutingEngine.shared
    @State private var showingAddChannel = false
    @State private var showingMixPresets = false
    @State private var showingAIMix = false
    @ObservedObject private var ai = AISettings.shared
    private let link = MixerLink.shared

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
            .sheet(isPresented: $showingMixPresets) { MixPresetsSheet() }
            .sheet(isPresented: $showingAIMix) { MixLevelsSheet() }
            .task { store.enableInputEnumeration() }
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
                Text("Turn Audio on to measure latency").foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                // The one routing change that restarts all audio — a setup choice, not a live one
                Section("Changing this restarts all audio briefly. Set it before the show.") {
                    Picker("Buffer Size", selection: Binding(
                        get: { engine.bufferFrames },
                        set: { engine.bufferFrames = $0 }
                    )) {
                        ForEach(AudioRoutingEngine.bufferSizeOptions, id: \.self) { frames in
                            Text(Self.bufferLabel(frames)).tag(frames)
                        }
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
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .scrollBounceBehavior(.basedOnSize)
        .navigationBarTitleDisplayMode(.inline)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            // A power switch with its state in words, so it can't be mistaken for Perform's play
            Button {
                Task {
                    if engine.isRunning { engine.stop() } else { await engine.start() }
                }
            } label: {
                Label(engine.isRunning ? "Audio On" : "Audio Off", systemImage: "power")
                    .labelStyle(.titleAndIcon)
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .tint(engine.isRunning ? .green : .gray)
            .accessibilityHint(engine.isRunning ? "Turns the routing audio off" : "Turns the routing audio on")
        }
        ToolbarItem(placement: .primaryAction) {
            Button { showingAddChannel = true } label: {
                Label("Add Channel", systemImage: "plus")
            }
        }
        ToolbarItemGroup(placement: .topBarLeading) {
            if !store.channels.isEmpty {
                Button { showingMixPresets = true } label: {
                    Label("Mix Presets", systemImage: "square.stack.3d.up")
                }
                if link.settings.showFader && ai.isAvailable(.mixLevels) {
                    Button { showingAIMix = true } label: {
                        Label("AI Mix", systemImage: "wand.and.stars")
                    }
                }
            }
        }
        ToolbarItem(placement: .secondaryAction) {
            ShareLink(item: AppOSC.referenceMarkdown(channels: store.channels)) {
                Label("Share OSC Reference", systemImage: "doc.text")
            }
        }
        if link.settings.showGain || link.settings.showFader {
            ToolbarItem(placement: .secondaryAction) {
                Button { link.requestCurrentValues() } label: {
                    Label("Read Gain & Faders from Mixer", systemImage: "arrow.down.circle")
                }
                .disabled(!link.isConnected)
            }
        }
    }

}

// MARK: - Channel strip

private struct FXEditTarget: Identifiable {
    let id = UUID()
    let slotIndex: Int
}

struct ChannelStripView: View {
    let channelID: UUID
    @Environment(\.managedObjectContext) private var viewContext
    @FocusState private var nameFocused: Bool
    @State private var nameBeforeEdit: String?
    @State private var renamedMacroCount = 0
    @State private var renameNotice: String?
    @State private var fxEditTarget: FXEditTarget?
    @State private var showingMacroSave = false
    @State private var newMacroName = ""
    @State private var confirmingRemove = false
    @State private var showingWizard = false
    /// FX row a drag is hovering over, highlighted as the drop spot
    @State private var fxDropTarget: Int?
    /// Shared by every strip so they flip together and stay lined up side by side
    @AppStorage("routingFXExpanded") private var fxExpanded = false

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
            stripFader
        }
        .frame(width: fxExpanded ? 270 : 185)
        .animation(.snappy, value: fxExpanded)
        .frame(maxHeight: .infinity, alignment: .top)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
        .overlay(alignment: .leading) {
            if engine.isRunning {
                TimelineView(.animation(minimumInterval: 0.05)) { _ in
                    LevelMeterBar(db: engine.channelInputLevel(id: channelID))
                }
                .frame(width: 4)
                .clipShape(RoundedRectangle(cornerRadius: 2))
                .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .trailing) {
            if engine.isRunning {
                TimelineView(.animation(minimumInterval: 0.05)) { _ in
                    LevelMeterBar(db: engine.channelOutputLevel(id: channelID))
                }
                .frame(width: 4)
                .clipShape(RoundedRectangle(cornerRadius: 2))
                .allowsHitTesting(false)
            }
        }
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
                    engine.syncChannel(channelID)   // rebuilds this channel only
                } else {
                    engine.applyMacro(
                        ChannelMacro(slots: c.slots, output: c.output,
                                     volume: c.volume, isMuted: c.isMuted),
                        to: channelID
                    )
                }
            }
        }
        .sheet(isPresented: $showingWizard) {
            ChannelWizardSheet(channelID: channelID)
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
                .focused($nameFocused)
                .onSubmit { nameFocused = false }
                .onChange(of: nameFocused) { _, focused in
                    if focused { nameBeforeEdit = channel.name } else { finishRename() }
                }

                ChannelWizardButton(channel: channel, isPresented: $showingWizard)

                Button(role: .destructive) {
                    confirmingRemove = true
                } label: {
                    Image(systemName: "minus.circle.fill").foregroundStyle(.red)
                }
                .confirmationDialog("Remove \(channel.name.isEmpty ? "this channel" : channel.name)?",
                                    isPresented: $confirmingRemove, titleVisibility: .visible) {
                    Button("Remove Channel", role: .destructive) {
                        store.remove(channel)
                        engine.syncChannel(channelID)
                    }
                }
            }

            Text(store.inputPort(for: channel)?.displayName ?? "Input \(channel.inputIndex + 1)")
                .font(.caption).foregroundStyle(.secondary)

            MixerLinkControls(channel: channel)

            if let renameNotice {
                Text(renameNotice)
                    .font(.caption2).foregroundStyle(.orange)
                    .task {
                        try? await Task.sleep(for: .seconds(4))
                        self.renameNotice = nil
                    }
            }

            if renamedMacroCount > 0 {
                Text("Updated \(renamedMacroCount) OSC address\(renamedMacroCount == 1 ? "" : "es")")
                    .font(.caption2).foregroundStyle(.green)
                    .task {
                        try? await Task.sleep(for: .seconds(3))
                        renamedMacroCount = 0
                    }
            }

            let nextExists = store.availableInputs.contains {
                $0.monoIndex == channel.inputIndex + 1
            }
            if nextExists {
                Toggle("Stereo Link", isOn: Binding(
                    get: { channel.isStereoLinked },
                    set: { val in
                        var c = channel; c.isStereoLinked = val; store.update(c)
                        engine.updateInput(of: c)   // instant; no rebuild
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
            Button {
                withAnimation(.snappy) { fxExpanded.toggle() }
            } label: {
                HStack {
                    Text("FX").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(fxExpanded ? 0 : -90))
                }
                .padding(.horizontal, 10)
                .frame(minHeight: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(fxExpanded ? "Show effects as rows" : "Show effect details")
            Divider()

            if fxExpanded {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)],
                          spacing: 6) {
                    ForEach(0..<6, id: \.self) { i in
                        FXSlotBlockView(slot: channel.slots[i]) {
                            fxEditTarget = FXEditTarget(slotIndex: i)
                        } onBypassToggle: {
                            toggleBypass(i)
                        }
                    }
                }
                .padding(8)
            } else {
                ForEach(0..<6, id: \.self) { i in
                    FXSlotRowView(slot: channel.slots[i],
                                  liveUnit: engine.liveAudioUnit(channelID: channelID, slotIndex: i)) {
                        fxEditTarget = FXEditTarget(slotIndex: i)
                    } onBypassToggle: {
                        toggleBypass(i)
                    }
                    .background(fxDropTarget == i ? Color.accentColor.opacity(0.15) : .clear)
                    // The payload carries the source row, so no state is left behind
                    // when a drag is cancelled. The channel ID keeps drops on other
                    // strips from moving this strip's effects.
                    .draggable("\(channelID.uuidString):\(i)")
                    .dropDestination(for: String.self) { items, _ in
                        guard let parts = items.first?.split(separator: ":"), parts.count == 2,
                              String(parts[0]) == channelID.uuidString,
                              let src = Int(parts[1]), (0..<6).contains(src), src != i
                        else { return false }
                        moveFXSlot(from: src, to: i)
                        return true
                    } isTargeted: { targeted in
                        if targeted { fxDropTarget = i } else if fxDropTarget == i { fxDropTarget = nil }
                    }
                    .contextMenu {
                        if channel.slots[i].type != nil {
                            Button(role: .destructive) { removeFXSlot(i) } label: {
                                Label("Remove Effect", systemImage: "trash")
                            }
                        }
                    }
                    if i < 5 { Divider() }
                }
            }
        }
    }

    private func toggleBypass(_ i: Int) {
        var c = channel
        c.slots[i].isBypassed.toggle()
        store.update(c)
        if engine.isRunning {
            engine.applyMacro(
                ChannelMacro(slots: c.slots, output: c.output,
                             volume: c.volume, isMuted: c.isMuted),
                to: channelID
            )
        }
    }

    private func removeFXSlot(_ i: Int) {
        var c = channel
        c.slots[i] = ChannelFXSlot()
        store.update(c)
        if engine.isRunning { engine.syncChannel(channelID) }
    }

    private func moveFXSlot(from src: Int, to dst: Int) {
        var c = channel
        c.slots.swapAt(src, dst)
        store.update(c)
        if engine.isRunning { engine.syncChannel(channelID) }
    }

    // MARK: Footer

    private var stripFooter: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Out").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Picker("Output", selection: Binding(
                    get: { channel.output },
                    set: { val in
                        var c = channel; c.output = val; store.update(c)
                        engine.updateOutput(of: c)   // instant; no rebuild
                    }
                )) {
                    Section("Stereo") {
                        ForEach(store.outputRoutes.filter(\.stereo), id: \.self) { Text($0.label).tag($0) }
                    }
                    Section("Mono") {
                        ForEach(store.outputRoutes.filter { !$0.stereo }, id: \.self) { Text($0.label).tag($0) }
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
                    Image(systemName: "plus.circle.fill").font(.title3)
                        .frame(width: 44, height: 32).contentShape(Rectangle())
                }
                .accessibilityLabel("Save Preset")
            }

            if channel.macros.isEmpty {
                Text("No presets yet").font(.caption).foregroundStyle(.tertiary)
            } else {
                ForEach(channel.macros) { macro in
                    HStack {
                        Button {
                            // Live: updates matching effects and the volume, rebuilds nothing
                            MixPresetStore.shared.recall(macro, on: channel)
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

    // MARK: Fader (pinned to bottom)

    @ViewBuilder
    private var stripFader: some View {
        let link = MixerLink.shared
        if link.settings.showFader && link.isConnected {
            let s = link.settings
            let db = link.faderDB[channel.id]
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Fader").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Text(db.map { MixerLinkSettings.faderLabel($0, floor: s.faderFloorDB) } ?? "—")
                        .font(.caption.monospacedDigit())
                }
                Slider(value: Binding(
                    get: { Double(s.faderFloat(db ?? s.faderFloorDB)) },
                    set: { link.setFader(s.faderDB(Float($0)), for: channel) }
                ), in: 0...1)
                .controlSize(.small)
            }
            .padding(10)
        }
    }

    /// Name editing ended: point /app/ macros and song commands at the new name
    private func finishRename() {
        defer { nameBeforeEdit = nil }
        // Names are OSC addresses, so they must be unique: "Vox" taken → "Vox 2"
        let unique = store.uniqueName(channel.name, excluding: channelID)
        if unique != channel.name {
            if !channel.name.trimmingCharacters(in: .whitespaces).isEmpty
                && unique != channel.name.trimmingCharacters(in: .whitespaces) {
                renameNotice = "\"\(channel.name)\" is taken — named \"\(unique)\""
            }
            var c = channel; c.name = unique; commit(c)
        }
        guard let old = nameBeforeEdit, old != channel.name,
              let index = store.channels.firstIndex(where: { $0.id == channelID }) else { return }
        let newSegment = AppOSC.channelSegment(channel, index: index)
        renamedMacroCount = AppOSCRouter.retargetChannel(from: old, to: newSegment, in: viewContext)
    }

    private func saveMacro() {
        guard !newMacroName.isEmpty else { return }
        let c = channel
        let macro = ChannelMacro(
            name: newMacroName,
            slots: c.slots, output: c.output,
            volume: c.volume, isMuted: c.isMuted
        )
        var updated = c
        updated.macros.append(macro)
        store.update(updated)
        newMacroName = ""
    }
}

// MARK: - Mixer link controls (gain knob, fader, Auto Gain)

/// The linked mixer channel's preamp gain and fader, under the strip's name. Shown when
/// turned on in Settings › Mixer Link; every move sends OSC.
struct MixerLinkControls: View {
    let channel: AudioChannel
    private let link = MixerLink.shared

    var body: some View {
        let s = link.settings
        if s.showGain || s.showFader {
            if link.isConnected {
                if s.showGain {
                    VStack(alignment: .leading, spacing: 6) {
                        gainRow(s)
                        if let state = link.autoGain[channel.id] { autoGainStatus(state) }
                    }
                    .padding(.top, 2)
                }
            } else {
                HStack(spacing: 4) {
                    Image(systemName: "cable.connector.slash").font(.caption2)
                    Text("OSC not connected").font(.caption2)
                }
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            }
        }
    }

    private func gainRow(_ s: MixerLinkSettings) -> some View {
        let gain = link.gainDB[channel.id]
        return HStack(spacing: 8) {
            MixerKnob(value: gain ?? s.gainMinDB, range: s.gainMinDB...s.gainMaxDB, known: gain != nil) {
                link.setGain($0, for: channel)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text("Gain").font(.caption2).foregroundStyle(.secondary)
                Text(gain.map { String(format: "%+.0f dB", $0) } ?? "—")
                    .font(.caption.monospacedDigit())
            }
            Spacer(minLength: 0)
            autoGainButton
        }
    }

    @ViewBuilder
    private var autoGainButton: some View {
        if case .listening(let left) = link.autoGain[channel.id] {
            Button { link.cancelAutoGain(for: channel.id) } label: {
                Text("\(left)s")
                    .font(.caption.weight(.bold).monospacedDigit())
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 30)
                    .background(Color.red, in: Capsule())
                    .frame(width: 44, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stop Auto Gain")
        } else {
            Menu {
                Button { Task { await link.runAutoGain(for: channel.id) } } label: {
                    Label("Run Auto Gain", systemImage: "waveform.badge.magnifyingglass")
                }
                Divider()
                Section("Target Level") {
                    ForEach(MixerLinkSettings.autoGainPresets) { preset in
                        Button {
                            link.settings.autoGainTargetDB = preset.targetDB
                        } label: {
                            Label(
                                "\(preset.name) (\(Int(preset.targetDB)) dBFS)",
                                systemImage: link.settings.autoGainTargetDB == preset.targetDB
                                    ? "checkmark.circle.fill" : "circle"
                            )
                        }
                    }
                }
            } label: {
                VStack(spacing: 1) {
                    Text("A")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Color.accentColor)
                    Text("\(Int(link.settings.autoGainTargetDB))")
                        .font(.system(size: 8).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .frame(width: 40, height: 30)
                .background(Color.accentColor.opacity(0.15), in: Capsule())
                .frame(width: 44, height: 40)
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .accessibilityLabel("Auto Gain — target \(Int(link.settings.autoGainTargetDB)) dBFS")
        }
    }

    private func autoGainStatus(_ state: MixerLink.AutoGainState) -> some View {
        Group {
            switch state {
            case .listening:
                Text("Sing or play your loudest part…").foregroundStyle(.orange)
            case .done(let message):
                Text("Auto Gain \(message)").foregroundStyle(.green)
            case .failed(let message):
                Text(message).foregroundStyle(.red)
            }
        }
        .font(.caption2)
        .fixedSize(horizontal: false, vertical: true)
        .onTapGesture { link.clearAutoGainMessage(for: channel.id) }
        .task(id: state) {
            if case .listening = state { return }
            try? await Task.sleep(for: .seconds(8))
            link.clearAutoGainMessage(for: channel.id)
        }
    }
}

/// A rotary knob: drag up/down to turn (150 pt = full range), double-tap to step +1
private struct MixerKnob: View {
    let value: Float
    let range: ClosedRange<Float>
    /// False until the mixer's value is known: drawn dimmed
    var known = true
    let onChange: (Float) -> Void
    @State private var dragStart: Float?

    private var fraction: Double {
        Double((value - range.lowerBound) / max(1, range.upperBound - range.lowerBound))
    }

    var body: some View {
        let sweep = 0.75   // 270° of travel, gap at the bottom
        ZStack {
            Circle()
                .trim(from: 0, to: sweep)
                .stroke(Color.secondary.opacity(0.25), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(135))
            Circle()
                .trim(from: 0, to: sweep * fraction)
                .stroke(known ? Color.accentColor : Color.secondary,
                        style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(135))
            Capsule()
                .fill(Color.primary.opacity(known ? 0.8 : 0.3))
                .frame(width: 2, height: 9)
                .offset(y: -9)
                .rotationEffect(.degrees(-135 + 270 * fraction))
        }
        .frame(width: 36, height: 36)
        .padding(4)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { g in
                    let start = dragStart ?? value
                    dragStart = start
                    let span = range.upperBound - range.lowerBound
                    let v = start - Float(g.translation.height) / 150 * span
                    onChange(min(range.upperBound, max(range.lowerBound, v.rounded())))
                }
                .onEnded { _ in dragStart = nil }
        )
        .onTapGesture(count: 2) { onChange(min(range.upperBound, value + 1)) }
        .accessibilityElement()
        .accessibilityLabel("Gain")
        .accessibilityValue(String(format: "%.0f dB", value))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onChange(min(range.upperBound, value + 1))
            case .decrement: onChange(max(range.lowerBound, value - 1))
            @unknown default: break
            }
        }
    }
}

// MARK: - FX slot row (compact display in strip)

struct FXSlotRowView: View {
    let slot: ChannelFXSlot
    var liveUnit: AUAudioUnit? = nil
    let onTap: () -> Void
    let onBypassToggle: () -> Void

    var body: some View {
        VStack(spacing: 0) {
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
                            Image(systemName: "plus.circle.fill").foregroundStyle(.secondary)
                                .font(.body).frame(width: 14)
                            Text("Add FX").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(minHeight: 40)
                    // Plain buttons only hit on drawn pixels; make the gaps count too
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if slot.type != nil {
                    BypassChip(isBypassed: slot.isBypassed, action: onBypassToggle)
                        .frame(width: 44, height: 40)
                }
            }
            .padding(.leading, 10).padding(.trailing, slot.type == nil ? 10 : 2)

            if let db = gainIndicatorDB {
                GainStagingBar(db: db)
                    .frame(height: 3)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 4)
            }
        }
        .contentShape(Rectangle())
    }

    private var gainIndicatorDB: Float? {
        guard !slot.isBypassed, slot.type == .gain else { return nil }
        let db = 20 * log10f(max(slot.gain.volume, 1e-7))
        return abs(db) > 0.5 ? db : nil
    }
}

/// The B button: orange when bypassed, with a finger-sized hit area around it
private struct BypassChip: View {
    let isBypassed: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("B")
                .font(.caption.weight(.bold))
                .foregroundStyle(isBypassed ? Color.white : Color.secondary)
                .frame(width: 36, height: 28)
                .background(isBypassed ? Color.orange : Color.secondary.opacity(0.15),
                            in: RoundedRectangle(cornerRadius: 6))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isBypassed ? "Bypassed" : "Bypass")
    }
}

// MARK: - FX slot block (expanded view: a glanceable summary; edits happen in the sheet)

struct FXSlotBlockView: View {
    let slot: ChannelFXSlot
    let onTap: () -> Void
    let onBypassToggle: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 3) {
                if let type = slot.type {
                    HStack(spacing: 4) {
                        Image(systemName: type.systemImage)
                            .font(.caption2).foregroundStyle(Color.accentColor)
                        Text(type.shortName).font(.caption.weight(.semibold)).lineLimit(1)
                    }
                    // Leave room for the B chip in the corner
                    .padding(.trailing, 30)
                    Spacer(minLength: 2)
                    if slot.isBypassed {
                        Text("Bypassed").font(.caption2.weight(.semibold)).foregroundStyle(.orange)
                    } else {
                        ForEach(slot.summary, id: \.self) { line in
                            Text(line)
                                .font(.caption2).monospacedDigit()
                                .lineLimit(1).minimumScaleFactor(0.7)
                        }
                    }
                } else {
                    Spacer(minLength: 0)
                    Image(systemName: "plus.circle.fill").font(.title3).foregroundStyle(.secondary)
                    Text("Add FX").font(.caption2).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 82, maxHeight: 82,
                   alignment: slot.type == nil ? .center : .topLeading)
            .padding(6)
            .opacity(slot.isBypassed ? 0.6 : 1)
            .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topTrailing) {
            if slot.type != nil {
                BypassChip(isBypassed: slot.isBypassed, action: onBypassToggle)
                    .frame(width: 40, height: 36)
            }
        }
    }
}

extension BuiltInFXType {
    /// Fits a summary block's header
    var shortName: String {
        switch self {
        case .gain:          "Gain"
        case .eq3Band:       "EQ"
        case .reverb:        "Reverb"
        case .delay:         "Delay"
        case .levelRider:    "Rider"
        case .optoComp:      "Opto"
        case .fetComp:       "FET"
        case .feedbackNotch: "Notch"
        case .pitchGuide:    "Pitch"
        case .microDetune:   "Detune"
        case .harmony:       "Harmony"
        case .piezoBody:     "Body"
        case .tone:          "Tone"
        case .warmth:        "Warmth"
        case .air:           "Air"
        case .punch:         "Punch"
        case .smartGate:     "Gate"
        }
    }
}

extension ChannelFXSlot {
    /// Up to three short lines of the settings that matter most, for a glance check
    var summary: [String] {
        func db(_ v: Float) -> String { v == 0 ? "0" : String(format: "%+.1f", v) }
        func hz(_ v: Float) -> String { v >= 1_000 ? String(format: "%.1fk", v / 1_000) : "\(Int(v))" }
        switch type {
        case nil:
            return []
        case .gain:
            let level = 20 * log10f(max(gain.volume, 1e-7))
            let pan = abs(gain.pan) < 0.01 ? "C" : "\(gain.pan < 0 ? "L" : "R")\(Int((abs(gain.pan) * 100).rounded()))"
            return [gain.volume < 1e-6 ? "−∞ dB" : "\(db(level.rounded(toPlaces: 1))) dB", "Pan \(pan)"]
        case .eq3Band:
            let bands = [("Lo", eq.lowShelfGain, eq.lowShelfFrequency),
                         ("Mid", eq.midGain, eq.midFrequency),
                         ("Hi", eq.highShelfGain, eq.highShelfFrequency)]
                .filter { abs($0.1) >= 0.05 }
                .map { "\($0.0) \(db($0.1)) @\(hz($0.2))" }
            return bands.isEmpty ? ["Flat"] : bands
        case .reverb:
            return [ReverbParams.presetNames.indices.contains(reverb.roomPreset)
                        ? ReverbParams.presetNames[reverb.roomPreset] : "Room",
                    "Wet \(Int(reverb.wetDryMix))%"]
        case .delay:
            return ["\(Int((delay.delayTime * 1000).rounded())) ms", "FB \(Int(delay.feedback))%",
                    "Wet \(Int(delay.wetDryMix))%"]
        case .levelRider:
            return ["Target \(Int(levelRider.targetLevel))",
                    "+\(Int(levelRider.maxBoost)) / \(Int(levelRider.maxCut)) dB",
                    "Gate \(Int(levelRider.gateThreshold))"]
        case .optoComp:
            return [optoComp.limitMode ? "Limit" : "Compress",
                    "PR \(Int(optoComp.peakReduction))",
                    "Gain +\(Int(optoComp.gain))"]
        case .fetComp:
            return [fetComp.ratio == .allButtons ? "All buttons" : "\(fetComp.ratio.label):1",
                    "In \(Int(fetComp.input)) Out \(db(fetComp.output.rounded()))",
                    "Atk \(Int(fetComp.attack)) Rel \(Int(fetComp.release))"]
        case .feedbackNotch:
            let n = feedbackNotch.notches.count
            guard n > 0 else { return ["No notches", "Ring out to set"] }
            let deepest = feedbackNotch.notches.min { $0.depth < $1.depth }!
            return ["\(n) notch\(n == 1 ? "" : "es")", "Deepest \(deepest.label)"]
        case .pitchGuide:
            let p = pitchGuide
            let songKey = AudioRoutingEngine.shared.songKey
            let key: String
            if p.songKeyDrive, let songKey, songKey.pitchClass != nil {
                key = "♪ \(songKey.root) \(PitchScale(songKey.scale).shortName)"
            } else {
                key = "\(p.keyName) \(p.scale.shortName)"
            }
            let speed = p.retuneSpeed < 1 ? "Instant" : "Speed \(Int(p.retuneSpeed)) ms"
            let third = p.transpose != 0 ? String(format: "%+d st", p.transpose)
                      : p.amount < 100 ? "Amount \(Int(p.amount))%"
                      : "± \(Int(p.tolerance))¢"
            return [key, speed, third]
        case .warmth:
            return warmth.drive == 0 ? ["Off"] : ["Drive \(Int(warmth.drive))%", warmth.character.displayName]
        case .air:
            return air.amount == 0 ? ["Off"] : ["Amount \(Int(air.amount))%", air.focus == .air ? "Air" : "Presence"]
        case .punch:
            let a = Int(punch.amount)
            return [a == 0 ? "Off" : a > 0 ? "Attack +\(a)" : "Sustain +\(-a)"]
        case .smartGate:
            return ["Sens \(Int(smartGate.sensitivity))%", "Depth \(Int(smartGate.depth)) dB"]
                + (smartGate.bleedDuck ? ["Singing only"] : [])
        case .tone:
            guard let instrument = tone.instrument else { return ["Pick instrument", "Does nothing"] }
            return ["\(instrument.icon) \(instrument.shortName)", "Amount \(Int(tone.amount))%"]
        case .piezoBody:
            let b = piezoBody
            if b.mute { return ["Muted", b.bodySize.displayName] }
            return ["Amount \(Int(b.amount))%",
                    b.bodySize.displayName,
                    b.phaseInvert ? "Phase Ø" : (b.level == 0 ? "Level 0 dB" : String(format: "Level %+.0f dB", b.level))]
        case .harmony:
            let h = harmony
            let voices = [h.voice1, h.voice2, h.voice3].filter(\.enabled).map(\.interval.shortLabel)
            let songKey = AudioRoutingEngine.shared.songKey
            let key = h.songKeyDrive && songKey?.pitchClass != nil
                ? "♪ \(songKey!.root) \(PitchScale(songKey!.scale).shortName)"
                : "\(PitchGuideParams.noteNames[h.key % 12]) \(h.scale.shortName)"
            return [voices.isEmpty ? "No voices" : voices.joined(separator: " "),
                    key,
                    h.leadGain == 0 ? "Lead off" : "Lead \(Int(h.leadLevel)) dB"]
        case .microDetune:
            let d = microDetune
            let bpm = AudioRoutingEngine.shared.songBPM
            let delays = d.tempoSync && bpm != nil
                ? "\(d.noteA.label) / \(d.noteB.label)"
                : "\(Int(d.delays(bpm: nil).a)) / \(Int(d.delays(bpm: nil).b)) ms"
            return ["+\(Int(d.pitchA)) / \(Int(d.pitchB))¢",
                    delays,
                    d.feedback > 0 ? "Mix \(Int(d.mix))% FB \(Int(d.feedback))" : "Mix \(Int(d.mix))%"]
        }
    }
}

extension PitchScale {
    var shortName: String {
        switch self {
        case .chromatic:       "Chrom"
        case .major:           "Maj"
        case .naturalMinor:    "Min"
        case .harmonicMinor:   "Harm Min"
        case .melodicMinor:    "Mel Min"
        case .dorian:          "Dorian"
        case .mixolydian:      "Mixo"
        case .majorPentatonic: "Maj Pent"
        case .minorPentatonic: "Min Pent"
        case .blues:           "Blues"
        case .phrygian:        "Phryg"
        case .lydian:          "Lydian"
        case .locrian:         "Locrian"
        }
    }
}

private extension Float {
    func rounded(toPlaces places: Int) -> Float {
        let m = powf(10, Float(places))
        return (self * m).rounded() / m
    }
}

// Horizontal bar centred at 0: orange extends left for cuts, green extends right for boosts
private struct GainStagingBar: View {
    let db: Float

    var body: some View {
        Canvas { context, size in
            let range: Double = 18
            let clamped = max(-range, min(range, Double(db)))
            let mid = size.width / 2
            let barW = abs(clamped) / range * mid
            let color = clamped < 0 ? Color.orange : Color.green
            let x = clamped < 0 ? mid - barW : mid
            context.fill(
                Path(CGRect(x: x, y: 0, width: max(1, barW), height: size.height)),
                with: .color(color.opacity(0.85))
            )
        }
    }
}

// Vertical bar that fills from the bottom; green < -18, yellow -18 to -6, red above -6
private struct LevelMeterBar: View {
    let db: Float

    var body: some View {
        GeometryReader { geo in
            let fill = max(0.0, min(1.0, Double(db + 60) / 60))
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                meterColor.frame(height: geo.size.height * fill)
            }
        }
        .background(Color.black.opacity(0.12))
    }

    private var meterColor: Color {
        if db > -6  { return .red }
        if db > -18 { return .yellow }
        return .green
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
                    case .levelRider:
                        LevelRiderEditor(params: $slot.levelRider,
                                         kernel: live(LevelRiderAudioUnit.self)?.kernel)
                    case .optoComp:   OptoCompEditor(params: $slot.optoComp)
                    case .fetComp:    FETCompEditor(params: $slot.fetComp)
                    case .feedbackNotch:
                        FeedbackNotchEditor(params: $slot.feedbackNotch,
                                            kernel: live(FeedbackNotchAudioUnit.self)?.kernel)
                    case .pitchGuide:
                        PitchGuideEditor(params: $slot.pitchGuide,
                                         kernel: live(PitchGuideAudioUnit.self)?.kernel)
                    case .microDetune:
                        MicroDetuneEditor(params: $slot.microDetune,
                                          kernel: live(MicroDetuneAudioUnit.self)?.kernel)
                    case .harmony:
                        HarmonyEditor(params: $slot.harmony,
                                      kernel: live(HarmonyAudioUnit.self)?.kernel)
                    case .piezoBody:
                        PiezoBodyEditor(params: $slot.piezoBody,
                                        kernel: live(PiezoBodyAudioUnit.self)?.kernel)
                    case .tone:
                        ToneEditor(params: $slot.tone, kernel: live(ToneAudioUnit.self)?.kernel)
                    case .warmth, .air, .punch, .smartGate:
                        OneKnobEditor(slot: $slot, kernel: live(OneKnobAudioUnit.self)?.kernel)
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
                        (liveUnit as? MicroDetuneAudioUnit)?.kernel
                            .applyParams(original.microDetune, bpm: AudioRoutingEngine.shared.songBPM)
                        (liveUnit as? PiezoBodyAudioUnit)?.kernel.applyParams(original.piezoBody)
                        (liveUnit as? ToneAudioUnit)?.kernel
                            .applyParams(instrument: original.tone.instrument, amount: original.tone.amount)
                        if let k = (liveUnit as? OneKnobAudioUnit)?.kernel {
                            OneKnobEditor.apply(original, to: k)
                        }
                        (liveUnit as? HarmonyAudioUnit)?.kernel
                            .applyParams(original.harmony.resolved(songKey: AudioRoutingEngine.shared.songKey))
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
    let kernel: LevelRiderKernel?

    var body: some View {
        if let kernel {
            LearnVoiceSection(
                readLevel: { Float(bitPattern: kernel.levelDBBits.load(ordering: .relaxed)) },
                describe: { levels in
                    let s = Self.settings(for: levels)
                    return "Apply sets Target \(Int(s.target)) dBFS, Max Boost +\(Int(s.maxBoost)) dB, Max Cut \(Int(s.maxCut)) dB and Gate \(Int(s.gate)) dBFS. Tap Done to keep them."
                },
                apply: { levels in
                    let s = Self.settings(for: levels)
                    params.targetLevel = s.target
                    params.maxBoost = s.maxBoost
                    params.maxCut = s.maxCut
                    params.gateThreshold = s.gate
                }
            )
        }
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

extension LevelRiderEditor {
    /// Aim between the softest and loudest lines; allow just enough boost and cut to reach them
    static func settings(for levels: VoiceLevels) -> (target: Float, maxBoost: Float, maxCut: Float, gate: Float) {
        let target = min(-6, max(-30, ((levels.softest + levels.loudest) / 2).rounded()))
        return (target,
                min(9, max(0, (target - levels.softest).rounded())),
                min(0, max(-18, (target - levels.loudest).rounded())),
                min(-20, max(-60, levels.gate.rounded())))
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
                Text("Tap Done (and turn Audio on if it’s off), then reopen this slot to ring out.")
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
                Text("Tap Done (and turn Audio on if it’s off), then reopen this slot to see what it hears.")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Live")
        } footer: {
            Text("Mono: corrects the first input of the channel. Put it before reverb and delay.")
        }

        if let kernel {
            LearnVoiceSection(
                readLevel: { Float(bitPattern: kernel.inputLevelBits.load(ordering: .relaxed)) },
                describe: { levels in
                    "Apply sets Gate to \(Int(min(-20, max(-70, levels.gate.rounded())))) dBFS."
                },
                apply: { levels in
                    params.gateThreshold = min(-20, max(-70, levels.gate.rounded()))
                }
            )
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
                 ? "The voice is corrected in the key of the song loaded in Perform. Transpose is separate and isn't changed by the song. The fallback is used when the song has no key set."
                 : "The key the singer sings in. Only notes in this key and scale are targets.")
        }

        Section {
            Stepper(value: $params.transpose, in: -12...12) {
                LabeledContent("Transpose") {
                    Text(params.transpose == 0 ? "Off" : String(format: "%+d st", params.transpose))
                        .monospacedDigit()
                }
            }
            LabeledContent("Wet Mix: \(Int(params.wetMix))%") {
                Slider(value: $params.wetMix, in: 0.0...100.0, step: 1)
            }
        } header: {
            Text("Transpose")
        } footer: {
            Text("Shifts the voice by whole semitones in the same pass as the tuning, so it adds no extra latency. Wet Mix controls how much processed signal is heard vs. the original — 100% is fully processed, lower values blend in the dry mic.")
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
                Slider(value: $params.retuneSpeed, in: 0.0...400.0, step: 1)
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
            Text("Retune Speed: how long the glide takes to land on the note, on the same scale as Auto-Tune's knob (Auto-Tune 15 ≈ 15 ms). 0 is the robotic effect, 10–25 tight pop, 50–150 natural. Tolerance: notes within this many cents are left alone; past it, correction kicks in. Amount: how far toward the note it pulls. Humanize: loosens the retune on long held notes.")
        }

        Section {
            LabeledContent("Pickiness: \(Int(params.pickiness))%") {
                Slider(value: $params.pickiness, in: 0.0...100.0, step: 1)
            }
            LabeledContent("Gate: \(Int(params.gateThreshold)) dBFS") {
                Slider(value: $params.gateThreshold, in: -70.0...(-20.0), step: 1)
            }
            Toggle("Shift Only While Singing", isOn: $params.shiftOnlyWhileSinging)
            // Left from before Bleed Duck moved to Smart Gate, on a chain with no free slot
            if params.bleedDuck != 0 {
                LabeledContent("Bleed Duck: \(Int(params.bleedDuck)) dB") {
                    Slider(value: $params.bleedDuck, in: -20.0...0.0, step: 1)
                }
            }
        } header: {
            Text("Bleed")
        } footer: {
            Text("Higher Pickiness only corrects clear, steady sung notes. Raise the Gate until bleed stops showing up in the Live meter. Between phrases (after a 0.3 s hold), Shift Only While Singing lets bleed through without Transpose or Formant. Bleed under the singing itself can't be separated." + (params.bleedDuck != 0 ? " Bleed Duck has moved to Smart Gate: set this to 0, then add a Smart Gate set to open for Singing." : " To turn the mic down between phrases, add a Smart Gate set to open for Singing."))
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
        return "Correcting in \(key.root) \(key.scale.rawValue)"
    }
}

private struct MicroDetuneEditor: View {
    @Binding var params: MicroDetuneParams
    let kernel: MicroDetuneKernel?

    private var songBPM: Int? { AudioRoutingEngine.shared.songBPM }

    var body: some View {
        Section {
            Menu {
                ForEach(MicroDetuneParams.stock) { stock in
                    Button(stock.name) { params = stock.params }
                }
            } label: {
                LabeledContent("Stock Settings") {
                    Text(stockName ?? "Custom").foregroundStyle(.secondary)
                }
            }
        } footer: {
            Text("Classic Micro Pitch is the H3000-style widener: A +9 cents, B −9 cents, B slightly late.")
        }

        Section {
            LabeledContent("Pitch A: +\(Int(params.pitchA))¢") {
                Slider(value: $params.pitchA, in: 0.0...50.0, step: 1)
            }
            LabeledContent("Pitch B: \(params.pitchB == 0 ? "0" : "−\(Int(-params.pitchB))")¢") {
                Slider(value: $params.pitchB, in: -50.0...0.0, step: 1)
            }
            LabeledContent("Pitch Mix: \(pitchMixLabel)") {
                Slider(value: $params.pitchMix, in: 0.0...100.0, step: 1)
            }
        } header: {
            Text("Voices")
        } footer: {
            Text("Voice A is shifted up and plays on the left; voice B is shifted down and plays on the right. Pitch Mix balances them (on a mono output they sum 50/50).")
        }

        Section {
            Toggle("Tempo Sync", isOn: $params.tempoSync)
            if params.tempoSync {
                Picker("Delay A", selection: $params.noteA) {
                    ForEach(NoteDivision.allCases) { Text($0.label).tag($0) }
                }
                Picker("Delay B", selection: $params.noteB) {
                    ForEach(NoteDivision.allCases) { Text($0.label).tag($0) }
                }
                let ms = params.delays(bpm: songBPM)
                LabeledContent("Now") {
                    Text(songBPM.map { "\($0) BPM: \(Int(ms.a)) / \(Int(ms.b)) ms + ~25" }
                         ?? "No song tempo — using \(Int(params.delayA)) / \(Int(params.delayB)) ms + ~25")
                        .foregroundStyle(.secondary)
                }
            } else {
                LabeledContent("Delay A: \(Int(params.delayA)) ms + ~25 shifter") {
                    Slider(value: Self.delayScale($params.delayA), in: 0...1)
                }
                LabeledContent("Delay B: \(Int(params.delayB)) ms + ~25 shifter") {
                    Slider(value: Self.delayScale($params.delayB), in: 0...1)
                }
            }
            LabeledContent("Feedback: \(Int(params.feedback))%") {
                Slider(value: $params.feedback, in: 0.0...95.0, step: 1)
            }
        } header: {
            Text("Delay")
        } footer: {
            Text("The shifted voices always arrive about 25 ms (0–50 ms, sweeping) later than the Delay setting: the pitch shifter reads from a short stretch of recent audio. The dry voice has no added delay. A few ms to ~30 ms thickens and widens; 80 ms and up is a pitched slapback. Feedback sends each voice back through its own shifter, so every repeat climbs (A) or falls (B) further. Tempo Sync follows the song loaded in Perform.")
        }

        Section {
            LabeledContent("Tone: \(toneLabel)") {
                Slider(value: $params.tone, in: -100.0...100.0, step: 1)
            }
            LabeledContent("Low Cut: \(params.lowCut <= 20 ? "Off" : "\(Int(params.lowCut)) Hz")") {
                Slider(value: $params.lowCut, in: 20.0...600.0, step: 5)
            }
            LabeledContent("Mod Depth: \(Int(params.modDepth))%") {
                Slider(value: $params.modDepth, in: 0.0...100.0, step: 1)
            }
            LabeledContent("Mod Rate: \(String(format: "%.1f", params.modRate)) Hz") {
                Slider(value: $params.modRate, in: 0.1...10.0, step: 0.1)
            }
        } header: {
            Text("Tone & Modulation")
        } footer: {
            Text("Tone tilts the voices darker (−) or brighter (+). Low Cut keeps the bass out of them so the low end stays centred. Mod adds chorus: at 100% each voice's shift swings from 0 to twice its setting.")
        }

        Section {
            LabeledContent("Mix: \(Int(params.mix))%") {
                Slider(value: $params.mix, in: 0.0...100.0, step: 1)
            }
        } footer: {
            Text("50% keeps the dry voice and the shifted voices both at full; above that the dry fades. Send the channel to a stereo output to hear the width. Put it after pitch correction.")
        }
        .onChange(of: params) { kernel?.applyParams(params, bpm: songBPM) }
    }

    private var stockName: String? {
        MicroDetuneParams.stock.first { $0.params == params }?.name
    }

    private var pitchMixLabel: String {
        switch params.pitchMix {
        case ..<1: "A only"
        case 99...: "B only"
        case 49.5..<50.5: "Even"
        default: params.pitchMix < 50 ? "A \(Int(100 - params.pitchMix))" : "B \(Int(params.pitchMix))"
        }
    }

    private var toneLabel: String {
        params.tone == 0 ? "Flat" : params.tone < 0 ? "Darker \(Int(-params.tone))" : "Brighter \(Int(params.tone))"
    }

    /// Fine control at short times: the slider runs 0…1, the delay is 2000 ms × position²
    private static func delayScale(_ ms: Binding<Float>) -> Binding<Double> {
        Binding(
            get: { (Double(ms.wrappedValue) / Double(MicroDetuneParams.maxDelayMs)).squareRoot() },
            set: { ms.wrappedValue = (Float($0 * $0) * MicroDetuneParams.maxDelayMs).rounded() }
        )
    }
}

private struct ToneEditor: View {
    @Binding var params: ToneParams
    let kernel: ToneKernel?

    var body: some View {
        Section {
            Picker("Instrument", selection: $params.instrument) {
                Text("None").tag(Optional<ToneInstrument>.none)
                ForEach(ToneInstrument.allCases) { Text("\($0.icon) \($0.displayName)").tag(Optional($0)) }
            }
            LabeledContent("Amount: \(Int(params.amount))%") {
                Slider(value: $params.amount, in: 0.0...100.0, step: 1)
            }
            if let kernel, let instrument = params.instrument {
                TimelineView(.animation(minimumInterval: 0.1)) { _ in
                    ToneMeter(kernel: kernel, profile: instrument.profile)
                }
            }
        } header: {
            Text("Tone")
        } footer: {
            Text(params.instrument.map { "\($0.toneDescription) It listens first: each move is applied only as far as the sound needs it (never more than the instrument's usual amount), and leveling and de-essing follow the playing level. Give it a few seconds of playing to settle. Amount scales it all; 0 is flat. Zero latency." }
                 ?? "Pick what's on this channel. Until then Tone passes the sound through untouched.")
        }
        .onChange(of: params) {
            kernel?.applyParams(instrument: params.instrument, amount: params.amount)
        }
    }
}

/// Warmth, Air, Punch and Smart Gate: one main knob each
private struct OneKnobEditor: View {
    @Binding var slot: ChannelFXSlot
    let kernel: OneKnobKernel?

    @MainActor static func apply(_ slot: ChannelFXSlot, to kernel: OneKnobKernel) {
        switch slot.type {
        case .warmth:    kernel.applyParams(slot.warmth)
        case .air:       kernel.applyParams(slot.air)
        case .punch:     kernel.applyParams(slot.punch)
        case .smartGate: kernel.applyParams(slot.smartGate)
        default:         break
        }
    }

    var body: some View {
        Group {
            switch slot.type {
            case .warmth: warmth
            case .air:    air
            case .punch:  punch
            default:      gate
            }
        }
        .onChange(of: slot) { if let kernel { Self.apply(slot, to: kernel) } }
    }

    private var warmth: some View {
        Section {
            LabeledContent("Drive: \(Int(slot.warmth.drive))%") {
                Slider(value: $slot.warmth.drive, in: 0.0...100.0, step: 1)
            }
            Picker("Character", selection: $slot.warmth.character) {
                ForEach(WarmthParams.Character.allCases) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)
        } header: {
            Text("Warmth")
        } footer: {
            Text("Saturation that thickens vocals, keys and bass: gentle and \"expensive\" at low Drive, gritty when pushed. Quiet parts pass unchanged; loud peaks get rounded. Tape also softens the very top; Tube adds even harmonics for a fuller, sweeter edge. Zero latency.")
        }
    }

    private var air: some View {
        Section {
            LabeledContent("Amount: \(Int(slot.air.amount))%") {
                Slider(value: $slot.air.amount, in: 0.0...100.0, step: 1)
            }
            Picker("Focus", selection: $slot.air.focus) {
                ForEach(AirParams.Focus.allCases) { Text($0.displayName).tag($0) }
            }
        } header: {
            Text("Air")
        } footer: {
            Text("A harmonic exciter: it makes new upper harmonics from what's already there, so a voice or guitar gets clearer and cuts through without the harshness of just turning up the treble. Presence works from 3 kHz up; Air from 6 kHz up for sparkle. Zero latency.")
        }
    }

    private var punch: some View {
        Section {
            LabeledContent(Self.punchLabel(slot.punch.amount)) {
                Slider(value: $slot.punch.amount, in: -100.0...100.0, step: 1)
            }
            if let kernel, slot.punch.amount != 0 {
                TimelineView(.animation(minimumInterval: 0.05)) { _ in
                    let db = Float(bitPattern: kernel.punchGainBits.load(ordering: .relaxed))
                    LabeledContent("Right now") {
                        Text(abs(db) < 0.3 ? "—" : String(format: "%+.1f dB", db))
                            .monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("Punch")
        } footer: {
            Text("Right: more attack — snappier drums, picking that jumps out. Left: softer attack and relatively more sustain — tames ringy toms, spiky strums and boomy hits. Centre is off. Steady sounds keep their level. Zero latency.")
        }
    }

    private var gate: some View {
        Section {
            LabeledContent("Sensitivity: \(Int(slot.smartGate.sensitivity))%") {
                Slider(value: $slot.smartGate.sensitivity, in: 0.0...100.0, step: 1)
            }
            LabeledContent("Depth: \(Int(slot.smartGate.depth)) dB") {
                Slider(value: $slot.smartGate.depth, in: 0.0...80.0, step: 1)
            }
            VStack(alignment: .leading, spacing: 6) {
                Picker("Opens For", selection: $slot.smartGate.bleedDuck) {
                    Text("Any Sound").tag(false)
                    Text("Singing").tag(true)
                }
                .pickerStyle(.segmented)
                Text(slot.smartGate.bleedDuck
                     ? "Stays shut for drums, cymbals and other loud bleed until someone sings. For vocal mics."
                     : "Opens for anything loud enough. For instruments, or a vocal mic in a quiet room.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let kernel {
                TimelineView(.animation(minimumInterval: 0.05)) { _ in
                    let open = kernel.gateOpenFlag.load(ordering: .relaxed)
                    let threshold = Float(bitPattern: kernel.gateThresholdBits.load(ordering: .relaxed))
                    let floor = Float(bitPattern: kernel.floorBits.load(ordering: .relaxed))
                    LabeledContent("Gate") {
                        Text(open ? "Open" : "Closed").foregroundStyle(open ? Color.green : Color.orange)
                    }
                    LabeledContent("Noise floor / opens at") {
                        Text(threshold < -110 ? "—" : String(format: "%.0f / %.0f dBFS", floor, threshold))
                            .monospacedDigit().foregroundStyle(.secondary)
                    }
                    if slot.smartGate.bleedDuck {
                        let singing = kernel.voiceFlag.load(ordering: .relaxed)
                        LabeledContent("Singing") {
                            Text(singing ? "Yes" : "—").foregroundStyle(singing ? Color.green : Color.secondary)
                        }
                    }
                }
            }
        } header: {
            Text("Smart Gate")
        } footer: {
            Text("Turns the channel down between notes to cut bleed and hiss, setting its own threshold: it learns the noise floor in the gaps and the level you play at, and opens between the two. Raise Sensitivity to gate more; lower it if quiet notes get cut. Depth is how far it turns down when closed. With Opens For set to Singing, a few dB of Depth is usually enough. Zero latency.")
        }
    }

    private static func punchLabel(_ amount: Float) -> String {
        let a = Int(amount)
        return a == 0 ? "Off" : a > 0 ? "More Attack: \(a)" : "More Sustain: \(-a)"
    }
}

/// What adaptive Tone is doing right now
private struct ToneMeter: View {
    let kernel: ToneKernel
    let profile: ToneProfile

    var body: some View {
        let confidence = Float(bitPattern: kernel.confidenceBits.load(ordering: .relaxed))
        let moves = [(profile.bands.0, Float(bitPattern: kernel.band0Bits.load(ordering: .relaxed))),
                     (profile.bands.1, Float(bitPattern: kernel.band1Bits.load(ordering: .relaxed))),
                     (profile.bands.2, Float(bitPattern: kernel.band2Bits.load(ordering: .relaxed))),
                     (profile.bands.3, Float(bitPattern: kernel.band3Bits.load(ordering: .relaxed)))]
        let gr = Float(bitPattern: kernel.gainReductionBits.load(ordering: .relaxed))
        let ess = Float(bitPattern: kernel.deEssBits.load(ordering: .relaxed))
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent("Status") {
                Text(confidence < 0.01 ? "Waiting for sound" : confidence < 1 ? "Listening… \(Int(confidence * 100))%" : "Adapting")
                    .foregroundStyle(confidence < 1 ? Color.orange : Color.green)
            }
            ForEach(Array(moves.enumerated()), id: \.offset) { _, move in
                if move.0.db != 0 {
                    let db = move.1
                    LabeledContent(Self.label(move.0)) {
                        Text(abs(db) < 0.1 ? "—" : String(format: "%+.1f dB", db))
                            .monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }
            LabeledContent("Leveling") {
                Text(gr < 0.5 ? "—" : String(format: "−%.0f dB", gr)).monospacedDigit().foregroundStyle(.secondary)
            }
            if profile.deEss {
                LabeledContent("De-essing") {
                    Text(ess < 0.5 ? "—" : String(format: "−%.0f dB", ess)).monospacedDigit().foregroundStyle(.secondary)
                }
            }
        }
    }

    private static func label(_ band: ToneProfile.Band) -> String {
        let f = band.freq >= 1_000 ? String(format: "%g kHz", band.freq / 1_000) : "\(Int(band.freq)) Hz"
        let what = band.kind == .highShelf ? "above" : band.kind == .lowShelf ? "below" : "at"
        return "\(band.db < 0 ? "Cut" : "Boost") \(what) \(f)"
    }
}

private struct PiezoBodyEditor: View {
    @Binding var params: PiezoBodyParams
    let kernel: PiezoBodyKernel?

    var body: some View {
        Section {
            LabeledContent("Amount: \(Int(params.amount))%") {
                Slider(value: $params.amount, in: 0.0...100.0, step: 1)
            }
            Picker("Body Size", selection: $params.bodySize) {
                ForEach(GuitarBodySize.allCases) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)
            if let kernel {
                TimelineView(.animation(minimumInterval: 0.1)) { _ in
                    LabeledContent("Smoothing") {
                        let gr = Float(bitPattern: kernel.gainReductionBits.load(ordering: .relaxed))
                        Text(gr < 0.5 ? "—" : String(format: "−%.0f dB", gr))
                            .monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("Piezo Body")
        } footer: {
            Text("For under-saddle (piezo) pickups. Amount puts back the body resonance a mic would hear, softens the nasal quack around 1.6 kHz and the brittle top, and evens out pick attack. Body Size moves the resonances to suit the guitar. Zero latency.")
        }

        Section {
            Toggle("Phase Invert", isOn: $params.phaseInvert)
            Toggle("Mute", isOn: $params.mute).tint(.orange)
            LabeledContent("Level: \(String(format: "%+.0f", params.level)) dB") {
                Slider(value: $params.level, in: -12.0...6.0, step: 0.5)
            }
        } header: {
            Text("Output")
        } footer: {
            Text("If the low end starts to boom or feed back on stage, try Phase Invert first. For feedback that rings at one pitch, put a Feedback Notch before this effect and ring it out at soundcheck.")
        }
        .onChange(of: params) { kernel?.applyParams(params) }
    }
}

private struct HarmonyEditor: View {
    @Binding var params: HarmonyParams
    let kernel: HarmonyKernel?

    var body: some View {
        Section {
            if let kernel {
                TimelineView(.animation(minimumInterval: 0.05)) { _ in
                    HarmonyMeter(kernel: kernel)
                }
            } else {
                Text("Tap Done (and turn Audio on if it’s off), then reopen this slot to see what it hears.")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Live")
        } footer: {
            Text("Harmonizes the first input of the channel. Put it after Pitch Guide, so the harmonies follow the corrected note, and before reverb and delay.")
        }

        if let kernel {
            LearnVoiceSection(
                readLevel: { Float(bitPattern: kernel.inputLevelBits.load(ordering: .relaxed)) },
                describe: { levels in
                    "Apply sets Gate to \(Int(min(-20, max(-70, levels.gate.rounded())))) dBFS."
                },
                apply: { levels in
                    params.gateThreshold = min(-20, max(-70, levels.gate.rounded()))
                }
            )
        }

        Section {
            Menu {
                ForEach(HarmonyParams.stock) { stock in
                    Button(stock.name) {
                        params.voice1 = stock.voice1
                        params.voice2 = stock.voice2
                        params.voice3 = stock.voice3
                    }
                }
            } label: {
                LabeledContent("Stock Voicings") {
                    Text(stockName ?? "Custom").foregroundStyle(.secondary)
                }
            }
        } footer: {
            Text("Sets the two voices. Key and detection stay as they are.")
        }

        voiceSection("Voice 1", voice: $params.voice1)
        voiceSection("Voice 2", voice: $params.voice2)
        voiceSection("Voice 3", voice: $params.voice3)

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
        } header: {
            Text("Key")
        } footer: {
            Text("Intervals are counted in the key's scale: a 3rd above is a major or minor 3rd, whichever is in the key. Pentatonic, blues and chromatic scales use the nearest interval that fits.")
        }

        Section {
            LabeledContent("Lead Level: \(params.leadGain == 0 ? "Off" : String(format: "%+.0f dB", params.leadLevel))") {
                Slider(value: $params.leadLevel, in: HarmonyParams.leadOff...6, step: 1)
            }
            LabeledContent("Humanize: \(Int(params.humanize))%") {
                Slider(value: $params.humanize, in: 0.0...100.0, step: 1)
            }
        } header: {
            Text("Blend")
        } footer: {
            Text("Gender (in each voice) moves the voice's resonances without moving its pitch: − sounds bigger and deeper (try −2 to −4 on an octave below), + smaller and brighter. Lead Level is the singer's own voice in this channel; all the way down is off, for harmonies only (e.g. on their own output). Humanize puts each voice a few cents off and a little late (up to 20–32 ms), drifting slowly, so they sound like singers rather than a copy.")
        }

        Section {
            Picker("Voice Range", selection: $params.voiceRange) {
                ForEach(VoiceRange.allCases) { Text($0.displayName).tag($0) }
            }
            LabeledContent("Pickiness: \(Int(params.pickiness))%") {
                Slider(value: $params.pickiness, in: 0.0...100.0, step: 1)
            }
            LabeledContent("Gate: \(Int(params.gateThreshold)) dBFS") {
                Slider(value: $params.gateThreshold, in: -70.0...(-20.0), step: 1)
            }
        } header: {
            Text("Detection")
        } footer: {
            Text("Harmonies only sing on clear, steady sung notes; they fade out on breaths, consonants and between phrases. Raise the Gate until bleed no longer shows up in the Live meter.")
        }
        .onChange(of: params) {
            kernel?.applyParams(params.resolved(songKey: AudioRoutingEngine.shared.songKey))
        }
    }

    @ViewBuilder
    private func voiceSection(_ title: String, voice: Binding<HarmonyVoice>) -> some View {
        Section {
            Toggle("Mute", isOn: Binding(get: { !voice.wrappedValue.enabled },
                                         set: { voice.wrappedValue.enabled = !$0 }))
                .tint(.orange)
            Picker("Interval", selection: voice.interval) {
                ForEach(HarmonyInterval.allCases) { Text($0.label).tag($0) }
            }
            LabeledContent("Level: \(String(format: "%+.0f", voice.wrappedValue.level)) dB") {
                Slider(value: voice.level, in: -24.0...6.0, step: 1)
            }
            LabeledContent("Pan: \(Self.panLabel(voice.wrappedValue.pan))") {
                Slider(value: voice.pan, in: -100.0...100.0, step: 5)
            }
            LabeledContent("Gender: \(Self.genderLabel(voice.wrappedValue.gender))") {
                Slider(value: voice.gender, in: -6.0...6.0, step: 0.5)
            }
        } header: {
            Text(voice.wrappedValue.enabled ? title : "\(title) — muted")
        }
    }

    private static func genderLabel(_ semis: Float) -> String {
        if semis == 0 { return "0" }
        return String(format: "%+.1f", semis) + (semis < 0 ? " deeper" : " brighter")
    }

    private static func panLabel(_ pan: Float) -> String {
        abs(pan) < 1 ? "C" : "\(pan < 0 ? "L" : "R")\(Int(abs(pan)))"
    }

    private var stockName: String? {
        HarmonyParams.stock.first {
            $0.voice1 == params.voice1 && $0.voice2 == params.voice2 && $0.voice3 == params.voice3
        }?.name
    }

    private var songKeyLabel: String {
        guard let key = AudioRoutingEngine.shared.songKey, key.pitchClass != nil else {
            return "No song key — using fallback"
        }
        return "Harmonizing in \(key.root) \(key.scale.rawValue)"
    }
}

/// What the harmonizer hears and the notes its voices are singing
private struct HarmonyMeter: View {
    let kernel: HarmonyKernel

    var body: some View {
        let detected = Float(bitPattern: kernel.detectedMidiBits.load(ordering: .relaxed))
        let v1 = Float(bitPattern: kernel.voiceMidi0.load(ordering: .relaxed))
        let v2 = Float(bitPattern: kernel.voiceMidi1.load(ordering: .relaxed))
        let v3 = Float(bitPattern: kernel.voiceMidi2.load(ordering: .relaxed))
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent("Hearing") {
                Text(detected < 0 ? "—" : PitchMeter.describe(detected))
                    .monospacedDigit()
                    .foregroundStyle(detected < 0 ? .secondary : .primary)
            }
            LabeledContent("Voice 1") { voiceText(v1) }
            LabeledContent("Voice 2") { voiceText(v2) }
            LabeledContent("Voice 3") { voiceText(v3) }
            LabeledContent("Harmony Latency") {
                Text(String(format: "%.1f ms", Float(bitPattern: kernel.latencyMsBits.load(ordering: .relaxed))))
                    .monospacedDigit().foregroundStyle(.secondary)
            }
        }
    }

    private func voiceText(_ midi: Float) -> some View {
        Text(midi < 0 ? "—" : PitchMeter.noteName(Int(midi)))
            .monospacedDigit()
            .foregroundStyle(midi < 0 ? Color.secondary : Color.green)
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
            LabeledContent("Singing") {
                let singing = kernel.singingFlag.load(ordering: .relaxed)
                Text(singing ? "Yes" : "No")
                    .foregroundStyle(singing ? Color.green : Color.secondary)
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
                        get: { prefs.metronomeOutput },
                        set: { prefs.metronomeOutput = $0; metronome.applyOutput() }
                    )) {
                        Section("Stereo") {
                            ForEach(store.outputRoutes.filter(\.stereo), id: \.self) { Text($0.label).tag($0) }
                        }
                        Section("Mono") {
                            ForEach(store.outputRoutes.filter { !$0.stereo }, id: \.self) { Text($0.label).tag($0) }
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
                Section {
                    TextField("e.g. Keys L, Vox, Guitar", text: $name)
                } header: {
                    Text("Channel Name")
                } footer: {
                    let unique = store.uniqueName(name, excluding: nil)
                    if unique != name.trimmingCharacters(in: .whitespaces) {
                        Text("That name is taken — it will be added as \"\(unique)\". Names must be unique because macros use them as OSC addresses.")
                            .foregroundStyle(.orange)
                    }
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
                        engine.syncChannel(ch.id)
                        dismiss()
                    }
                    .disabled(store.availableInputs.isEmpty)
                }
            }
        }
    }
}
