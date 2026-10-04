//
//  MacroChatView.swift
//  Midi Set List
//

import Combine
import SwiftUI
import CoreData
import FoundationModels

// MARK: - On-device structured output type

@Generable
struct GeneratedSingleMacro {
    @Guide(description: "Short, human-readable name (e.g. Clean, Drive, Scene 1, Fader Up)")
    var name: String
    @Guide(description: "Bank Select MSB value 0-127. Nil if not needed.")
    var msbValue: Int?
    @Guide(description: "Bank Select LSB value 0-127. Nil if not needed.")
    var lsbValue: Int?
    @Guide(description: "Program Change number 0-127. Nil if not needed.")
    var pcValue: Int?
    @Guide(description: "Control Change CC number 0-127. Nil if no CC message is needed.")
    var ccNumber: Int?
    @Guide(description: "Control Change value 0-127. Required when ccNumber is provided.")
    var ccValue: Int?
    @Guide(description: "OSC address path (e.g. /ch/01/mix/fader). Nil for MIDI commands.")
    var oscAddress: String?
    @Guide(description: "OSC float value. Required when oscAddress is set. Faders use 0.0–1.0.")
    var oscFloatArg: Double?
}

/// MIDI-only variant for devices with no OSC in their spec or macros. The small on-device
/// model can't reach for an OSC address it doesn't have a field for.
@Generable
struct GeneratedMIDIMacro {
    @Guide(description: "Short, human-readable name (e.g. Clean, Drive, Patch A1)")
    var name: String
    @Guide(description: "Bank Select MSB value 0-127. Nil if not needed.")
    var msbValue: Int?
    @Guide(description: "Bank Select LSB value 0-127. Nil if not needed.")
    var lsbValue: Int?
    @Guide(description: "Program Change number 0-127. Nil if not needed.")
    var pcValue: Int?
    @Guide(description: "Control Change CC number 0-127. Nil if no CC message is needed.")
    var ccNumber: Int?
    @Guide(description: "Control Change value 0-127. Required when ccNumber is provided.")
    var ccValue: Int?
}

// MARK: - Message model

struct MacroChatMessage: Identifiable {
    let id: UUID
    var kind: Kind
    /// Set on bulk results, e.g. "Action 2 of 3"
    var bulkLabel: String?

    init(id: UUID = UUID(), kind: Kind, bulkLabel: String? = nil) {
        self.id = id; self.kind = kind; self.bulkLabel = bulkLabel
    }

    enum Kind {
        case user(String)
        case result(ParsedMacro, prompt: String)
        case error(String)
        /// "Would you like to split this into X actions?"
        case splitProposal(original: String, actions: [String])
        /// Placeholder slot for one bulk action, replaced in place by its result
        case pending(String)
    }
}

// MARK: - Persistent chat session (owned by MacrosListView so state survives sheet dismissal)

class MacroChatSession: ObservableObject {
    @Published var messages: [MacroChatMessage] = []
    @Published var isGenerating = false
    @Published var savedIDs: Set<UUID> = []
    @Published var memorySavedIDs: Set<UUID> = []
    @Published var sessionCost: Double = 0
    @Published var sessionModelID: String = ""
    @Published var statusText = "Thinking…"
    /// Split proposals the user has answered: true = split, false = sent as one
    @Published var splitChoices: [UUID: Bool] = [:]

    var externalHistory: [ExternalAIMessage] = []
    var languageModelSession: LanguageModelSession?
    var isSetup = false

    var hasOpenSplitProposal: Bool {
        messages.contains {
            if case .splitProposal = $0.kind { return splitChoices[$0.id] == nil }
            return false
        }
    }

    func clear() {
        messages = []; isGenerating = false
        savedIDs = []; memorySavedIDs = []; splitChoices = [:]
        externalHistory = []; sessionCost = 0; sessionModelID = ""
        languageModelSession = nil; isSetup = false
    }
}

// MARK: - Memory save request (sheet trigger)

private struct MemorySaveRequest: Identifiable {
    let id = UUID()
    let messageID: UUID
}

// MARK: - Chat View

struct MacroChatView: View {
    let category: MacroCategory
    let device: InstrumentDevice
    @ObservedObject var chatSession: MacroChatSession

    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var aiSettings = AISettings.shared

    @State private var input = ""
    @State private var memorySaveRequest: MemorySaveRequest? = nil

    private var onDeviceAvailable: Bool { SystemLanguageModel.default.isAvailable }
    private var activeProvider: AIProviderType { aiSettings.provider(for: .macroChat) }
    private var canUseAI: Bool { activeProvider != .onDevice || onDeviceAvailable }
    private var isOffline: Bool { aiSettings.offlineMode }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if isOffline {
                    OfflineModeBanner()
                }
                if !canUseAI {
                    ContentUnavailableView(
                        "AI Not Available",
                        systemImage: isOffline ? "wifi.slash" : "brain.head.profile",
                        description: Text(isOffline
                            ? "No internet connection, and on-device AI needs Apple Intelligence (iPhone 15 Pro / iPhone 16+, iOS 18.1+). Reconnect to use Claude or ChatGPT."
                            : "Requires Apple Intelligence (iPhone 15 Pro / iPhone 16+, iOS 18.1+) or an external AI key configured in Settings.")
                    )
                } else {
                    messageList
                    Divider()
                    inputBar
                }
            }
            .navigationTitle("Generate Macros")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                if !chatSession.messages.isEmpty {
                    ToolbarItem(placement: .secondaryAction) {
                        Button(role: .destructive) {
                            chatSession.clear()
                        } label: {
                            Label("Clear Chat", systemImage: "trash")
                        }
                    }
                }
            }
            .onAppear { setupSession() }
            .sheet(item: $memorySaveRequest) { req in
                MemorySaveSheet(
                    allMessages: chatSession.messages,
                    targetMessageID: req.messageID,
                    device: device
                ) {
                    chatSession.memorySavedIDs.insert(req.messageID)
                }
            }
        }
    }

    // MARK: - Message list

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    // Context chip
                    VStack(spacing: 2) {
                        HStack(spacing: 6) {
                            Image(systemName: activeProvider.icon).font(.caption2)
                            Text("\(device.name)  ·  \(category.name)  ·  \(activeProvider.displayName)")
                                .font(.caption)
                            if isOffline { OfflineModeBadge() }
                        }
                        if !chatSession.sessionModelID.isEmpty && !isOffline {
                            Text(chatSession.sessionModelID).font(.caption2).foregroundStyle(.tertiary)
                        }
                        if chatSession.sessionCost > 0 {
                            Text(String(format: "Est. session cost ≈ $%.4f", chatSession.sessionCost))
                                .font(.caption2).foregroundStyle(.orange)
                        }
                    }
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 14)

                    if chatSession.messages.isEmpty {
                        emptyState
                    }

                    ForEach(chatSession.messages) { msg in
                        messageBubble(for: msg).padding(.horizontal)
                    }

                    if chatSession.isGenerating {
                        HStack(spacing: 8) {
                            ProgressView().scaleEffect(0.8)
                            Text(chatSession.statusText).font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal)
                    }

                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.bottom, 8)
            }
            .onChange(of: chatSession.messages.count) { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom") } }
            .onChange(of: chatSession.isGenerating)   { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom") } }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "wand.and.stars")
                .font(.largeTitle).foregroundStyle(.secondary)
            Text("Describe a patch or command and the AI will build the macro for you.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: 8) {
                Text("Try an example:")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    ForEach(examplePrompts, id: \.self) { example in
                        Button { input = example } label: {
                            Text(example)
                                .font(.caption).multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10).padding(.vertical, 8)
                        }
                        .buttonStyle(.bordered).tint(.secondary)
                    }
                }
            }
            .padding(.horizontal, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 32).padding(.horizontal, 20)
    }

    // MARK: - Bubble renderer

    @ViewBuilder
    private func messageBubble(for msg: MacroChatMessage) -> some View {
        switch msg.kind {
        case .user(let text):
            HStack {
                Spacer(minLength: 60)
                Text(text)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Color.blue, in: RoundedRectangle(cornerRadius: 18))
                    .foregroundStyle(.white).font(.body)
            }

        case .result(let macro, let prompt):
            VStack(alignment: .leading, spacing: 10) {
                if let label = msg.bulkLabel {
                    bulkHeader(label, action: prompt)
                }
                HStack(spacing: 8) {
                    Image(systemName: macro.oscAddress != nil ? "network" : "waveform")
                        .foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(macro.name).font(.headline)
                        Text(previewText(for: macro))
                            .font(.caption).foregroundStyle(.secondary).fontDesign(.monospaced)
                    }
                }
                HStack(spacing: 10) {
                    if chatSession.savedIDs.contains(msg.id) {
                        Label("Added", systemImage: "checkmark.circle.fill")
                            .font(.subheadline).foregroundStyle(.green)
                    } else {
                        Button { addMacro(macro, messageID: msg.id) } label: {
                            Label("Add to \(category.name)", systemImage: "plus.circle.fill")
                                .font(.subheadline.weight(.medium))
                        }
                        .buttonStyle(.bordered).tint(.green)
                    }

                    if chatSession.memorySavedIDs.contains(msg.id) {
                        Label("Saved to Memory", systemImage: "brain.filled.head.profile")
                            .font(.caption).foregroundStyle(.purple)
                    } else {
                        Button {
                            memorySaveRequest = MemorySaveRequest(messageID: msg.id)
                        } label: {
                            Label("Save to Memory", systemImage: "brain.head.profile")
                                .font(.caption.weight(.medium))
                        }
                        .buttonStyle(.bordered).tint(.purple)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))

        case .error(let text):
            VStack(alignment: .leading, spacing: 6) {
                if let label = msg.bulkLabel {
                    bulkHeader(label, action: nil)
                }
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(text).font(.caption).foregroundStyle(.secondary)
                }
            }

        case .pending(let action):
            VStack(alignment: .leading, spacing: 8) {
                bulkHeader(msg.bulkLabel ?? "Action", action: action)
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.8)
                    Text("Waiting…").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground).opacity(0.5), in: RoundedRectangle(cornerRadius: 16))

        case .splitProposal(let original, let actions):
            splitProposalBubble(id: msg.id, original: original, actions: actions)
        }
    }

    private func bulkHeader(_ label: String, action: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.caption2.weight(.bold)).tracking(0.8)
                .foregroundStyle(.indigo)
            if let action {
                Text(action).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func splitProposalBubble(id: UUID, original: String, actions: [String]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("This looks like \(actions.count) actions", systemImage: "arrow.triangle.branch")
                .font(.headline).foregroundStyle(.indigo)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(actions.enumerated()), id: \.offset) { index, action in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(index + 1)")
                            .font(.caption.weight(.bold)).monospacedDigit()
                            .foregroundStyle(.white)
                            .frame(width: 20, height: 20)
                            .background(Color.indigo, in: Circle())
                        Text(action).font(.subheadline)
                    }
                }
            }

            switch chatSession.splitChoices[id] {
            case .some(true):
                Label("Split into \(actions.count) actions", systemImage: "checkmark.circle.fill")
                    .font(.subheadline).foregroundStyle(.green)
            case .some(false):
                Label("Sent as one request", systemImage: "arrow.up.circle")
                    .font(.subheadline).foregroundStyle(.secondary)
            case .none:
                Text("Would you like to split this into \(actions.count) actions?")
                    .font(.subheadline.weight(.medium))
                HStack(spacing: 10) {
                    Button {
                        Task { await resolveSplit(id: id, original: original, actions: actions, split: true) }
                    } label: {
                        Label("Split into \(actions.count)", systemImage: "square.split.1x2")
                            .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent).tint(.indigo)

                    Button {
                        Task { await resolveSplit(id: id, original: original, actions: actions, split: false) }
                    } label: {
                        Text("Send as One").font(.subheadline)
                    }
                    .buttonStyle(.bordered)
                }
                .disabled(chatSession.isGenerating)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.indigo.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.indigo.opacity(0.35), lineWidth: 1))
    }

    // MARK: - Input bar

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField(inputPlaceholder, text: $input, axis: .vertical)
                .lineLimit(1...4).textFieldStyle(.plain)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20))
                .offlineModeOutline(isOffline)

            Button { Task { await generate() } } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(canSend ? (isOffline ? Color.offlineMode : .blue) : Color(.tertiaryLabel))
            }
            .disabled(!canSend)
        }
        .padding(.horizontal).padding(.vertical, 10)
    }

    // MARK: - Logic

    private var inputPlaceholder: String {
        if chatSession.hasOpenSplitProposal { return "Choose split or send as one above…" }
        return isOffline ? "Describe a macro (on-device)…" : "Describe a macro…"
    }

    private var canSend: Bool {
        !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !chatSession.isGenerating
            && !chatSession.hasOpenSplitProposal
    }

    private var examplePrompts: [String] {
        let specLoaded = !DeviceSpecManager.specContext(for: device).isEmpty
        if specLoaded {
            return [
                "First program in the list",
                "Program change to patch 12",
                "Expression pedal max",
                "Sustain on",
                "Modulation wheel to 64",
                "Volume to 100"
            ]
        }
        return [
            "Load preset 5 on bank 0",
            "Program change to patch 12 on channel \(device.midiChannel)",
            "Reverb on — CC 91, value 100",
            "Expression pedal max — CC 11, value 127",
            "Switch to snapshot 2",
            "Mute channel 3 on the mixer via OSC"
        ]
    }

    private func setupSession() {
        guard !chatSession.isSetup else { return }
        chatSession.isSetup = true
        guard activeProvider == .onDevice, onDeviceAvailable else { return }
        chatSession.languageModelSession = makeOnDeviceSession()
    }

    /// True when the device's spec or existing macros show it speaks OSC. Otherwise the
    /// on-device model only gets MIDI fields to fill in. "OSC 1" style oscillator labels
    /// in synth specs don't count — only OSC the network protocol does.
    private var deviceUsesOSC: Bool {
        if device.categories.contains(where: { $0.macros.contains(where: \.isOSC) }) { return true }
        let spec = DeviceSpecManager.specContext(for: device)
        return spec.range(of: #"(?i)open sound control|\bOSC\b[^\n]{0,40}\b(address|path|port|udp)"#,
                          options: .regularExpression) != nil
    }

    /// The user asked for OSC in this message ("via OSC", "OSC fader") — not "OSC 2" the oscillator.
    private func mentionsOSC(_ text: String) -> Bool {
        text.range(of: #"(?i)\bOSC\b(?!\s*\d)"#, options: .regularExpression) != nil
    }

    private func makeOnDeviceSession() -> LanguageModelSession {
        let specContext = DeviceSpecManager.specContext(for: device)
        var instructions = """
            You are a MIDI macro assistant for the app "Complete Control."
            Device: \(device.name), MIDI channel \(device.midiChannel).
            Category: \(category.name).
            """
        if !deviceUsesOSC {
            instructions += "\nThis is a MIDI instrument. Every macro uses MIDI fields only — never OSC."
        }
        if !specContext.isEmpty {
            instructions += "\n\nDevice reference spec — use ONLY values from this spec:\n\(specContext)"
            instructions += """

                Rules:
                - Output MIDI fields only (MSB, LSB, PC, CC number + value). No OSC unless in spec.
                - Use program numbers, CC numbers, and bank values exactly as listed in the spec above.
                - Never invent CC numbers or program numbers not in the spec.
                - Always provide a short, descriptive name.
                - CORRECTION RULE: If the user corrects a specific field (e.g. "LSB should be 2"), reproduce the previous macro with only that field changed. Do not regenerate from scratch.
                """
        } else {
            instructions += """

                Parse each message into a single macro. Use MIDI fields (MSB/LSB/PC/CC, values 0-127) \
                for MIDI instruments. For network mixers (Behringer XR18, X32, etc.) use OSC instead.
                Always provide a short, descriptive name.
                When refining a previous result, adjust only what changed.
                """
        }
        return LanguageModelSession(instructions: instructions)
    }

    private var plannerContext: BulkRequestPlanner.Context {
        BulkRequestPlanner.Context(deviceName: device.name, midiChannel: device.midiChannel, categoryName: category.name)
    }

    @MainActor
    private func generate() async {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        input = ""
        chatSession.messages.append(MacroChatMessage(kind: .user(text)))
        chatSession.isGenerating = true
        defer { chatSession.isGenerating = false }

        // Bulk check: local yes/no first, then the orchestrator lists the actions
        chatSession.statusText = "Checking request…"
        if await BulkRequestPlanner.isMultiAction(text, context: plannerContext) {
            chatSession.statusText = "Listing actions…"
            if let actions = try? await BulkRequestPlanner.splitActions(text, context: plannerContext),
               actions.count > 1 {
                chatSession.messages.append(MacroChatMessage(kind: .splitProposal(original: text, actions: actions)))
                return
            }
            // Orchestrator failed or found one action — send it as a single request
        }

        chatSession.statusText = "Thinking…"
        await sendSingle(text)
    }

    @MainActor
    private func resolveSplit(id: UUID, original: String, actions: [String], split: Bool) async {
        chatSession.splitChoices[id] = split
        chatSession.isGenerating = true
        defer { chatSession.isGenerating = false }

        if split {
            await runBulk(actions)
        } else {
            chatSession.statusText = "Thinking…"
            await sendSingle(original)
        }
    }

    @MainActor
    private func sendSingle(_ text: String) async {
        do {
            let macro = try await generateMacro(for: text)
            chatSession.messages.append(MacroChatMessage(kind: .result(macro, prompt: text)))
        } catch {
            chatSession.messages.append(MacroChatMessage(kind: .error(error.localizedDescription)))
        }
    }

    /// Sends each action as its own single-action request. Every action gets a numbered
    /// placeholder up front, so results always appear in the original order even when
    /// external calls finish out of order.
    @MainActor
    private func runBulk(_ actions: [String]) async {
        let total = actions.count
        let slotIDs: [UUID] = actions.enumerated().map { index, action in
            let slot = MacroChatMessage(kind: .pending(action), bulkLabel: "Action \(index + 1) of \(total)")
            chatSession.messages.append(slot)
            return slot.id
        }

        func fill(_ index: Int, with kind: MacroChatMessage.Kind) {
            guard let i = chatSession.messages.firstIndex(where: { $0.id == slotIDs[index] }) else { return }
            chatSession.messages[i].kind = kind
        }

        chatSession.statusText = "Running \(total) actions…"

        if activeProvider == .onDevice {
            // One on-device session handles one request at a time — run in order. Each action
            // starts from the chat as it was before the split, like the external path, so an
            // earlier action's answer can't pull a later one off course.
            let base = chatSession.languageModelSession ?? makeOnDeviceSession()
            chatSession.languageModelSession = base
            for (index, action) in actions.enumerated() {
                do {
                    let session = LanguageModelSession(transcript: base.transcript)
                    fill(index, with: .result(try await generateOnDevice(userText: action, session: session), prompt: action))
                } catch {
                    fill(index, with: .error(error.localizedDescription))
                }
            }
            return
        }

        // External: independent calls in parallel, all sharing the history from before the split
        let history = chatSession.externalHistory
        var responses: [Int: AIResponse] = [:]
        var offlineRetries: [Int] = []

        await withTaskGroup(of: (Int, Result<(macro: ParsedMacro, response: AIResponse), Error>).self) { group in
            for (index, action) in actions.enumerated() {
                group.addTask {
                    do { return (index, .success(try await requestExternal(userText: action, history: history))) }
                    catch { return (index, .failure(error)) }
                }
            }
            for await (index, result) in group {
                switch result {
                case .success(let output):
                    responses[index] = output.response
                    chatSession.sessionCost += output.response.cost()
                    if chatSession.sessionModelID.isEmpty { chatSession.sessionModelID = output.response.modelID }
                    fill(index, with: .result(output.macro, prompt: actions[index]))
                case .failure(let error) where ExternalAIError.isConnectivity(error) && onDeviceAvailable:
                    offlineRetries.append(index)
                case .failure(let error):
                    fill(index, with: .error(error.localizedDescription))
                }
            }
        }

        // Keep the conversation history in the original order
        for (index, action) in actions.enumerated() {
            guard let response = responses[index] else { continue }
            chatSession.externalHistory.append(ExternalAIMessage(role: "user", content: action))
            chatSession.externalHistory.append(ExternalAIMessage(role: "assistant", content: response.text))
        }

        // Connection dropped mid-batch — finish those actions on-device, in order, each from a clean start
        let base = chatSession.languageModelSession ?? makeOnDeviceSession()
        chatSession.languageModelSession = base
        for index in offlineRetries.sorted() {
            do {
                let session = LanguageModelSession(transcript: base.transcript)
                fill(index, with: .result(try await generateOnDevice(userText: actions[index], session: session), prompt: actions[index]))
            } catch {
                fill(index, with: .error(error.localizedDescription))
            }
        }
    }

    /// One single-action request on the routed provider, falling back to on-device if the connection drops.
    @MainActor
    private func generateMacro(for text: String) async throws -> ParsedMacro {
        if activeProvider == .onDevice {
            return try await generateOnDevice(userText: text)
        }
        do {
            let output = try await requestExternal(userText: text, history: chatSession.externalHistory)
            chatSession.externalHistory.append(ExternalAIMessage(role: "user", content: text))
            chatSession.externalHistory.append(ExternalAIMessage(role: "assistant", content: output.response.text))
            chatSession.sessionCost += output.response.cost()
            if chatSession.sessionModelID.isEmpty { chatSession.sessionModelID = output.response.modelID }
            return output.macro
        } catch let error where ExternalAIError.isConnectivity(error) && onDeviceAvailable {
            // Connection dropped mid-request — answer locally
            return try await generateOnDevice(userText: text)
        }
    }

    private func generateOnDevice(userText: String, session: LanguageModelSession? = nil) async throws -> ParsedMacro {
        guard onDeviceAvailable else { throw ExternalAIError.apiError("On-device AI is not available.") }
        let session = session ?? {
            // Created on demand in case the connection dropped after the chat opened
            let shared = chatSession.languageModelSession ?? makeOnDeviceSession()
            chatSession.languageModelSession = shared
            return shared
        }()
        // No cost for on-device processing
        if deviceUsesOSC || mentionsOSC(userText) {
            return ParsedMacro(try await session.respond(to: userText, generating: GeneratedSingleMacro.self).content)
        }
        return ParsedMacro(try await session.respond(to: userText, generating: GeneratedMIDIMacro.self).content)
    }

    /// Calls the external provider without touching chat state, so several can run at once.
    private func requestExternal(userText: String, history: [ExternalAIMessage]) async throws -> (macro: ParsedMacro, response: AIResponse) {
        let provider = activeProvider
        guard let apiKey = provider == .openAI ? AISettings.shared.openAIKey : AISettings.shared.anthropicKey
        else { throw ExternalAIError.notConfigured }

        let aiResponse = try await ExternalAIClient.chat(
            provider: provider,
            apiKey: apiKey,
            systemPrompt: externalSystemPrompt,
            messages: history + [ExternalAIMessage(role: "user", content: userText)],
            workspaceID: provider == .anthropic ? AISettings.shared.anthropicWorkspaceID : nil,
            anthropicModelID: AISettings.shared.anthropicModel(for: .macroChat),
            anthropicThinking: AISettings.shared.thinkingEnabled(for: .macroChat)
        )

        let jsonString = extractJSON(from: aiResponse.text)
        guard let data = jsonString.data(using: .utf8) else {
            throw ExternalAIError.apiError("No JSON found. Model returned: \(aiResponse.text.prefix(300))")
        }
        do {
            let macro = try JSONDecoder().decode(ParsedMacro.self, from: data)
            return (macro, aiResponse)
        } catch {
            throw ExternalAIError.apiError("JSON decode failed (\(error.localizedDescription)). Raw: \(aiResponse.text.prefix(300))")
        }
    }

    private var externalSystemPrompt: String {
        let specContext = DeviceSpecManager.specContext(for: device)
        var prompt = """
            You are a MIDI macro assistant for the app "Complete Control."
            Device: \(device.name), MIDI channel \(device.midiChannel).
            Category: \(category.name).
            """
        prompt += """

            CORRECTION OVERRIDE (highest priority — supersedes spec):
            If the user's message explicitly states a field value (e.g. "LSB should be 2", \
            "use PC 5", "CC number is 7"), that value is GROUND TRUTH. Use it EXACTLY as stated, \
            even if the spec says otherwise. Take your previous JSON and change ONLY the stated \
            field — copy every other field unchanged.
            """
        if !specContext.isEmpty {
            prompt += "\n\nDevice reference spec — use values from this spec when the user has not explicitly overridden them:\n\(specContext)"
        }
        prompt += """

            Respond ONLY with a JSON object — no markdown fences, no explanation. Schema:
            {
              "name": "string",
              "msbValue": integer 0-127 or null,
              "lsbValue": integer 0-127 or null,
              "pcValue": integer 0-127 or null,
              "ccNumber": integer 0-127 or null,
              "ccValue": integer 0-127 or null,
              "oscAddress": string or null,
              "oscFloatArg": number or null
            }
            """
        return prompt
    }

    private func extractJSON(from text: String) -> String {
        // Extract the outermost {...} block in case the model wrapped it in markdown
        if let start = text.firstIndex(of: "{"),
           let end = text.lastIndex(of: "}") {
            return String(text[start...end])
        }
        return text
    }

    private func addMacro(_ macro: ParsedMacro, messageID: UUID) {
        let isOSC = macro.oscAddress != nil
        let m = DeviceMacro.create(
            name: macro.name,
            channel: device.midiChannel,
            delayMilliseconds: 50,
            orderIndex: category.macros.count,
            msbValue: macro.msbValue,
            lsbValue: macro.lsbValue,
            pcValue: macro.pcValue,
            ccNumber: macro.ccNumber,
            ccValue: macro.ccValue,
            isOSC: isOSC,
            oscAddress: macro.oscAddress,
            oscFloatArg: macro.oscFloatArg,
            in: viewContext
        )
        m.category = category
        try? viewContext.save()
        chatSession.savedIDs.insert(messageID)
    }

    private func previewText(for macro: ParsedMacro) -> String {
        if let addr = macro.oscAddress {
            if let val = macro.oscFloatArg { return "OSC \(addr) → \(String(format: "%.4g", val))" }
            return "OSC \(addr)"
        }
        var parts: [String] = []
        if let msb = macro.msbValue { parts.append("MSB \(msb)") }
        if let lsb = macro.lsbValue { parts.append("LSB \(lsb)") }
        if let pc  = macro.pcValue  { parts.append("PC \(pc)") }
        if let ccN = macro.ccNumber { parts.append("CC#\(ccN)=\(macro.ccValue ?? 0)") }
        if parts.isEmpty { return "(no commands)" }
        return parts.joined(separator: " → ") + " [Ch \(device.midiChannel)]"
    }
}

// MARK: - Memory save sheet

private struct MemorySaveSheet: View {
    let allMessages: [MacroChatMessage]
    let targetMessageID: UUID
    let device: InstrumentDevice
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedIDs: Set<UUID> = []

    private var targetIndex: Int? {
        allMessages.firstIndex(where: { $0.id == targetMessageID })
    }

    // Up to 4 messages ending at (and including) the target, skipping errors
    private var candidates: [MacroChatMessage] {
        guard let idx = targetIndex else { return [] }
        let start = max(0, idx - 4)
        return allMessages[start...idx].filter {
            switch $0.kind {
            case .user, .result: return true
            case .error, .splitProposal, .pending: return false
            }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Choose which messages to include in the memory entry for \(device.name). The target result is always included.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Section("Context to Save") {
                    ForEach(candidates) { msg in
                        let isTarget = msg.id == targetMessageID
                        Button {
                            guard !isTarget else { return }
                            if selectedIDs.contains(msg.id) { selectedIDs.remove(msg.id) }
                            else { selectedIDs.insert(msg.id) }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: selectedIDs.contains(msg.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selectedIDs.contains(msg.id) ? .purple : .secondary)
                                    .imageScale(.large)

                                VStack(alignment: .leading, spacing: 3) {
                                    switch msg.kind {
                                    case .user(let text):
                                        Label("You", systemImage: "person.fill")
                                            .font(.caption2).foregroundStyle(.blue)
                                        Text(text).font(.subheadline).foregroundStyle(.primary)
                                    case .result(let macro, _):
                                        Label(isTarget ? "Result (this macro)" : "Previous result",
                                              systemImage: "waveform")
                                            .font(.caption2).foregroundStyle(.secondary)
                                        Text(macro.name)
                                            .font(.subheadline).foregroundStyle(.primary)
                                        Text(macroValues(macro))
                                            .font(.caption).foregroundStyle(.secondary).fontDesign(.monospaced)
                                    case .error, .splitProposal, .pending:
                                        EmptyView()
                                    }
                                }
                                Spacer()
                            }
                            .padding(.vertical, 2)
                        }
                        .buttonStyle(.plain)
                        .disabled(isTarget)
                    }
                }
            }
            .navigationTitle("Save to Memory")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save(); onSaved(); dismiss() }
                        .fontWeight(.semibold)
                }
            }
            .onAppear {
                // Always include target; pre-select up to 2 messages before it
                selectedIDs.insert(targetMessageID)
                guard let idx = targetIndex else { return }
                let start = max(0, idx - 2)
                for i in start..<idx { selectedIDs.insert(allMessages[i].id) }
            }
        }
    }

    private func save() {
        let ordered = allMessages.filter { selectedIDs.contains($0.id) }
        var lines: [String] = []
        for msg in ordered {
            switch msg.kind {
            case .user(let text):
                lines.append("- You: \"\(text)\"")
            case .result(let macro, _):
                let tag = msg.id == targetMessageID ? "Confirmed" : "Previous"
                lines.append("- \(tag): \(macro.name) → \(macroValues(macro))")
            case .error, .splitProposal, .pending:
                break
            }
        }
        DeviceSpecManager.appendToMemory(for: device, note: lines.joined(separator: "\n"))
    }

    private func macroValues(_ macro: ParsedMacro) -> String {
        if let addr = macro.oscAddress {
            if let v = macro.oscFloatArg { return "OSC \(addr) → \(String(format: "%.4g", v))" }
            return "OSC \(addr)"
        }
        var parts: [String] = []
        if let v = macro.msbValue { parts.append("MSB \(v)") }
        if let v = macro.lsbValue { parts.append("LSB \(v)") }
        if let v = macro.pcValue  { parts.append("PC \(v)") }
        if let n = macro.ccNumber { parts.append("CC#\(n)=\(macro.ccValue ?? 0)") }
        return parts.isEmpty ? "(no commands)" : parts.joined(separator: " → ")
    }
}
