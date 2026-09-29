//
//  SettingsView.swift
//  Midi Set List
//

import SwiftUI

struct SettingsView: View {
    @ObservedObject private var ai = AISettings.shared
    @ObservedObject private var remote = MIDIRemoteSettings.shared
    @AppStorage(AutoScrollingTextView.leadInLinesKey) private var lyricsLeadInLines = AutoScrollingTextView.defaultLeadInLines

    var body: some View {
        NavigationStack {
            List {
                midiSection
                lyricsSection
                if ai.anyAIAvailable {
                    offlineModeSection
                    apiKeysSection
                    taskRoutingSection
                    activeProvidersSection
                    // Spending only applies to paid providers
                    if ai.hasOpenAIKey || ai.hasAnthropicKey || !AICostLedger.shared.days.isEmpty {
                        AICostSection()
                    }
                } else {
                    // No Apple Intelligence and no keys — only show how to turn AI on
                    aiUnavailableSection
                    apiKeysSection
                }
                BackupSection()
            }
            .animation(.default, value: ai.offlineMode)
            .navigationTitle("Settings")
            .offlineStatusBadge()
            .navigationBarTitleDisplayMode(.large)
        }
    }

    // MARK: - MIDI

    private var midiSection: some View {
        Section {
            NavigationLink {
                MIDIRemoteSettingsView()
            } label: {
                LabeledContent {
                    Text(remote.isEnabled ? remote.receiveChannelLabel : "Off")
                } label: {
                    Label("MIDI Receive & Control", systemImage: "slider.horizontal.below.rectangle")
                }
            }
        } header: {
            Text("MIDI")
        } footer: {
            Text("Choose the receive channel and which messages recall snapshots or change songs — for foot controllers and other MIDI gear.")
        }
    }

    // MARK: - Lyrics

    private var lyricsSection: some View {
        Section {
            Stepper(value: $lyricsLeadInLines, in: 0...10) {
                LabeledContent("Blank Lines Before Lyrics") {
                    Text("\(lyricsLeadInLines)")
                        .monospacedDigit()
                }
            }
        } header: {
            Text("Lyrics")
        } footer: {
            Text("Empty lines shown above a song's lyrics, so the first line starts lower and auto-scroll has a lead-in. Applies on the Perform screen and in full view.")
        }
    }

    // MARK: - No AI available

    private var aiUnavailableSection: some View {
        Section {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "eye.slash")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 4) {
                    Text("AI features are hidden").font(.body.weight(.semibold))
                    Text("This device doesn't support Apple Intelligence. Add a ChatGPT or Claude key below to turn on AI macro generation, reference files and device memory.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        } footer: {
            Text("Nothing has been deleted — your reference files and device memory come back as soon as AI is available.")
        }
    }

    // MARK: - Connection

    private var offlineModeSection: some View {
        Section {
            if ai.offlineMode {
                OfflineModeBanner()
                    .listRowInsets(EdgeInsets())
            }
            HStack(spacing: 10) {
                Image(systemName: ai.offlineMode ? "wifi.slash" : "wifi")
                    .foregroundStyle(ai.offlineMode ? Color.offlineMode : .green)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(ai.offlineMode ? "Offline" : "Online").font(.body.weight(.semibold))
                    Text(ai.offlineMode ? "All AI tasks are using On-Device" : "AI tasks use the providers below")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Connection")
        } footer: {
            Text("With no internet connection, every AI feature automatically falls back to the on-device model, whatever provider or model is picked below. Your choices take over again as soon as you're back online.")
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
                Label("No connection — all tasks are using On-Device until you're back online.", systemImage: "wifi.slash")
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
                        if !ai.isAvailable(task) {
                            Text("Not available right now — hidden in the app")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        } else if mismatch {
                            Text("Add a \(configured.displayName) key above to activate")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        } else if configured == .onDevice && resolved != .onDevice {
                            Text("No Apple Intelligence on this device — using \(resolved.displayName)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if ai.offlineMode {
                        Spacer()
                        OfflineModeBadge()
                    }
                }
                .opacity(ai.isAvailable(task) ? 1 : 0.5)
                .padding(.vertical, 2)
            }
        }
    }
}

// MARK: - Task routing row

private extension AITask {
    var routingCaption: String? {
        switch self {
        case .bulkCheck: return "Quick yes/no check on each chat message: does it ask for more than one action? If the chosen AI isn't available, messages are sent as one."
        case .specAnalysis: return "Used by \"Generate Reference with AI\" on a device page. Claude or ChatGPT handle long manuals best."
        case .bulkSplit: return "Rewrites a multi-action chat message into a list of single actions."
        case .setListAssistant: return "Creates, reorders and trims set lists from a request. Always shows a summary for approval first."
        default:         return nil
        }
    }
}

private struct TaskRoutingRow: View {
    let task: AITask
    @ObservedObject private var ai = AISettings.shared

    private var selectedProvider: AIProviderType { ai.routing[task, default: .onDevice] }

    /// Flags options that can't run, e.g. On-Device without Apple Intelligence or a provider with no key
    private func label(for provider: AIProviderType) -> String {
        switch provider {
        case .onDevice  where !ai.onDeviceAvailable: return "\(provider.displayName) (unavailable)"
        case .openAI    where !ai.hasOpenAIKey:      return "\(provider.displayName) (no key)"
        case .anthropic where !ai.hasAnthropicKey:   return "\(provider.displayName) (no key)"
        default:                                     return provider.displayName
        }
    }

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
                        Label(label(for: provider), systemImage: provider.icon).tag(provider)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }

            if let caption = task.routingCaption {
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
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
