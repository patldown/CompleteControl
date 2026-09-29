//
//  AnalyzeDeviceSpecIntent.swift
//  Midi Set List
//
//  Stage 1 of the two-stage AI pipeline:
//    1. This intent: raw spec (text/image) → structured .md reference file → attached to device
//    2. GenerateMacrosIntent: reads the .md → builds accurate macros
//

import AppIntents
import CoreData
import Foundation
import FoundationModels
import UIKit
import Vision

// MARK: - Intent

struct AnalyzeDeviceSpecIntent: AppIntent {
    static let title: LocalizedStringResource = "Analyze Device Spec"
    static let description = IntentDescription(
        "Uses on-device AI to analyze a MIDI or OSC device specification (pasted text or a photo) and generates a structured Markdown reference file. This file is saved to the device and automatically used by Generate Macros with AI to build accurate macros."
    )

    @Parameter(title: "Device", description: "The instrument device to generate a reference spec for.")
    var device: DeviceEntity

    @Parameter(title: "Spec Text", description: "Paste text from the device manual or MIDI implementation chart.")
    var specText: String?

    @Parameter(title: "Spec Image", description: "Photo or screenshot of the spec sheet or MIDI implementation table.")
    var specImage: IntentFile?

    func perform() async throws -> some IntentResult & ProvidesDialog {
        // 1. Collect input text (from parameter or OCR)
        var inputText = specText ?? ""
        if let image = specImage, inputText.isEmpty {
            if let uiImage = UIImage(data: image.data), let cgImage = uiImage.cgImage {
                inputText = try extractText(from: cgImage)
            }
        }

        guard !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AnalyzeSpecError.noInput
        }

        // 2. Check for existing spec files — confirm replace if any exist
        let existingFiles: [DeviceSpecFile] = await MainActor.run {
            let ctx = PersistenceController.shared.viewContext
            let req = NSFetchRequest<InstrumentDevice>(entityName: "InstrumentDevice")
            req.predicate = NSPredicate(format: "id == %@", device.id as CVarArg)
            req.fetchLimit = 1
            return (try? ctx.fetch(req).first?.specFiles) ?? []
        }

        if !existingFiles.isEmpty {
            let count = existingFiles.count
            let noun = count == 1 ? "file" : "files"
            try await requestConfirmation(
                actionName: .`continue`,
                dialog: "\(device.name) already has \(count) reference \(noun). Replace with the new AI-generated spec?"
            )
            // User confirmed — delete existing files
            await MainActor.run {
                let ctx = PersistenceController.shared.viewContext
                let req = NSFetchRequest<InstrumentDevice>(entityName: "InstrumentDevice")
                req.predicate = NSPredicate(format: "id == %@", device.id as CVarArg)
                req.fetchLimit = 1
                if let instrumentDevice = try? ctx.fetch(req).first {
                    for file in instrumentDevice.specFiles { DeviceSpecManager.delete(file) }
                    instrumentDevice.specFileNamesData = nil
                    try? ctx.save()
                }
            }
        }

        // 3. Run on-device AI with the structured instruction template
        guard SystemLanguageModel.default.isAvailable else {
            throw AnalyzeSpecError.aiNotAvailable
        }

        let session = LanguageModelSession(instructions: Self.instructionTemplate)
        let prompt = """
        Device: \(device.name)

        Raw specification to analyze:
        \(inputText)
        """

        let mdContent: String
        do {
            let response = try await session.respond(to: prompt)
            mdContent = response.content
        } catch {
            throw AnalyzeSpecError.generationFailed(error.localizedDescription)
        }

        // 4. Save as .md and attach to device
        let filename = "\(device.name) Reference.md"
        try await MainActor.run {
            let specFile = try DeviceSpecManager.save(
                data: Data(mdContent.utf8),
                displayName: filename
            )
            let ctx = PersistenceController.shared.viewContext
            let req = NSFetchRequest<InstrumentDevice>(entityName: "InstrumentDevice")
            req.predicate = NSPredicate(format: "id == %@", device.id as CVarArg)
            req.fetchLimit = 1
            guard let instrumentDevice = try ctx.fetch(req).first else {
                DeviceSpecManager.delete(specFile)
                throw AnalyzeSpecError.deviceNotFound(device.name)
            }
            instrumentDevice.addSpecFile(specFile)
            try ctx.save()
        }

        return .result(dialog: "Generated '\(filename)' and attached it to \(device.name). Run Generate Macros with AI to build macros from this spec.")
    }

    // MARK: - OCR helper

    private func extractText(from cgImage: CGImage) throws -> String {
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

    // Shared with GetSpecPromptIntent — single source of truth
    private static var instructionTemplate: String { GetSpecPromptIntent.instructionTemplate }
}

// MARK: - Errors

enum AnalyzeSpecError: Error, LocalizedError {
    case noInput
    case aiNotAvailable
    case deviceNotFound(String)
    case generationFailed(String)

    var errorDescription: String? {
        switch self {
        case .noInput:
            return "Please provide either a spec image or pasted text from the device manual."
        case .aiNotAvailable:
            return "Apple Intelligence is not available. Requires iPhone 15 Pro or iPhone 16+ with iOS 18.1+ and Apple Intelligence enabled."
        case .deviceNotFound(let name):
            return "No device named '\(name)' found in your library. Create it first in the Instruments tab."
        case .generationFailed(let reason):
            return "AI generation failed: \(reason)"
        }
    }
}
