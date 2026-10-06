//
//  DeviceLibraryChatView.swift
//  Midi Set List
//
//  AI chat for the device library. Can create new InstrumentDevice objects or
//  add macro commands to existing (or new) devices across the full library.
//

import Combine
import CoreData
import FoundationModels
import SwiftUI

// MARK: - On-device structured output type

@Generable
struct GeneratedLibraryAction {
    @Guide(description: "Either 'new_device' to create a MIDI device, or 'new_macro' to add a command macro.")
    var actionType: String
    @Guide(description: "Name of the device. For new_device: the new device's name. For new_macro: the device to add the macro to.")
    var deviceName: String
    @Guide(description: "Manufacturer name (new_device only, optional).")
    var manufacturer: String?
    @Guide(description: "MIDI channel 1–16. Required for new_device; use the device's known channel for new_macro.")
    var midiChannel: Int
    @Guide(description: "Macro category name (new_macro only, e.g. Presets, Snapshots, Mix Controls).")
    var categoryName: String?
    @Guide(description: "Short macro name (new_macro only, e.g. Clean, Drive, Tap Tempo).")
    var macroName: String?
    @Guide(description: "Bank Select MSB 0–127, nil if not needed.")
    var msbValue: Int?
    @Guide(description: "Bank Select LSB 0–127, nil if not needed.")
    var lsbValue: Int?
    @Guide(description: "Program Change 0–127, nil if not needed.")
    var pcValue: Int?
    @Guide(description: "CC number 0–127, nil if not needed.")
    var ccNumber: Int?
    @Guide(description: "CC value 0–127, required when ccNumber is set.")
    var ccValue: Int?
    @Guide(description: "OSC address path, e.g. /ch/01/mix/fader. Nil for MIDI-only macros.")
    var oscAddress: String?
    @Guide(description: "OSC float value 0.0–1.0. Required when oscAddress is set.")
    var oscFloatArg: Double?
}

// MARK: - Parsed result

struct ParsedLibraryAction {
    enum Kind {
        case createDevice(name: String, manufacturer: String?, midiChannel: Int)
        case addMacro(deviceName: String, categoryName: String, macro: ParsedMacro)
    }
    var kind: Kind

    var deviceName: String {
        switch kind {
        case .createDevice(let name, _, _): return name
        case .addMacro(let name, _, _): return name
        }
    }

    static func from(_ g: GeneratedLibraryAction) -> ParsedLibraryAction? {
        let type = g.actionType
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: " ", with: "")
        switch type {
        case "newdevice", "createdevice", "device":
            let ch = max(1, min(16, g.midiChannel))
            let mfr = g.manufacturer.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
            return ParsedLibraryAction(kind: .createDevice(name: g.deviceName, manufacturer: mfr, midiChannel: ch))
        case "newmacro", "addmacro", "macro":
            let cat = (g.categoryName ?? "").trimmingCharacters(in: .whitespaces)
            let name = (g.macroName ?? "").trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return nil }
            let macro = ParsedMacro(
                name: name, msbValue: g.msbValue, lsbValue: g.lsbValue,
                pcValue: g.pcValue, ccNumber: g.ccNumber, ccValue: g.ccValue,
                oscAddress: g.oscAddress, oscFloatArg: g.oscFloatArg
            )
            return ParsedLibraryAction(kind: .addMacro(
                deviceName: g.deviceName,
                categoryName: cat.isEmpty ? "General" : cat,
                macro: macro
            ))
        default:
            return nil
        }
    }
}

// MARK: - Decodable mirror for the external AI path

private struct DecodedLibraryAction: Decodable {
    var actionType: String
    var deviceName: String
    var manufacturer: String?
    var midiChannel: Int?
    var categoryName: String?
    var macroName: String?
    var msbValue: Int?
    var lsbValue: Int?
    var pcValue: Int?
    var ccNumber: Int?
    var ccValue: Int?
    var oscAddress: String?
    var oscFloatArg: Double?

    func toParsed() -> ParsedLibraryAction? {
        let type = actionType
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: " ", with: "")
        switch type {
        case "newdevice", "createdevice", "device":
            let ch = max(1, min(16, midiChannel ?? 1))
            let mfr = manufacturer.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
            return ParsedLibraryAction(kind: .createDevice(name: deviceName, manufacturer: mfr, midiChannel: ch))
        case "newmacro", "addmacro", "macro":
            let cat = (categoryName ?? "").trimmingCharacters(in: .whitespaces)
            let name = (macroName ?? "").trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return nil }
            let macro = ParsedMacro(
                name: name, msbValue: msbValue, lsbValue: lsbValue,
                pcValue: pcValue, ccNumber: ccNumber, ccValue: ccValue,
                oscAddress: oscAddress, oscFloatArg: oscFloatArg
            )
            return ParsedLibraryAction(kind: .addMacro(
                deviceName: deviceName,
                categoryName: cat.isEmpty ? "General" : cat,
                macro: macro
            ))
        default:
            return nil
        }
    }
}

// MARK: - Message model

struct LibraryChatMessage: Identifiable {
    let id: UUID
    var kind: Kind
    var bulkLabel: String?

    init(id: UUID = UUID(), kind: Kind, bulkLabel: String? = nil) {
        self.id = id; self.kind = kind; self.bulkLabel = bulkLabel
    }

    enum Kind {
        case user(String)
        case result(ParsedLibraryAction, prompt: String)
        case error(String)
        case splitProposal(original: String, actions: [String])
        case pending(String)
    }
}

// MARK: - Session (owned by DeviceLibraryView so state survives sheet dismissal)

class DeviceLibraryChatSession: ObservableObject {
    @Published var messages: [LibraryChatMessage] = []
    @Published var isGenerating = false
    @Published var savedIDs: Set<UUID> = []
    @Published var sessionCost: Double = 0
    @Published var sessionModelID: String = ""
    @Published var statusText = "Thinking…"
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
        messages = []; isGenerating = false; savedIDs = []; splitChoices = [:]
        externalHistory = []; sessionCost = 0; sessionModelID = ""
        languageModelSession = nil; isSetup = false
    }
}

// MARK: - Chat view

struct DeviceLibraryChatView: View {
    @ObservedObject var chatSession: DeviceLibraryChatSession

    @FetchRequest(sortDescriptors: [SortDescriptor(\.name)]) private var instruments: FetchedResults<InstrumentDevice>
    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var aiSettings = AISettings.shared

    @State private var input = ""

    private var onDeviceAvailable: Bool { SystemLanguageModel.default.isAvailable }
    private var activeProvider: AIProviderType { aiSettings.provider(for: .libraryChat) }
    private var canUseAI: Bool { activeProvider != .onDevice || onDeviceAvailable }
    private var isOffline: Bool { aiSettings.offlineMode }

    private var deviceSummary: String {
        instruments.isEmpty ? "" : instruments.map { "\($0.name) (Ch \($0.midiChannel))" }.joined(separator: ", ")
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if isOffline { OfflineModeBanner() }
                if !canUseAI {
                    ContentUnavailableView(
                        "AI Not Available",
                        systemImage: isOffline ? "wifi.slash" : "brain.head.profile",
                        description: Text(isOffline
                            ? "No internet connection, and on-device AI needs Apple Intelligence (iPhone 15 Pro / iPhone 16+, iOS 18.1+)."
                            : "Requires Apple Intelligence (iPhone 15 Pro / iPhone 16+, iOS 18.1+) or an external AI key in Settings.")
                    )
                } else {
                    messageList
                    Divider()
                    inputBar
                }
            }
            .navigationTitle("Device Library AI")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                if !chatSession.messages.isEmpty {
                    ToolbarItem(placement: .secondaryAction) {
                        Button(role: .destructive) { chatSession.clear() } label: {
                            Label("Clear Chat", systemImage: "trash")
                        }
                    }
                }
            }
            .onAppear { setupSession() }
        }
    }

    // MARK: - Message list

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    VStack(spacing: 2) {
                        HStack(spacing: 6) {
                            Image(systemName: activeProvider.icon).font(.caption2)
                            Text("\(instruments.count) device\(instruments.count == 1 ? "" : "s")  ·  \(activeProvider.displayName)")
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

                    if chatSession.messages.isEmpty { emptyState }

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
            Text("Describe a device to add or a command macro to create — the AI builds it for you.")
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
    private func messageBubble(for msg: LibraryChatMessage) -> some View {
        switch msg.kind {
        case .user(let text):
            HStack {
                Spacer(minLength: 60)
                Text(text)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Color.blue, in: RoundedRectangle(cornerRadius: 18))
                    .foregroundStyle(.white).font(.body)
            }

        case .result(let action, let prompt):
            VStack(alignment: .leading, spacing: 10) {
                if let label = msg.bulkLabel { bulkHeader(label, action: prompt) }
                actionSummary(for: action)
                if chatSession.savedIDs.contains(msg.id) {
                    Label("Added", systemImage: "checkmark.circle.fill")
                        .font(.subheadline).foregroundStyle(.green)
                } else {
                    Button { addAction(action, messageID: msg.id) } label: {
                        Label(addButtonLabel(for: action), systemImage: "plus.circle.fill")
                            .font(.subheadline.weight(.medium))
                    }
                    .buttonStyle(.bordered).tint(.green)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))

        case .error(let text):
            VStack(alignment: .leading, spacing: 6) {
                if let label = msg.bulkLabel { bulkHeader(label, action: nil) }
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

    @ViewBuilder
    private func actionSummary(for action: ParsedLibraryAction) -> some View {
        switch action.kind {
        case .createDevice(let name, let mfr, let ch):
            HStack(spacing: 8) {
                Image(systemName: "pianokeys").foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text("New Device: \(name)").font(.headline)
                    if let mfr {
                        Text(mfr).font(.caption).foregroundStyle(.secondary)
                    }
                    Text("MIDI Ch \(ch)")
                        .font(.caption).foregroundStyle(.secondary).fontDesign(.monospaced)
                }
            }
        case .addMacro(let devName, let cat, let macro):
            HStack(spacing: 8) {
                Image(systemName: macro.oscAddress != nil ? "network" : "waveform").foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text(macro.name).font(.headline)
                    Text("\(devName) › \(cat)")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(macroPreview(macro, deviceName: devName))
                        .font(.caption).foregroundStyle(.secondary).fontDesign(.monospaced)
                }
            }
        }
    }

    private func bulkHeader(_ label: String, action: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.caption2.weight(.bold)).tracking(0.8).foregroundStyle(.indigo)
            if let action { Text(action).font(.caption).foregroundStyle(.secondary) }
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

    // MARK: - Helpers

    private var inputPlaceholder: String {
        if chatSession.hasOpenSplitProposal { return "Choose split or send as one above…" }
        return isOffline ? "Describe a device or macro (on-device)…" : "Describe a device or macro…"
    }

    private var canSend: Bool {
        !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !chatSession.isGenerating
            && !chatSession.hasOpenSplitProposal
    }

    private var examplePrompts: [String] {
        if instruments.isEmpty {
            return [
                "Create an HX Stomp on ch 1",
                "Add a BeatBuddy on ch 10",
                "Add a guitar synth on ch 5",
                "Create an XR18 mixer"
            ]
        }
        let first = instruments.first!.name
        return [
            "Add a Clean preset to \(first)",
            "Add tap tempo CC 64 to \(first)",
            "Add a Drive preset bank 1 to \(first)",
            "Add snapshot 2 macro to \(first)"
        ]
    }

    private func addButtonLabel(for action: ParsedLibraryAction) -> String {
        switch action.kind {
        case .createDevice:                      return "Add Device"
        case .addMacro(let dev, let cat, _): return "Add to \(dev) › \(cat)"
        }
    }

    private func macroPreview(_ macro: ParsedMacro, deviceName: String) -> String {
        let ch = instruments.first(where: { $0.name.lowercased() == deviceName.lowercased() })?.midiChannel ?? 1
        if let addr = macro.oscAddress {
            if let v = macro.oscFloatArg { return "OSC \(addr) → \(String(format: "%.4g", v))" }
            return "OSC \(addr)"
        }
        var parts: [String] = []
        if let msb = macro.msbValue { parts.append("MSB \(msb)") }
        if let lsb = macro.lsbValue { parts.append("LSB \(lsb)") }
        if let pc  = macro.pcValue  { parts.append("PC \(pc)") }
        if let ccN = macro.ccNumber { parts.append("CC#\(ccN)=\(macro.ccValue ?? 0)") }
        if parts.isEmpty { return "(no commands)" }
        return parts.joined(separator: " → ") + " [Ch \(ch)]"
    }

    // MARK: - Session setup

    private func setupSession() {
        guard !chatSession.isSetup else { return }
        chatSession.isSetup = true
        guard activeProvider == .onDevice, onDeviceAvailable else { return }
        chatSession.languageModelSession = makeOnDeviceSession()
    }

    private func makeOnDeviceSession() -> LanguageModelSession {
        var instructions = """
            You are a device library assistant for the app "Complete Control."
            You help create MIDI instruments and add command macros to them.
            """
        if !deviceSummary.isEmpty {
            instructions += "\nKnown devices: \(deviceSummary)."
        }
        instructions += """

            For each request produce ONE action:
            - actionType "new_device": creates a device (deviceName required, manufacturer optional, midiChannel 1–16)
            - actionType "new_macro": adds one command macro (deviceName, categoryName, macroName required; \
            fill the relevant MIDI or OSC fields)
            A bank select + program change together is ONE new_macro. CC values and OSC floats are in range 0–127 / 0.0–1.0.
            """
        return LanguageModelSession(instructions: instructions)
    }

    private var plannerContext: BulkRequestPlanner.LibraryContext {
        BulkRequestPlanner.LibraryContext(deviceSummary: deviceSummary)
    }

    // MARK: - Generation

    @MainActor
    private func generate() async {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        input = ""
        chatSession.messages.append(LibraryChatMessage(kind: .user(text)))
        chatSession.isGenerating = true
        defer { chatSession.isGenerating = false }

        chatSession.statusText = "Checking request…"
        if await BulkRequestPlanner.isMultiLibraryAction(text, context: plannerContext) {
            chatSession.statusText = "Listing actions…"
            if let actions = try? await BulkRequestPlanner.splitLibraryActions(text, context: plannerContext),
               actions.count > 1 {
                chatSession.messages.append(LibraryChatMessage(kind: .splitProposal(original: text, actions: actions)))
                return
            }
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
            let action = try await generateAction(for: text)
            chatSession.messages.append(LibraryChatMessage(kind: .result(action, prompt: text)))
        } catch {
            chatSession.messages.append(LibraryChatMessage(kind: .error(error.localizedDescription)))
        }
    }

    @MainActor
    private func runBulk(_ actions: [String]) async {
        let total = actions.count
        let slotIDs: [UUID] = actions.enumerated().map { index, action in
            let slot = LibraryChatMessage(kind: .pending(action), bulkLabel: "Action \(index + 1) of \(total)")
            chatSession.messages.append(slot)
            return slot.id
        }

        func fill(_ index: Int, with kind: LibraryChatMessage.Kind) {
            guard let i = chatSession.messages.firstIndex(where: { $0.id == slotIDs[index] }) else { return }
            chatSession.messages[i].kind = kind
        }

        chatSession.statusText = "Running \(total) actions…"

        if activeProvider == .onDevice {
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

        let history = chatSession.externalHistory
        var responses: [Int: AIResponse] = [:]
        var offlineRetries: [Int] = []

        await withTaskGroup(of: (Int, Result<(ParsedLibraryAction, AIResponse), Error>).self) { group in
            for (index, action) in actions.enumerated() {
                group.addTask {
                    do { return (index, .success(try await requestExternal(userText: action, history: history))) }
                    catch { return (index, .failure(error)) }
                }
            }
            for await (index, result) in group {
                switch result {
                case .success(let output):
                    responses[index] = output.1
                    chatSession.sessionCost += output.1.cost()
                    if chatSession.sessionModelID.isEmpty { chatSession.sessionModelID = output.1.modelID }
                    fill(index, with: .result(output.0, prompt: actions[index]))
                case .failure(let error) where ExternalAIError.isConnectivity(error) && onDeviceAvailable:
                    offlineRetries.append(index)
                case .failure(let error):
                    fill(index, with: .error(error.localizedDescription))
                }
            }
        }

        for (index, action) in actions.enumerated() {
            guard let response = responses[index] else { continue }
            chatSession.externalHistory.append(ExternalAIMessage(role: "user", content: action))
            chatSession.externalHistory.append(ExternalAIMessage(role: "assistant", content: response.text))
        }

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

    @MainActor
    private func generateAction(for text: String) async throws -> ParsedLibraryAction {
        if activeProvider == .onDevice {
            return try await generateOnDevice(userText: text)
        }
        do {
            let (action, response) = try await requestExternal(userText: text, history: chatSession.externalHistory)
            chatSession.externalHistory.append(ExternalAIMessage(role: "user", content: text))
            chatSession.externalHistory.append(ExternalAIMessage(role: "assistant", content: response.text))
            chatSession.sessionCost += response.cost()
            if chatSession.sessionModelID.isEmpty { chatSession.sessionModelID = response.modelID }
            return action
        } catch let error where ExternalAIError.isConnectivity(error) && onDeviceAvailable {
            return try await generateOnDevice(userText: text)
        }
    }

    private func generateOnDevice(userText: String, session: LanguageModelSession? = nil) async throws -> ParsedLibraryAction {
        guard onDeviceAvailable else { throw ExternalAIError.apiError("On-device AI is not available.") }
        let session = session ?? {
            let shared = chatSession.languageModelSession ?? makeOnDeviceSession()
            chatSession.languageModelSession = shared
            return shared
        }()
        let generated = try await session.respond(to: userText, generating: GeneratedLibraryAction.self).content
        guard let action = ParsedLibraryAction.from(generated) else {
            throw ExternalAIError.apiError("AI returned an unrecognised action type: \(generated.actionType)")
        }
        return action
    }

    private func requestExternal(userText: String, history: [ExternalAIMessage]) async throws -> (ParsedLibraryAction, AIResponse) {
        let provider = activeProvider
        guard let apiKey = provider == .openAI ? AISettings.shared.openAIKey : AISettings.shared.anthropicKey
        else { throw ExternalAIError.notConfigured }

        let aiResponse = try await ExternalAIClient.chat(
            provider: provider,
            apiKey: apiKey,
            systemPrompt: externalSystemPrompt,
            messages: history + [ExternalAIMessage(role: "user", content: userText)],
            workspaceID: provider == .anthropic ? AISettings.shared.anthropicWorkspaceID : nil,
            anthropicModelID: AISettings.shared.anthropicModel(for: .libraryChat),
            anthropicThinking: AISettings.shared.thinkingEnabled(for: .libraryChat)
        )

        let jsonString = extractJSON(from: aiResponse.text)
        guard let data = jsonString.data(using: .utf8) else {
            throw ExternalAIError.apiError("No JSON found. Model returned: \(aiResponse.text.prefix(300))")
        }
        do {
            let decoded = try JSONDecoder().decode(DecodedLibraryAction.self, from: data)
            guard let action = decoded.toParsed() else {
                throw ExternalAIError.apiError("Unrecognised action type '\(decoded.actionType)'. Raw: \(aiResponse.text.prefix(300))")
            }
            return (action, aiResponse)
        } catch {
            throw ExternalAIError.apiError("JSON decode failed (\(error.localizedDescription)). Raw: \(aiResponse.text.prefix(300))")
        }
    }

    private var externalSystemPrompt: String {
        var prompt = """
            You are a device library assistant for the app "Complete Control."
            You help build a library of MIDI devices and command macros.
            """
        if !deviceSummary.isEmpty {
            prompt += "\nKnown devices: \(deviceSummary)."
        }
        prompt += """

            CORRECTION OVERRIDE (highest priority): If the user explicitly states a field value, use it exactly.
            For each request respond with ONE action. Respond ONLY with a JSON object — no markdown, no explanation.
            Schema:
            {
              "actionType": "new_device" | "new_macro",
              "deviceName": "string",
              "manufacturer": "string or null",
              "midiChannel": integer 1-16,
              "categoryName": "string or null",
              "macroName": "string or null",
              "msbValue": integer 0-127 or null,
              "lsbValue": integer 0-127 or null,
              "pcValue": integer 0-127 or null,
              "ccNumber": integer 0-127 or null,
              "ccValue": integer 0-127 or null,
              "oscAddress": "string or null",
              "oscFloatArg": number or null
            }
            new_device: fill deviceName, manufacturer (if known), midiChannel; all macro fields null.
            new_macro: fill deviceName (existing or new), categoryName, macroName, and the MIDI/OSC fields.
            """
        return prompt
    }

    private func extractJSON(from text: String) -> String {
        if let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") {
            return String(text[start...end])
        }
        return text
    }

    // MARK: - Core Data

    private func addAction(_ action: ParsedLibraryAction, messageID: UUID) {
        switch action.kind {
        case .createDevice(let name, let mfr, let ch):
            let _ = InstrumentDevice.create(name: name, manufacturer: mfr, midiChannel: ch, in: viewContext)

        case .addMacro(let devName, let catName, let macro):
            let device = instruments.first(where: { $0.name.lowercased() == devName.lowercased() })
                ?? InstrumentDevice.create(name: devName, manufacturer: nil, midiChannel: 1, in: viewContext)
            let category = device.categories.first(where: { $0.name.lowercased() == catName.lowercased() })
                ?? MacroCategory.create(name: catName, orderIndex: device.categories.count, device: device, in: viewContext)
            let m = DeviceMacro.create(
                name: macro.name,
                channel: device.midiChannel,
                delayMilliseconds: 50,
                orderIndex: category.macros.count,
                msbValue: macro.msbValue, lsbValue: macro.lsbValue,
                pcValue: macro.pcValue, ccNumber: macro.ccNumber, ccValue: macro.ccValue,
                isOSC: macro.oscAddress != nil,
                oscAddress: macro.oscAddress, oscFloatArg: macro.oscFloatArg,
                in: viewContext
            )
            m.category = category
        }
        try? viewContext.save()
        chatSession.savedIDs.insert(messageID)
    }
}
