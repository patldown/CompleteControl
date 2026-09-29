//
//  DeviceMacro.swift
//  Midi Set List
//

import CoreData
import Foundation

/// A macro is either a sequence of MIDI messages (MSB → LSB → PC → CC)
/// or a single OSC float message. Toggle `isOSC` to switch modes.
@objc(DeviceMacro)
class DeviceMacro: NSManagedObject, Identifiable {

    // ── Attributes ─────────────────────────────────────────────────────
    @NSManaged var id: UUID
    @NSManaged var name: String
    @NSManaged var notes: String?
    @NSManaged var isOSC: Bool
    @NSManaged var isGroup: Bool
    @NSManaged var oscAddress: String?
    /// Formula evaluated at send time for OSC float arg (overrides oscFloatArg when non-empty).
    @NSManaged var oscFormula: String?
    /// Formula evaluated at send time for CC value (overrides ccValue when non-empty).
    @NSManaged var ccValueFormula: String?
    /// Formula evaluated at send time for PC program number (overrides pcValue when non-empty).
    @NSManaged var pcValueFormula: String?
    /// JSON-encoded [String] of child macro UUID strings, in send order. Used when isGroup is true.
    @NSManaged var groupMacroOrderData: String?

    @NSManaged private var channelRaw: Int16
    @NSManaged private var delayMillisecondsRaw: Int32
    @NSManaged private var orderIndexRaw: Int32

    @NSManaged private var msbValueRaw: NSNumber?
    @NSManaged private var lsbValueRaw: NSNumber?
    @NSManaged private var pcValueRaw: NSNumber?
    @NSManaged private var ccNumberRaw: NSNumber?
    @NSManaged private var ccValueRaw: NSNumber?
    @NSManaged private var oscFloatArgRaw: NSNumber?

    // ── Public API (matching old SwiftData model) ──────────────────────
    var channel: Int {
        get { Int(channelRaw) }
        set { channelRaw = Int16(newValue) }
    }

    var delayMilliseconds: Int {
        get { Int(delayMillisecondsRaw) }
        set { delayMillisecondsRaw = Int32(newValue) }
    }

    var orderIndex: Int {
        get { Int(orderIndexRaw) }
        set { orderIndexRaw = Int32(newValue) }
    }

    var msbValue: Int? {
        get { msbValueRaw?.intValue }
        set { msbValueRaw = newValue.map { NSNumber(value: $0) } }
    }

    var lsbValue: Int? {
        get { lsbValueRaw?.intValue }
        set { lsbValueRaw = newValue.map { NSNumber(value: $0) } }
    }

    var pcValue: Int? {
        get { pcValueRaw?.intValue }
        set { pcValueRaw = newValue.map { NSNumber(value: $0) } }
    }

    var ccNumber: Int? {
        get { ccNumberRaw?.intValue }
        set { ccNumberRaw = newValue.map { NSNumber(value: $0) } }
    }

    var ccValue: Int? {
        get { ccValueRaw?.intValue }
        set { ccValueRaw = newValue.map { NSNumber(value: $0) } }
    }

    var oscFloatArg: Double? {
        get { oscFloatArgRaw?.doubleValue }
        set { oscFloatArgRaw = newValue.map { NSNumber(value: $0) } }
    }

    // ── Relationships ──────────────────────────────────────────────────
    @NSManaged var category: MacroCategory?

    // Commands generated from this macro across all songs
    @NSManaged private var generatedCommandsRaw: NSSet
    var generatedCommands: [MIDICommand] {
        (generatedCommandsRaw.allObjects as? [MIDICommand]) ?? []
    }

    // Group membership: a group macro contains ordered child macros
    @NSManaged private var childMacrosRaw: NSSet
    @NSManaged private var parentGroupsRaw: NSSet

    /// Child macros in the order specified by groupMacroOrderData.
    var childMacros: [DeviceMacro] {
        let all = (childMacrosRaw.allObjects as? [DeviceMacro]) ?? []
        guard let raw = groupMacroOrderData,
              let data = raw.data(using: .utf8),
              let ids = try? JSONDecoder().decode([String].self, from: data) else {
            return all.sorted { $0.orderIndex < $1.orderIndex }
        }
        let map = Dictionary(uniqueKeysWithValues: all.map { ($0.id.uuidString, $0) })
        return ids.compactMap { map[$0] }
    }

    func setChildMacros(_ macros: [DeviceMacro]) {
        let set = NSMutableSet()
        macros.forEach { set.add($0) }
        setValue(set, forKey: "childMacrosRaw")
        if let data = try? JSONEncoder().encode(macros.map { $0.id.uuidString }),
           let str = String(data: data, encoding: .utf8) {
            groupMacroOrderData = str
        }
    }

    // ── Factory ────────────────────────────────────────────────────────
    static func create(
        name: String,
        notes: String? = nil,
        channel: Int = 1,
        delayMilliseconds: Int = 50,
        orderIndex: Int = 0,
        msbValue: Int? = nil,
        lsbValue: Int? = nil,
        pcValue: Int? = nil,
        ccNumber: Int? = nil,
        ccValue: Int? = nil,
        isOSC: Bool = false,
        oscAddress: String? = nil,
        oscFloatArg: Double? = nil,
        in context: NSManagedObjectContext
    ) -> DeviceMacro {
        let m = DeviceMacro(context: context)
        m.id = UUID()
        m.name = name
        m.notes = notes
        m.channelRaw = Int16(channel)
        m.delayMillisecondsRaw = Int32(delayMilliseconds)
        m.orderIndexRaw = Int32(orderIndex)
        m.msbValue = msbValue
        m.lsbValue = lsbValue
        m.pcValue = pcValue
        m.ccNumber = ccNumber
        m.ccValue = ccValue
        m.isOSC = isOSC
        m.oscAddress = oscAddress
        m.oscFloatArg = oscFloatArg
        return m
    }

    // ── Command generation ─────────────────────────────────────────────

    /// Expands this macro into MIDICommand objects that can be added to a song.
    /// Pass the song's context so the commands are in the same store.
    func toMIDICommands(in context: NSManagedObjectContext) -> [MIDICommand] {
        if isGroup {
            return childMacros.flatMap { $0.toMIDICommands(in: context) }
        }

        if isOSC {
            guard let address = oscAddress,
                  !address.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
            let cmd = MIDICommand(commandType: .oscMessage, channel: nil, value1: 0,
                                  delayMilliseconds: delayMilliseconds, notes: name,
                                  context: context)
            cmd.oscAddress = address
            cmd.oscFloatArg = oscFloatArg
            let f = oscFormula?.trimmingCharacters(in: .whitespaces)
            cmd.oscFormula = (f?.isEmpty == false) ? f : nil
            return [cmd]
        }

        var commands: [MIDICommand] = []
        if let msb = msbValue {
            commands.append(MIDICommand(commandType: .bankSelectMSB, channel: channel,
                                        value1: msb, delayMilliseconds: 20,
                                        notes: "\(name) – MSB", context: context))
        }
        if let lsb = lsbValue {
            commands.append(MIDICommand(commandType: .bankSelectLSB, channel: channel,
                                        value1: lsb, delayMilliseconds: 20,
                                        notes: "\(name) – LSB", context: context))
        }
        if let pc = pcValue {
            let cmd = MIDICommand(commandType: .programChange, channel: channel,
                                  value1: pc, delayMilliseconds: 20,
                                  notes: "\(name) – PC", context: context)
            let f = pcValueFormula?.trimmingCharacters(in: .whitespaces)
            cmd.value1Formula = (f?.isEmpty == false) ? f : nil
            commands.append(cmd)
        }
        if let ccNum = ccNumber {
            let cmd = MIDICommand(commandType: .controlChange, channel: channel,
                                  value1: ccNum, value2: ccValue ?? 0,
                                  delayMilliseconds: 20,
                                  notes: "\(name) – CC", context: context)
            let f = ccValueFormula?.trimmingCharacters(in: .whitespaces)
            cmd.value2Formula = (f?.isEmpty == false) ? f : nil
            commands.append(cmd)
        }
        if !commands.isEmpty {
            commands[commands.count - 1].delayMilliseconds = delayMilliseconds
        }
        return commands
    }

    // ── Computed properties ────────────────────────────────────────────
    var hasAnyCommand: Bool {
        if isGroup { return !childMacros.isEmpty }
        if isOSC { return !(oscAddress ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
        return msbValue != nil || lsbValue != nil || pcValue != nil || ccNumber != nil
    }

    var hasOSCFormula: Bool { !(oscFormula ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
    var hasCCFormula:  Bool { !(ccValueFormula ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
    var hasPCFormula:  Bool { !(pcValueFormula ?? "").trimmingCharacters(in: .whitespaces).isEmpty }

    var displayDescription: String {
        if isGroup {
            let children = childMacros
            if children.isEmpty { return "Empty group" }
            let names = children.prefix(3).map(\.name).joined(separator: " → ")
            let extra = children.count > 3 ? " → …" : ""
            return "Group: \(names)\(extra)"
        }
        if isOSC {
            let addr = oscAddress ?? "(no address)"
            if hasOSCFormula { return "OSC \(addr) [formula]" }
            if let val = oscFloatArg { return "OSC \(addr) → \(String(format: "%.4g", val))" }
            return "OSC \(addr)"
        }
        var parts: [String] = []
        if let msb = msbValue { parts.append("MSB \(msb)") }
        if let lsb = lsbValue { parts.append("LSB \(lsb)") }
        if let pc  = pcValue  { parts.append(hasPCFormula  ? "PC[formula]"           : "PC \(pc)") }
        if let ccN = ccNumber { parts.append(hasCCFormula  ? "CC#\(ccN)[formula]"    : "CC#\(ccN)=\(ccValue ?? 0)") }
        guard !parts.isEmpty else { return "No commands" }
        return parts.joined(separator: " → ") + " [Ch \(channel)]"
    }

    // ── Drift detection ────────────────────────────────────────────────

    /// Lightweight snapshot of one command's identity — used for drift comparison
    /// without having to create managed objects.
    struct CommandSignature: Equatable {
        var type: MIDICommandType
        var channel: Int?
        var value1: Int
        var value2: Int?
        var value1Formula: String?
        var value2Formula: String?
        var oscAddress: String?
        var oscFormula: String?
    }

    /// The sequence of command signatures this macro would produce right now.
    var expectedSignatures: [CommandSignature] {
        if isGroup { return childMacros.flatMap { $0.expectedSignatures } }
        if isOSC {
            guard let addr = oscAddress, !addr.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
            return [CommandSignature(type: .oscMessage, channel: nil, value1: 0, value2: nil,
                                     value1Formula: nil, value2Formula: nil,
                                     oscAddress: addr, oscFormula: trimmed(oscFormula))]
        }
        var sigs: [CommandSignature] = []
        if let msb = msbValue {
            sigs.append(CommandSignature(type: .bankSelectMSB, channel: channel, value1: msb,
                                          value2: nil, value1Formula: nil, value2Formula: nil,
                                          oscAddress: nil, oscFormula: nil))
        }
        if let lsb = lsbValue {
            sigs.append(CommandSignature(type: .bankSelectLSB, channel: channel, value1: lsb,
                                          value2: nil, value1Formula: nil, value2Formula: nil,
                                          oscAddress: nil, oscFormula: nil))
        }
        if let pc = pcValue {
            sigs.append(CommandSignature(type: .programChange, channel: channel, value1: pc,
                                          value2: nil, value1Formula: trimmed(pcValueFormula),
                                          value2Formula: nil, oscAddress: nil, oscFormula: nil))
        }
        if let ccN = ccNumber {
            sigs.append(CommandSignature(type: .controlChange, channel: channel, value1: ccN,
                                          value2: ccValue ?? 0, value1Formula: nil,
                                          value2Formula: trimmed(ccValueFormula),
                                          oscAddress: nil, oscFormula: nil))
        }
        return sigs
    }

    /// Songs that contain commands from this macro whose values no longer match
    /// what the macro would produce today.
    var driftingSongs: [Song] {
        let expected = expectedSignatures
        return Dictionary(grouping: generatedCommands.compactMap(\.song), by: \.objectID)
            .values
            .compactMap(\.first)
            .filter { song in
                let cmds = song.sortedCommands.filter { $0.sourceMacro?.objectID == objectID }
                guard cmds.count == expected.count else { return true }
                return zip(cmds, expected).contains { cmd, sig in
                    cmd.commandType    != sig.type         ||
                    cmd.channel        != sig.channel      ||
                    cmd.value1         != sig.value1       ||
                    cmd.value2         != sig.value2       ||
                    trimmed(cmd.value1Formula) != sig.value1Formula ||
                    trimmed(cmd.value2Formula) != sig.value2Formula ||
                    cmd.oscAddress     != sig.oscAddress   ||
                    trimmed(cmd.oscFormula)    != sig.oscFormula
                }
            }
            .sorted { $0.name < $1.name }
    }

    var hasDrift: Bool { !driftingSongs.isEmpty }

    private func trimmed(_ s: String?) -> String? {
        let t = s?.trimmingCharacters(in: .whitespaces)
        return t?.isEmpty == false ? t : nil
    }
}
