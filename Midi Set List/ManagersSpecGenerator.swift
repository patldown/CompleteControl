//
//  SpecGenerator.swift
//  Midi Set List
//
//  In-app version of the "Analyze Device Spec" shortcut: turns a raw manual
//  excerpt (pasted text, PDF, text file or photo) into the structured Markdown
//  reference file the macro AI reads. Uses the "Build Reference File" routing.
//

import Foundation
import FoundationModels
import PDFKit
import UIKit
import UniformTypeIdentifiers
import Vision

// MARK: - Text extraction (pasted text, PDF, text file, image)

enum SpecTextExtractor {

    enum ExtractError: LocalizedError {
        case unreadable(String)
        var errorDescription: String? {
            switch self {
            case .unreadable(let name): return "Couldn't read any text from \(name)."
            }
        }
    }

    /// Reads text from a file picked in Files. Images go through on-device text recognition.
    static func text(from url: URL) throws -> String {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        let type = UTType(filenameExtension: url.pathExtension)
        let text: String?
        if type?.conforms(to: .pdf) == true {
            text = PDFDocument(url: url)?.string
        } else if type?.conforms(to: .image) == true {
            let data = try Data(contentsOf: url)
            text = UIImage(data: data)?.cgImage.flatMap { try? recognizeText(in: $0) }
        } else {
            text = try? String(contentsOf: url, encoding: .utf8)
        }

        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw ExtractError.unreadable(url.lastPathComponent) }
        return text
    }

    /// On-device OCR (Vision) — works offline and without Apple Intelligence.
    static func recognizeText(in cgImage: CGImage) throws -> String {
        var recognized: [String] = []
        var recognitionError: Error?
        let request = VNRecognizeTextRequest { request, error in
            if let error { recognitionError = error; return }
            recognized = (request.results as? [VNRecognizedTextObservation])?.compactMap {
                $0.topCandidates(1).first?.string
            } ?? []
        }
        request.recognitionLevel = .accurate
        try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
        if let error = recognitionError { throw error }
        return recognized.joined(separator: "\n")
    }
}

// MARK: - Generator

enum SpecGenerator {

    struct Output {
        let markdown: String
        /// The model hit its output limit, so the end of the file is missing
        let truncated: Bool
    }

    /// Rough size above which the on-device model's small context window is likely to overflow
    static let onDeviceCharacterLimit = 9_000

    static func generate(deviceName: String, sourceText: String) async throws -> Output {
        let ai = AISettings.shared
        let provider = ai.provider(for: .specAnalysis)
        let instructions = GetSpecPromptIntent.instructionTemplate
        let prompt = """
            Device: \(deviceName)

            Raw specification to analyze:
            \(sourceText)
            """

        func generateOnDevice() async throws -> Output {
            guard ai.onDeviceAvailable else { throw ExternalAIError.apiError("On-device AI is not available.") }
            guard sourceText.count <= onDeviceCharacterLimit else {
                throw ExternalAIError.apiError("This spec is too long for on-device AI (\(sourceText.count) characters, limit about \(onDeviceCharacterLimit)). Paste a smaller section, or route \"Build Reference File\" to Claude or ChatGPT in Settings.")
            }
            let session = LanguageModelSession(instructions: instructions)
            let response = try await session.respond(to: prompt)
            return Output(markdown: cleaned(response.content), truncated: false)
        }

        guard provider != .onDevice else { return try await generateOnDevice() }
        guard let apiKey = provider == .openAI ? ai.openAIKey : ai.anthropicKey
        else { throw ExternalAIError.notConfigured }

        do {
            let response = try await ExternalAIClient.chat(
                provider: provider,
                apiKey: apiKey,
                systemPrompt: instructions,
                messages: [ExternalAIMessage(role: "user", content: prompt)],
                workspaceID: provider == .anthropic ? ai.anthropicWorkspaceID : nil,
                anthropicModelID: ai.anthropicModel(for: .specAnalysis),
                anthropicThinking: ai.thinkingEnabled(for: .specAnalysis),
                maxOutputTokens: 12_000   // a full reference file is long
            )
            return Output(markdown: cleaned(response.text), truncated: response.truncated)
        } catch let error where ExternalAIError.isConnectivity(error) && ai.onDeviceAvailable {
            return try await generateOnDevice()
        }
    }

    /// Strips a ```markdown fence if the model wrapped its whole answer in one
    private static func cleaned(_ text: String) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("```") {
            if let firstNewline = t.firstIndex(of: "\n") { t = String(t[t.index(after: firstNewline)...]) }
            if t.hasSuffix("```") { t = String(t.dropLast(3)) }
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
