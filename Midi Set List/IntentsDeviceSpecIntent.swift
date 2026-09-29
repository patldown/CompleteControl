//
//  DeviceSpecIntent.swift
//  Midi Set List
//

import AppIntents
import CoreData
import Foundation

// MARK: - Attach Device Spec Intent

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
            // File takes priority
            data = f.data
            displayName = f.filename
        } else if let text = specText?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            // Create a .md from the raw text
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

// MARK: - Errors

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
