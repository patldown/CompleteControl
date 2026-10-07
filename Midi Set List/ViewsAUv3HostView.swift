//
//  AUv3HostView.swift
//  Midi Set List
//
//  UI for the audio FX rack: engine start/stop, channel routing, four effect slots,
//  plugin browser, and each plugin's native AUViewController.
//

import AVFoundation
import CoreAudioKit
import SwiftUI

// MARK: - Main rack view

struct AUv3HostView: View {
    private let host = AUv3Host.shared

    @State private var browserTarget: SlotRef?
    @State private var uiTarget: SlotRef?
    @State private var loadingSlot: Int?
    @State private var errorBanner: String?

    var body: some View {
        List {
            engineSection
            routingSection
            slotsSection
        }
        .navigationTitle("Audio FX Rack")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $browserTarget) { ref in
            AUv3PluginBrowserView { component in
                browserTarget = nil
                install(component, into: ref.id)
            }
        }
        .sheet(item: $uiTarget) { ref in
            if let au = host.slots[ref.id].audioUnit {
                AUv3PluginUISheet(audioUnit: au, title: host.slots[ref.id].name)
            }
        }
        .overlay(alignment: .bottom) {
            if let msg = errorBanner {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(Color.red.opacity(0.88), in: Capsule())
                    .padding()
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .onTapGesture { errorBanner = nil }
            }
        }
        .animation(.default, value: errorBanner != nil)
    }

    // MARK: Engine section

    private var engineSection: some View {
        Section {
            HStack {
                Label(
                    host.isRunning ? "Running" : "Stopped",
                    systemImage: host.isRunning ? "waveform" : "waveform.slash"
                )
                .foregroundStyle(host.isRunning ? .green : .secondary)
                Spacer()
                if host.isRunning {
                    Button("Stop", role: .destructive) { host.stop() }
                } else {
                    Button("Start") { Task { await startEngine() } }
                }
            }
            if let err = host.lastError {
                Label(err, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("Engine")
        } footer: {
            Text("Requires a wired audio interface. Audio from the chosen input runs through the effect chain and is sent to the chosen output. Routing changes take effect on the next start.")
        }
    }

    // MARK: Routing section

    @ViewBuilder
    private var routingSection: some View {
        let inputPairs  = AUv3Host.inputBusPairCount
        let outputPairs = AUv3Host.outputBusPairCount

        if inputPairs > 1 || outputPairs > 1 {
            Section("Routing") {
                if inputPairs > 1 {
                    Picker("Input", selection: Binding(
                        get: { host.inputBus },
                        set: { host.inputBus = $0 }
                    )) {
                        ForEach(0..<inputPairs, id: \.self) { bus in
                            Text("Ch \(bus * 2 + 1)-\(bus * 2 + 2)").tag(bus)
                        }
                    }
                    .disabled(host.isRunning)
                }
                if outputPairs > 1 {
                    Picker("Output", selection: Binding(
                        get: { host.outputBus },
                        set: { host.outputBus = $0 }
                    )) {
                        ForEach(0..<outputPairs, id: \.self) { bus in
                            Text("Ch \(bus * 2 + 1)-\(bus * 2 + 2)").tag(bus)
                        }
                    }
                    .disabled(host.isRunning)
                }
            }
        }
    }

    // MARK: Slots section

    private var slotsSection: some View {
        Section {
            ForEach(Array(host.slots.enumerated()), id: \.offset) { index, slot in
                slotRow(index: index, slot: slot)
            }
        } header: {
            Text("Effects — \(host.slots.filter(\.isLoaded).count) of 4 loaded")
        } footer: {
            Text("Tap + to browse installed AUv3 effects. Slots run in order top to bottom.")
        }
    }

    @ViewBuilder
    private func slotRow(index: Int, slot: AUv3Slot) -> some View {
        HStack(spacing: 12) {
            Text("\(index + 1)")
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 16)

            if slot.isLoaded {
                VStack(alignment: .leading, spacing: 2) {
                    Text(slot.name)
                    if !slot.manufacturer.isEmpty {
                        Text(slot.manufacturer).font(.caption).foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 8)

                // Bypass
                Button {
                    host.setBypass(!slot.isBypassed, forSlot: index)
                } label: {
                    Image(systemName: slot.isBypassed ? "power.circle" : "power.circle.fill")
                        .imageScale(.large)
                        .foregroundStyle(slot.isBypassed ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.accentColor))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(slot.isBypassed ? "Enable" : "Bypass")

                // Open plugin UI
                Button {
                    uiTarget = SlotRef(id: index)
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .imageScale(.large)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open plugin settings")

                // Remove
                Button(role: .destructive) {
                    host.removePlugin(fromSlot: index)
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .imageScale(.large)
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove plugin")

            } else if loadingSlot == index {
                ProgressView()
                Text("Loading…").foregroundStyle(.secondary)
                Spacer()
            } else {
                Text("Empty").foregroundStyle(.tertiary)
                Spacer()
                Button {
                    browserTarget = SlotRef(id: index)
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .imageScale(.large)
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add plugin to slot \(index + 1)")
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: Actions

    private func startEngine() async {
        do { try await host.start() }
        catch { errorBanner = error.localizedDescription }
    }

    private func install(_ component: AVAudioUnitComponent, into index: Int) {
        loadingSlot = index
        Task {
            do { try await host.loadPlugin(component, intoSlot: index) }
            catch { errorBanner = error.localizedDescription }
            loadingSlot = nil
        }
    }
}

// Small Identifiable wrapper so sheet(item:) works with plain Int indices
private struct SlotRef: Identifiable { let id: Int }

// MARK: - Plugin browser

struct AUv3PluginBrowserView: View {
    var onSelect: (AVAudioUnitComponent) -> Void
    @State private var search = ""
    @Environment(\.dismiss) private var dismiss

    private var effects: [AVAudioUnitComponent] {
        let all = AUv3Host.availableEffects()
        guard !search.isEmpty else { return all }
        return all.filter {
            $0.name.localizedCaseInsensitiveContains(search) ||
            $0.manufacturerName.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if effects.isEmpty {
                    if search.isEmpty {
                        ContentUnavailableView(
                            "No AUv3 Effects Found",
                            systemImage: "puzzlepiece.extension",
                            description: Text("Install apps that include AUv3 audio effects — they'll appear here.")
                        )
                    } else {
                        ContentUnavailableView.search(text: search)
                    }
                } else {
                    List(effects, id: \.componentID) { component in
                        Button {
                            onSelect(component)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(component.name).foregroundStyle(.primary)
                                Text(component.manufacturerName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .searchable(text: $search, prompt: "Search")
                }
            }
            .navigationTitle("Choose Effect")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Plugin native UI sheet

struct AUv3PluginUISheet: View {
    let audioUnit: AVAudioUnit
    let title: String
    @State private var pluginVC: UIViewController?
    @State private var noUI = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if noUI {
                    ContentUnavailableView(
                        "No Plugin UI",
                        systemImage: "slider.horizontal.below.square.and.square.filled",
                        description: Text("This plugin doesn't provide a custom interface.")
                    )
                } else if let vc = pluginVC {
                    AUViewControllerRepresentable(viewController: vc)
                        .ignoresSafeArea()
                } else {
                    ProgressView("Loading…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task {
            let vc = await withCheckedContinuation { (continuation: CheckedContinuation<UIViewController?, Never>) in
                audioUnit.auAudioUnit.requestViewController { vc in
                    continuation.resume(returning: vc)
                }
            }
            if let vc { pluginVC = vc } else { noUI = true }
        }
    }
}

private struct AUViewControllerRepresentable: UIViewControllerRepresentable {
    let viewController: UIViewController
    func makeUIViewController(context: Context) -> UIViewController { viewController }
    func updateUIViewController(_ vc: UIViewController, context: Context) {}
}
