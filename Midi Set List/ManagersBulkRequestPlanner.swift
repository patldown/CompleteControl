//
//  BulkRequestPlanner.swift
//  Midi Set List
//
//  Detects when one macro chat request asks for several macros and rewrites it
//  into a list of standalone single-macro requests.
//
//  1. isMultiAction — yes/no check, using the provider routed for
//                     "Detect Bulk Requests" in Settings.
//  2. splitActions  — orchestrator that rewrites the request into the full,
//                     ordered action list, using the provider routed for
//                     "Split Bulk Requests" in Settings.
//

import Foundation
import FoundationModels

// MARK: - On-device structured output types

@Generable
struct MultiActionCheck {
    @Guide(description: "True only if the request asks for MORE THAN ONE separate macro.")
    var hasMultipleActions: Bool
}

@Generable
struct SplitActionList {
    @Guide(description: "One standalone request per macro, in the same order as the original request.")
    var actions: [String]
}

// MARK: - Planner

enum BulkRequestPlanner {

    struct Context {
        let deviceName: String
        let midiChannel: Int
        let categoryName: String
    }

    private static let macroDefinition = """
        A macro is ONE command set for a device: a bank select (MSB/LSB) plus program change \
        together is ONE macro; one CC message is ONE macro; one OSC message is ONE macro.
        """

    /// Yes/no check on the provider routed for "Detect Bulk Requests".
    /// Returns false (send as one) if that model is unavailable or fails.
    static func isMultiAction(_ request: String, context: Context) async -> Bool {
        let ai = AISettings.shared
        let provider = ai.provider(for: .bulkCheck)
        let instructions = """
            You classify requests sent to a MIDI/OSC macro assistant.
            Device: \(context.deviceName). Category: \(context.categoryName).
            \(macroDefinition)
            Answer true only if the request clearly asks for more than one macro, e.g. \
            "load presets 1 to 5", "reverb on and delay off", "mute channels 1, 2 and 3".
            Answer false for a single macro, a question, or a correction to a previous \
            result (e.g. "LSB should be 2").
            """

        func checkOnDevice() async -> Bool {
            guard SystemLanguageModel.default.isAvailable else { return false }
            let session = LanguageModelSession(instructions: instructions)
            return (try? await session.respond(to: request, generating: MultiActionCheck.self)
                .content.hasMultipleActions) ?? false
        }

        guard provider != .onDevice,
              let apiKey = provider == .openAI ? ai.openAIKey : ai.anthropicKey
        else { return await checkOnDevice() }

        do {
            let response = try await ExternalAIClient.chat(
                provider: provider,
                apiKey: apiKey,
                systemPrompt: instructions + """

                    Respond ONLY with a JSON object — no markdown fences, no explanation:
                    {"multiple": true} or {"multiple": false}
                    """,
                messages: [ExternalAIMessage(role: "user", content: request)],
                workspaceID: provider == .anthropic ? ai.anthropicWorkspaceID : nil,
                anthropicModelID: ai.anthropicModel(for: .bulkCheck),
                anthropicThinking: ai.thinkingEnabled(for: .bulkCheck)
            )
            return decodeMultiple(from: response.text)
        } catch let error where ExternalAIError.isConnectivity(error) {
            // Connection dropped mid-request — check on-device instead
            return await checkOnDevice()
        } catch {
            return false
        }
    }

    private struct CheckPayload: Decodable { let multiple: Bool }

    private static func decodeMultiple(from text: String) -> Bool {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"),
              let data = String(text[start...end]).data(using: .utf8),
              let payload = try? JSONDecoder().decode(CheckPayload.self, from: data)
        else { return false }
        return payload.multiple
    }

    /// Orchestrator: rewrites a multi-action request into standalone single-macro requests.
    static func splitActions(_ request: String, context: Context) async throws -> [String] {
        let ai = AISettings.shared
        let provider = ai.provider(for: .bulkSplit)
        let instructions = """
            You split a request sent to a MIDI/OSC macro assistant into separate requests, one per macro.
            Device: \(context.deviceName), MIDI channel \(context.midiChannel). Category: \(context.categoryName).
            \(macroDefinition)
            Rules:
            - Keep the exact order the user gave. Expand ranges ("presets 1 to 3" → three requests).
            - Each request must stand alone: repeat any shared details (bank, channel, values) in every one.
            - Do not add, drop, or invent actions. Keep each request short, in the user's wording.
            """

        func splitOnDevice() async throws -> [String] {
            let session = LanguageModelSession(instructions: instructions)
            return try await session.respond(to: request, generating: SplitActionList.self).content.actions
        }

        let actions: [String]
        if provider == .onDevice {
            actions = try await splitOnDevice()
        } else {
            guard let apiKey = provider == .openAI ? ai.openAIKey : ai.anthropicKey
            else { throw ExternalAIError.notConfigured }
            do {
                let response = try await ExternalAIClient.chat(
                    provider: provider,
                    apiKey: apiKey,
                    systemPrompt: instructions + """

                        Respond ONLY with a JSON object — no markdown fences, no explanation:
                        {"actions": ["first request", "second request"]}
                        """,
                    messages: [ExternalAIMessage(role: "user", content: request)],
                    workspaceID: provider == .anthropic ? ai.anthropicWorkspaceID : nil,
                    anthropicModelID: ai.anthropicModel(for: .bulkSplit),
                    anthropicThinking: ai.thinkingEnabled(for: .bulkSplit)
                )
                actions = try decodeActions(from: response.text)
            } catch let error where ExternalAIError.isConnectivity(error) && SystemLanguageModel.default.isAvailable {
                // Connection dropped mid-request — split on-device instead
                actions = try await splitOnDevice()
            }
        }

        return actions
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private struct ActionsPayload: Decodable { let actions: [String] }

    private static func decodeActions(from text: String) throws -> [String] {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"),
              let data = String(text[start...end]).data(using: .utf8),
              let payload = try? JSONDecoder().decode(ActionsPayload.self, from: data)
        else { throw ExternalAIError.apiError("Could not read the action list. Model returned: \(text.prefix(300))") }
        return payload.actions
    }
}
