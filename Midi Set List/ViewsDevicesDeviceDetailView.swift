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
            } header: {
                Text("Reference Files")
            } footer: {
                Text("Attach PDF or text MIDI/OSC specifications. The AI macro generator will automatically use these as context when generating macros for this device.")
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
            SpecFileViewerSheet(file: file)
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
                    }
                }
            }
            .safeAreaInset(edge: .top) {
                if ai.offlineMode { OfflineModeBanner() }
            }
            .safeAreaInset(edge: .bottom) {
                if !isEditing && !content.isEmpty {
                    Button {
                        Task { await compactMemory() }
                    } label: {
                        HStack(spacing: 8) {
                            if isCompacting {
                                ProgressView().scaleEffect(0.8)
                                Text("Compacting…")
                            } else {
                                Image(systemName: ai.offlineMode ? "wifi.slash" : "sparkles")
                                Text(ai.offlineMode ? "Compact with On-Device AI" : "Compact with AI")
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

    private func compactOnDevice(systemPrompt: String) async throws -> String {
        let session = LanguageModelSession(instructions: systemPrompt)
        return try await session.respond(to: content).content
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

        let specContext = DeviceSpecManager.specContext(for: device)
        var systemPrompt = """
            You are a memory file optimizer for a MIDI device assistant app called "Midi Set List."
            The memory file holds user-confirmed corrections and learned values for a specific MIDI device.
            """
        if !specContext.isEmpty {
            systemPrompt += """

                The device's reference spec is provided below. You know what is already documented there.
                Use it to decide what to KEEP vs. DROP from the memory file:
                - KEEP entries that correct or add to the spec (these are the user's ground truth)
                - DROP entries that merely restate what the spec already says correctly
                - DROP entries that are superseded by a later correction in the memory file

                DEVICE SPEC:
                \(specContext)
                """
        }
        systemPrompt += """

            Condense the memory file into a minimal, non-redundant set of bullet facts.
            Rules:
            - One fact per line, starting with "- "
            - Remove duplicate or near-duplicate entries (keep the most specific/recent one)
            - Strip out conversational context — keep only the factual conclusion
            - Aim for under 20 lines
            - No headers, no markdown fences, no explanation
            Output ONLY the compacted memory content.
            """

        do {
            let text: String
            if ai.offlineMode {
                text = try await compactOnDevice(systemPrompt: systemPrompt)
            } else {
                do {
                    text = try await ExternalAIClient.chat(
                        provider: provider,
                        apiKey: apiKey ?? "",
                        systemPrompt: systemPrompt,
                        messages: [ExternalAIMessage(role: "user", content: content)],
                        workspaceID: provider == .anthropic ? ai.anthropicWorkspaceID : nil,
                        anthropicModelID: ai.anthropicModel(for: .macroChat),
                        anthropicThinking: false
                    ).text
                } catch let error where ExternalAIError.isConnectivity(error) && SystemLanguageModel.default.isAvailable {
                    // Connection dropped mid-request — fall back to on-device
                    text = try await compactOnDevice(systemPrompt: systemPrompt)
                }
            }
            content = text.trimmingCharacters(in: .whitespacesAndNewlines)
            saveEdits()
            isEditing = true  // drop into edit mode so user can review the result
        } catch {
            compactError = error.localizedDescription
        }
    }
}

// MARK: - Spec file content viewer

private struct SpecFileViewerSheet: View {
    let file: DeviceSpecFile
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false
    @State private var isEditing = false
    @State private var editedContent: String = ""

    private var savedContent: String {
        DeviceSpecManager.extractText(file) ?? "(Unable to read file)"
    }

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
        .onAppear { editedContent = savedContent }
    }

    private func saveEdits() {
        let url = DeviceSpecManager.fileURL(file)
        try? editedContent.data(using: .utf8)?.write(to: url, options: .atomic)
    }
}
