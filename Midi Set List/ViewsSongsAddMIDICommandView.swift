//
//  AddMIDICommandView.swift
//  Midi Set List
//

import SwiftUI
import CoreData

struct AddMIDICommandView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) private var viewContext
    let song: Song
    /// Snapshot the new command is added to (0 = Snapshot 1)
    var snapshotIndex: Int = 0

    @State private var commandType: MIDICommandType = .programChange
    @State private var useOmniChannel = true
    @State private var channel = 1
    @State private var value1 = 0
    @State private var value2 = 0
    @State private var delayMilliseconds = 50
    @State private var notes = ""
    @State private var oscAddress = ""
    @State private var oscFloatArg: Double = 0.0
    @State private var oscFormula = ""
    @State private var value1Formula = ""
    @State private var value2Formula = ""

    private var formulaContext: FormulaEvaluator.Context {
        .forSong(bpm: song.bpm)
    }

    private var oscFormulaResult: Double? {
        guard !oscFormula.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return FormulaEvaluator.evaluate(oscFormula, context: formulaContext)
    }

    private var oscFormulaError: String? {
        guard !oscFormula.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return FormulaEvaluator.errorDescription(for: oscFormula, context: formulaContext)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Command Type") {
                    Picker("Type", selection: $commandType) {
                        ForEach(MIDICommandType.allCases, id: \.self) { type in
                            Text(type.description).tag(type)
                        }
                    }
                }

                if commandType != .oscMessage {
                    Section("Channel") {
                        Toggle("Omni (All Channels)", isOn: $useOmniChannel)
                        if !useOmniChannel {
                            Picker("MIDI Channel", selection: $channel) {
                                ForEach(1...16, id: \.self) { Text("Channel \($0)").tag($0) }
                            }
                        }
                    }
                }

                Section("Values") {
                    switch commandType {
                    case .programChange:
                        LabeledContent("Program") {
                            TextField("0–127", value: $value1, format: .number)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 70)
                                .foregroundStyle(value1Formula.trimmingCharacters(in: .whitespaces).isEmpty ? .primary : .tertiary)
                        }
                        .onChange(of: value1) { _, v in value1 = max(0, min(127, v)) }
                    case .controlChange:
                        LabeledContent("CC Number") {
                            TextField("0–127", value: $value1, format: .number)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 70)
                        }
                        .onChange(of: value1) { _, v in value1 = max(0, min(127, v)) }
                        LabeledContent("CC Value") {
                            TextField("0–127", value: $value2, format: .number)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 70)
                                .foregroundStyle(value2Formula.trimmingCharacters(in: .whitespaces).isEmpty ? .primary : .tertiary)
                        }
                        .onChange(of: value2) { _, v in value2 = max(0, min(127, v)) }
                    case .bankSelectMSB:
                        LabeledContent("Bank MSB") {
                            TextField("0–127", value: $value1, format: .number)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 70)
                                .foregroundStyle(value1Formula.trimmingCharacters(in: .whitespaces).isEmpty ? .primary : .tertiary)
                        }
                        .onChange(of: value1) { _, v in value1 = max(0, min(127, v)) }
                    case .bankSelectLSB:
                        LabeledContent("Bank LSB") {
                            TextField("0–127", value: $value1, format: .number)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 70)
                                .foregroundStyle(value1Formula.trimmingCharacters(in: .whitespaces).isEmpty ? .primary : .tertiary)
                        }
                        .onChange(of: value1) { _, v in value1 = max(0, min(127, v)) }
                    case .oscMessage:
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
                    }
                }

                if commandType == .oscMessage {
                    OSCFormulaSection(
                        formula: $oscFormula,
                        result: oscFormulaResult,
                        error: oscFormulaError,
                        bpm: song.bpm
                    )
                } else {
                    MIDIValueFormulaSection(
                        commandType: commandType,
                        value1Formula: $value1Formula,
                        value2Formula: $value2Formula,
                        bpm: song.bpm
                    )
                }

                Section {
                    Stepper("Delay: \(delayMilliseconds)ms", value: $delayMilliseconds, in: 0...1000, step: 10)
                } header: {
                    Text("Timing")
                } footer: {
                    Text("Delay after this command before sending the next one.")
                }

                Section("Notes (Optional)") {
                    TextField("Add a description", text: $notes, axis: .vertical)
                        .lineLimit(2...4)
                }
            }
            .navigationTitle("Add Command")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Add") { addCommand() } }
            }
        }
    }

    private func addCommand() {
        let command: MIDICommand
        if commandType == .oscMessage {
            command = MIDICommand(commandType: .oscMessage, channel: nil, value1: 0,
                                  delayMilliseconds: delayMilliseconds,
                                  notes: notes.isEmpty ? nil : notes,
                                  context: viewContext)
            command.oscAddress = oscAddress.isEmpty ? nil : oscAddress
            command.oscFloatArg = oscFloatArg
            let trimFormula = oscFormula.trimmingCharacters(in: .whitespaces)
            command.oscFormula = trimFormula.isEmpty ? nil : trimFormula
        } else {
            command = MIDICommand(
                commandType: commandType,
                channel: useOmniChannel ? nil : channel,
                value1: value1,
                value2: commandType.requiresTwoValues ? value2 : nil,
                delayMilliseconds: delayMilliseconds,
                notes: notes.isEmpty ? nil : notes,
                context: viewContext
            )
            let v1f = value1Formula.trimmingCharacters(in: .whitespaces)
            let v2f = value2Formula.trimmingCharacters(in: .whitespaces)
            command.value1Formula = v1f.isEmpty ? nil : v1f
            command.value2Formula = v2f.isEmpty ? nil : v2f
        }
        song.addCommand(command, toSnapshot: snapshotIndex)
        try? viewContext.save()
        dismiss()
    }
}

struct EditMIDICommandView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) private var viewContext
    let command: MIDICommand

    @State private var commandType: MIDICommandType
    @State private var useOmniChannel: Bool
    @State private var channel: Int
    @State private var value1: Int
    @State private var value2: Int
    @State private var delayMilliseconds: Int
    @State private var notes: String
    @State private var oscAddress: String
    @State private var oscFloatArg: Double
    @State private var oscFormula: String
    @State private var value1Formula: String
    @State private var value2Formula: String

    init(command: MIDICommand) {
        self.command = command
        _commandType = State(initialValue: command.commandType)
        _useOmniChannel = State(initialValue: command.channel == nil)
        _channel = State(initialValue: command.channel ?? 1)
        _value1 = State(initialValue: command.value1)
        _value2 = State(initialValue: command.value2 ?? 0)
        _delayMilliseconds = State(initialValue: command.delayMilliseconds)
        _notes = State(initialValue: command.notes ?? "")
        _oscAddress = State(initialValue: command.oscAddress ?? "")
        _oscFloatArg = State(initialValue: command.oscFloatArg ?? 0.0)
        _oscFormula = State(initialValue: command.oscFormula ?? "")
        _value1Formula = State(initialValue: command.value1Formula ?? "")
        _value2Formula = State(initialValue: command.value2Formula ?? "")
    }

    private var formulaContext: FormulaEvaluator.Context {
        .forSong(bpm: command.song?.bpm)
    }

    private var oscFormulaResult: Double? {
        guard !oscFormula.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return FormulaEvaluator.evaluate(oscFormula, context: formulaContext)
    }

    private var oscFormulaError: String? {
        guard !oscFormula.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return FormulaEvaluator.errorDescription(for: oscFormula, context: formulaContext)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Command Type") {
                    Picker("Type", selection: $commandType) {
                        ForEach(MIDICommandType.allCases, id: \.self) { type in
                            Text(type.description).tag(type)
                        }
                    }
                }

                if commandType != .oscMessage {
                    Section("Channel") {
                        Toggle("Omni (All Channels)", isOn: $useOmniChannel)
                        if !useOmniChannel {
                            Picker("MIDI Channel", selection: $channel) {
                                ForEach(1...16, id: \.self) { Text("Channel \($0)").tag($0) }
                            }
                        }
                    }
                }

                Section("Values") {
                    switch commandType {
                    case .programChange:
                        LabeledContent("Program") {
                            TextField("0–127", value: $value1, format: .number)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 70)
                                .foregroundStyle(value1Formula.trimmingCharacters(in: .whitespaces).isEmpty ? .primary : .tertiary)
                        }
                        .onChange(of: value1) { _, v in value1 = max(0, min(127, v)) }
                    case .controlChange:
                        LabeledContent("CC Number") {
                            TextField("0–127", value: $value1, format: .number)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 70)
                        }
                        .onChange(of: value1) { _, v in value1 = max(0, min(127, v)) }
                        LabeledContent("CC Value") {
                            TextField("0–127", value: $value2, format: .number)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 70)
                                .foregroundStyle(value2Formula.trimmingCharacters(in: .whitespaces).isEmpty ? .primary : .tertiary)
                        }
                        .onChange(of: value2) { _, v in value2 = max(0, min(127, v)) }
                    case .bankSelectMSB:
                        LabeledContent("Bank MSB") {
                            TextField("0–127", value: $value1, format: .number)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 70)
                                .foregroundStyle(value1Formula.trimmingCharacters(in: .whitespaces).isEmpty ? .primary : .tertiary)
                        }
                        .onChange(of: value1) { _, v in value1 = max(0, min(127, v)) }
                    case .bankSelectLSB:
                        LabeledContent("Bank LSB") {
                            TextField("0–127", value: $value1, format: .number)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 70)
                                .foregroundStyle(value1Formula.trimmingCharacters(in: .whitespaces).isEmpty ? .primary : .tertiary)
                        }
                        .onChange(of: value1) { _, v in value1 = max(0, min(127, v)) }
                    case .oscMessage:
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
                    }
                }

                if commandType == .oscMessage {
                    OSCFormulaSection(
                        formula: $oscFormula,
                        result: oscFormulaResult,
                        error: oscFormulaError,
                        bpm: command.song?.bpm
                    )
                } else {
                    MIDIValueFormulaSection(
                        commandType: commandType,
                        value1Formula: $value1Formula,
                        value2Formula: $value2Formula,
                        bpm: command.song?.bpm
                    )
                }

                Section {
                    Stepper("Delay: \(delayMilliseconds)ms", value: $delayMilliseconds, in: 0...1000, step: 10)
                } header: {
                    Text("Timing")
                } footer: {
                    Text("Delay after this command before sending the next one.")
                }

                Section("Notes (Optional)") {
                    TextField("Add a description", text: $notes, axis: .vertical)
                        .lineLimit(2...4)
                }
            }
            .navigationTitle("Edit Command")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { saveChanges() } }
            }
        }
    }

    private func saveChanges() {
        command.commandType = commandType
        command.delayMilliseconds = delayMilliseconds
        command.notes = notes.isEmpty ? nil : notes
        command.song?.dateModified = Date()

        if commandType == .oscMessage {
            command.channel = nil
            command.value1 = 0
            command.value2 = nil
            command.oscAddress = oscAddress.isEmpty ? nil : oscAddress
            command.oscFloatArg = oscFloatArg
            let trimFormula = oscFormula.trimmingCharacters(in: .whitespaces)
            command.oscFormula = trimFormula.isEmpty ? nil : trimFormula
            command.value1Formula = nil
            command.value2Formula = nil
        } else {
            command.channel = useOmniChannel ? nil : channel
            command.value1 = value1
            command.value2 = commandType.requiresTwoValues ? value2 : nil
            command.oscAddress = nil
            command.oscFloatArg = nil
            command.oscFormula = nil
            let v1f = value1Formula.trimmingCharacters(in: .whitespaces)
            let v2f = value2Formula.trimmingCharacters(in: .whitespaces)
            command.value1Formula = v1f.isEmpty ? nil : v1f
            command.value2Formula = v2f.isEmpty ? nil : v2f
        }
        try? viewContext.save()
        dismiss()
    }
}

// MARK: - OSC Formula section (shared between Add and Edit)

struct OSCFormulaSection: View {
    @Binding var formula: String
    let result: Double?
    let error: String?
    let bpm: Int?

    var body: some View {
        Section {
            TextField("e.g. log(bpm / 60.0) / log(2.0)", text: $formula, axis: .vertical)
                .lineLimit(2...5)
                .keyboardType(.asciiCapable)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .font(.system(.body, design: .monospaced))

            if let result {
                LabeledContent("→ Result") {
                    Text(String(format: "%.6g", result))
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.green)
                }
            } else if let error, !formula.trimmingCharacters(in: .whitespaces).isEmpty {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Formula (optional)")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Overrides Float Value at send time. Leave blank to use the fixed value above.")
                Text("Variables: bpm\(bpm.map { " = \($0)" } ?? " (set in song)"), pi, e")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("Functions: log log10 exp sqrt pow abs clamp lognorm logmap db sin cos")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - MIDI Value Formula section (shared between Add and Edit)

struct MIDIValueFormulaSection: View {
    let commandType: MIDICommandType
    @Binding var value1Formula: String
    @Binding var value2Formula: String
    let bpm: Int?

    private var activeFormula: Binding<String> {
        commandType == .controlChange ? $value2Formula : $value1Formula
    }

    private var formulaResult: Double? {
        let f = activeFormula.wrappedValue
        guard !f.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return FormulaEvaluator.evaluate(f, context: .forSong(bpm: bpm))
    }

    private var formulaError: String? {
        let f = activeFormula.wrappedValue
        guard !f.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return FormulaEvaluator.errorDescription(for: f, context: .forSong(bpm: bpm))
    }

    private var headerLabel: String {
        switch commandType {
        case .controlChange:  return "CC Value Formula (Optional)"
        case .programChange:  return "Program Formula (Optional)"
        case .bankSelectMSB:  return "Bank MSB Formula (Optional)"
        case .bankSelectLSB:  return "Bank LSB Formula (Optional)"
        case .oscMessage:     return ""
        }
    }

    private var placeholder: String {
        switch commandType {
        case .controlChange:  return "e.g. bpm >= 128 ? 1 : 0"
        case .programChange:  return "e.g. floor(bpm / 10)"
        case .bankSelectMSB, .bankSelectLSB: return "e.g. floor(bpm / 12)"
        case .oscMessage:     return ""
        }
    }

    var body: some View {
        Section {
            TextField(placeholder, text: activeFormula, axis: .vertical)
                .lineLimit(2...5)
                .keyboardType(.asciiCapable)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .font(.system(.body, design: .monospaced))

            if let result = formulaResult {
                LabeledContent("→ Result") {
                    Text(String(format: "%.6g", result))
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.green)
                }
            } else if let error = formulaError,
                      !activeFormula.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } header: {
            Text(headerLabel)
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Overrides the fixed value above at send time. Leave blank to use the stepper.")
                Text("Variables: bpm\(bpm.map { " = \($0)" } ?? " (set in song)"), pi, e")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("Comparisons: > >= < <= == !=   Ternary: condition ? a : b")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

#Preview {
    let ctx = PersistenceController.preview.viewContext
    let song = Song.create(name: "Test Song", in: ctx)
    try? ctx.save()
    return AddMIDICommandView(song: song)
        .environment(\.managedObjectContext, ctx)
}
