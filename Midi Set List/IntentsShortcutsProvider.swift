//
//  ShortcutsProvider.swift
//  Midi Set List
//

import AppIntents

struct CompleteControlShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CreateDeviceIntent(),
            phrases: [
                "Create instrument in \(.applicationName)",
                "Add device to \(.applicationName)",
                "New instrument in \(.applicationName)"
            ],
            shortTitle: "Create Instrument",
            systemImageName: "pianokeys"
        )
        AppShortcut(
            intent: CreateMacroCategoryIntent(),
            phrases: [
                "Create macro category in \(.applicationName)",
                "Add category to instrument in \(.applicationName)"
            ],
            shortTitle: "Create Macro Category",
            systemImageName: "folder.badge.plus"
        )
        AppShortcut(
            intent: AddMacroIntent(),
            phrases: [
                "Add MIDI macro in \(.applicationName)",
                "Create macro in \(.applicationName)"
            ],
            shortTitle: "Add MIDI Macro",
            systemImageName: "waveform.badge.plus"
        )
        AppShortcut(
            intent: GenerateMacrosIntent(),
            phrases: [
                "Generate macros in \(.applicationName)",
                "Create MIDI macros in \(.applicationName)",
                "Import MIDI table in \(.applicationName)"
            ],
            shortTitle: "Generate Macros with AI",
            systemImageName: "wand.and.stars"
        )
        AppShortcut(
            intent: AttachDeviceSpecIntent(),
            phrases: [
                "Attach spec to device in \(.applicationName)",
                "Add reference file to instrument in \(.applicationName)"
            ],
            shortTitle: "Attach Device Spec",
            systemImageName: "doc.badge.plus"
        )
        AppShortcut(
            intent: AnalyzeDeviceSpecIntent(),
            phrases: [
                "Analyze device spec in \(.applicationName)",
                "Generate reference spec in \(.applicationName)",
                "Build device reference in \(.applicationName)"
            ],
            shortTitle: "Analyze Device Spec",
            systemImageName: "doc.text.magnifyingglass"
        )
        AppShortcut(
            intent: GetSpecPromptIntent(),
            phrases: [
                "Get reference system prompt in \(.applicationName)",
                "Get MIDI spec builder prompt in \(.applicationName)"
            ],
            shortTitle: "Get Reference Builder System Prompt",
            systemImageName: "square.and.arrow.up.on.square"
        )
        AppShortcut(
            intent: CreateSongIntent(),
            phrases: [
                "Create song in \(.applicationName)",
                "Add song to \(.applicationName)",
                "New song in \(.applicationName)"
            ],
            shortTitle: "Create Song",
            systemImageName: "music.note"
        )
        AppShortcut(
            intent: AddLyricsToSongIntent(),
            phrases: [
                "Add lyrics in \(.applicationName)",
                "Update song lyrics in \(.applicationName)"
            ],
            shortTitle: "Add Lyrics to Song",
            systemImageName: "text.alignleft"
        )
    }
}
