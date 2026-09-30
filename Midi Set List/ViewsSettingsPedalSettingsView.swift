//
//  PedalSettingsView.swift
//  Midi Set List
//
//  Settings for Bluetooth page-turner pedals: turn them on, test what each pedal
//  sends, and learn which key does what on the Perform screen.
//

import SwiftUI

struct PedalSettingsView: View {
    @ObservedObject private var pedals = PedalSettings.shared
    @State private var lastKey: PedalKey?

    var body: some View {
        List {
            Section {
                Toggle("Use Page-Turner Pedals", isOn: $pedals.isEnabled)
            } footer: {
                Text("Pair the pedal in the iPad or iPhone Bluetooth settings first. Page turners connect as a keyboard and usually send arrow or Page Up / Page Down keys — those already work. Use Learn below for anything else.")
            }

            Section("Test") {
                HStack(spacing: 12) {
                    Image(systemName: "shoe.2")
                        .foregroundStyle(lastKey == nil ? Color.secondary : Color.accentColor)
                        .symbolEffect(.bounce, value: lastKey)
                    if let lastKey {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(lastKey.name).font(.body.weight(.semibold))
                            Text(pedals.bindings[lastKey].map { "→ \($0.title)" } ?? "Not assigned — tap Learn on an action")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text("Press a pedal to see what it sends")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }

            Section {
                ForEach(PedalAction.allCases) { action in
                    actionRow(action)
                }
            } header: {
                Text("On the Perform Screen")
            } footer: {
                Text("Tap Learn, then press the pedal. Each key does one thing, so learning a key moves it off any other action. Page up / down and auto-scroll also work in full-screen lyrics.")
            }

            Section {
                Button("Reset to Defaults") {
                    pedals.resetToDefaults()
                }
            } footer: {
                Text("Defaults: ↓, Page Down and → scroll down a page; ↑, Page Up and ← scroll up.")
            }
        }
        .navigationTitle("Page-Turner Pedals")
        .navigationBarTitleDisplayMode(.inline)
        .background(PedalKeyCatcher(onKey: handle).frame(width: 0, height: 0))
        .onDisappear { pedals.learning = nil }
    }

    private func actionRow(_ action: PedalAction) -> some View {
        let keys = pedals.keys(for: action)
        let isLearning = pedals.learning == action
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(action.title, systemImage: action.systemImage)
                Spacer()
                Button(isLearning ? "Press a pedal…" : "Learn") {
                    pedals.learning = isLearning ? nil : action
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(isLearning ? .orange : .accentColor)
            }
            if !keys.isEmpty {
                // Assigned keys; tap one to remove it
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(keys, id: \.self) { key in
                            Button {
                                pedals.remove(key)
                            } label: {
                                HStack(spacing: 4) {
                                    Text(key.name)
                                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                                }
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color(.tertiarySystemFill), in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove \(key.name)")
                        }
                    }
                }
                .padding(.leading, 36)
            }
        }
        .padding(.vertical, 2)
    }

    private func handle(_ key: PedalKey) -> Bool {
        lastKey = key
        if let action = pedals.learning {
            pedals.assign(key, to: action)
            pedals.learning = nil
            return true
        }
        // Show the key either way, but let unassigned keys through (e.g. keyboard navigation)
        return pedals.bindings[key] != nil
    }
}

#Preview {
    NavigationStack { PedalSettingsView() }
}
