//
//  ActivityLogView.swift
//  Midi Set List
//

import SwiftUI
import CoreData

struct ActivityLogView: View {
    @Environment(ActivityLog.self) private var log
    @Environment(\.managedObjectContext) private var viewContext

    @State private var filter: Filter = .all
    @State private var savingEntry: ActivityLog.Entry?

    enum Filter: String, CaseIterable {
        case all    = "All"
        case midi   = "MIDI"
        case osc    = "OSC"
        case errors = "Errors"
    }

    var filteredEntries: [ActivityLog.Entry] {
        switch filter {
        case .all:    return log.entries
        case .midi:   return log.entries.filter { $0.proto == .midi }
        case .osc:    return log.entries.filter { $0.proto == .osc }
        case .errors: return log.entries.filter { $0.direction == .error }
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Filter", selection: $filter) {
                    ForEach(Filter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(Color(.systemGroupedBackground))

                if filteredEntries.isEmpty {
                    ContentUnavailableView {
                        Label(filter == .errors ? "No Errors" : "No Activity",
                              systemImage: filter == .errors ? "checkmark.circle" : "waveform.slash")
                    } description: {
                        Text(filter == .all
                             ? "Messages will appear here as MIDI and OSC are sent."
                             : "No \(filter.rawValue) messages yet.")
                    }
                } else {
                    List(filteredEntries) { entry in
                        LogEntryRow(entry: entry) {
                            savingEntry = entry
                        }
                        .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Activity")
            .offlineStatusBadge()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Clear") { log.clear() }
                        .disabled(log.entries.isEmpty)
                }
            }
            .sheet(item: $savingEntry) { entry in
                if entry.proto == .osc {
                    SaveOSCAsActionSheet(entry: entry)
                } else {
                    SaveMIDIAsActionSheet(entry: entry)
                }
            }
        }
    }
}

// MARK: - Row

private struct LogEntryRow: View {
    let entry: ActivityLog.Entry
    var onSaveAsMacro: (() -> Void)? = nil

    private var canSaveAsMacro: Bool {
        entry.direction == .in && (
            entry.proto == .osc ||
            (entry.proto == .midi && entry.midiPayload != nil)
        )
    }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: directionIcon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(directionColor)
                .frame(width: 18)

            Text(protoBadge)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(protoColor, in: RoundedRectangle(cornerRadius: 4))
                .fixedSize()

            Text(entry.message)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(entry.direction == .error ? .red : .primary)
                .lineLimit(2)

            Spacer(minLength: 0)

            Text(entry.date, format: .dateTime.hour().minute().second())
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .monospacedDigit()

            if canSaveAsMacro, let onSaveAsMacro {
                Button(action: onSaveAsMacro) {
                    Image(systemName: "plus.circle")
                        .foregroundStyle(.green)
                        .imageScale(.medium)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 2)
    }

    private var directionIcon: String {
        switch entry.direction {
        case .out:    return "arrow.up"
        case .in:     return "arrow.down"
        case .system: return "circle.fill"
        case .error:  return "exclamationmark.triangle.fill"
        }
    }

    private var directionColor: Color {
        switch entry.direction {
        case .out:    return .blue
        case .in:     return .green
        case .system: return .secondary
        case .error:  return .red
        }
    }

    private var protoBadge: String {
        switch entry.proto {
        case .midi:   return "MIDI"
        case .osc:    return "OSC"
        case .system: return "SYS"
        }
    }

    private var protoColor: Color {
        switch entry.proto {
        case .midi:   return .blue
        case .osc:    return .green
        case .system: return .gray
        }
    }
}

// MARK: - Save OSC as Macro sheet

struct SaveOSCAsActionSheet: View {
    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.dismiss) private var dismiss

    @FetchRequest(sortDescriptors: [SortDescriptor(\.name)])
    private var instruments: FetchedResults<InstrumentDevice>

    @FetchRequest(sortDescriptors: [SortDescriptor(\.name)])
    private var oscTargets: FetchedResults<OSCTarget>

    let entry: ActivityLog.Entry

    private let oscAddress: String
    private let oscFloatArg: Double?

    // nil = no selection; String = name of an OSCTarget (we find-or-create an InstrumentDevice for it)
    @State private var selectedInstrument: InstrumentDevice?
    @State private var selectedOSCTargetName: String? = nil
    @State private var pickerMode: PickerMode = .none
    @State private var selectedCategory: MacroCategory?
    @State private var newCategoryName: String = "OSC Actions"
    @State private var macroName: String
    @State private var delayMs: Int = 50

    enum PickerMode: Hashable {
        case none
        case instrument(ObjectIdentifier)
        case oscTarget(String)
    }

    init(entry: ActivityLog.Entry) {
        self.entry = entry
        let parsed = Self.parseOSCMessage(entry.message)
        self.oscAddress = parsed.address
        self.oscFloatArg = parsed.floatArg
        let lastName = parsed.address.components(separatedBy: "/").last(where: { !$0.isEmpty }) ?? parsed.address
        _macroName = State(initialValue: lastName)
    }

    private static func parseOSCMessage(_ message: String) -> (address: String, floatArg: Double?) {
        if let range = message.range(of: " \u{2192} ") {
            let address = String(message[..<range.lowerBound])
            let floatStr = String(message[range.upperBound...])
            return (address, Double(floatStr))
        }
        return (message, nil)
    }

    private var resolvedInstrument: InstrumentDevice? {
        switch pickerMode {
        case .instrument(let oid):
            return instruments.first { ObjectIdentifier($0) == oid }
        case .oscTarget(let name):
            return instruments.first { $0.name == name }
        case .none:
            return nil
        }
    }

    private var availableCategories: [MacroCategory] {
        resolvedInstrument?.sortedCategories ?? []
    }

    private var canSave: Bool {
        !macroName.trimmingCharacters(in: .whitespaces).isEmpty && pickerMode != .none
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("OSC Message") {
                    LabeledContent("Address") {
                        Text(oscAddress)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    if let val = oscFloatArg {
                        LabeledContent("Float Value") {
                            Text(String(format: "%.4g", val))
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section {
                    TextField("Macro name", text: $macroName)
                    Stepper("Delay: \(delayMs)ms", value: $delayMs, in: 0...2000, step: 10)
                } header: {
                    Text("Action")
                }

                Section {
                    if instruments.isEmpty && oscTargets.isEmpty {
                        Text("No devices yet — add one in the Devices tab first.")
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Device", selection: $pickerMode) {
                            Text("Select device…").tag(PickerMode.none)
                            if !oscTargets.isEmpty {
                                ForEach(oscTargets, id: \.id) { target in
                                    Label(target.name, systemImage: "network")
                                        .tag(PickerMode.oscTarget(target.name))
                                }
                            }
                            if !instruments.isEmpty {
                                ForEach(instruments) { device in
                                    Label(device.displayName, systemImage: "pianokeys")
                                        .tag(PickerMode.instrument(ObjectIdentifier(device)))
                                }
                            }
                        }
                        .onChange(of: pickerMode) { _, _ in selectedCategory = nil }

                        if pickerMode != .none {
                            if availableCategories.isEmpty {
                                TextField("New category name", text: $newCategoryName)
                            } else {
                                Picker("Category", selection: $selectedCategory) {
                                    Text("New Category…").tag(nil as MacroCategory?)
                                    ForEach(availableCategories) { cat in
                                        Text(cat.name).tag(cat as MacroCategory?)
                                    }
                                }
                                if selectedCategory == nil {
                                    TextField("New category name", text: $newCategoryName)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Save to Device")
                } footer: {
                    Text("The macro will appear in the Devices tab under the selected device.")
                }
            }
            .navigationTitle("Save as Macro")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(!canSave)
                }
            }
        }
    }

    private func save() {
        let trimName = macroName.trimmingCharacters(in: .whitespaces)

        // Resolve or create the InstrumentDevice
        let device: InstrumentDevice
        if let existing = resolvedInstrument {
            device = existing
        } else if case .oscTarget(let name) = pickerMode {
            // Auto-create an InstrumentDevice entry for this OSC target
            let newDevice = InstrumentDevice.create(name: name, midiChannel: 1, in: viewContext)
            device = newDevice
        } else {
            return
        }

        let category: MacroCategory
        if let existing = selectedCategory {
            category = existing
        } else {
            let catName = newCategoryName.trimmingCharacters(in: .whitespaces)
            category = MacroCategory.create(
                name: catName.isEmpty ? "OSC Actions" : catName,
                orderIndex: device.categories.count,
                device: device,
                in: viewContext
            )
        }

        let macro = DeviceMacro.create(
            name: trimName,
            delayMilliseconds: delayMs,
            isOSC: true,
            oscAddress: oscAddress,
            oscFloatArg: oscFloatArg,
            in: viewContext
        )
        macro.category = category

        try? viewContext.save()
        dismiss()
    }
}

// MARK: - Save MIDI as Macro sheet

struct SaveMIDIAsActionSheet: View {
    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.dismiss) private var dismiss

    @FetchRequest(sortDescriptors: [SortDescriptor(\.name)])
    private var instruments: FetchedResults<InstrumentDevice>

    let entry: ActivityLog.Entry

    @State private var macroName: String
    @State private var delayMs: Int = 50
    @State private var selectedInstrument: InstrumentDevice?
    @State private var selectedCategory: MacroCategory?
    @State private var newCategoryName: String = "MIDI"

    init(entry: ActivityLog.Entry) {
        self.entry = entry
        _macroName = State(initialValue: entry.message)
    }

    private var payload: ActivityLog.Entry.MIDIPayload? { entry.midiPayload }

    private var canSave: Bool {
        !macroName.trimmingCharacters(in: .whitespaces).isEmpty && selectedInstrument != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Captured Message") {
                    Text(entry.message)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                Section("Action") {
                    TextField("Macro name", text: $macroName)
                    Stepper("Delay: \(delayMs)ms", value: $delayMs, in: 0...2000, step: 10)
                }

                Section {
                    if instruments.isEmpty {
                        Text("No instruments yet — add one in the Devices tab.")
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Device", selection: $selectedInstrument) {
                            Text("Select device…").tag(nil as InstrumentDevice?)
                            ForEach(instruments) { device in
                                Label(device.displayName, systemImage: "pianokeys")
                                    .tag(device as InstrumentDevice?)
                            }
                        }
                        .onChange(of: selectedInstrument) { _, _ in selectedCategory = nil }

                        if let device = selectedInstrument {
                            let cats = device.sortedCategories
                            if cats.isEmpty {
                                TextField("New category name", text: $newCategoryName)
                            } else {
                                Picker("Category", selection: $selectedCategory) {
                                    Text("New Category…").tag(nil as MacroCategory?)
                                    ForEach(cats) { cat in
                                        Text(cat.name).tag(cat as MacroCategory?)
                                    }
                                }
                                if selectedCategory == nil {
                                    TextField("New category name", text: $newCategoryName)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Save to Device")
                } footer: {
                    Text("The macro will appear in the Devices tab under the selected device.")
                }
            }
            .navigationTitle("Save as Macro")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.disabled(!canSave) }
            }
        }
    }

    private func save() {
        guard let device = selectedInstrument, let payload else { return }
        let trimName = macroName.trimmingCharacters(in: .whitespaces)

        let category: MacroCategory
        if let existing = selectedCategory {
            category = existing
        } else {
            let catName = newCategoryName.trimmingCharacters(in: .whitespaces)
            category = MacroCategory.create(
                name: catName.isEmpty ? "MIDI" : catName,
                orderIndex: device.categories.count,
                device: device,
                in: viewContext
            )
        }

        let macro: DeviceMacro
        switch payload.kind {
        case .programChange:
            macro = DeviceMacro.create(name: trimName, channel: payload.channel,
                                       delayMilliseconds: delayMs,
                                       pcValue: payload.value1, in: viewContext)
        case .controlChange:
            macro = DeviceMacro.create(name: trimName, channel: payload.channel,
                                       delayMilliseconds: delayMs,
                                       ccNumber: payload.value1, ccValue: payload.value2,
                                       in: viewContext)
        case .bankSelectMSB:
            macro = DeviceMacro.create(name: trimName, channel: payload.channel,
                                       delayMilliseconds: delayMs,
                                       msbValue: payload.value1, in: viewContext)
        case .bankSelectLSB:
            macro = DeviceMacro.create(name: trimName, channel: payload.channel,
                                       delayMilliseconds: delayMs,
                                       lsbValue: payload.value1, in: viewContext)
        }
        macro.category = category
        try? viewContext.save()
        dismiss()
    }
}

// MARK: - Preview

#Preview {
    let log = ActivityLog()
    log.log("MIDI initialized", direction: .system, proto: .system)
    log.log("Scan found 2 MIDI destinations", direction: .system, proto: .midi)
    log.log("Connected to Yamaha MX88", direction: .system, proto: .midi)
    log.log("OSC connecting: XR18 (192.168.1.100:10023)", direction: .system, proto: .osc)
    log.log("Keepalive active: /xremote every 8s → XR18", direction: .system, proto: .osc)
    log.log("PC 12 [Ch 3]", direction: .out, proto: .midi)
    log.log("/ch/01/mix/fader → 0.75", direction: .out, proto: .osc)
    log.log("/main/mix/on", direction: .out, proto: .osc)
    log.log("Send failed: no MIDI devices connected", direction: .error, proto: .midi)
    return ActivityLogView()
        .environment(log)
        .environment(\.managedObjectContext, PersistenceController.preview.viewContext)
}
