//
//  DeviceSpecIntents.swift
//  Midi Set List
//
//  Three intents for attaching and building device spec reference files:
//    GetSpecPromptIntent     — returns the system prompt for use with external LLMs
//    AttachDeviceSpecIntent  — manually attaches a file or pasted text to a device
//    AnalyzeDeviceSpecIntent — uses on-device AI to build a structured .md reference
//
//  Two-stage AI pipeline:
//    Stage 1 (AnalyzeDeviceSpecIntent): raw spec → structured .md → attached to device
//    Stage 2 (GenerateMacrosIntent):    reads the .md → builds accurate macros
//

import AppIntents
import CoreData
import Foundation
import FoundationModels
import UIKit
import Vision

// MARK: - Get Reference Builder System Prompt

struct GetSpecPromptIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Reference Builder System Prompt"
    static let description = IntentDescription(
        "Returns the v2 system prompt used to generate a structured MIDI reference file. Use it as the system prompt in any LLM shortcut (ChatGPT, Claude, etc.), with your raw spec pages as the user message. Optionally include spec text to get a combined ready-to-send prompt."
    )

    @Parameter(
        title: "Spec Text",
        description: "Optional. If provided, the output combines the system prompt and your spec text into one ready-to-send message. Leave empty to get just the system prompt."
    )
    var specText: String?

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        let trimmed = specText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let output: String
        let dialog: String

        if trimmed.isEmpty {
            output = Self.instructionTemplate
            dialog = "System prompt ready. Use it as the system/instruction prompt in your LLM shortcut, with your raw spec as the user message."
        } else {
            output = """
            \(Self.instructionTemplate)

            ---

            \(trimmed)
            """
            dialog = "Combined prompt ready. Send this directly to your LLM shortcut, then use 'Attach Device Spec' to save the response."
        }

        return .result(value: output, dialog: IntentDialog(stringLiteral: dialog))
    }

    // Single source of truth — also used by AnalyzeDeviceSpecIntent
    static let instructionTemplate = """
    Build a Markdown MIDI reference for a small local LLM that will generate MIDI messages for a device.

    The LLM can only output: MSB, LSB, PC, and CC number + value, with a channel. \
    Formatting and sending are handled elsewhere; don't describe them.

    ## Hard rules

    1. Use ONLY facts written in the attached spec. No outside knowledge, no "typical" MIDI behavior, \
       no inferences.
    2. If the spec doesn't cover something, write NOT IN SPEC in that spot. Never fill a gap with a guess.
    3. Any value meaning not stated word-for-word in the spec (e.g. "0 = off, 127 = on") gets (VERIFY).
    4. Exclude NRPN, SysEx, and any parameter written with colons (e.g. 2:43).
    5. Copy CC numbers exactly. Before finishing, re-check every CC number against the spec.
    6. Anything the LLM can't output (e.g. MIDI Start/Stop real-time messages, clock) goes under \
       NOT CONTROLLABLE unless the spec gives a CC for it.
    7. If a parameter needs two or more CCs sent together, list them in ONE row with the required \
       order (e.g. 106 then 107).
    8. For trigger commands (fill, transition, tap, pause, etc.), state the value to send from the \
       spec, or mark (VERIFY).
    9. If any selection or value needs math (program numbers, BPM, folder numbers), use a complete \
       lookup table if it has 128 rows or fewer. If larger, write APP CONVERTS and list the inputs \
       the app needs (e.g. APP CONVERTS: folder, song). Never output a formula.
    10. Follow the template below exactly: same headings, same order, same table columns. \
        Add nothing else.

    ## Template

    # [Device] — MIDI Reference
    <!-- Excluded: [list] | VERIFY: [list] | NOT IN SPEC: [list] -->

    Allowed outputs: MSB, LSB, PC, CC number + value (0–127), channel (1–16).

    ## CONFIG
    - GLOBAL_CH = [from spec, or NOT IN SPEC]

    ## PROGRAM / SONG SELECTION
    Rule: [one sentence from spec, or NOT IN SPEC]

    | Program | MSB | LSB | PC |
    |---|---|---|---|
    [every slot, or APP CONVERTS: inputs, or NOT IN SPEC]

    ## NOT CONTROLLABLE — DO NOT GENERATE
    [items, or NOT IN SPEC]
    If asked, reply: UNSUPPORTED

    ## CC TABLE
    Use ONLY CC numbers listed here. If not listed, reply UNSUPPORTED.

    | Parameter | CC (send order) | Values |
    |---|---|---|
    [rows grouped by section; paired CCs in one row; math values = APP CONVERTS]

    ---

    After the file, list briefly:
    - Which spec pages you used for selection and for the CC table
    - Every NOT IN SPEC, VERIFY, and APP CONVERTS item
    """
}

// MARK: - Attach Device Spec File

struct AttachDeviceSpecIntent: AppIntent {
    static let title: LocalizedStringResource = "Attach Device Spec File"
    static let description = IntentDescription(
        "Attaches a MIDI or OSC specification to an instrument device. Provide either a file (PDF, text, markdown) or paste/type raw text — a .md file will be created from the text automatically. The AI macro generator will use this reference when creating macros for the device."
    )

    @Parameter(title: "Device", description: "The instrument device to attach the spec to.")
    var device: DeviceEntity

    @Parameter(title: "Spec File", description: "Optional. A PDF or text file containing the device's MIDI or OSC specification. Use this OR Spec Text — not both.")
    var file: IntentFile?

    @Parameter(title: "Spec Text", description: "Optional. Paste or type the spec content directly. A .md file will be created and attached automatically. Use this OR Spec File — not both.")
    var specText: String?

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let deviceID = device.id
        let deviceName = device.name

        let data: Data
        let displayName: String

        if let f = file {
            data = f.data
            displayName = f.filename
        } else if let text = specText?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            guard let encoded = text.data(using: .utf8) else {
                throw DeviceSpecError.encodingFailed
            }
            data = encoded
            displayName = "\(device.name) Spec.md"
        } else {
            throw DeviceSpecError.noInput
        }

        try await MainActor.run {
            let specFile = try DeviceSpecManager.save(data: data, displayName: displayName)
            let ctx = PersistenceController.shared.viewContext
            let request = NSFetchRequest<InstrumentDevice>(entityName: "InstrumentDevice")
            request.predicate = NSPredicate(format: "id == %@", deviceID as CVarArg)
            request.fetchLimit = 1
            guard let instrumentDevice = try ctx.fetch(request).first else {
                DeviceSpecManager.delete(specFile)
                throw DeviceSpecError.deviceNotFound(deviceName)
            }
            instrumentDevice.addSpecFile(specFile)
            try ctx.save()
        }

        return .result(dialog: "Attached '\(displayName)' to \(device.name). The AI will use this as reference when generating macros.")
    }
}

enum DeviceSpecError: Error, LocalizedError {
    case deviceNotFound(String)
    case noInput
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .deviceNotFound(let name):
            return "No device named '\(name)' found in your library. Create it first in the Instruments tab or using the Create Instrument shortcut."
        case .noInput:
            return "Please provide either a Spec File or Spec Text."
        case .encodingFailed:
            return "Could not encode the spec text. Make sure the text is valid UTF-8."
        }
    }
}

// MARK: - Analyze Device Spec (on-device AI)

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
        var inputText = specText ?? ""
        if let image = specImage, inputText.isEmpty {
            if let uiImage = UIImage(data: image.data), let cgImage = uiImage.cgImage {
                inputText = try extractText(from: cgImage)
            }
        }

        guard !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AnalyzeSpecError.noInput
        }

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

        guard SystemLanguageModel.default.isAvailable else {
            throw AnalyzeSpecError.aiNotAvailable
        }

        let session = LanguageModelSession(instructions: GetSpecPromptIntent.instructionTemplate)
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
}

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
