//
//  SettingsView.swift
//  Midi Set List
//

import AppIntents
import SwiftUI

struct SettingsView: View {
    @ObservedObject private var ai = AISettings.shared
    @ObservedObject private var remote = MIDIRemoteSettings.shared
    @ObservedObject private var prefs = UserPreferences.shared
    @ObservedObject private var pedals = PedalSettings.shared
    @ObservedObject private var band = BandSettings.shared
    @FetchRequest(sortDescriptors: [SortDescriptor(\.orderIndexRaw)]) private var roles: FetchedResults<BandRole>

    var body: some View {
        NavigationStack {
            List {
                midiSection
                bandSection
                lyricsSection
                if ai.anyAIAvailable {
                    offlineModeSection
                    apiKeysSection
                    taskRoutingSection
                    siriShortcutsSection
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
            .performShortcut()
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
            NavigationLink {
                PedalSettingsView()
            } label: {
                LabeledContent {
                    Text(pedals.isEnabled ? "On" : "Off")
                } label: {
                    Label("Page-Turner Pedals", systemImage: "shoe.2")
                }
            }
        } header: {
            Text("MIDI & Pedals")
        } footer: {
            Text("MIDI: choose the receive channel and which messages recall snapshots or change songs. Page-turner pedals: Bluetooth pedals that act as a keyboard, for turning pages and more.")
        }
    }

    // MARK: - Band

    private var bandSection: some View {
        Section {
            NavigationLink {
                BandSettingsView()
            } label: {
                LabeledContent {
                    Text(band.showsAllParts
                         ? "All Parts"
                         : roles.filter { band.myRoleIDs.contains($0.id) }.map(\.name).joined(separator: ", "))
                } label: {
                    Label("This Device Plays", systemImage: "person.3")
                }
            }
        } header: {
            Text("Band")
        } footer: {
            Text("Pick your instrument to see just your parts of each song, and whether chords read as capo shapes or concert pitch.")
        }
    }

    // MARK: - Lyrics

    private var lyricsSection: some View {
        Section {
            Picker("View", selection: $prefs.chartModeOverride) {
                Text("Remember Per Song").tag(PerformChartMode?.none)
                ForEach(PerformChartMode.allCases) { mode in
                    Text("Always \(mode.title)").tag(Optional(mode))
                }
            }

            speedStepper("New Song Lyrics Speed", value: $prefs.lyricsScrollSpeed)
            speedStepper("New Song Sheet Music Speed", value: $prefs.sheetMusicScrollSpeed)

            Stepper(value: $prefs.lyricsLeadInLines, in: UserPreferences.leadInLinesRange) {
                LabeledContent("Blank Lines Before Lyrics") {
                    Text("\(prefs.lyricsLeadInLines)")
                        .monospacedDigit()
                }
            }
        } header: {
            Text("Your Performance Settings")
        } footer: {
            Text(prefs.chartModeOverride == nil
                 ? "For songs with both lyrics and sheet music, each song opens in the view you last used on it, at your last speed. These are yours alone and follow your Apple ID, so someone sharing your songs keeps their own. New songs start at the speeds above."
                 : "Every song with \(prefs.chartModeOverride?.title.lowercased() ?? "") shows it. Your remembered view for each song is kept — switch back to Remember Per Song to use it again.")
        }
    }

    private func speedStepper(_ title: String, value: Binding<Double>) -> some View {
        Stepper(value: value, in: UserPreferences.scrollSpeedRange, step: 5) {
            LabeledContent(title) {
                Text("\(Int(value.wrappedValue))")
                    .monospacedDigit()
            }
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
            // Belongs to the Claude key, so it sits under it, indented, once a key is saved
            if ai.hasAnthropicKey || ai.hasAnthropicWorkspaceID {
                APIKeyRow(
                    label: "Workspace ID (optional)",
                    icon: "building.2",
                    iconColor: .orange,
                    hasKey: ai.hasAnthropicWorkspaceID,
                    placeholder: "Paste Workspace ID…",
                    noun: "ID",
                    isSubItem: true,
                    onSave: { id in ai.anthropicWorkspaceID = id },
                    onClear: { ai.anthropicWorkspaceID = nil }
                )
                .listRowSeparator(.hidden, edges: .top)
            }
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
            // Shortcut-only tasks are picked in the Siri Shortcuts section
            ForEach(AITask.allCases.filter { !$0.isShortcutOnly }, id: \.rawValue) { task in
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

    // MARK: - Siri Shortcuts

    private var siriShortcutsSection: some View {
        Section {
            AIShortcutRow(
                name: "Create Song",
                icon: "music.note",
                detail: "Choose Song Details › From Text or From File with AI to fill in the title, artist, key, scale, BPM, genre and lyrics from a chord chart, lyric sheet, PDF or photo.",
                engine: .routed
            )
            TaskRoutingRow(task: .songDetails, title: "AI for Create Song")
                .padding(.leading, 38)
                .listRowSeparator(.hidden, edges: .top)

            AIShortcutRow(
                name: "Analyze Device Spec",
                icon: "doc.text.magnifyingglass",
                detail: "Reads a MIDI implementation chart (pasted text or a photo) and saves a reference file on the instrument.",
                engine: .onDeviceOnly
            )
            AIShortcutRow(
                name: "Generate Macros from MIDI Table",
                icon: "wand.and.stars",
                detail: "Turns a MIDI table into a category of ready-to-use macros on an instrument.",
                engine: .onDeviceOnly
            )
            AIShortcutRow(
                name: "Get Reference Builder System Prompt",
                icon: "square.and.arrow.up.on.square",
                detail: "Gives you the prompt to use with an Ask ChatGPT or Ask Claude action, then Attach Device Spec saves the answer.",
                engine: .yourOwn
            )

            ShortcutsLink()
                .shortcutsLinkStyle(.automaticOutline)
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
        } header: {
            Text("Siri Shortcuts")
        } footer: {
            Text("Find these in the Shortcuts app under Midi Set List, or ask Siri — e.g. \"Create song in Midi Set List\".")
        }
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

// MARK: - Siri Shortcut row

private struct AIShortcutRow: View {
    enum Engine {
        /// Uses the AI picked for its task in these settings
        case routed
        /// Calls Apple Intelligence directly
        case onDeviceOnly
        /// Hands a prompt to an AI action of the person's choosing in Shortcuts
        case yourOwn
    }

    let name: String
    let icon: String
    let detail: String
    let engine: Engine
    @ObservedObject private var ai = AISettings.shared

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.indigo)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text(name).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
                engineLabel.font(.caption2)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var engineLabel: some View {
        switch engine {
        case .routed:
            Label("Uses the AI picked below", systemImage: "arrow.down")
                .foregroundStyle(.secondary)
        case .onDeviceOnly where ai.onDeviceAvailable:
            Label("Uses Apple Intelligence (on-device)", systemImage: "iphone")
                .foregroundStyle(.secondary)
        case .onDeviceOnly:
            Label("Needs Apple Intelligence, which isn't on this device", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        case .yourOwn:
            Label("Works with the ChatGPT or Claude action in Shortcuts", systemImage: "arrow.triangle.branch")
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Task routing row

private extension AITask {
    /// Only used by a Siri Shortcut, so it's set up in the Siri Shortcuts section
    var isShortcutOnly: Bool { self == .songDetails }

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
    /// Defaults to the task's name
    var title: String?
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
                Text(title ?? task.displayName).font(.subheadline)
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
    /// Word used on the buttons: "Add Key", "Remove ID"…
    var noun: String = "Key"
    /// Shown indented beneath the row it belongs to
    var isSubItem = false
    let onSave: (String) -> Void
    let onClear: () -> Void

    @State private var showingEntry = false
    @State private var pendingKey = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                if isSubItem {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .frame(width: 24)
                }
                Image(systemName: icon)
                    .font(isSubItem ? .caption : .body)
                    .foregroundStyle(iconColor)
                    .frame(width: isSubItem ? 18 : 24)
                Text(label)
                    .font(isSubItem ? .caption : .subheadline)
                    .foregroundStyle(isSubItem ? .secondary : .primary)
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
                    Button("Add \(noun)") { showingEntry = true }
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
                            Button("Remove \(noun)", role: .destructive) {
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
                .padding(.leading, isSubItem ? 62 : 34)
            }
        }
        .padding(.vertical, isSubItem ? 0 : 4)
    }
}
