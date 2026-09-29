//
//  GetSpecPromptIntent.swift
//  Midi Set List
//
//  Returns the system prompt used to build a .md reference file.
//  Use it as the system prompt in any LLM shortcut (ChatGPT, Claude, etc.),
//  with your raw spec text as the user message.
//
//  Typical Shortcuts chain:
//    1. Get Reference Builder System Prompt  →  system prompt text
//    2. Ask ChatGPT / Ask Claude  (system = output of step 1, message = your spec text)
//    3. Attach Device Spec  →  save the LLM response as a reference file on the device
//

import AppIntents

struct GetSpecPromptIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Reference Builder System Prompt"
    static let description = IntentDescription(
        "Returns the v2 system prompt used to generate a structured MIDI reference file. Use it as the system prompt in any LLM shortcut (ChatGPT, Claude, etc.), with your raw spec pages as the user message. Optionally include spec text to get a combined ready-to-send prompt."
    )

    @Parameter(
        title: "Spec Text",
        description: "Optional. If provided, the output combines the system prompt and your spec text into one ready-to-send message. Leave empty to get just the system prompt."
    )
    var specText: String?

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        let trimmed = specText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let output: String
        let dialog: String

        if trimmed.isEmpty {
            // Return just the system prompt — user sets this as system/instruction in their LLM shortcut
            output = Self.instructionTemplate
            dialog = "System prompt ready. Use it as the system/instruction prompt in your LLM shortcut, with your raw spec as the user message."
        } else {
            // Combined: system prompt + spec as user message, merged for LLMs that take a single input
            output = """
            \(Self.instructionTemplate)

            ---

            \(trimmed)
            """
            dialog = "Combined prompt ready. Send this directly to your LLM shortcut, then use 'Attach Device Spec' to save the response."
        }

        return .result(value: output, dialog: IntentDialog(stringLiteral: dialog))
    }

    // Single source of truth — also used by AnalyzeDeviceSpecIntent
    static let instructionTemplate = """
    Build a Markdown MIDI reference for a small local LLM that will generate MIDI messages for a device.

    The LLM can only output: MSB, LSB, PC, and CC number + value, with a channel. \
    Formatting and sending are handled elsewhere; don't describe them.

    ## Hard rules

    1. Use ONLY facts written in the attached spec. No outside knowledge, no "typical" MIDI behavior, \
       no inferences.
    2. If the spec doesn't cover something, write NOT IN SPEC in that spot. Never fill a gap with a guess.
    3. Any value meaning not stated word-for-word in the spec (e.g. "0 = off, 127 = on") gets (VERIFY).
    4. Exclude NRPN, SysEx, and any parameter written with colons (e.g. 2:43).
    5. Copy CC numbers exactly. Before finishing, re-check every CC number against the spec.
    6. Anything the LLM can't output (e.g. MIDI Start/Stop real-time messages, clock) goes under \
       NOT CONTROLLABLE unless the spec gives a CC for it.
    7. If a parameter needs two or more CCs sent together, list them in ONE row with the required \
       order (e.g. 106 then 107).
    8. For trigger commands (fill, transition, tap, pause, etc.), state the value to send from the \
       spec, or mark (VERIFY).
    9. If any selection or value needs math (program numbers, BPM, folder numbers), use a complete \
       lookup table if it has 128 rows or fewer. If larger, write APP CONVERTS and list the inputs \
       the app needs (e.g. APP CONVERTS: folder, song). Never output a formula.
    10. Follow the template below exactly: same headings, same order, same table columns. \
        Add nothing else.

    ## Template

    # [Device] — MIDI Reference
    <!-- Excluded: [list] | VERIFY: [list] | NOT IN SPEC: [list] -->

    Allowed outputs: MSB, LSB, PC, CC number + value (0–127), channel (1–16).

    ## CONFIG
    - GLOBAL_CH = [from spec, or NOT IN SPEC]

    ## PROGRAM / SONG SELECTION
    Rule: [one sentence from spec, or NOT IN SPEC]

    | Program | MSB | LSB | PC |
    |---|---|---|---|
    [every slot, or APP CONVERTS: inputs, or NOT IN SPEC]

    ## NOT CONTROLLABLE — DO NOT GENERATE
    [items, or NOT IN SPEC]
    If asked, reply: UNSUPPORTED

    ## CC TABLE
    Use ONLY CC numbers listed here. If not listed, reply UNSUPPORTED.

    | Parameter | CC (send order) | Values |
    |---|---|---|
    [rows grouped by section; paired CCs in one row; math values = APP CONVERTS]

    ---

    After the file, list briefly:
    - Which spec pages you used for selection and for the CC table
    - Every NOT IN SPEC, VERIFY, and APP CONVERTS item
    """
}
