//
//  SetListAssistantView.swift
//  Midi Set List
//
//  Ask AI to create or change a set list. Every change is shown as a
//  summary first and only applied when the user taps Apply.
//

import CoreData
import FoundationModels
import SwiftUI

struct SetListAssistantView: View {
    /// The open set list, or nil when opened from the Set Lists screen (create only)
    let setList: SetList?

    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var ai = AISettings.shared

    @FetchRequest(sortDescriptors: [SortDescriptor(\.name)]) private var allSongs: FetchedResults<Song>
    @FetchRequest(sortDescriptors: [SortDescriptor(\.dateModified, order: .reverse)]) private var allSetLists: FetchedResults<SetList>

    @State private var messages: [Message] = []
    @State private var planStates: [UUID: PlanState] = [:]
    @State private var input = ""
    @State private var isWorking = false

    // Conversation state, so follow-ups ("actually keep Wonderwall") revise the plan
    @State private var catalog: SetListAssistant.Catalog?
    @State private var systemPrompt = ""
    @State private var history: [ExternalAIMessage] = []
    @State private var onDeviceSession: LanguageModelSession?

    private struct Message: Identifiable {
        let id = UUID()
        let kind: Kind
        enum Kind {
            case user(String)
            case plan(SetListChangePreview)
            case error(String)
        }
    }

    private enum PlanState { case applied(String), discarded }

    /// Only the newest plan can be applied; older ones were replaced by follow-ups
    private var latestPlanID: UUID? {
        messages.last(where: { if case .plan = $0.kind { return true } else { return false } })?.id
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if ai.offlineMode { OfflineModeBanner() }
                conversation
                Divider()
                inputBar
            }
            .navigationTitle(setList == nil ? "New Set List with AI" : "Edit with AI")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    // MARK: - Conversation

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if messages.isEmpty { emptyState }

                    ForEach(messages) { message in
                        bubble(for: message).padding(.horizontal)
                    }

                    if isWorking {
                        HStack(spacing: 8) {
                            ProgressView().scaleEffect(0.8)
                            Text("Planning changes…").font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal)
                    }

                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.vertical, 14)
            }
            .onChange(of: messages.count) { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom") } }
            .onChange(of: isWorking)      { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom") } }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "sparkles.rectangle.stack")
                .font(.largeTitle).foregroundStyle(.secondary)
            Text(setList == nil
                 ? "Describe the set you want. You'll see the plan before anything is created."
                 : "Describe what to change in \"\(setList?.name ?? "")\". You'll see a summary before anything changes.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: 8) {
                Text("Try an example:")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(examples, id: \.self) { example in
                    Button { input = example } label: {
                        Text(example)
                            .font(.caption).multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10).padding(.vertical, 8)
                    }
                    .buttonStyle(.bordered).tint(.secondary)
                }
            }
        }
        .padding(.horizontal, 20).padding(.top, 24)
    }

    private var examples: [String] {
        if setList != nil {
            return [
                "Remove the two slowest songs",
                "Reorder from slowest to fastest BPM",
                "Move the first song to the end",
                "Make a new set list with just the first 5 songs"
            ]
        }
        return [
            "Make a 6-song set that builds in energy",
            "New set list with all my rock songs, fastest first",
            "Copy my latest set list but in reverse order"
        ]
    }

    // MARK: - Bubbles

    @ViewBuilder
    private func bubble(for message: Message) -> some View {
        switch message.kind {
        case .user(let text):
            HStack {
                Spacer(minLength: 60)
                Text(text)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Color.blue, in: RoundedRectangle(cornerRadius: 18))
                    .foregroundStyle(.white)
            }
        case .plan(let preview):
            planCard(preview, id: message.id)
        case .error(let text):
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(text).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func planCard(_ preview: SetListChangePreview, id: UUID) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(planTitle(preview), systemImage: planIcon(preview))
                .font(.headline)
                .foregroundStyle(preview.kind == .none ? Color.secondary : Color.indigo)

            Text(preview.summary).font(.subheadline)

            if preview.kind == .update, let newName = preview.newName {
                changeRow(icon: "pencil", color: .blue,
                          text: "Rename: \(preview.oldName ?? "") → \(newName)")
            }

            if !preview.removed.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("REMOVE (\(preview.removed.count))")
                        .font(.caption2.weight(.bold)).foregroundStyle(.red)
                    ForEach(preview.removed, id: \.objectID) { song in
                        changeRow(icon: "minus.circle.fill", color: .red, text: song.displayName, struck: true)
                    }
                }
            }

            if preview.kind != .none {
                VStack(alignment: .leading, spacing: 4) {
                    Text(preview.kind == .create ? "SONGS (\(preview.finalSongs.count))" : "NEW ORDER (\(preview.finalSongs.count))")
                        .font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                    ForEach(Array(preview.finalSongs.enumerated()), id: \.element.id) { index, entry in
                        orderRow(index: index, entry: entry)
                    }
                }
            }

            if !preview.unknownIDs.isEmpty {
                changeRow(icon: "questionmark.circle", color: .orange,
                          text: "Skipped \(preview.unknownIDs.count) song reference(s) not in your library")
            }

            planActions(preview, id: id)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.indigo.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.indigo.opacity(0.3), lineWidth: 1))
        .opacity(id == latestPlanID || planStates[id] != nil ? 1 : 0.55)
    }

    @ViewBuilder
    private func planActions(_ preview: SetListChangePreview, id: UUID) -> some View {
        switch planStates[id] {
        case .applied(let message)?:
            Label(message, systemImage: "checkmark.circle.fill")
                .font(.subheadline.weight(.medium)).foregroundStyle(.green)
        case .discarded?:
            Label("Discarded — nothing changed", systemImage: "xmark.circle")
                .font(.subheadline).foregroundStyle(.secondary)
        case nil:
            if id != latestPlanID {
                Text("Replaced by a newer plan").font(.caption).foregroundStyle(.secondary)
            } else if preview.hasChanges {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        Button { apply(preview, id: id) } label: {
                            Label(preview.kind == .create ? "Create Set List" : "Apply Changes",
                                  systemImage: "checkmark")
                                .font(.subheadline.weight(.semibold))
                        }
                        .buttonStyle(.borderedProminent).tint(.indigo)

                        Button("Discard") { planStates[id] = .discarded }
                            .buttonStyle(.bordered)
                    }
                    Text("Or type below to adjust this plan.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            } else if preview.kind != .none {
                Text("No changes to apply.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func orderRow(index: Int, entry: SetListChangePreview.Entry) -> some View {
        HStack(spacing: 8) {
            Text("\(index + 1)")
                .font(.caption.weight(.semibold)).monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 22, alignment: .trailing)
            Text(entry.song.displayName).font(.subheadline).lineLimit(1)
            if let bpm = entry.song.bpm {
                Text("\(bpm)").font(.caption2).monospacedDigit().foregroundStyle(.tertiary)
            }
            Spacer(minLength: 4)
            switch entry.mark {
            case .added: tag("NEW", color: .green)
            case .moved: tag("MOVED", color: .orange)
            case .unchanged: EmptyView()
            }
        }
    }

    private func tag(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
    }

    private func changeRow(icon: String, color: Color, text: String, struck: Bool = false) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(color).font(.caption)
            Text(text).font(.subheadline).strikethrough(struck).foregroundStyle(struck ? .secondary : .primary)
        }
    }

    private func planTitle(_ preview: SetListChangePreview) -> String {
        switch preview.kind {
        case .create: return "Create \"\(preview.newName ?? "New Set List")\""
        case .update: return "Update \"\(setList?.name ?? "")\""
        case .none:   return "No changes"
        }
    }

    private func planIcon(_ preview: SetListChangePreview) -> String {
        switch preview.kind {
        case .create: return "plus.rectangle.on.rectangle"
        case .update: return "arrow.up.arrow.down"
        case .none:   return "info.circle"
        }
    }

    // MARK: - Input

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField(latestPlanIsOpen ? "Adjust the plan, or tap Apply…" : "Describe the set list change…",
                      text: $input, axis: .vertical)
                .lineLimit(1...4).textFieldStyle(.plain)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20))
                .offlineModeOutline(ai.offlineMode)

            Button { Task { await send() } } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(canSend ? (ai.offlineMode ? Color.offlineMode : .indigo) : Color(.tertiaryLabel))
            }
            .disabled(!canSend)
        }
        .padding(.horizontal).padding(.vertical, 10)
    }

    private var canSend: Bool {
        !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isWorking
    }

    private var latestPlanIsOpen: Bool {
        guard let id = latestPlanID else { return false }
        return planStates[id] == nil
    }

    // MARK: - Actions

    @MainActor
    private func send() async {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        input = ""
        messages.append(Message(kind: .user(text)))
        isWorking = true
        defer { isWorking = false }

        if catalog == nil { startConversation() }
        guard let catalog else { return }

        let turn = history + [ExternalAIMessage(role: "user", content: text)]
        do {
            let result = try await SetListAssistant.requestPlan(
                systemPrompt: systemPrompt,
                history: turn,
                onDeviceSession: { sessionForOnDevice() }
            )
            history = turn + [ExternalAIMessage(role: "assistant", content: result.rawText ?? result.plan.summary)]
            let preview = SetListAssistant.preview(for: result.plan, catalog: catalog, current: setList)
            messages.append(Message(kind: .plan(preview)))
        } catch {
            messages.append(Message(kind: .error(error.localizedDescription)))
        }
    }

    /// Snapshot the library and set lists once per conversation so song IDs stay stable
    private func startConversation() {
        let built = SetListAssistant.Catalog(songs: Array(allSongs))
        catalog = built
        systemPrompt = SetListAssistant.systemPrompt(catalog: built, current: setList, otherSetLists: Array(allSetLists))
    }

    private func sessionForOnDevice() -> LanguageModelSession {
        if let session = onDeviceSession { return session }
        let session = LanguageModelSession(instructions: systemPrompt)
        onDeviceSession = session
        return session
    }

    private func apply(_ preview: SetListChangePreview, id: UUID) {
        do {
            let result = try SetListAssistant.apply(preview, to: setList, in: viewContext)
            switch preview.kind {
            case .create: planStates[id] = .applied("Created \"\(result?.name ?? "set list")\" — find it in Set Lists")
            default:      planStates[id] = .applied("Changes applied")
            }
            // The library and set lists changed — rebuild context for any follow-up request
            catalog = nil
            history = []
            onDeviceSession = nil
        } catch {
            messages.append(Message(kind: .error("Couldn't save: \(error.localizedDescription)")))
        }
    }
}
