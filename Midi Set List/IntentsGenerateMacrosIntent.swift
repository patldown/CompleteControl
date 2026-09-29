//
//  GenerateMacrosIntent.swift
//  Midi Set List
//
//  Uses FoundationModels (Apple Intelligence) to generate DeviceMacro objects
//  from a MIDI implementation table supplied as text or an image (OCR via Vision).
//

import AppIntents
import CoreData
import FoundationModels
import Vision
import UIKit

// MARK: - Generable types for structured output

@Generable
struct GeneratedMacroSet {
    @Guide(description: "A short category name that groups these macros (e.g. Patches, Scenes, Snapshots)")
    var categoryName: String

    @Guide(description: "All MIDI macros extracted from the table")
    var macros: [GeneratedMacroItem]
}

@Generable
struct GeneratedMacroItem {
    @Guide(description: "Human-readable name for this patch, preset, or parameter (e.g. Clean, Drive, Scene 1)")
    var name: String

    @Guide(description: "Bank Select LSB value 0-127. Set to nil if this patch does not require Bank Select LSB.")
    var lsbValue: Int?

    @Guide(description: "Bank Select MSB value 0-127. Set to nil if this patch does not require Bank Select MSB.")
    var msbValue: Int?

    @Guide(description: "Program Change number 0-127. Set to nil if no Program Change is needed.")
    var pcValue: Int?

    @Guide(description: "Control Change CC number 0-127. Set to nil if no CC message is needed.")
    var ccNumber: Int?

    @Guide(description: "Control Change value 0-127. Set when ccNumber is provided, otherwise nil.")
    var ccValue: Int?
}

// MARK: - Intent

struct GenerateMacrosIntent: AppIntent {
    static let title: LocalizedStringResource = "Generate Macros from MIDI Table"
    static let description = IntentDescription(
        "Uses on-device AI to read a MIDI implementation table and create macro commands for an instrument in your library. Provide the device, a category name, and either a MIDI table image or pasted text."
    )

    @Parameter(title: "Device", description: "The instrument to add macros to — must already exist in your library.")
    var device: DeviceEntity

    @Parameter(title: "Category Name", description: "Name for the new macro category (e.g. Patches, Scenes).", default: "Generated")
    var categoryName: String

    @Parameter(title: "MIDI Table Image", description: "Screenshot or photo of a MIDI implementation chart. The shortcut will OCR the text automatically.")
    var image: IntentFile?

    @Parameter(title: "MIDI Table Text", description: "Paste the MIDI table as plain text if you don't have an image.")
    var tableText: String?

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<MacroCategoryEntity> {
        // 1. Collect text input
        var inputText = tableText ?? ""

        if let image, inputText.isEmpty {
            let imageData = image.data
            if let uiImage = UIImage(data: imageData), let cgImage = uiImage.cgImage {
                inputText = try extractText(from: cgImage)
            }
        }

        // Load any spec files attached to this device for additional AI context
        let specContext: String = (try? await MainActor.run {
            let ctx = PersistenceController.shared.viewContext
            let request = NSFetchRequest<InstrumentDevice>(entityName: "InstrumentDevice")
            request.predicate = NSPredicate(format: "id == %@", device.id as CVarArg)
            request.fetchLimit = 1
            guard let instrumentDevice = try ctx.fetch(request).first else { return "" }
            return DeviceSpecManager.specContext(for: instrumentDevice)
        }) ?? ""

        let hasInput = !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasSpec  = !specContext.isEmpty
        guard hasInput || hasSpec else {
            throw GenerateMacrosError.noInput
        }

        // 2. Run on-device AI
        guard SystemLanguageModel.default.isAvailable else {
            throw GenerateMacrosError.aiNotAvailable
        }

        let session = LanguageModelSession(
            instructions: "You are a MIDI expert. Extract every distinct patch, preset, scene, or parameter entry from the provided MIDI implementation table and return them as structured macros. Use PC for Program Change entries, CC for Control Change entries, MSB for Bank Select MSB, LSB for Bank Select LSB."
        )

        var promptParts = ["Device: \(device.name)", "Category hint: \(categoryName)"]
        if hasSpec  { promptParts.append("\nDevice Reference Manual:\n\(specContext)") }
        if hasInput { promptParts.append("\nMIDI table:\n\(inputText)") }
        let prompt = promptParts.joined(separator: "\n")

        let response = try await session.respond(to: prompt, generating: GeneratedMacroSet.self)
        let generated = response.content

        // 3. Save to Core Data
        let deviceID = device.id
        let deviceName = device.name
        let catName = categoryName
        let generatedItems = generated.macros
        let finalCategoryName = generated.categoryName.isEmpty ? catName : generated.categoryName

        let entity = try await MainActor.run {
            let ctx = PersistenceController.shared.viewContext
            let request = NSFetchRequest<InstrumentDevice>(entityName: "InstrumentDevice")
            request.predicate = NSPredicate(format: "id == %@", deviceID as CVarArg)
            request.fetchLimit = 1
            guard let instrumentDevice = try ctx.fetch(request).first else {
                throw GenerateMacrosError.deviceNotFound(deviceName)
            }

            let category = MacroCategory.create(
                name: finalCategoryName,
                orderIndex: instrumentDevice.categories.count,
                device: instrumentDevice,
                in: ctx
            )

            for (index, item) in generatedItems.enumerated() {
                let macro = DeviceMacro.create(
                    name: item.name,
                    channel: instrumentDevice.midiChannel,
                    delayMilliseconds: 50,
                    orderIndex: index,
                    msbValue: item.msbValue,
                    lsbValue: item.lsbValue,
                    pcValue: item.pcValue,
                    ccNumber: item.ccNumber,
                    ccValue: item.ccValue,
                    in: ctx
                )
                macro.category = category
            }

            try ctx.save()

            return MacroCategoryEntity(
                id: category.id,
                name: finalCategoryName,
                deviceID: instrumentDevice.id,
                deviceName: instrumentDevice.name
            )
        }

        let count = generatedItems.count
        return .result(value: entity, dialog: "Created \(count) macro\(count == 1 ? "" : "s") in '\(finalCategoryName)' for \(device.name).")
    }

    // MARK: - Helpers

    private func extractText(from cgImage: CGImage) throws -> String {
        var recognized: [String] = []
        var recognitionError: Error?

        let request = VNRecognizeTextRequest { request, error in
            if let error {
                recognitionError = error
                return
            }
            recognized = (request.results as? [VNRecognizedTextObservation])?.compactMap {
                $0.topCandidates(1).first?.string
            } ?? []
        }
        request.recognitionLevel = .accurate

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])

        if let error = recognitionError { throw error }
        return recognized.joined(separator: "\n")
    }
}

// MARK: - Errors

enum GenerateMacrosError: Error, LocalizedError {
    case noInput
    case aiNotAvailable
    case deviceNotFound(String)

    var errorDescription: String? {
        switch self {
        case .noInput:
            return "Please provide a MIDI table image, pasted text, or attach a spec file to the device in the Instruments tab."
        case .aiNotAvailable:
            return "Apple Intelligence is not available on this device. Requires iPhone 15 Pro or iPhone 16+ running iOS 18.1 or later with Apple Intelligence enabled."
        case .deviceNotFound(let name):
            return "No device named '\(name)' was found in your library. Create it first using the Create Instrument shortcut or the Instruments tab."
        }
    }
}
