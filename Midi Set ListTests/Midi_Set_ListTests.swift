//
//  Midi_Set_ListTests.swift
//  Midi Set ListTests
//

import Testing
import CoreData
import Foundation
@testable import Midi_Set_List

// MARK: - MIDICommandType

@Suite("MIDICommandType")
struct MIDICommandTypeTests {

    @Test func shortCodes() {
        #expect(MIDICommandType.programChange.shortCode == "PC")
        #expect(MIDICommandType.controlChange.shortCode == "CC")
        #expect(MIDICommandType.bankSelectMSB.shortCode == "Bank MSB")
        #expect(MIDICommandType.bankSelectLSB.shortCode == "Bank LSB")
        #expect(MIDICommandType.oscMessage.shortCode == "OSC")
    }

    @Test func requiresTwoValues() {
        #expect(MIDICommandType.controlChange.requiresTwoValues)
        #expect(!MIDICommandType.programChange.requiresTwoValues)
        #expect(!MIDICommandType.bankSelectMSB.requiresTwoValues)
        #expect(!MIDICommandType.bankSelectLSB.requiresTwoValues)
        #expect(!MIDICommandType.oscMessage.requiresTwoValues)
    }

    @Test func isMIDI() {
        #expect(MIDICommandType.programChange.isMIDI)
        #expect(MIDICommandType.controlChange.isMIDI)
        #expect(MIDICommandType.bankSelectMSB.isMIDI)
        #expect(MIDICommandType.bankSelectLSB.isMIDI)
        #expect(!MIDICommandType.oscMessage.isMIDI)
    }

    @Test func ccNumbers() {
        #expect(MIDICommandType.bankSelectMSB.ccNumber == 0)
        #expect(MIDICommandType.bankSelectLSB.ccNumber == 32)
        #expect(MIDICommandType.programChange.ccNumber == nil)
        #expect(MIDICommandType.controlChange.ccNumber == nil)
        #expect(MIDICommandType.oscMessage.ccNumber == nil)
    }
}

// MARK: - MIDICommand

@Suite("MIDICommand")
struct MIDICommandTests {

    let controller = PersistenceController(inMemory: true)
    var ctx: NSManagedObjectContext { controller.viewContext }

    @Test func displayDescription_programChange_withChannel() {
        let cmd = MIDICommand(commandType: .programChange, channel: 3, value1: 12, context: ctx)
        #expect(cmd.displayDescription == "PC 12 [Ch 3]")
    }

    @Test func displayDescription_programChange_omni() {
        let cmd = MIDICommand(commandType: .programChange, channel: nil, value1: 5, context: ctx)
        #expect(cmd.displayDescription == "PC 5 [Omni]")
    }

    @Test func displayDescription_controlChange() {
        let cmd = MIDICommand(commandType: .controlChange, channel: 1, value1: 7, value2: 100, context: ctx)
        #expect(cmd.displayDescription == "CC #7 = 100 [Ch 1]")
    }

    @Test func displayDescription_bankSelectMSB() {
        let cmd = MIDICommand(commandType: .bankSelectMSB, channel: 2, value1: 0, context: ctx)
        #expect(cmd.displayDescription == "Bank MSB 0 [Ch 2]")
    }

    @Test func displayDescription_bankSelectLSB() {
        let cmd = MIDICommand(commandType: .bankSelectLSB, channel: 1, value1: 32, context: ctx)
        #expect(cmd.displayDescription == "Bank LSB 32 [Ch 1]")
    }

    @Test func displayDescription_oscMessage_withFloat() {
        let cmd = MIDICommand(commandType: .oscMessage, channel: nil, value1: 0, context: ctx)
        cmd.oscAddress = "/ch/01/mix/fader"
        cmd.oscFloatArg = 0.75
        #expect(cmd.displayDescription == "OSC /ch/01/mix/fader → 0.75")
    }

    @Test func displayDescription_oscMessage_noFloat() {
        let cmd = MIDICommand(commandType: .oscMessage, channel: nil, value1: 0, context: ctx)
        cmd.oscAddress = "/main/mix/on"
        #expect(cmd.displayDescription == "OSC /main/mix/on")
    }

    @Test func displayDescription_oscMessage_noAddress() {
        let cmd = MIDICommand(commandType: .oscMessage, channel: nil, value1: 0, context: ctx)
        #expect(cmd.displayDescription == "OSC (no address)")
    }

    // MARK: Formula display descriptions

    @Test func displayDescription_controlChange_withV2Formula() {
        let cmd = MIDICommand(commandType: .controlChange, channel: 1, value1: 106, value2: 0, context: ctx)
        cmd.value2Formula = "bpm >= 128 ? 1 : 0"
        #expect(cmd.displayDescription == "CC #106 [formula] [Ch 1]")
    }

    @Test func displayDescription_programChange_withV1Formula() {
        let cmd = MIDICommand(commandType: .programChange, channel: 2, value1: 5, context: ctx)
        cmd.value1Formula = "floor(bpm / 10)"
        #expect(cmd.displayDescription == "PC [formula] [Ch 2]")
    }

    @Test func displayDescription_bankMSB_withV1Formula() {
        let cmd = MIDICommand(commandType: .bankSelectMSB, channel: 1, value1: 0, context: ctx)
        cmd.value1Formula = "bpm > 64 ? 1 : 0"
        #expect(cmd.displayDescription == "Bank MSB [formula] [Ch 1]")
    }

    @Test func displayDescription_bankLSB_withV1Formula() {
        let cmd = MIDICommand(commandType: .bankSelectLSB, channel: 1, value1: 0, context: ctx)
        cmd.value1Formula = "bpm > 64 ? 1 : 0"
        #expect(cmd.displayDescription == "Bank LSB [formula] [Ch 1]")
    }

    @Test func displayDescription_oscMessage_withFormula() {
        let cmd = MIDICommand(commandType: .oscMessage, channel: nil, value1: 0, context: ctx)
        cmd.oscAddress = "/ch/01/mix/fader"
        cmd.oscFormula = "bpm / 180.0"
        #expect(cmd.displayDescription == "OSC /ch/01/mix/fader [formula]")
    }

    @Test func displayDescription_controlChange_whitespaceFormula_notTreatedAsFormula() {
        let cmd = MIDICommand(commandType: .controlChange, channel: 1, value1: 7, value2: 64, context: ctx)
        cmd.value2Formula = "   "
        #expect(cmd.displayDescription == "CC #7 = 64 [Ch 1]")
    }

    // MARK: hasValueFormula helpers

    @Test func hasValue1Formula_false_whenNil() {
        let cmd = MIDICommand(commandType: .programChange, channel: 1, value1: 5, context: ctx)
        #expect(!cmd.hasValue1Formula)
    }

    @Test func hasValue1Formula_true_whenSet() {
        let cmd = MIDICommand(commandType: .programChange, channel: 1, value1: 5, context: ctx)
        cmd.value1Formula = "bpm / 10"
        #expect(cmd.hasValue1Formula)
    }

    @Test func hasValue2Formula_false_whenNil() {
        let cmd = MIDICommand(commandType: .controlChange, channel: 1, value1: 0, value2: 0, context: ctx)
        #expect(!cmd.hasValue2Formula)
    }

    @Test func hasValue2Formula_false_whenWhitespace() {
        let cmd = MIDICommand(commandType: .controlChange, channel: 1, value1: 0, value2: 0, context: ctx)
        cmd.value2Formula = "   "
        #expect(!cmd.hasValue2Formula)
    }

    @Test func hasValue2Formula_true_whenSet() {
        let cmd = MIDICommand(commandType: .controlChange, channel: 1, value1: 0, value2: 0, context: ctx)
        cmd.value2Formula = "bpm >= 128 ? 1 : 0"
        #expect(cmd.hasValue2Formula)
    }

    // MARK: isValid

    @Test func isValid_normalMIDI() {
        let cmd = MIDICommand(commandType: .programChange, channel: 1, value1: 64, context: ctx)
        #expect(cmd.isValid)
    }

    @Test func isValid_channelTooHigh() {
        let cmd = MIDICommand(commandType: .programChange, channel: 17, value1: 0, context: ctx)
        #expect(!cmd.isValid)
    }

    @Test func isValid_channelTooLow() {
        let cmd = MIDICommand(commandType: .programChange, channel: 0, value1: 0, context: ctx)
        #expect(!cmd.isValid)
    }

    @Test func isValid_valueTooHigh() {
        let cmd = MIDICommand(commandType: .programChange, channel: 1, value1: 128, context: ctx)
        #expect(!cmd.isValid)
    }

    @Test func isValid_omniChannel() {
        let cmd = MIDICommand(commandType: .controlChange, channel: nil, value1: 7, value2: 64, context: ctx)
        #expect(cmd.isValid)
    }

    @Test func isValid_oscWithAddress() {
        let cmd = MIDICommand(commandType: .oscMessage, channel: nil, value1: 0, context: ctx)
        cmd.oscAddress = "/ch/01/mix/fader"
        #expect(cmd.isValid)
    }

    @Test func isValid_oscNoAddress() {
        let cmd = MIDICommand(commandType: .oscMessage, channel: nil, value1: 0, context: ctx)
        #expect(!cmd.isValid)
    }

    @Test func isValid_oscWhitespaceOnlyAddress() {
        let cmd = MIDICommand(commandType: .oscMessage, channel: nil, value1: 0, context: ctx)
        cmd.oscAddress = "   "
        #expect(!cmd.isValid)
    }
}

// MARK: - DeviceMacro

@Suite("DeviceMacro")
struct DeviceMacroTests {

    let controller = PersistenceController(inMemory: true)
    var ctx: NSManagedObjectContext { controller.viewContext }

    // MARK: toMIDICommands — ordering

    @Test func msbSentBeforeLsb() {
        let macro = DeviceMacro.create(name: "Test", msbValue: 2, lsbValue: 5, in: ctx)
        let cmds = macro.toMIDICommands(in: ctx)
        #expect(cmds.count == 2)
        #expect(cmds[0].commandType == .bankSelectMSB)
        #expect(cmds[0].value1 == 2)
        #expect(cmds[1].commandType == .bankSelectLSB)
        #expect(cmds[1].value1 == 5)
    }

    @Test func fullSequence_orderIsMSB_LSB_PC_CC() {
        let macro = DeviceMacro.create(name: "Test", channel: 2,
                                       msbValue: 1, lsbValue: 0, pcValue: 15,
                                       ccNumber: 69, ccValue: 3, in: ctx)
        let cmds = macro.toMIDICommands(in: ctx)
        #expect(cmds.count == 4)
        #expect(cmds[0].commandType == .bankSelectMSB)
        #expect(cmds[1].commandType == .bankSelectLSB)
        #expect(cmds[2].commandType == .programChange)
        #expect(cmds[3].commandType == .controlChange)
    }

    @Test func allCommandsUseDeviceChannel() {
        let macro = DeviceMacro.create(name: "Test", channel: 5, msbValue: 0, pcValue: 3, in: ctx)
        let cmds = macro.toMIDICommands(in: ctx)
        #expect(cmds.allSatisfy { $0.channel == 5 })
    }

    // MARK: toMIDICommands — nil slot skipping

    @Test func skipsNilSlots_pcOnly() {
        let macro = DeviceMacro.create(name: "Test", pcValue: 7, in: ctx)
        let cmds = macro.toMIDICommands(in: ctx)
        #expect(cmds.count == 1)
        #expect(cmds[0].commandType == .programChange)
        #expect(cmds[0].value1 == 7)
    }

    @Test func skipsNilSlots_ccOnly() {
        let macro = DeviceMacro.create(name: "Test", ccNumber: 11, ccValue: 64, in: ctx)
        let cmds = macro.toMIDICommands(in: ctx)
        #expect(cmds.count == 1)
        #expect(cmds[0].commandType == .controlChange)
        #expect(cmds[0].value1 == 11)
        #expect(cmds[0].value2 == 64)
    }

    @Test func emptyWhenNoCommandsSet() {
        let macro = DeviceMacro.create(name: "Test", in: ctx)
        #expect(macro.toMIDICommands(in: ctx).isEmpty)
    }

    // MARK: toMIDICommands — delay behaviour

    @Test func delayAppliedToLastCommandOnly() {
        let macro = DeviceMacro.create(name: "Test", delayMilliseconds: 150,
                                       msbValue: 0, lsbValue: 0, pcValue: 5, in: ctx)
        let cmds = macro.toMIDICommands(in: ctx)
        #expect(cmds[0].delayMilliseconds == 20)   // inter-command fixed gap
        #expect(cmds[1].delayMilliseconds == 20)
        #expect(cmds[2].delayMilliseconds == 150)  // configured delay on last
    }

    @Test func singleCommand_usesConfiguredDelay() {
        let macro = DeviceMacro.create(name: "Test", delayMilliseconds: 200, pcValue: 3, in: ctx)
        let cmds = macro.toMIDICommands(in: ctx)
        #expect(cmds.count == 1)
        #expect(cmds[0].delayMilliseconds == 200)
    }

    // MARK: toMIDICommands — OSC mode

    @Test func oscMode_returnsSingleOSCCommand() {
        let macro = DeviceMacro.create(name: "Fader Up", isOSC: true,
                                       oscAddress: "/ch/01/mix/fader", oscFloatArg: 1.0, in: ctx)
        let cmds = macro.toMIDICommands(in: ctx)
        #expect(cmds.count == 1)
        #expect(cmds[0].commandType == .oscMessage)
        #expect(cmds[0].oscAddress == "/ch/01/mix/fader")
        #expect(cmds[0].oscFloatArg == 1.0)
    }

    @Test func oscMode_noAddress_returnsEmpty() {
        let macro = DeviceMacro.create(name: "Test", isOSC: true, in: ctx)
        #expect(macro.toMIDICommands(in: ctx).isEmpty)
    }

    @Test func oscMode_whitespaceAddress_returnsEmpty() {
        let macro = DeviceMacro.create(name: "Test", isOSC: true, oscAddress: "   ", in: ctx)
        #expect(macro.toMIDICommands(in: ctx).isEmpty)
    }

    @Test func oscMode_commandUsesConfiguredDelay() {
        let macro = DeviceMacro.create(name: "Test", delayMilliseconds: 80,
                                       isOSC: true, oscAddress: "/main/mix/on", in: ctx)
        let cmds = macro.toMIDICommands(in: ctx)
        #expect(cmds[0].delayMilliseconds == 80)
    }

    // MARK: toMIDICommands — formula propagation

    @Test func ccFormula_propagatesToGeneratedCommand() {
        let macro = DeviceMacro.create(name: "Test", ccNumber: 106, ccValue: 0, in: ctx)
        macro.ccValueFormula = "bpm >= 128 ? 1 : 0"
        let cmds = macro.toMIDICommands(in: ctx)
        #expect(cmds.count == 1)
        #expect(cmds[0].value2Formula == "bpm >= 128 ? 1 : 0")
    }

    @Test func pcFormula_propagatesToGeneratedCommand() {
        let macro = DeviceMacro.create(name: "Test", pcValue: 5, in: ctx)
        macro.pcValueFormula = "floor(bpm / 10)"
        let cmds = macro.toMIDICommands(in: ctx)
        #expect(cmds.count == 1)
        #expect(cmds[0].value1Formula == "floor(bpm / 10)")
    }

    @Test func oscFormula_propagatesToGeneratedCommand() {
        let macro = DeviceMacro.create(name: "Test", isOSC: true,
                                       oscAddress: "/ch/01/mix/fader", in: ctx)
        macro.oscFormula = "bpm / 180.0"
        let cmds = macro.toMIDICommands(in: ctx)
        #expect(cmds.count == 1)
        #expect(cmds[0].oscFormula == "bpm / 180.0")
    }

    @Test func nilFormula_doesNotPropagateToGeneratedCommand() {
        let macro = DeviceMacro.create(name: "Test", ccNumber: 7, ccValue: 100, in: ctx)
        let cmds = macro.toMIDICommands(in: ctx)
        #expect(cmds[0].value2Formula == nil)
    }

    @Test func whitespaceOnlyFormula_doesNotPropagateToGeneratedCommand() {
        let macro = DeviceMacro.create(name: "Test", ccNumber: 7, ccValue: 100, in: ctx)
        macro.ccValueFormula = "   "
        let cmds = macro.toMIDICommands(in: ctx)
        #expect(cmds[0].value2Formula == nil)
    }

    // MARK: hasAnyCommand

    @Test func hasAnyCommand_falseWhenAllNil() {
        #expect(!DeviceMacro.create(name: "Test", in: ctx).hasAnyCommand)
    }

    @Test func hasAnyCommand_trueForEachMIDISlot() {
        #expect(DeviceMacro.create(name: "T", msbValue: 0, in: ctx).hasAnyCommand)
        #expect(DeviceMacro.create(name: "T", lsbValue: 0, in: ctx).hasAnyCommand)
        #expect(DeviceMacro.create(name: "T", pcValue: 0, in: ctx).hasAnyCommand)
        #expect(DeviceMacro.create(name: "T", ccNumber: 0, in: ctx).hasAnyCommand)
    }

    @Test func hasAnyCommand_osc_trueWhenAddressSet() {
        #expect(!DeviceMacro.create(name: "T", isOSC: true, in: ctx).hasAnyCommand)
        #expect(DeviceMacro.create(name: "T", isOSC: true, oscAddress: "/test", in: ctx).hasAnyCommand)
        #expect(!DeviceMacro.create(name: "T", isOSC: true, oscAddress: "  ", in: ctx).hasAnyCommand)
    }

    // MARK: displayDescription

    @Test func displayDescription_midiMode_msbLsbPC() {
        let macro = DeviceMacro.create(name: "T", channel: 1,
                                       msbValue: 2, lsbValue: 0, pcValue: 5, in: ctx)
        #expect(macro.displayDescription == "MSB 2 → LSB 0 → PC 5 [Ch 1]")
    }

    @Test func displayDescription_midiMode_noCommands() {
        let macro = DeviceMacro.create(name: "T", in: ctx)
        #expect(macro.displayDescription == "No commands")
    }

    @Test func displayDescription_oscMode() {
        let macro = DeviceMacro.create(name: "T", isOSC: true,
                                       oscAddress: "/ch/01/mix/fader", oscFloatArg: 0.75, in: ctx)
        #expect(macro.displayDescription == "OSC /ch/01/mix/fader → 0.75")
    }

    @Test func displayDescription_oscMode_noFloat() {
        let macro = DeviceMacro.create(name: "T", isOSC: true, oscAddress: "/main/mix/on", in: ctx)
        #expect(macro.displayDescription == "OSC /main/mix/on")
    }

    @Test func displayDescription_oscMode_withFormula() {
        let macro = DeviceMacro.create(name: "T", isOSC: true,
                                       oscAddress: "/ch/01/mix/fader", oscFloatArg: 0.0, in: ctx)
        macro.oscFormula = "bpm / 180.0"
        #expect(macro.displayDescription == "OSC /ch/01/mix/fader [formula]")
    }

    @Test func displayDescription_cc_withFormula() {
        let macro = DeviceMacro.create(name: "T", channel: 1, ccNumber: 106, ccValue: 0, in: ctx)
        macro.ccValueFormula = "bpm >= 128 ? 1 : 0"
        #expect(macro.displayDescription == "CC#106[formula] [Ch 1]")
    }

    @Test func displayDescription_pc_withFormula() {
        let macro = DeviceMacro.create(name: "T", channel: 3, pcValue: 5, in: ctx)
        macro.pcValueFormula = "floor(bpm / 10)"
        #expect(macro.displayDescription == "PC[formula] [Ch 3]")
    }
}

// MARK: - FormulaEvaluator

@Suite("FormulaEvaluator")
struct FormulaEvaluatorTests {

    func eval(_ s: String, bpm: Int = 0) -> Double? {
        FormulaEvaluator.evaluate(s, context: .forSong(bpm: bpm))
    }

    // MARK: Arithmetic regression

    @Test func addition()       { #expect(eval("1 + 2") == 3) }
    @Test func subtraction()    { #expect(eval("10 - 3") == 7) }
    @Test func multiplication() { #expect(eval("3 * 4") == 12) }
    @Test func division()       { #expect(eval("8 / 2") == 4) }
    @Test func power()          { #expect(eval("2^8") == 256) }
    @Test func unaryNegative()  { #expect(eval("-5 + 3") == -2) }
    @Test func bpmVariable()    { #expect(eval("bpm + 10", bpm: 120) == 130) }
    @Test func piConstant()     { #expect(eval("pi") ?? 0 > 3.14 && eval("pi") ?? 0 < 3.15) }
    @Test func floorFunction()  { #expect(eval("floor(3.7)") == 3) }
    @Test func minFunction()    { #expect(eval("min(5, 3)") == 3) }
    @Test func maxFunction()    { #expect(eval("max(5, 3)") == 5) }

    // MARK: Comparison operators (return 1.0 = true, 0.0 = false)

    @Test func gt_true()   { #expect(eval("5 > 3") == 1) }
    @Test func gt_false()  { #expect(eval("3 > 5") == 0) }
    @Test func gt_equal()  { #expect(eval("5 > 5") == 0) }

    @Test func ge_above()  { #expect(eval("6 >= 5") == 1) }
    @Test func ge_equal()  { #expect(eval("5 >= 5") == 1) }
    @Test func ge_below()  { #expect(eval("4 >= 5") == 0) }

    @Test func lt_true()   { #expect(eval("3 < 5") == 1) }
    @Test func lt_false()  { #expect(eval("5 < 3") == 0) }
    @Test func lt_equal()  { #expect(eval("5 < 5") == 0) }

    @Test func le_below()  { #expect(eval("4 <= 5") == 1) }
    @Test func le_equal()  { #expect(eval("5 <= 5") == 1) }
    @Test func le_above()  { #expect(eval("6 <= 5") == 0) }

    @Test func eq_equal()  { #expect(eval("7 == 7") == 1) }
    @Test func eq_unequal(){ #expect(eval("7 == 8") == 0) }

    @Test func ne_unequal(){ #expect(eval("7 != 8") == 1) }
    @Test func ne_equal()  { #expect(eval("7 != 7") == 0) }

    @Test func comparison_uses_bpm() {
        #expect(eval("bpm > 100", bpm: 150) == 1)
        #expect(eval("bpm > 100", bpm: 90)  == 0)
    }

    @Test func comparison_withArithmetic() {
        #expect(eval("bpm + 10 > 130", bpm: 120) == 1)  // 130 > 130 is false
        #expect(eval("bpm + 10 > 129", bpm: 120) == 1)  // 130 > 129 is true
    }

    // MARK: Ternary operator

    @Test func ternary_trueCondition()  { #expect(eval("1 ? 10 : 20") == 10) }
    @Test func ternary_falseCondition() { #expect(eval("0 ? 10 : 20") == 20) }

    @Test func ternary_withComparison_true()  { #expect(eval("3 > 2 ? 99 : 1") == 99) }
    @Test func ternary_withComparison_false() { #expect(eval("2 > 3 ? 99 : 1") == 1) }

    @Test func ternary_branches_can_have_arithmetic() {
        #expect(eval("1 > 0 ? 2 * 3 : 10 + 1") == 6)
        #expect(eval("0 > 1 ? 2 * 3 : 10 + 1") == 11)
    }

    @Test func ternary_withBPM_high()  { #expect(eval("bpm >= 128 ? 1 : 0", bpm: 150) == 1) }
    @Test func ternary_withBPM_low()   { #expect(eval("bpm >= 128 ? 1 : 0", bpm: 90)  == 0) }
    @Test func ternary_withBPM_exact() { #expect(eval("bpm >= 128 ? 1 : 0", bpm: 128) == 1) }

    // MARK: BeatBuddy BPM formulas (primary use case)

    @Test func beatbuddy_msb_at90()  { #expect(eval("bpm >= 128 ? 1 : 0", bpm: 90)  == 0) }
    @Test func beatbuddy_msb_at127() { #expect(eval("bpm >= 128 ? 1 : 0", bpm: 127) == 0) }
    @Test func beatbuddy_msb_at128() { #expect(eval("bpm >= 128 ? 1 : 0", bpm: 128) == 1) }
    @Test func beatbuddy_msb_at173() { #expect(eval("bpm >= 128 ? 1 : 0", bpm: 173) == 1) }
    @Test func beatbuddy_msb_at255() { #expect(eval("bpm >= 128 ? 1 : 0", bpm: 255) == 1) }

    @Test func beatbuddy_lsb_at90()  { #expect(eval("bpm >= 128 ? bpm - 128 : bpm", bpm: 90)  == 90) }
    @Test func beatbuddy_lsb_at127() { #expect(eval("bpm >= 128 ? bpm - 128 : bpm", bpm: 127) == 127) }
    @Test func beatbuddy_lsb_at128() { #expect(eval("bpm >= 128 ? bpm - 128 : bpm", bpm: 128) == 0) }
    @Test func beatbuddy_lsb_at173() { #expect(eval("bpm >= 128 ? bpm - 128 : bpm", bpm: 173) == 45) }
    @Test func beatbuddy_lsb_at180() { #expect(eval("bpm >= 128 ? bpm - 128 : bpm", bpm: 180) == 52) }

    // Both formulas together add up to the original BPM
    @Test func beatbuddy_msb_lsb_reconstruct() {
        for bpm in [90, 120, 127, 128, 140, 173, 200, 250] {
            let msb = eval("bpm >= 128 ? 1 : 0", bpm: bpm) ?? -1
            let lsb = eval("bpm >= 128 ? bpm - 128 : bpm", bpm: bpm) ?? -1
            #expect(Int(msb) * 128 + Int(lsb) == bpm, "Failed for BPM \(bpm)")
        }
    }

    // MARK: Error cases

    @Test func missingColon_returnsNil() {
        #expect(eval("1 ? 2") == nil)
    }

    @Test func unknownVariable_returnsNil() {
        #expect(eval("foo") == nil)
    }

    @Test func divisionByZero_returnsNil() {
        #expect(eval("1 / 0") == nil)
    }

    @Test func emptyString_returnsNil() {
        #expect(eval("") == nil)
    }

    @Test func whitespaceOnly_returnsNil() {
        #expect(eval("   ") == nil)
    }
}

// MARK: - OSCEncoder

@Suite("OSCEncoder")
struct OSCEncoderTests {

    // MARK: padded

    @Test func padded_alwaysMultipleOf4() {
        for length in 0...20 {
            let str = String(repeating: "x", count: length)
            let data = OSCEncoder.padded(str)
            #expect(data.count % 4 == 0,
                    "padded(\"\(str)\") count \(data.count) not divisible by 4")
        }
    }

    @Test func padded_containsNullTerminator() {
        let data = OSCEncoder.padded("hi")
        #expect(data.count == 4)
        #expect(data[2] == 0x00)
    }

    @Test func padded_3ByteString_padsTo4() {
        let data = OSCEncoder.padded("/ab")
        #expect(data.count == 4)
        #expect(data[3] == 0x00)
    }

    @Test func padded_4ByteString_padsTo8() {
        let data = OSCEncoder.padded("abcd")
        #expect(data.count == 8)
    }

    // MARK: encode — structure

    @Test func encode_noArg_correctByteCount() {
        let data = OSCEncoder.encode(address: "/ab", floatArg: nil)
        #expect(data.count == 8)
    }

    @Test func encode_floatArg_correctByteCount() {
        let data = OSCEncoder.encode(address: "/ab", floatArg: 1.0)
        #expect(data.count == 12)
    }

    @Test func encode_addressBytesAtStart() {
        let data = OSCEncoder.encode(address: "/ab", floatArg: nil)
        #expect(data[0] == 0x2F)
        #expect(data[1] == 0x61)
        #expect(data[2] == 0x62)
        #expect(data[3] == 0x00)
    }

    @Test func encode_typeTag_noArg() {
        let data = OSCEncoder.encode(address: "/ab", floatArg: nil)
        #expect(data[4] == UInt8(ascii: ","))
        #expect(data[5] == 0x00)
        #expect(data[6] == 0x00)
        #expect(data[7] == 0x00)
    }

    @Test func encode_typeTag_floatArg() {
        let data = OSCEncoder.encode(address: "/ab", floatArg: 1.0)
        #expect(data[4] == UInt8(ascii: ","))
        #expect(data[5] == UInt8(ascii: "f"))
        #expect(data[6] == 0x00)
        #expect(data[7] == 0x00)
    }

    // MARK: encode — float bytes (big-endian IEEE 754)

    @Test func encode_float_one_bigEndian() {
        let data = OSCEncoder.encode(address: "/ab", floatArg: 1.0)
        #expect(data[8]  == 0x3F)
        #expect(data[9]  == 0x80)
        #expect(data[10] == 0x00)
        #expect(data[11] == 0x00)
    }

    @Test func encode_float_zero_bigEndian() {
        let data = OSCEncoder.encode(address: "/ab", floatArg: 0.0)
        #expect(data[8]  == 0x00)
        #expect(data[9]  == 0x00)
        #expect(data[10] == 0x00)
        #expect(data[11] == 0x00)
    }

    @Test func encode_float_half_bigEndian() {
        let data = OSCEncoder.encode(address: "/ab", floatArg: 0.5)
        #expect(data[8]  == 0x3F)
        #expect(data[9]  == 0x00)
        #expect(data[10] == 0x00)
        #expect(data[11] == 0x00)
    }

    @Test func encode_float_roundtrip() {
        let original: Float = 0.75
        let data = OSCEncoder.encode(address: "/ab", floatArg: original)
        let bits = UInt32(data[8]) << 24 | UInt32(data[9]) << 16 |
                   UInt32(data[10]) << 8 | UInt32(data[11])
        let recovered = Float(bitPattern: bits)
        #expect(recovered == original)
    }

    // MARK: encode — real-world XR18 addresses

    @Test func encode_xr18Fader_correctByteCount() {
        let data = OSCEncoder.encode(address: "/ch/01/mix/fader", floatArg: 0.75)
        #expect(data.count == 28)
        #expect(data.count % 4 == 0)
    }

    @Test func encode_allSectionsMultipleOf4() {
        let addresses = ["/a", "/ab", "/abc", "/ch/01", "/ch/01/mix/fader"]
        for addr in addresses {
            let data = OSCEncoder.encode(address: addr, floatArg: 0.5)
            #expect(data.count % 4 == 0,
                    "encode(address: \"\(addr)\") count \(data.count) not aligned")
        }
    }
}

// MARK: - Song

@Suite("Song")
struct SongTests {

    let controller = PersistenceController(inMemory: true)
    var ctx: NSManagedObjectContext { controller.viewContext }

    @Test func displayName_withoutArtist() {
        let song = Song.create(name: "Wonderwall", in: ctx)
        #expect(song.displayName == "Wonderwall")
    }

    @Test func displayName_withArtist() {
        let song = Song.create(name: "Wonderwall", artist: "Oasis", in: ctx)
        #expect(song.displayName == "Wonderwall - Oasis")
    }

    @Test func displayName_emptyArtistFallsBack() {
        let song = Song.create(name: "Africa", artist: "", in: ctx)
        #expect(song.displayName == "Africa")
    }

    @Test func sortedCommands_correctOrder() {
        let song = Song.create(name: "Test", in: ctx)
        let c1 = MIDICommand(commandType: .programChange, channel: 1, value1: 10, context: ctx)
        let c2 = MIDICommand(commandType: .programChange, channel: 1, value1: 20, context: ctx)
        let c3 = MIDICommand(commandType: .programChange, channel: 1, value1: 30, context: ctx)
        song.addCommand(c1); song.addCommand(c2); song.addCommand(c3)
        // Override with scrambled order indexes
        c1.orderIndex = 2; c2.orderIndex = 0; c3.orderIndex = 1
        let sorted = song.sortedCommands
        #expect(sorted[0].value1 == 20)  // orderIndex 0
        #expect(sorted[1].value1 == 30)  // orderIndex 1
        #expect(sorted[2].value1 == 10)  // orderIndex 2
    }

    @Test func addCommand_assignsSequentialOrderIndexes() {
        let song = Song.create(name: "Test", in: ctx)
        let c1 = MIDICommand(commandType: .programChange, channel: 1, value1: 0, context: ctx)
        let c2 = MIDICommand(commandType: .programChange, channel: 1, value1: 0, context: ctx)
        let c3 = MIDICommand(commandType: .programChange, channel: 1, value1: 0, context: ctx)
        song.addCommand(c1); song.addCommand(c2); song.addCommand(c3)
        #expect(c1.orderIndex == 0)
        #expect(c2.orderIndex == 1)
        #expect(c3.orderIndex == 2)
    }

    @Test func removeCommand_reindexesRemaining() {
        let song = Song.create(name: "Test", in: ctx)
        let c1 = MIDICommand(commandType: .programChange, channel: 1, value1: 1, context: ctx)
        let c2 = MIDICommand(commandType: .programChange, channel: 1, value1: 2, context: ctx)
        let c3 = MIDICommand(commandType: .programChange, channel: 1, value1: 3, context: ctx)
        song.addCommand(c1); song.addCommand(c2); song.addCommand(c3)
        song.removeCommand(c2)
        #expect(song.commands.count == 2)
        let sorted = song.sortedCommands
        #expect(sorted[0].orderIndex == 0)
        #expect(sorted[1].orderIndex == 1)
    }

    @Test func moveCommand_updatesOrderIndexes() {
        let song = Song.create(name: "Test", in: ctx)
        let c1 = MIDICommand(commandType: .programChange, channel: 1, value1: 1, context: ctx)
        let c2 = MIDICommand(commandType: .programChange, channel: 1, value1: 2, context: ctx)
        let c3 = MIDICommand(commandType: .programChange, channel: 1, value1: 3, context: ctx)
        song.addCommand(c1); song.addCommand(c2); song.addCommand(c3)
        song.moveCommand(from: 0, to: 2)  // move c1 to the end
        let sorted = song.sortedCommands
        #expect(sorted[0].value1 == 2)
        #expect(sorted[1].value1 == 3)
        #expect(sorted[2].value1 == 1)
    }
}
