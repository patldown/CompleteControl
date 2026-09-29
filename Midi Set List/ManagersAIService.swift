//
//  AIService.swift
//  Midi Set List
//

import Combine
import Foundation
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
    case macroChat       = "task_macro_chat"
    case specAnalysis    = "task_spec_analysis"
    case macroGeneration = "task_macro_generation"
    case bulkCheck       = "task_bulk_check"
    case bulkSplit       = "task_bulk_split"

    var displayName: String {
        switch self {
        case .macroChat:       return "Macro Chat (wand)"
        case .specAnalysis:    return "Build Reference File"
        case .macroGeneration: return "Generate Macros"
        case .bulkCheck:       return "Detect Bulk Requests"
        case .bulkSplit:       return "Split Bulk Requests"
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
    // No connection always wins and routes to on-device.
    func provider(for task: AITask) -> AIProviderType {
        if offlineMode { return .onDevice }
        let selected = routing[task, default: .onDevice]
        switch selected {
        case .openAI    where hasOpenAIKey:    return .openAI
        case .anthropic where hasAnthropicKey: return .anthropic
        default: return .onDevice
        }
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

    func cost() -> Double {
        // Approximate pricing per million tokens; best-effort by model family
        let id = modelID.lowercased()
        let (inRate, outRate): (Double, Double)
        if id.contains("opus")   { inRate = 15.0;  outRate = 75.0  }
        else if id.contains("sonnet") { inRate = 3.0;   outRate = 15.0  }
        else                     { inRate = 0.80;  outRate = 4.0   } // haiku / unknown
        return (Double(inputTokens) * inRate + Double(outputTokens) * outRate) / 1_000_000
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
        anthropicThinking: Bool = false
    ) async throws -> AIResponse {
        // Fail fast with no connection so callers can fall back to on-device
        guard !AISettings.shared.offlineMode else { throw ExternalAIError.noConnection }
        switch provider {
        case .openAI:    return try await openAI(apiKey: apiKey, system: systemPrompt, messages: messages)
        case .anthropic: return try await anthropic(apiKey: apiKey, workspaceID: workspaceID, modelID: anthropicModelID, thinking: anthropicThinking, system: systemPrompt, messages: messages)
        case .onDevice:  throw ExternalAIError.notConfigured
        }
    }

    private static func openAI(apiKey: String, system: String, messages: [ExternalAIMessage]) async throws -> AIResponse {
        var msgs: [[String: String]] = [["role": "system", "content": system]]
        msgs += messages.map { ["role": $0.role, "content": $0.content] }
        let modelID = "gpt-4o-mini"
        let body: [String: Any] = ["model": modelID, "messages": msgs]
        var req = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: req)
        try validate(response, data: data)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = ((json["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String
        else { throw ExternalAIError.parseError }
        let usage = json["usage"] as? [String: Any]
        return AIResponse(
            text: content,
            inputTokens: usage?["prompt_tokens"] as? Int ?? 0,
            outputTokens: usage?["completion_tokens"] as? Int ?? 0,
            modelID: modelID
        )
    }

    private static func anthropic(apiKey: String, workspaceID: String?, modelID: String, thinking: Bool, system: String, messages: [ExternalAIMessage]) async throws -> AIResponse {
        var body: [String: Any] = [
            "model": modelID,
            "max_tokens": thinking ? 16000 : 2048,
            "system": system,
            "messages": messages.map { ["role": $0.role, "content": $0.content] }
        ]
        if thinking {
            body["thinking"] = ["type": "adaptive"]
            body["output_config"] = ["effort": "high"]
        }
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
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
            modelID: modelID
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
