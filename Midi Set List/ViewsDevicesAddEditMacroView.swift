//
//  AddEditMacroView.swift
//  Midi Set List
//

import SwiftUI
import CoreData

// MARK: - Mode enum

enum MacroMode: String, CaseIterable {
    case midi  = "MIDI"
    case osc   = "OSC"
    case group = "Group"
}

// MARK: - View

struct AddEditMacroView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.dismiss) private var dismiss

    let category: MacroCategory
    let device: InstrumentDevice
    var macro: DeviceMacro?

    @State private var name: String
    @State private var notes: String
    @State private var channel: Int
    @State private var delayMs: Int
    @State private var macroMode: MacroMode

    // MIDI slots (MSB → LSB → PC → CC)
    @State private var sendMSB: Bool
    @State private var msbVal: Int
    @State private var sendLSB: Bool
    @State private var lsbVal: Int
    @State private var sendPC: Bool
    @State private var pcVal: Int
    @State private var pcValueFormula: String
    @State private var sendCC: Bool
    @State private var ccNum: Int
    @State private var ccVal: Int
    @State private var ccValueFormula: String

    // OSC mode
    @State private var oscAddress: String
    @State private var oscFloatArg: Double
    @State private var oscFormula: String

    // Group mode — ordered list of selected macro IDs
    @State private var selectedMacroIDs: [UUID]

    // Preview BPM for formula evaluation in this view (no song context)
    @State private var formulaPreviewBPM: Int = 120

    // Drift detection
    @State private var showingDriftAlert = false
    @State private var affectedSongs: [Song] = []

    init(category: MacroCategory, device: InstrumentDevice, macro: DeviceMacro? = nil) {
        self.category = category
        self.device   = device
        self.macro    = macro

        _name    = State(initialValue: macro?.name ?? "")
        _notes   = State(initialValue: macro?.notes ?? "")
        _channel = State(initialValue: macro?.channel ?? device.midiChannel)
        _delayMs = State(initialValue: macro?.delayMilliseconds ?? 50)

        if macro?.isGroup == true {
            _macroMode = State(initialValue: .group)
        } else if macro?.isOSC == true {
            _macroMode = State(initialValue: .osc)
        } else {
            _macroMode = State(initialValue: .midi)
        }

        _sendMSB        = State(initialValue: macro?.msbValue != nil)
        _msbVal         = State(initialValue: macro?.msbValue ?? 0)
        _sendLSB        = State(initialValue: macro?.lsbValue != nil)
        _lsbVal         = State(initialValue: macro?.lsbValue ?? 0)
        _sendPC         = State(initialValue: macro?.pcValue != nil)
        _pcVal          = State(initialValue: macro?.pcValue ?? 0)
        _pcValueFormula = State(initialValue: macro?.pcValueFormula ?? "")
        _sendCC         = State(initialValue: macro?.ccNumber != nil)
        _ccNum          = State(initialValue: macro?.ccNumber ?? 0)
        _ccVal          = State(initialValue: macro?.ccValue ?? 0)
        _ccValueFormula = State(initialValue: macro?.ccValueFormula ?? "")

        _oscAddress  = State(initialValue: macro?.oscAddress ?? "")
        _oscFloatArg = State(initialValue: macro?.oscFloatArg ?? 0.0)
        _oscFormula  = State(initialValue: macro?.oscFormula ?? "")

        _selectedMacroIDs = State(initialValue: macro?.childMacros.map(\.id) ?? [])
    }

    var isEditing: Bool { macro != nil }

    private var previewContext: FormulaEvaluator.Context {
        .forSong(bpm: formulaPreviewBPM)
    }

    private var anyFormulaActive: Bool {
        macroMode != .group && (
            !oscFormula.trimmingCharacters(in: .whitespaces).isEmpty ||
            !ccValueFormula.trimmingCharacters(in: .whitespaces).isEmpty ||
            !pcValueFormula.trimmingCharacters(in: .whitespaces).isEmpty
        )
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            Form {
                Section("Macro Info") {
                    TextField("Name (e.g. Preset 1A, Clean)", text: $name)
                    TextField("Notes (optional)", text: $notes)
                    Picker("Type", selection: $macroMode) {
                        ForEach(MacroMode.allCases, id: \.self) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                switch macroMode {
                case .midi:  midiSection
                case .osc:   oscSection
                case .group: groupSection
                }

                if anyFormulaActive {
                    Section {
                        LabeledContent("Preview BPM") {
                            TextField("BPM", value: $formulaPreviewBPM, format: .number)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 70)
                        }
                        .onChange(of: formulaPreviewBPM) { _, v in formulaPreviewBPM = max(20, min(300, v)) }
                    } header: {
                        Text("Formula Preview")
                    } footer: {
                        Text("Formula results shown above use this BPM. Actual send uses the song's BPM.")
                    }
                }

                if macroMode != .group {
                    Section("Timing") {
                        LabeledContent("Post-macro delay") {
                            TextField("ms", value: $delayMs, format: .number)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 70)
                        }
                        .onChange(of: delayMs) { _, v in delayMs = max(0, min(2000, v)) }
                    }
                }

                Section("Preview") {
                    Text(previewDescription)
                        .font(.caption)
                        .foregroundStyle(previewDescription.contains("No") || previewDescription.contains("Empty") ? .red : .secondary)
                        .fontDesign(.monospaced)
                }
            }
            .navigationTitle(isEditing ? "Edit Macro" : "New Macro")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .alert("Update Song Commands?", isPresented: $showingDriftAlert) {
                Button("Update \(affectedSongs.count) Song\(affectedSongs.count == 1 ? "" : "s")") {
                    if let macro {
                        affectedSongs.forEach { $0.applyMacroDrift(macro, in: viewContext) }
                        try? viewContext.save()
                    }
                    dismiss()
                }
                Button("Keep Existing", role: .cancel) { dismiss() }
            } message: {
                let names = affectedSongs.prefix(3).map(\.name).joined(separator: ", ")
                let extra = affectedSongs.count > 3 ? " and \(affectedSongs.count - 3) more" : ""
                Text("Commands in \(affectedSongs.count) song\(affectedSongs.count == 1 ? "" : "s") (\(names)\(extra)) came from this macro. Replace them with the updated settings?")
            }
        }
    }

    // MARK: - OSC section

    @ViewBuilder
    private var oscSection: some View {
        Section {
            TextField("/ch/01/mix/fader", text: $oscAddress)
                .keyboardType(.URL)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            AppEffectPickerButton(address: $oscAddress, value: $oscFloatArg)
            HStack {
                Text("Float Value")
                    .foregroundStyle(oscFormula.trimmingCharacters(in: .whitespaces).isEmpty ? .primary : .tertiary)
                Spacer()
                TextField("0.0", value: $oscFloatArg, format: .number)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
                    .foregroundStyle(oscFormula.trimmingCharacters(in: .whitespaces).isEmpty ? .primary : .tertiary)
            }
        } header: {
            Text("OSC Message")
        } footer: {
            Text("Sent to all connected OSC targets. XR18 faders: 0.0–1.0. Addresses starting /app/ control this app's own effects instead.")
        }

        Section {
            TextField("e.g. log(bpm / 60.0) / log(2.0)", text: $oscFormula, axis: .vertical)
                .lineLimit(2...5)
                .keyboardType(.asciiCapable)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .font(.system(.body, design: .monospaced))

            if let result = FormulaEvaluator.evaluate(oscFormula, context: previewContext),
               !oscFormula.trimmingCharacters(in: .whitespaces).isEmpty {
                LabeledContent("→ Result @\(formulaPreviewBPM) BPM") {
                    Text(String(format: "%.6g", result))
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.green)
                }
            } else if let error = FormulaEvaluator.errorDescription(for: oscFormula, context: previewContext),
                      !oscFormula.trimmingCharacters(in: .whitespaces).isEmpty {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("OSC Formula (Optional)")
        } footer: {
            Text("Overrides Float Value at send time using the song's BPM.\nComparisons: > >= < <= == !=   Ternary: cond ? a : b")
        }
    }

    // MARK: - MIDI section

    @ViewBuilder
    private var midiSection: some View {
        Section("MIDI Channel") {
            Picker("Channel", selection: $channel) {
                ForEach(1...16, id: \.self) { Text("Ch \($0)").tag($0) }
            }
        }

        Section {
            Toggle("Send Bank Select MSB", isOn: $sendMSB)
            if sendMSB {
                LabeledContent("Value") {
                    TextField("0–127", value: $msbVal, format: .number)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 70)
                }
                .onChange(of: msbVal) { _, v in msbVal = max(0, min(127, v)) }
            }
        } header: {
            Text("Bank Select MSB (CC 0)")
        } footer: {
            if sendMSB { Text("Sent first in the sequence.") }
        }

        Section {
            Toggle("Send Bank Select LSB", isOn: $sendLSB)
            if sendLSB {
                LabeledContent("Value") {
                    TextField("0–127", value: $lsbVal, format: .number)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 70)
                }
                .onChange(of: lsbVal) { _, v in lsbVal = max(0, min(127, v)) }
            }
        } header: {
            Text("Bank Select LSB (CC 32)")
        } footer: {
            if sendLSB { Text("Sent after MSB.") }
        }

        Section {
            Toggle("Send Program Change", isOn: $sendPC)
            if sendPC {
                LabeledContent("Program") {
                    TextField("0–127", value: $pcVal, format: .number)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 70)
                        .foregroundStyle(pcValueFormula.trimmingCharacters(in: .whitespaces).isEmpty ? .primary : .tertiary)
                }
                .onChange(of: pcVal) { _, v in pcVal = max(0, min(127, v)) }

                formulaField(
                    label: "Program Formula (Optional)",
                    formula: $pcValueFormula,
                    placeholder: "e.g. floor(bpm / 10)"
                )
            }
        } header: {
            Text("Program Change")
        } footer: {
            if sendPC { Text("Sent after any bank selects.") }
        }

        Section {
            Toggle("Send Control Change", isOn: $sendCC)
            if sendCC {
                LabeledContent("CC Number") {
                    TextField("0–127", value: $ccNum, format: .number)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 70)
                }
                .onChange(of: ccNum) { _, v in ccNum = max(0, min(127, v)) }

                LabeledContent("CC Value") {
                    TextField("0–127", value: $ccVal, format: .number)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 70)
                        .foregroundStyle(ccValueFormula.trimmingCharacters(in: .whitespaces).isEmpty ? .primary : .tertiary)
                }
                .onChange(of: ccVal) { _, v in ccVal = max(0, min(127, v)) }

                formulaField(
                    label: "CC Value Formula (Optional)",
                    formula: $ccValueFormula,
                    placeholder: "e.g. bpm >= 128 ? 1 : 0"
                )
            }
        } header: {
            Text("Control Change")
        } footer: {
            if sendCC { Text("Sent last in the sequence.") }
        }
    }

    // MARK: - Group section

    @ViewBuilder
    private var groupSection: some View {
        Section {
            if selectedMacros.isEmpty {
                Text("No macros in group yet.")
                    .foregroundStyle(.secondary)
                    .italic()
            } else {
                ForEach(selectedMacros) { m in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(m.name)
                        Text(m.displayDescription)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .onDelete { offsets in
                    var ids = selectedMacroIDs
                    for i in offsets {
                        ids.removeAll { $0 == selectedMacros[i].id }
                    }
                    selectedMacroIDs = ids
                }
                .onMove { from, to in
                    var ids = selectedMacros.map(\.id)
                    ids.move(fromOffsets: from, toOffset: to)
                    selectedMacroIDs = ids
                }
            }
        } header: {
            Text("Group Members")
        } footer: {
            Text("Drag to reorder. Swipe to remove. Macros are sent in listed order.")
        }
        .environment(\.editMode, .constant(.active))

        Section {
            if availableGroupMacros.isEmpty {
                Text("No other macros available to add.")
                    .foregroundStyle(.secondary)
                    .italic()
            } else {
                ForEach(availableGroupMacros, id: \.0.id) { (m, catName) in
                    Button {
                        selectedMacroIDs.append(m.id)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(m.name)
                                    .foregroundStyle(.primary)
                                Text("\(catName) · \(m.displayDescription)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "plus.circle")
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                }
            }
        } header: {
            Text("Add Member")
        }
    }

    // MARK: - Shared inline formula row

    @ViewBuilder
    private func formulaField(label: String, formula: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            TextField(placeholder, text: formula, axis: .vertical)
                .lineLimit(2...4)
                .keyboardType(.asciiCapable)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .font(.system(.body, design: .monospaced))
        }
        .padding(.vertical, 2)

        if !formula.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty {
            if let result = FormulaEvaluator.evaluate(formula.wrappedValue, context: previewContext) {
                LabeledContent("→ Result @\(formulaPreviewBPM) BPM") {
                    Text(String(format: "%.6g", result))
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.green)
                }
            } else if let error = FormulaEvaluator.errorDescription(for: formula.wrappedValue, context: previewContext) {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    // MARK: - Computed helpers for group mode

    private var selectedMacros: [DeviceMacro] {
        let all = device.sortedCategories.flatMap { $0.sortedMacros }
        let map = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
        return selectedMacroIDs.compactMap { map[$0] }
    }

    // Returns (macro, categoryName) for macros that can still be added to the group
    private var availableGroupMacros: [(DeviceMacro, String)] {
        device.sortedCategories.flatMap { cat in
            cat.sortedMacros.compactMap { m -> (DeviceMacro, String)? in
                guard !m.isGroup,
                      m.objectID != macro?.objectID,
                      !selectedMacroIDs.contains(m.id) else { return nil }
                return (m, cat.name)
            }
        }
    }

    // MARK: - Preview description

    private var previewDescription: String {
        switch macroMode {
        case .group:
            if selectedMacroIDs.isEmpty { return "Empty group" }
            let names = selectedMacros.prefix(3).map(\.name).joined(separator: " → ")
            let extra = selectedMacros.count > 3 ? " → …" : ""
            return "Group: \(names)\(extra)"
        case .osc:
            if oscAddress.isEmpty { return "No address" }
            if !oscFormula.trimmingCharacters(in: .whitespaces).isEmpty { return "OSC \(oscAddress) [formula]" }
            return "OSC \(oscAddress) → \(String(format: "%.4g", oscFloatArg))"
        case .midi:
            var parts: [String] = []
            if sendMSB { parts.append("MSB \(msbVal)") }
            if sendLSB { parts.append("LSB \(lsbVal)") }
            if sendPC  { parts.append(pcValueFormula.trimmingCharacters(in: .whitespaces).isEmpty ? "PC \(pcVal)" : "PC[formula]") }
            if sendCC  { parts.append(ccValueFormula.trimmingCharacters(in: .whitespaces).isEmpty ? "CC#\(ccNum)=\(ccVal)" : "CC#\(ccNum)[formula]") }
            guard !parts.isEmpty else { return "No commands" }
            return parts.joined(separator: " → ") + " [Ch \(channel)]"
        }
    }

    // MARK: - Save

    private func save() {
        let trimmedName    = name.trimmingCharacters(in: .whitespaces)
        let trimCCFormula  = ccValueFormula.trimmingCharacters(in: .whitespaces)
        let trimPCFormula  = pcValueFormula.trimmingCharacters(in: .whitespaces)
        let trimOSCFormula = oscFormula.trimmingCharacters(in: .whitespaces)

        if let macro {
            macro.name              = trimmedName
            macro.notes             = notes.isEmpty ? nil : notes
            macro.delayMilliseconds = delayMs
            macro.isOSC             = macroMode == .osc
            macro.isGroup           = macroMode == .group

            switch macroMode {
            case .group:
                macro.setChildMacros(selectedMacros)
                // Clear MIDI/OSC fields
                macro.oscAddress = nil; macro.oscFloatArg = nil; macro.oscFormula = nil
                macro.msbValue = nil;   macro.lsbValue = nil
                macro.pcValue = nil;    macro.pcValueFormula = nil
                macro.ccNumber = nil;   macro.ccValue = nil; macro.ccValueFormula = nil

            case .osc:
                macro.oscAddress  = oscAddress.isEmpty ? nil : oscAddress
                macro.oscFloatArg = oscFloatArg
                macro.oscFormula  = trimOSCFormula.isEmpty ? nil : trimOSCFormula
                macro.msbValue = nil; macro.lsbValue = nil
                macro.pcValue = nil;  macro.pcValueFormula = nil
                macro.ccNumber = nil; macro.ccValue = nil; macro.ccValueFormula = nil
                macro.groupMacroOrderData = nil

            case .midi:
                macro.channel        = channel
                macro.msbValue       = sendMSB ? msbVal : nil
                macro.lsbValue       = sendLSB ? lsbVal : nil
                macro.pcValue        = sendPC  ? pcVal  : nil
                macro.pcValueFormula = (sendPC  && !trimPCFormula.isEmpty) ? trimPCFormula : nil
                macro.ccNumber       = sendCC  ? ccNum  : nil
                macro.ccValue        = sendCC  ? ccVal  : nil
                macro.ccValueFormula = (sendCC  && !trimCCFormula.isEmpty) ? trimCCFormula : nil
                macro.oscAddress = nil; macro.oscFloatArg = nil; macro.oscFormula = nil
                macro.groupMacroOrderData = nil
            }

            try? viewContext.save()

            let uniqueSongs = Dictionary(
                grouping: macro.generatedCommands.compactMap(\.song),
                by: \.objectID
            ).values.compactMap(\.first)

            if uniqueSongs.isEmpty {
                dismiss()
            } else {
                affectedSongs = uniqueSongs
                showingDriftAlert = true
            }
        } else {
            let newMacro = DeviceMacro.create(
                name:              trimmedName,
                notes:             notes.isEmpty ? nil : notes,
                channel:           macroMode == .midi ? channel : 1,
                delayMilliseconds: macroMode != .group ? delayMs : 0,
                orderIndex:        category.macros.count,
                msbValue:          (macroMode == .midi && sendMSB) ? msbVal : nil,
                lsbValue:          (macroMode == .midi && sendLSB) ? lsbVal : nil,
                pcValue:           (macroMode == .midi && sendPC)  ? pcVal  : nil,
                ccNumber:          (macroMode == .midi && sendCC)  ? ccNum  : nil,
                ccValue:           (macroMode == .midi && sendCC)  ? ccVal  : nil,
                isOSC:             macroMode == .osc,
                oscAddress:        macroMode == .osc ? (oscAddress.isEmpty ? nil : oscAddress) : nil,
                oscFloatArg:       macroMode == .osc ? oscFloatArg : nil,
                in:                viewContext
            )
            newMacro.isGroup         = macroMode == .group
            newMacro.category        = category
            newMacro.oscFormula      = (macroMode == .osc && !trimOSCFormula.isEmpty) ? trimOSCFormula : nil
            newMacro.ccValueFormula  = (macroMode == .midi && sendCC && !trimCCFormula.isEmpty) ? trimCCFormula : nil
            newMacro.pcValueFormula  = (macroMode == .midi && sendPC && !trimPCFormula.isEmpty) ? trimPCFormula : nil

            if macroMode == .group {
                newMacro.setChildMacros(selectedMacros)
            }

            try? viewContext.save()
            dismiss()
        }
    }
}
