//
//  SettingsView.swift
//  Midi Set List
//

import SwiftUI

struct SettingsView: View {
    @ObservedObject private var ai = AISettings.shared

    var body: some View {
        NavigationStack {
            List {
                offlineModeSection
                apiKeysSection
                taskRoutingSection
                activeProvidersSection
            }
            .animation(.default, value: ai.offlineMode)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.large)
        }
    }

    // MARK: - Offline Mode

    private var offlineModeSection: some View {
        Section {
            if ai.offlineMode {
                OfflineModeBanner()
                    .listRowInsets(EdgeInsets())
            }
            Toggle(isOn: $ai.offlineMode) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Offline Mode").font(.body.weight(.semibold))
                        Text("Force on-device AI for every task")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "airplane")
                        .foregroundStyle(ai.offlineMode ? Color.offlineMode : .secondary)
                }
            }
            .tint(.offlineMode)
        } footer: {
            Text("When on, every AI feature uses the on-device model — whatever provider or model is picked below. No requests are sent to Claude or ChatGPT. Your routing choices come back when you turn it off.")
        }
    }

    // MARK: - API Keys

    private var apiKeysSection: some View {
        Section {
            APIKeyRow(
                label: "ChatGPT (OpenAI)",
                icon: "brain",
                iconColor: .green,
                hasKey: ai.hasOpenAIKey,
                onSave: { key in ai.openAIKey = key },
                onClear: { ai.openAIKey = nil }
            )
            APIKeyRow(
                label: "Claude (Anthropic)",
                icon: "sparkles",
                iconColor: .orange,
                hasKey: ai.hasAnthropicKey,
                onSave: { key in ai.anthropicKey = key },
                onClear: { ai.anthropicKey = nil }
            )
            APIKeyRow(
                label: "Anthropic Workspace ID",
                icon: "building.2",
                iconColor: .orange,
                hasKey: ai.hasAnthropicWorkspaceID,
                placeholder: "Paste Workspace ID…",
                onSave: { id in ai.anthropicWorkspaceID = id },
                onClear: { ai.anthropicWorkspaceID = nil }
            )
        } header: {
            Text("API Keys")
        } footer: {
            Text("Keys are stored securely in the iOS Keychain and never leave your device except in direct API calls.")
        }
        .id(ai.keyVersion)   // re-render when keys change
    }

    // MARK: - Task Routing

    private var taskRoutingSection: some View {
        Section {
            ForEach(AITask.allCases, id: \.rawValue) { task in
                TaskRoutingRow(task: task)
            }
        } header: {
            Text("Task Routing")
        } footer: {
            if ai.offlineMode {
                Label("Overridden by Offline Mode — all tasks use On-Device.", systemImage: "airplane")
                    .foregroundStyle(Color.offlineMode)
            } else {
                Text("Choose which AI handles each task. External providers give higher quality but require a network connection and incur API costs.")
            }
        }
        .disabled(ai.offlineMode)
        .opacity(ai.offlineMode ? 0.5 : 1)
        .task(id: ai.offlineMode) { await ai.fetchAnthropicModels() }
    }

    // MARK: - Active providers summary

    private var activeProvidersSection: some View {
        Section("Active") {
            ForEach(AITask.allCases, id: \.rawValue) { task in
                let resolved = ai.provider(for: task)
                let configured = ai.routing[task, default: .onDevice]
                let mismatch = !ai.offlineMode && configured != .onDevice && resolved == .onDevice
                HStack(spacing: 10) {
                    Image(systemName: resolved.icon)
                        .foregroundStyle(ai.offlineMode ? Color.offlineMode : mismatch ? .orange : .secondary)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(task.displayName)
                            .font(.subheadline)
                        Text(resolved.displayName)
                            .font(.caption)
                            .foregroundStyle(mismatch ? .orange : .secondary)
                        if mismatch {
                            Text("Add a \(configured.displayName) key above to activate")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                    }
                    if ai.offlineMode {
                        Spacer()
                        OfflineModeBadge()
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }
}

// MARK: - Task routing row

private struct TaskRoutingRow: View {
    let task: AITask
    @ObservedObject private var ai = AISettings.shared

    private var selectedProvider: AIProviderType { ai.routing[task, default: .onDevice] }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(task.displayName).font(.subheadline)
                Spacer()
                Picker("", selection: Binding(
                    get: { selectedProvider },
                    set: { ai.setProvider($0, for: task) }
                )) {
                    ForEach(AIProviderType.allCases) { provider in
                        Label(provider.displayName, systemImage: provider.icon).tag(provider)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }

            if selectedProvider == .anthropic {
                HStack {
                    Text("Model").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Picker("", selection: Binding(
                        get: { ai.anthropicModel(for: task) },
                        set: { ai.setAnthropicModel($0, for: task) }
                    )) {
                        ForEach(ai.availableAnthropicModels) { model in
                            Text(model.displayName).tag(model.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }
                .padding(.leading, 8)

                Toggle(isOn: Binding(
                    get: { ai.thinkingEnabled(for: task) },
                    set: { ai.setThinkingEnabled($0, for: task) }
                )) {
                    Text("Extended Thinking").font(.caption).foregroundStyle(.secondary)
                }
                .toggleStyle(.switch)
                .padding(.leading, 8)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - API key row

private struct APIKeyRow: View {
    let label: String
    let icon: String
    let iconColor: Color
    let hasKey: Bool
    var placeholder: String = "Paste API key…"
    let onSave: (String) -> Void
    let onClear: () -> Void

    @State private var showingEntry = false
    @State private var pendingKey = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .foregroundStyle(iconColor)
                    .frame(width: 24)
                Text(label)
                    .font(.subheadline)
                Spacer()
                if hasKey && !showingEntry {
                    HStack(spacing: 6) {
                        Image(systemName: "lock.fill").foregroundStyle(.green).font(.caption)
                        Text("Saved").font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Update") { showingEntry = true }
                        .font(.caption)
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                } else if !showingEntry {
                    Button("Add Key") { showingEntry = true }
                        .font(.caption)
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .tint(.accentColor)
                }
            }

            if showingEntry {
                VStack(alignment: .leading, spacing: 8) {
                    SecureField(placeholder, text: $pendingKey)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))

                    HStack {
                        if hasKey {
                            Button("Remove Key", role: .destructive) {
                                onClear()
                                pendingKey = ""
                                showingEntry = false
                            }
                            .font(.caption)
                        }
                        Spacer()
                        Button("Cancel") {
                            pendingKey = ""
                            showingEntry = false
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)

                        Button("Save") {
                            onSave(pendingKey)
                            pendingKey = ""
                            showingEntry = false
                        }
                        .font(.caption.weight(.semibold))
                        .buttonStyle(.borderedProminent)
                        .controlSize(.mini)
                        .disabled(pendingKey.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                .padding(.leading, 34)
            }
        }
        .padding(.vertical, 4)
    }
}
