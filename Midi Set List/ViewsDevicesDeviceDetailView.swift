//
//  DeviceDetailView.swift
//  Midi Set List
//

import SwiftUI
import CoreData
import UniformTypeIdentifiers
import FoundationModels

struct DeviceDetailView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @ObservedObject var device: InstrumentDevice
    @ObservedObject private var ai = AISettings.shared

    @State private var showingAddCategory = false
    @State private var showingEditDevice = false
    @State private var newCategoryName = ""
    @State private var showingFilePicker = false
    @State private var importError: String?
    @State private var showingImportError = false
    @State private var viewingSpecFile: DeviceSpecFile?
    @State private var referenceInputMode: ReferenceInputSheet.Mode?
    /// A file just added from the paste/generate sheet, opened once that sheet closes
    @State private var pendingReview: (file: DeviceSpecFile, note: String?)?
    /// Review note shown on the viewer for a freshly AI-generated file
    @State private var reviewNotes: [String: String] = [:]
    @State private var showingMemory = false
    @State private var showingClearMemoryConfirm = false
    @State private var memoryExists = false

    var body: some View {
        List {
            Section {
                LabeledContent("MIDI Channel", value: "Channel \(device.midiChannel)")
                if let manufacturer = device.manufacturer, !manufacturer.isEmpty {
                    LabeledContent("Manufacturer", value: manufacturer)
                }
            }

            Section("Macro Categories") {
                if device.sortedCategories.isEmpty {
                    Text("No categories yet — tap + to add one")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                } else {
                    ForEach(device.sortedCategories) { category in
                        NavigationLink(destination: MacrosListView(category: category, device: device)) {
                            HStack {
                                Image(systemName: "folder.fill")
                                    .foregroundStyle(.orange)
                                Text(category.name)
                                Spacer()
                                Text("\(category.macros.count)")
                                    .foregroundStyle(.secondary)
                                    .font(.caption)
                            }
                        }
                    }
                    .onDelete(perform: deleteCategories)
                }
            }

            // AI-only sections: hidden (never deleted) when no AI can use them
            if ai.isAvailable(.macroChat) {
                Section {
                    if device.specFiles.isEmpty {
                        Text("No spec files attached")
                            .foregroundStyle(.secondary)
                            .font(.subheadline)
                    } else {
                        ForEach(device.specFiles) { file in
                            Button { viewingSpecFile = file } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: file.filename.lowercased().hasSuffix(".pdf")
                                          ? "doc.richtext.fill" : "doc.text.fill")
                                        .foregroundStyle(.blue)
                                        .frame(width: 24)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(file.displayName)
                                            .font(.subheadline)
                                            .foregroundStyle(.primary)
                                        Text(file.filename.lowercased().hasSuffix(".pdf") ? "PDF" : "Text")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(.vertical, 2)
                            }
                            .buttonStyle(.plain)
                        }
                        .onDelete(perform: deleteSpecFiles)
                    }

                    Button {
                        showingFilePicker = true
                    } label: {
                        Label("Attach Spec File", systemImage: "doc.badge.plus")
                    }

                    Button {
                        referenceInputMode = .paste
                    } label: {
                        Label("Paste Reference Text", systemImage: "doc.on.clipboard")
                    }

                    if ai.isAvailable(.specAnalysis) {
                        Button {
                            referenceInputMode = .generate
                        } label: {
                            Label("Generate Reference with AI", systemImage: "sparkles")
                                .foregroundStyle(ai.offlineMode ? Color.offlineMode : .accentColor)
                        }
                    }
                } header: {
                    Text("Reference Files")
                } footer: {
                    Text("Attach or paste MIDI/OSC specifications, or have AI turn a manual excerpt into a structured reference. The AI macro generator automatically uses these as context for this device.")
                }

                Section {
                    if ai.offlineMode {
                        OfflineModeBanner(detail: "AI features for this device run on-device")
                            .listRowInsets(EdgeInsets())
                    }
                    if memoryExists {
                        Button { showingMemory = true } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "brain.head.profile")
                                    .foregroundStyle(.purple)
                                    .frame(width: 24)
                                Text("View Device Memory")
                                    .font(.subheadline)
                                    .foregroundStyle(.primary)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption).foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 2)
                        }
                        .buttonStyle(.plain)

                        Button(role: .destructive) {
                            showingClearMemoryConfirm = true
                        } label: {
                            Label("Clear Device Memory", systemImage: "trash")
                                .font(.subheadline)
                        }
                    } else {
                        Text("No memory yet — use \"Save to Memory\" in the macro chat to record corrections.")
                            .foregroundStyle(.secondary)
                            .font(.subheadline)
                    }
                } header: {
                    HStack {
                        Text("AI Memory")
                        if ai.offlineMode {
                            Spacer()
                            OfflineModeBadge()
                        }
                    }
                } footer: {
                    Text("Corrections saved from the macro chat are always injected into future AI sessions for this device.")
                }
            }
        }
        .onAppear { memoryExists = DeviceSpecManager.hasMemory(for: device) }
        .navigationTitle(device.name)
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showingAddCategory = true } label: {
                    Image(systemName: "folder.badge.plus")
                }
            }
            ToolbarItem(placement: .navigationBarLeading) {
                Button("Edit") { showingEditDevice = true }
            }
        }
        .alert("New Category", isPresented: $showingAddCategory) {
            TextField("Category name", text: $newCategoryName)
            Button("Add") { addCategory() }
            Button("Cancel", role: .cancel) { newCategoryName = "" }
        } message: {
            Text("e.g. Patch Selection, Scenes, Snapshots")
        }
        .alert("Import Failed", isPresented: $showingImportError) {
            Button("OK", role: .cancel) {}
        } message: {
            if let error = importError { Text(error) }
        }
        .sheet(isPresented: $showingEditDevice) {
            AddEditDeviceView(device: device)
        }
        .sheet(item: $viewingSpecFile) { file in
            SpecFileViewerSheet(
                file: file,
                reviewNote: reviewNotes[file.id],
                onDiscard: {
                    DeviceSpecManager.delete(file)
                    device.removeSpecFile(file)
                    try? viewContext.save()
                    reviewNotes[file.id] = nil
                },
                onReviewed: { reviewNotes[file.id] = nil }
            )
        }
        .sheet(item: $referenceInputMode, onDismiss: {
            // Open the new file for review once the input sheet has closed
            guard let pending = pendingReview else { return }
            pendingReview = nil
            if let note = pending.note { reviewNotes[pending.file.id] = note }
            viewingSpecFile = pending.file
        }) { mode in
            ReferenceInputSheet(device: device, mode: mode) { file, note in
                pendingReview = (file, note)
            }
        }
        .sheet(isPresented: $showingMemory, onDismiss: { memoryExists = DeviceSpecManager.hasMemory(for: device) }) {
            DeviceMemorySheet(device: device)
        }
        .confirmationDialog("Clear AI Memory?", isPresented: $showingClearMemoryConfirm, titleVisibility: .visible) {
            Button("Clear Memory", role: .destructive) {
                DeviceSpecManager.clearMemory(for: device)
                memoryExists = false
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes all saved corrections for \(device.name). The AI will no longer have this learned context.")
        }
        .fileImporter(
            isPresented: $showingFilePicker,
            allowedContentTypes: [.pdf, .plainText],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                importSpecFile(url: url)
            case .failure(let error):
                importError = error.localizedDescription
                showingImportError = true
            }
        }
    }

    private func addCategory() {
        let trimmed = newCategoryName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let _ = MacroCategory.create(name: trimmed, orderIndex: device.categories.count,
                                      device: device, in: viewContext)
        try? viewContext.save()
        newCategoryName = ""
    }

    private func deleteCategories(at offsets: IndexSet) {
        let sorted = device.sortedCategories
        for index in offsets { viewContext.delete(sorted[index]) }
        try? viewContext.save()
    }

    private func importSpecFile(url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            let specFile = try DeviceSpecManager.save(data: data, displayName: url.lastPathComponent)
            device.addSpecFile(specFile)
            try viewContext.save()
        } catch {
            importError = error.localizedDescription
            showingImportError = true
        }
    }

    private func deleteSpecFiles(at offsets: IndexSet) {
        let files = device.specFiles
        for index in offsets {
            DeviceSpecManager.delete(files[index])
            device.removeSpecFile(files[index])
        }
        try? viewContext.save()
    }
}

// MARK: - Device memory viewer

private struct DeviceMemorySheet: View {
    let device: InstrumentDevice
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var ai = AISettings.shared
    @State private var content: String = ""
    @State private var copied = false
    @State private var isEditing = false
    @State private var isCompacting = false
    @State private var compactError: String? = nil
    /// Set while reviewing a compaction result; the saved file is untouched until "Keep"
    @State private var originalBeforeCompact: String? = nil

    private var isReviewing: Bool { originalBeforeCompact != nil }

    var body: some View {
        NavigationStack {
            Group {
                if isEditing {
                    TextEditor(text: $content)
                        .font(.system(.caption, design: .monospaced))
                        .padding(.horizontal, 12)
                } else {
                    ScrollView {
                        Text(content.isEmpty ? "No memory entries yet." : content)
                            .font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                    }
                }
            }
            .navigationTitle("\(device.name) Memory")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        if isEditing { saveEdits() }
                        dismiss()
                    }
                    .disabled(isReviewing)  // choose Keep or Discard first
                }
                ToolbarItem(placement: .primaryAction) {
                    HStack(spacing: 16) {
                        Button {
                            UIPasteboard.general.string = content
                            withAnimation { copied = true }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                withAnimation { copied = false }
                            }
                        } label: {
                            Label(copied ? "Copied!" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                                .foregroundStyle(copied ? .green : .accentColor)
                        }
                        .disabled(copied || isEditing || content.isEmpty)

                        Button {
                            if isEditing { saveEdits() }
                            isEditing.toggle()
                        } label: {
                            Label(isEditing ? "Lock" : "Edit", systemImage: isEditing ? "lock.fill" : "pencil")
                                .foregroundStyle(isEditing ? .orange : .accentColor)
                        }
                        .disabled(isReviewing)
                    }
                }
            }
            .interactiveDismissDisabled(isReviewing)
            .safeAreaInset(edge: .top) {
                if ai.offlineMode { OfflineModeBanner() }
            }
            .safeAreaInset(edge: .bottom) {
                if isReviewing {
                    reviewBar
                } else if !isEditing && !content.isEmpty && canCompact {
                    Button {
                        Task { await compactMemory() }
                    } label: {
                        HStack(spacing: 8) {
                            if isCompacting {
                                ProgressView().scaleEffect(0.8)
                                Text("Working out lessons…")
                            } else {
                                Image(systemName: ai.offlineMode ? "wifi.slash" : "lightbulb")
                                Text(ai.offlineMode ? "Turn into Lessons (On-Device)" : "Turn into Lessons Learned")
                            }
                        }
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(ai.offlineMode ? Color.offlineMode : .primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                        .offlineModeOutline(ai.offlineMode, cornerRadius: 12)
                        .padding(.horizontal)
                        .padding(.bottom, 4)
                    }
                    .disabled(isCompacting)
                    .buttonStyle(.plain)
                }
            }
        }
        .onAppear { content = DeviceSpecManager.memoryContent(for: device) }
        .alert("Compact Failed", isPresented: Binding(
            get: { compactError != nil },
            set: { if !$0 { compactError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            if let err = compactError { Text(err) }
        }
    }

    private func saveEdits() {
        try? content.write(to: DeviceSpecManager.memoryFileURL(for: device), atomically: true, encoding: .utf8)
    }

    private var reviewBar: some View {
        VStack(spacing: 8) {
            Text("Review the lessons — edit if needed. Your original memory is kept until you tap Keep.")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 12) {
                Button(role: .destructive) {
                    if let original = originalBeforeCompact { content = original }
                    originalBeforeCompact = nil
                    isEditing = false
                } label: {
                    Label("Discard", systemImage: "arrow.uturn.backward")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    saveEdits()
                    originalBeforeCompact = nil
                    isEditing = false
                } label: {
                    Label("Keep", systemImage: "checkmark")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
            .controlSize(.large)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func compactOnDevice(systemPrompt: String) async throws -> String {
        let session = LanguageModelSession(instructions: systemPrompt)
        return try await session.respond(to: content).content
    }

    /// Compact runs on Claude/ChatGPT when online, or on-device when offline.
    /// The button is hidden when neither can run it.
    private var canCompact: Bool {
        ai.offlineMode ? ai.onDeviceAvailable : ai.provider(for: .macroChat) != .onDevice
    }

    @MainActor
    private func compactMemory() async {
        let provider = ai.provider(for: .macroChat)
        let apiKey = provider == .openAI ? ai.openAIKey : ai.anthropicKey
        if ai.offlineMode {
            guard SystemLanguageModel.default.isAvailable else {
                compactError = "No internet connection, and on-device AI needs Apple Intelligence on this device. Reconnect to compact with Claude or ChatGPT."
                return
            }
        } else if provider == .onDevice || apiKey == nil {
            compactError = "Compact requires an external AI provider. Configure Claude or ChatGPT in Settings → Task Routing → Macro Chat."
            return
        }

        isCompacting = true
        defer { isCompacting = false }

        do {
            let text: String
            if ai.offlineMode {
                text = try await compactOnDevice(systemPrompt: lessonsPrompt(onDevice: true))
            } else {
                do {
                    text = try await ExternalAIClient.chat(
                        provider: provider,
                        apiKey: apiKey ?? "",
                        systemPrompt: lessonsPrompt(onDevice: false),
                        messages: [ExternalAIMessage(role: "user", content: content)],
                        workspaceID: provider == .anthropic ? ai.anthropicWorkspaceID : nil,
                        anthropicModelID: ai.anthropicModel(for: .macroChat),
                        anthropicThinking: ai.thinkingEnabled(for: .macroChat)
                    ).text
                } catch let error where ExternalAIError.isConnectivity(error) && SystemLanguageModel.default.isAvailable {
                    // Connection dropped mid-request — fall back to on-device
                    text = try await compactOnDevice(systemPrompt: lessonsPrompt(onDevice: true))
                }
            }
            // Nothing is saved yet — the user reviews, then keeps or discards
            originalBeforeCompact = content
            content = text.trimmingCharacters(in: .whitespacesAndNewlines)
            isEditing = true
        } catch {
            compactError = error.localizedDescription
        }
    }

    /// Turns raw chat corrections into lessons learned: a rule the assistant can
    /// apply to new requests, the reason behind it, and a concrete example.
    private func lessonsPrompt(onDevice: Bool) -> String {
        var spec = DeviceSpecManager.specFilesContext(for: device)
        // The on-device model has a small context window — keep the spec excerpt short
        if onDevice && spec.count > 4000 { spec = String(spec.prefix(4000)) + "\n[spec truncated]" }

        var prompt = """
            You maintain the AI memory for "\(device.name)" (MIDI channel \(device.midiChannel)) \
            in the app "Midi Set List". The memory is read by an AI assistant before it builds \
            MIDI/OSC macros for this device.

            The raw memory is a log of chat moments the user saved: what they asked ("You:"), \
            what the AI got wrong ("Previous:"), and the values they confirmed ("Confirmed:").

            Turn it into LESSONS LEARNED the assistant can apply to NEW requests — not a shorter log. \
            For each lesson, work out the underlying rule from the evidence: why was the first answer \
            wrong, and what pattern does the correction reveal (e.g. an off-by-one numbering scheme, \
            a bank that needs LSB instead of MSB, a naming convention the user prefers)?
            """
        if !spec.isEmpty {
            prompt += """


                Compare against the device reference spec below. When the memory contradicts the spec, \
                say so explicitly ("The spec says X, but on this unit it is Y"). Drop entries that only \
                repeat what the spec already states correctly.

                DEVICE SPEC:
                \(spec)
                """
        }
        prompt += """


            Output format (Markdown, nothing else — no fences, no preamble):

            # \(device.name) — Lessons Learned

            ## <Topic, e.g. Bank select, Program numbers, Effects CCs, Naming>
            - **Lesson:** <a general rule, phrased as an instruction for next time>
              **Why:** <what went wrong and what the user confirmed — the evidence>
              **Example:** "<the user's wording>" → <confirmed values, e.g. MSB 0, LSB 2, PC 12>

            ## Confirmed values
            - <macro name> → <values>   (quick reference, one line each)

            Rules:
            - Every lesson must make sense on its own, without the original chat.
            - Never drop a confirmed value — if it doesn't fit a lesson, keep it under Confirmed values.
            - Merge duplicates. If a later correction overrides an earlier one, keep only the latest.
            - Don't invent reasons. If the cause isn't clear from the evidence, write \
            "**Why:** Not stated — confirmed by the user." rather than guessing.
            - Group related lessons under the same topic. Skip empty sections.
            - The memory may already contain an earlier "Lessons Learned" section followed by new \
            raw entries. Keep the existing lessons and fold the new evidence into them — update, \
            strengthen or correct a lesson rather than duplicating it.
            """
        return prompt
    }
}

// MARK: - Spec file content viewer

private struct SpecFileViewerSheet: View {
    let file: DeviceSpecFile
    /// Set for a freshly AI-generated file: shows a review banner
    var reviewNote: String? = nil
    var onDiscard: (() -> Void)? = nil
    var onReviewed: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var copied = false
    @State private var isEditing = false
    @State private var editedContent: String = ""
    @State private var reviewed = false

    private var savedContent: String {
        DeviceSpecManager.extractText(file) ?? "(Unable to read file)"
    }

    /// PDFs are shown as extracted text; saving that text back would corrupt the PDF
    private var isEditable: Bool { !file.filename.lowercased().hasSuffix(".pdf") }

    var body: some View {
        NavigationStack {
            Group {
                if isEditing {
                    TextEditor(text: $editedContent)
                        .font(.system(.caption, design: .monospaced))
                        .padding(.horizontal, 12)
                } else {
                    ScrollView {
                        Text(editedContent)
                            .font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                    }
                }
            }
            .navigationTitle(file.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        if isEditing { saveEdits() }
                        dismiss()
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    HStack(spacing: 16) {
                        Button {
                            UIPasteboard.general.string = editedContent
                            withAnimation { copied = true }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                withAnimation { copied = false }
                            }
                        } label: {
                            Label(
                                copied ? "Copied!" : "Copy",
                                systemImage: copied ? "checkmark" : "doc.on.doc"
                            )
                            .foregroundStyle(copied ? .green : .accentColor)
                        }
                        .disabled(copied || isEditing)

                        if isEditable {
                            Button {
                                if isEditing { saveEdits() }
                                isEditing.toggle()
                            } label: {
                                Label(
                                    isEditing ? "Lock" : "Edit",
                                    systemImage: isEditing ? "lock.fill" : "pencil"
                                )
                                .foregroundStyle(isEditing ? .orange : .accentColor)
                            }
                        }
                    }
                }
            }
            .safeAreaInset(edge: .top) {
                if let reviewNote, !reviewed { reviewBanner(reviewNote) }
            }
        }
        .onAppear { editedContent = savedContent }
    }

    private func reviewBanner(_ note: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(note, systemImage: "sparkles")
                .font(.caption)
            HStack(spacing: 10) {
                Button {
                    if isEditing { saveEdits(); isEditing = false }
                    reviewed = true
                    onReviewed?()
                } label: {
                    Label("Looks Good", systemImage: "checkmark")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderedProminent).tint(.indigo)

                Button(role: .destructive) {
                    onDiscard?()
                    dismiss()
                } label: {
                    Label("Discard", systemImage: "trash")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.indigo.opacity(0.1))
    }

    private func saveEdits() {
        let url = DeviceSpecManager.fileURL(file)
        try? editedContent.data(using: .utf8)?.write(to: url, options: .atomic)
    }
}
