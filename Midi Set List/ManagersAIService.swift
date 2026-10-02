//
//  AIService.swift
//  Midi Set List
//

import Combine
import Foundation
import FoundationModels
import Network
import Security

// MARK: - ParsedMacro (common output for both on-device and external AI paths)

struct ParsedMacro: Decodable {
    var name: String
    var msbValue: Int?
    var lsbValue: Int?
    var pcValue: Int?
    var ccNumber: Int?
    var ccValue: Int?
    var oscAddress: String?
    var oscFloatArg: Double?
}

extension ParsedMacro {
    init(_ g: GeneratedSingleMacro) {
        name = g.name; msbValue = g.msbValue; lsbValue = g.lsbValue
        pcValue = g.pcValue; ccNumber = g.ccNumber; ccValue = g.ccValue
        oscAddress = g.oscAddress; oscFloatArg = g.oscFloatArg
    }

    init(_ g: GeneratedMIDIMacro) {
        name = g.name; msbValue = g.msbValue; lsbValue = g.lsbValue
        pcValue = g.pcValue; ccNumber = g.ccNumber; ccValue = g.ccValue
    }
}

// MARK: - Anthropic model info (fetched live from API)

struct AnthropicModelInfo: Identifiable, Decodable {
    let id: String
    let displayName: String

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
    }

    static let fallbacks: [AnthropicModelInfo] = [
        AnthropicModelInfo(id: "claude-haiku-4-5-20251001", displayName: "Claude Haiku 4.5"),
        AnthropicModelInfo(id: "claude-sonnet-4-6",         displayName: "Claude Sonnet 4.6"),
        AnthropicModelInfo(id: "claude-opus-4-8",           displayName: "Claude Opus 4.8"),
    ]
}

// MARK: - Provider type

enum AIProviderType: String, CaseIterable, Identifiable {
    case onDevice, openAI, anthropic
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .onDevice:  return "On-Device"
        case .openAI:    return "ChatGPT"
        case .anthropic: return "Claude"
        }
    }
    var icon: String {
        switch self {
        case .onDevice:  return "iphone"
        case .openAI:    return "brain"
        case .anthropic: return "sparkles"
        }
    }
}

// MARK: - Task type (one routing slot per AI feature)

enum AITask: String, CaseIterable {
    case macroChat        = "task_macro_chat"
    case libraryChat      = "task_library_chat"
    case specAnalysis     = "task_spec_analysis"
    case macroGeneration  = "task_macro_generation"
    case bulkCheck        = "task_bulk_check"
    case bulkSplit        = "task_bulk_split"
    case setListAssistant = "task_set_list_assistant"
    case songDetails      = "task_song_details"

    var displayName: String {
        switch self {
        case .macroChat:       return "Macro Chat (wand)"
        case .libraryChat:     return "Device Library AI (wand)"
        case .specAnalysis:    return "Build Reference File"
        case .macroGeneration: return "Generate Macros"
        case .bulkCheck:       return "Detect Bulk Requests"
        case .bulkSplit:       return "Split Bulk Requests"
        case .setListAssistant: return "Set List Assistant"
        case .songDetails:     return "Song Details (Shortcut)"
        }
    }
}

// MARK: - Keychain

enum AppKeychain {
    private static let service = "com.midisetlist.apikeys"

    static func save(_ value: String, for key: String) {
        let data = Data(value.utf8)
        var q: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service, kSecAttrAccount: key
        ]
        SecItemDelete(q as CFDictionary)
        q[kSecValueData] = data
        q[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(q as CFDictionary, nil)
    }

    static func load(for key: String) -> String? {
        let q: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service, kSecAttrAccount: key,
            kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(for key: String) {
        let q: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service, kSecAttrAccount: key
        ]
        SecItemDelete(q as CFDictionary)
    }
}

// MARK: - Settings

class AISettings: ObservableObject {
    static let shared = AISettings()

    // Per-task routing — stored as raw string in UserDefaults
    @Published var routing: [AITask: AIProviderType] = [:] {
        didSet { saveRouting() }
    }

    // Triggers UI refresh when a key is saved or cleared
    @Published var keyVersion: Int = 0

    // Offline mode — set automatically when the device has no network connection.
    // While offline, every AI task falls back to the on-device model regardless of
    // the routing or Anthropic model chosen; normal routing resumes when back online.
    @Published private(set) var offlineMode = false
    private let pathMonitor = NWPathMonitor()

    var openAIKey: String? {
        get { AppKeychain.load(for: "openai_api_key") }
        set { updateKey(newValue, for: "openai_api_key") }
    }
    var anthropicKey: String? {
        get { AppKeychain.load(for: "anthropic_api_key") }
        set { updateKey(newValue, for: "anthropic_api_key") }
    }
    var anthropicWorkspaceID: String? {
        get { AppKeychain.load(for: "anthropic_workspace_id") }
        set { updateKey(newValue, for: "anthropic_workspace_id") }
    }
    var hasOpenAIKey: Bool { openAIKey != nil }
    var hasAnthropicKey: Bool { anthropicKey != nil }
    var hasAnthropicWorkspaceID: Bool { anthropicWorkspaceID != nil }

    // Per-task model selection (defaults to Sonnet)
    func anthropicModel(for task: AITask) -> String {
        let dict = UserDefaults.standard.dictionary(forKey: "anthropic_task_models") as? [String: String] ?? [:]
        return dict[task.rawValue] ?? "claude-sonnet-4-6"
    }
    func setAnthropicModel(_ modelID: String, for task: AITask) {
        var dict = UserDefaults.standard.dictionary(forKey: "anthropic_task_models") as? [String: String] ?? [:]
        dict[task.rawValue] = modelID
        UserDefaults.standard.set(dict, forKey: "anthropic_task_models")
        objectWillChange.send()
    }

    // Per-task thinking toggle (defaults to OFF)
    func thinkingEnabled(for task: AITask) -> Bool {
        let dict = UserDefaults.standard.dictionary(forKey: "anthropic_task_thinking") as? [String: Bool] ?? [:]
        return dict[task.rawValue] ?? false
    }
    func setThinkingEnabled(_ enabled: Bool, for task: AITask) {
        var dict = UserDefaults.standard.dictionary(forKey: "anthropic_task_thinking") as? [String: Bool] ?? [:]
        dict[task.rawValue] = enabled
        UserDefaults.standard.set(dict, forKey: "anthropic_task_thinking")
        objectWillChange.send()
    }

    @Published var availableAnthropicModels: [AnthropicModelInfo] = AnthropicModelInfo.fallbacks

    func fetchAnthropicModels() async {
        guard !offlineMode, let key = anthropicKey else { return }
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/models")!)
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        if let wid = anthropicWorkspaceID { req.setValue(wid, forHTTPHeaderField: "anthropic-workspace-id") }
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["data"] as? [[String: Any]] else { return }
        let models = items.compactMap { item -> AnthropicModelInfo? in
            guard let id = item["id"] as? String,
                  let name = item["display_name"] as? String else { return nil }
            return AnthropicModelInfo(id: id, displayName: name)
        }
        guard !models.isEmpty else { return }
        await MainActor.run { self.availableAnthropicModels = models }
    }

    // Returns the configured provider, falling back to on-device if no key.
    // Without Apple Intelligence, falls back to whichever external provider has a key.
    // No connection always wins and routes to on-device.
    func provider(for task: AITask) -> AIProviderType {
        if offlineMode { return .onDevice }
        let selected = routing[task, default: .onDevice]
        switch selected {
        case .openAI    where hasOpenAIKey:    return .openAI
        case .anthropic where hasAnthropicKey: return .anthropic
        default:
            if !onDeviceAvailable {
                if hasAnthropicKey { return .anthropic }
                if hasOpenAIKey    { return .openAI }
            }
            return .onDevice
        }
    }

    // MARK: Availability — AI surfaces are hidden when nothing can run them

    /// Apple Intelligence is supported and enabled on this device
    var onDeviceAvailable: Bool { SystemLanguageModel.default.isAvailable }

    /// Some AI could run here: Apple Intelligence, or a ChatGPT / Claude key
    var anyAIAvailable: Bool { onDeviceAvailable || hasOpenAIKey || hasAnthropicKey }

    /// The provider this task resolves to can actually run right now
    func isAvailable(_ task: AITask) -> Bool {
        provider(for: task) != .onDevice || onDeviceAvailable
    }

    func setProvider(_ provider: AIProviderType, for task: AITask) {
        routing[task] = provider
    }

    private func saveRouting() {
        var dict: [String: String] = [:]
        for (task, provider) in routing { dict[task.rawValue] = provider.rawValue }
        UserDefaults.standard.set(dict, forKey: "ai_task_routing")
    }

    private func updateKey(_ value: String?, for key: String) {
        if let v = value, !v.trimmingCharacters(in: .whitespaces).isEmpty {
            AppKeychain.save(v.trimmingCharacters(in: .whitespaces), for: key)
        } else {
            AppKeychain.delete(for: key)
        }
        DispatchQueue.main.async { self.keyVersion += 1 }
    }

    private init() {
        var loaded: [AITask: AIProviderType] = [:]
        if let dict = UserDefaults.standard.dictionary(forKey: "ai_task_routing") as? [String: String] {
            for (k, v) in dict {
                if let task = AITask(rawValue: k), let prov = AIProviderType(rawValue: v) {
                    loaded[task] = prov
                }
            }
        }
        routing = loaded

        pathMonitor.pathUpdateHandler = { [weak self] path in
            let offline = path.status != .satisfied
            DispatchQueue.main.async {
                guard let self, self.offlineMode != offline else { return }
                self.offlineMode = offline
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "com.midisetlist.network-monitor"))
    }
}

// MARK: - External AI message

struct ExternalAIMessage {
    let role: String    // "user" | "assistant"
    let content: String
}

// MARK: - AI response with token usage

struct AIResponse {
    let text: String
    let inputTokens: Int
    let outputTokens: Int
    let modelID: String
    /// True when the model stopped because it hit the output limit (the text is cut off)
    var truncated = false

    func cost() -> Double {
        let rates = AIPricing.rates(for: modelID)
        return (Double(inputTokens) * rates.input + Double(outputTokens) * rates.output) / 1_000_000
    }
}

// MARK: - Pricing (USD per million tokens, standard API rates)

enum AIPricing {
    /// Checked in order — more specific model IDs first.
    /// Estimates only: excludes prompt caching and batch discounts.
    private static let table: [(match: String, input: Double, output: Double)] = [
        ("fable",       10.00, 50.00),
        ("mythos",      10.00, 50.00),
        ("opus-5-5",     4.00, 20.00),
        ("opus-5",       5.00, 25.00),
        ("opus-4-8",     5.00, 25.00),
        ("opus-4-7",     5.00, 25.00),
        ("opus-4-6",     5.00, 25.00),
        ("opus-4-5",     5.00, 25.00),
        ("opus",        15.00, 75.00),   // Opus 4 / 4.1 and older
        ("sonnet-5",     2.00, 10.00),   // Sonnet 5 and 5.5
        ("sonnet",       3.00, 15.00),   // Sonnet 4.x
        ("haiku-4-5",    1.00,  5.00),
        ("haiku-3-5",    0.80,  4.00),
        ("haiku",        0.25,  1.25),
        ("gpt-4o-mini",  0.15,  0.60),
        ("gpt-4o",       2.50, 10.00),
    ]

    static func rates(for modelID: String) -> (input: Double, output: Double) {
        let id = modelID.lowercased()
        if let row = table.first(where: { id.contains($0.match) }) { return (row.input, row.output) }
        return (3.00, 15.00)   // unknown model — mid-range estimate
    }
}

// MARK: - External AI client

enum ExternalAIClient {

    static func chat(
        provider: AIProviderType,
        apiKey: String,
        systemPrompt: String,
        messages: [ExternalAIMessage],
        workspaceID: String? = nil,
        anthropicModelID: String = "claude-sonnet-4-6",
        anthropicThinking: Bool = false,
        maxOutputTokens: Int? = nil
    ) async throws -> AIResponse {
        // Fail fast with no connection so callers can fall back to on-device
        guard !AISettings.shared.offlineMode else { throw ExternalAIError.noConnection }
        let response: AIResponse
        switch provider {
        case .openAI:    response = try await openAI(apiKey: apiKey, system: systemPrompt, messages: messages, maxTokens: maxOutputTokens)
        case .anthropic: response = try await anthropic(apiKey: apiKey, workspaceID: workspaceID, modelID: anthropicModelID, thinking: anthropicThinking, system: systemPrompt, messages: messages, maxTokens: maxOutputTokens)
        case .onDevice:  throw ExternalAIError.notConfigured
        }
        // Every paid request, from every feature, goes through here
        AICostLedger.shared.record(response)
        return response
    }

    /// Long outputs (e.g. a full reference file) can take well over the 60s default
    private static let requestTimeout: TimeInterval = 300

    private static func openAI(apiKey: String, system: String, messages: [ExternalAIMessage], maxTokens: Int?) async throws -> AIResponse {
        var msgs: [[String: String]] = [["role": "system", "content": system]]
        msgs += messages.map { ["role": $0.role, "content": $0.content] }
        let modelID = "gpt-4o-mini"
        var body: [String: Any] = ["model": modelID, "messages": msgs]
        if let maxTokens { body["max_tokens"] = maxTokens }
        var req = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        req.timeoutInterval = requestTimeout
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: req)
        try validate(response, data: data)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choice = (json["choices"] as? [[String: Any]])?.first,
              let content = (choice["message"] as? [String: Any])?["content"] as? String
        else { throw ExternalAIError.parseError }
        let usage = json["usage"] as? [String: Any]
        return AIResponse(
            text: content,
            inputTokens: usage?["prompt_tokens"] as? Int ?? 0,
            outputTokens: usage?["completion_tokens"] as? Int ?? 0,
            modelID: modelID,
            truncated: choice["finish_reason"] as? String == "length"
        )
    }

    private static func anthropic(apiKey: String, workspaceID: String?, modelID: String, thinking: Bool, system: String, messages: [ExternalAIMessage], maxTokens: Int?) async throws -> AIResponse {
        // Thinking shares the output budget, so it always gets at least 16k
        let limit = thinking ? max(16000, maxTokens ?? 0) : (maxTokens ?? 2048)
        var body: [String: Any] = [
            "model": modelID,
            "max_tokens": limit,
            "system": system,
            "messages": messages.map { ["role": $0.role, "content": $0.content] }
        ]
        if thinking {
            body["thinking"] = ["type": "adaptive"]
            body["output_config"] = ["effort": "high"]
        }
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.timeoutInterval = requestTimeout
        req.httpMethod = "POST"
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let wid = workspaceID { req.setValue(wid, forHTTPHeaderField: "anthropic-workspace-id") }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: req)
        try validate(response, data: data)
        let raw = String(data: data, encoding: .utf8) ?? "<unreadable>"
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let blocks = json["content"] as? [[String: Any]],
              let text = blocks.first(where: { $0["type"] as? String == "text" })?["text"] as? String
        else { throw ExternalAIError.apiError("Unexpected response body: \(raw.prefix(400))") }
        let usage = json["usage"] as? [String: Any]
        return AIResponse(
            text: text,
            inputTokens: usage?["input_tokens"] as? Int ?? 0,
            outputTokens: usage?["output_tokens"] as? Int ?? 0,
            modelID: modelID,
            truncated: json["stop_reason"] as? String == "max_tokens"
        )
    }

    private static func validate(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw ExternalAIError.parseError }
        guard http.statusCode == 200 else {
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { ($0["error"] as? [String: Any])?["message"] as? String }
                ?? String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw ExternalAIError.apiError(msg)
        }
    }
}

// MARK: - Errors

enum ExternalAIError: Error, LocalizedError {
    case notConfigured
    case apiError(String)
    case parseError
    case noConnection

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "No external AI provider configured. Add an API key in Settings."
        case .apiError(let msg): return "API error: \(msg)"
        case .parseError:        return "Could not parse the AI response. Try again."
        case .noConnection:      return "No internet connection — Claude and ChatGPT are unavailable."
        }
    }

    /// True for errors caused by a missing or dropped connection, where falling back
    /// to the on-device model makes sense.
    static func isConnectivity(_ error: Error) -> Bool {
        if case ExternalAIError.noConnection = error { return true }
        guard let urlError = error as? URLError else { return false }
        let codes: [URLError.Code] = [
            .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost,
            .cannotFindHost, .dnsLookupFailed, .timedOut,
            .internationalRoamingOff, .dataNotAllowed
        ]
        return codes.contains(urlError.code)
    }
}
