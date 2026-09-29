//
//  ReferenceInputSheet.swift
//  Midi Set List
//
//  AI builds a structured reference file from a manual excerpt:
//   • .paste    — straight to pasting text
//   • .generate — pick a source: pasted text, a file, or an attached file
//  Both can instead save the text as-is (no AI); that's the only option when
//  no AI is available.
//

import SwiftUI
import UniformTypeIdentifiers

struct ReferenceInputSheet: View {
    enum Mode: String, Identifiable {
        case paste, generate
        var id: String { rawValue }
    }

    let device: InstrumentDevice
    let mode: Mode
    /// Called with the saved file, plus a review note for AI-generated files
    let onSaved: (DeviceSpecFile, _ reviewNote: String?) -> Void

    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var ai = AISettings.shared

    private enum Source: String, CaseIterable, Identifiable {
        case paste = "Paste", file = "File", attached = "Attached"
        var id: String { rawValue }
    }

    @State private var text = ""
    @State private var source: Source = .paste
    @State private var showingFilePicker = false
    @State private var loadedFrom: String?
    @State private var isWorking = false
    @State private var isGenerating = false
    @State private var errorMessage: String?

    private var trimmedText: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canGenerate: Bool { ai.isAvailable(.specAnalysis) }

    var body: some View {
        NavigationStack {
            Form {
                if ai.offlineMode && canGenerate {
                    OfflineModeBanner().listRowInsets(EdgeInsets())
                }

                if mode == .generate {
                    Section {
                        Picker("Source", selection: $source) {
                            ForEach(availableSources) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                    } header: {
                        Text("Source")
                    } footer: {
                        Text("A manual excerpt or MIDI implementation chart. Photos and screenshots are read with on-device text recognition.")
                    }
                }

                sourceSection

                if canGenerate {
                    Section {
                        Label(providerDescription, systemImage: ai.provider(for: .specAnalysis).icon)
                            .font(.subheadline)
                        if isTooLongForOnDevice {
                            Label("This is long for on-device AI (\(text.count) characters). Paste a smaller section, or use Claude or ChatGPT.",
                                  systemImage: "exclamationmark.triangle.fill")
                                .font(.caption).foregroundStyle(.orange)
                        }
                    } footer: {
                        Text("The result opens for review. Items marked (VERIFY) or NOT IN SPEC need checking against the manual.")
                    }

                    Section {
                        Button {
                            Task { await submit(generate: false) }
                        } label: {
                            Label("Save as-is (no AI)", systemImage: "square.and.arrow.down")
                        }
                        .disabled(trimmedText.isEmpty)
                    } footer: {
                        Text("For text that's already a clean reference — saves it exactly as it is.")
                    }
                }
            }
            .disabled(isWorking)
            .overlay { if isWorking { workingOverlay } }
            .navigationTitle(mode == .paste ? "Paste Reference Text" : "Generate Reference")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(isWorking)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(canGenerate ? "Generate" : "Save") {
                        Task { await submit(generate: canGenerate) }
                    }
                    .fontWeight(.semibold)
                    .disabled(trimmedText.isEmpty || isWorking)
                }
            }
            .fileImporter(
                isPresented: $showingFilePicker,
                allowedContentTypes: [.pdf, .plainText, .text, .image],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    load(from: url.lastPathComponent) { try SpecTextExtractor.text(from: url) }
                case .failure(let error):
                    errorMessage = error.localizedDescription
                }
            }
            .alert("Couldn't Continue", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                if let errorMessage { Text(errorMessage) }
            }
            .onChange(of: source) {
                // Each source starts fresh so text from one never leaks into another
                text = ""
                loadedFrom = nil
            }
        }
        .interactiveDismissDisabled(isWorking)
    }

    // MARK: - Source input

    private var availableSources: [Source] {
        device.specFiles.isEmpty ? [.paste, .file] : Source.allCases
    }

    @ViewBuilder
    private var sourceSection: some View {
        switch (mode, source) {
        case (.paste, _), (.generate, .paste):
            Section {
                TextEditor(text: $text)
                    .font(.system(.caption, design: .monospaced))
                    .frame(minHeight: 220)
                Button {
                    if let clip = UIPasteboard.general.string { text = clip }
                } label: {
                    Label("Paste from Clipboard", systemImage: "doc.on.clipboard")
                }
            } header: {
                Text("Text")
            } footer: {
                if !text.isEmpty { Text("\(text.count) characters") }
            }

        case (.generate, .file):
            Section {
                Button {
                    showingFilePicker = true
                } label: {
                    Label(loadedFrom == nil ? "Choose PDF, Text or Image…" : "Choose a Different File…",
                          systemImage: "folder")
                }
                loadedPreview
            } header: {
                Text("File")
            }

        case (.generate, .attached):
            Section {
                ForEach(device.specFiles) { file in
                    Button {
                        load(from: file.displayName) { try readAttached(file) }
                    } label: {
                        HStack {
                            Image(systemName: "doc.text")
                            Text(file.displayName).foregroundStyle(.primary)
                            Spacer()
                            if loadedFrom == file.displayName {
                                Image(systemName: "checkmark").foregroundStyle(.tint)
                            }
                        }
                    }
                }
                loadedPreview
            } header: {
                Text("Attached Files")
            } footer: {
                Text("Turns a raw attached manual into a structured reference. The original stays attached — delete it afterwards if you don't need both.")
            }
        }
    }

    @ViewBuilder
    private var loadedPreview: some View {
        if let loadedFrom, !text.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Label("\(loadedFrom) · \(text.count) characters", systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green)
                Text(String(text.prefix(300)) + (text.count > 300 ? "…" : ""))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(6)
            }
        }
    }

    private var workingOverlay: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(isGenerating ? "Building reference file…" : "Saving…")
                .font(.subheadline.weight(.medium))
            if isGenerating {
                Text("Long manuals can take a minute.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private var providerDescription: String {
        let provider = ai.provider(for: .specAnalysis)
        return "Uses \(provider.displayName) · change in Settings → Build Reference File"
    }

    private var isTooLongForOnDevice: Bool {
        ai.provider(for: .specAnalysis) == .onDevice && text.count > SpecGenerator.onDeviceCharacterLimit
    }

    // MARK: - Actions

    private func load(from sourceName: String, _ read: () throws -> String) {
        do {
            text = try read()
            loadedFrom = sourceName
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func readAttached(_ file: DeviceSpecFile) throws -> String {
        guard let content = DeviceSpecManager.extractText(file),
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw SpecTextExtractor.ExtractError.unreadable(file.displayName) }
        return content
    }

    @MainActor
    private func submit(generate: Bool) async {
        isWorking = true
        isGenerating = generate
        defer { isWorking = false; isGenerating = false }
        do {
            if !generate {
                // Save exactly as given — named after where it came from
                let base = loadedFrom.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent }
                let file = try attach(markdown: trimmedText, named: base ?? "\(device.name) Notes")
                onSaved(file, nil)
            } else {
                let output = try await SpecGenerator.generate(deviceName: device.name, sourceText: trimmedText)
                let file = try attach(markdown: output.markdown, named: "\(device.name) Reference")
                let note = output.truncated
                    ? "AI-generated, but the model ran out of room and the end is missing. Review it, or try a smaller section."
                    : "AI-generated from your spec. Check anything marked (VERIFY) or NOT IN SPEC before relying on it."
                onSaved(file, note)
            }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func attach(markdown: String, named rawName: String) throws -> DeviceSpecFile {
        var displayName = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        if displayName.isEmpty { displayName = "\(device.name) Notes" }
        let lower = displayName.lowercased()
        if !lower.hasSuffix(".md") && !lower.hasSuffix(".txt") { displayName += ".md" }

        let file = try DeviceSpecManager.save(data: Data(markdown.utf8), displayName: displayName)
        device.addSpecFile(file)
        do {
            try viewContext.save()
        } catch {
            DeviceSpecManager.delete(file)
            throw error
        }
        return file
    }
}
