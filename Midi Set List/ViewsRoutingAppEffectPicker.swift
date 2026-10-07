//
//  AppEffectPicker.swift
//  Midi Set List
//
//  "Pick App Effect…" for OSC macro and command editors: choose a routing channel, one
//  of its effects and a parameter, set a value, and it fills in the /app/ address and
//  float value. See ModelsAppOSC.swift and docs/app-osc-reference.md.
//

import SwiftUI

/// Drop into any OSC editor next to the address field
struct AppEffectPickerButton: View {
    @Binding var address: String
    @Binding var value: Double
    @State private var showing = false

    var body: some View {
        Button {
            showing = true
        } label: {
            Label("Pick App Effect…", systemImage: "slider.horizontal.3")
        }
        .sheet(isPresented: $showing) {
            AppEffectPickerSheet { pickedAddress, pickedValue in
                address = pickedAddress
                value = pickedValue
            }
        }
    }
}

private struct AppEffectPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onPick: (String, Double) -> Void

    private let store = AudioRoutingStore.shared
    @State private var channelID: UUID?
    @State private var fxSegment: String?      // nil = channel-level (volume / mute)
    @State private var paramKey: String?
    @State private var value: Double = 0

    private var channelIndex: Int? { store.channels.firstIndex { $0.id == channelID } }
    private var channel: AudioChannel? { channelIndex.map { store.channels[$0] } }
    private var effects: [AppFXInstance] {
        channel.map(AppOSC.fxSegments(for:)) ?? []
    }
    private var effect: AppFXInstance? {
        effects.first { $0.segment == fxSegment }
    }

    /// Parameters on offer for the current selection, including the shared ones
    private var params: [AppFXParam] {
        guard let effect else {
            return [
                AppFXParam(key: "volume", name: "Channel Volume", range: 0...1, unit: "", kind: .number,
                           detail: "", get: { _ in 0 }, set: { _, _ in }),
                AppFXParam(key: "mute", name: "Channel Mute", range: 0...1, unit: "", kind: .toggle,
                           detail: "", get: { _ in 0 }, set: { _, _ in }),
            ]
        }
        let bypass = AppFXParam(key: "bypass", name: "Bypass", range: 0...1, unit: "", kind: .toggle,
                                detail: "", get: { $0.isBypassed ? 1 : 0 }, set: { $0.isBypassed = $1 >= 0.5 })
        return [bypass] + effect.type.oscParams
    }
    private var param: AppFXParam? { params.first { $0.key == paramKey } }

    private var resultAddress: String? {
        guard let channel, let channelIndex, let param else { return nil }
        let ch = AppOSC.channelSegment(channel, index: channelIndex)
        guard let effect else { return "\(AppOSC.prefix)\(ch)/\(param.key)" }
        return "\(AppOSC.prefix)\(ch)/\(effect.segment)/\(param.key)"
    }

    var body: some View {
        NavigationStack {
            Form {
                if store.channels.isEmpty {
                    Text("Add a channel in the Routing tab first.").foregroundStyle(.secondary)
                } else {
                    Section("Channel") {
                        Picker("Channel", selection: $channelID) {
                            Text("Choose…").tag(UUID?.none)
                            ForEach(Array(store.channels.enumerated()), id: \.element.id) { i, ch in
                                Text(AppOSC.channelSegment(ch, index: i)).tag(Optional(ch.id))
                            }
                        }
                    }
                    if channel != nil {
                        Section("Effect") {
                            Picker("Effect", selection: $fxSegment) {
                                Text("Channel (volume, mute)").tag(String?.none)
                                ForEach(effects, id: \.segment) { fx in
                                    Text("Slot \(fx.slotIndex + 1): \(fx.type.displayName)").tag(Optional(fx.segment))
                                }
                            }
                        }
                        Section("Parameter") {
                            Picker("Parameter", selection: $paramKey) {
                                Text("Choose…").tag(String?.none)
                                ForEach(params) { p in Text(p.name).tag(Optional(p.key)) }
                            }
                        }
                    }
                    if let param {
                        Section {
                            valueEditor(for: param)
                        } header: {
                            Text("Value")
                        } footer: {
                            Text([param.rangeDescription, param.detail].filter { !$0.isEmpty }.joined(separator: ". "))
                        }
                    }
                    if let resultAddress {
                        Section("Will Send") {
                            Text("\(resultAddress)  \(String(format: "%g", value))")
                                .font(.callout.monospaced())
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            .navigationTitle("App Effect")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", role: .cancel) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use") {
                        if let resultAddress { onPick(resultAddress, value) }
                        dismiss()
                    }
                    .disabled(resultAddress == nil)
                }
            }
            .onChange(of: channelID) { fxSegment = nil; paramKey = nil }
            .onChange(of: fxSegment) { paramKey = nil }
            .onChange(of: paramKey) {
                // Start from the effect's current setting, so "Use" changes nothing by surprise
                guard let param else { return }
                if let effect, let channel {
                    value = param.get(channel.slots[effect.slotIndex])
                } else if let channel {
                    value = param.key == "mute" ? (channel.isMuted ? 1 : 0) : Double(channel.volume)
                }
            }
        }
    }

    @ViewBuilder
    private func valueEditor(for param: AppFXParam) -> some View {
        switch param.kind {
        case .toggle:
            Toggle(param.name, isOn: Binding(get: { value >= 0.5 }, set: { value = $0 ? 1 : 0 }))
        case .choice(let options):
            Picker(param.name, selection: Binding(get: { Int(value) }, set: { value = Double($0) })) {
                ForEach(Array(options.enumerated()), id: \.offset) { i, name in Text(name).tag(i) }
            }
        case .action:
            Text("Triggers when sent; the value is ignored.").foregroundStyle(.secondary)
        case .number:
            LabeledContent("\(String(format: "%g", value)) \(param.unit)") {
                if param.isWholeNumber {
                    Slider(value: $value, in: param.range, step: 1)
                } else {
                    Slider(value: $value, in: param.range)
                }
            }
            .onChange(of: value) { value = param.normalized(value) }
        }
    }
}
