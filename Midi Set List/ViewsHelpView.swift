//
//  HelpView.swift
//  Midi Set List
//

import SwiftUI

struct HelpView: View {
    var body: some View {
        NavigationStack {
            List {
                ForEach(HelpTopic.all) { topic in
                    NavigationLink(destination: HelpDetailView(topic: topic)) {
                        HStack(spacing: 12) {
                            Image(systemName: topic.icon)
                                .font(.title3)
                                .foregroundStyle(topic.color)
                                .frame(width: 32)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(topic.title)
                                    .font(.headline)
                                Text(topic.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .navigationTitle("Help")
            .offlineStatusBadge()
            .performShortcut()
        }
    }
}

// MARK: - Detail view

private struct HelpDetailView: View {
    let topic: HelpTopic

    var body: some View {
        List {
            ForEach(topic.sections) { section in
                Section {
                    ForEach(section.items) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            if !item.heading.isEmpty {
                                Text(item.heading)
                                    .font(.subheadline)
                                    .fontWeight(.semibold)
                            }
                            Text(item.body)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                } header: {
                    Label(section.title, systemImage: section.icon)
                }
            }
        }
        .navigationTitle(topic.title)
        .navigationBarTitleDisplayMode(.large)
    }
}

// MARK: - Data model

struct HelpTopic: Identifiable {
    let id = UUID()
    let title: String
    let subtitle: String
    let icon: String
    let color: Color
    let sections: [HelpSection]

    static let all: [HelpTopic] = [
        performTopic,
        midiClockTopic,
        bluetoothMIDITopic,
        oscXR18Topic,
        midiChainTopic,
        formulasTopic,
    ]
}

struct HelpSection: Identifiable {
    let id = UUID()
    let title: String
    let icon: String
    let items: [HelpItem]
}

struct HelpItem: Identifiable {
    let id = UUID()
    let heading: String
    let body: String

    init(_ heading: String = "", _ body: String) {
        self.heading = heading
        self.body = body
    }
}

// MARK: - Topics

private let performTopic = HelpTopic(
    title: "Perform, Snapshots & Foot Controllers",
    subtitle: "Play a set list and control it from MIDI",
    icon: "play.circle",
    color: .green,
    sections: [
        HelpSection(title: "Snapshots", icon: "square.stack.3d.up", items: [
            HelpItem("What they are",
                     "Each song has up to 12 snapshots. A snapshot is a group of macros, macro groups and commands — think of them like presets on a guitar pedal: one button, many changes at once."),
            HelpItem("Snapshot 1",
                     "Every song starts with Snapshot 1. It's sent when the song loads. Once Snapshot 1 has at least one command, tap + Add to create more."),
            HelpItem("Managing them",
                     "Tap a snapshot in the song to edit its commands. Long-press it to rename, duplicate, send or delete."),
        ]),
        HelpSection(title: "Perform tab", icon: "play.fill", items: [
            HelpItem("Playing a set",
                     "Pick a set list and press Play. The first song loads and its Snapshot 1 is sent. Use Next / Previous to move through the set, and tap a snapshot to recall it."),
            HelpItem("Jumping around",
                     "The Songs menu (top right) jumps straight to any song in the set. The screen stays awake until you press End."),
            HelpItem("Lyrics & charts",
                     "A song's lyrics or chart show below its snapshots. Press play to auto-scroll, and use − / + to set the speed. The expand button fills the screen with lyrics while the snapshot row stays on top, so you can still recall snapshots."),
            HelpItem("Sheet music",
                     "Attach a PDF or photos of sheet music from a song's Lyrics & Sheet Music screen. On Perform it scrolls just like lyrics, with its own speed. Pinch to zoom on images."),
            HelpItem("Lyrics or sheet music, per song",
                     "If a song has both, the menu on the lyrics bar switches between them. Each song remembers your last choice and scroll speed — for you only, so a guitarist and a pianist sharing songs each get their own. To show one view on every song, pick Always Lyrics or Always Sheet Music in Settings → Your Performance Settings; switching back brings each song's memory back."),
            HelpItem("Chords, key & transpose",
                     "Chords in lyrics show in yellow when they're recognised — either a line of just chords above the words (G  D/F♯  Em7) or inline in brackets ([G]). The ± button on the lyrics bar moves them up or down, up to 6 semitones, and the song's key moves with them. Your saved lyrics aren't changed."),
            HelpItem("Capo",
                     "Turn on Capo in a song's Key & Capo section and set the fret the chart uses. With Capo Keeps Original Key on, transposing moves the capo the opposite way so the audience hears the same key — e.g. transpose down 2 for open shapes and the capo goes up 2. Turn it off to really change the key; the capo then stays where you set it. Perform shows the key, the capo and the chord shapes you're playing."),
        ]),
        HelpSection(title: "MIDI control", icon: "slider.horizontal.below.rectangle", items: [
            HelpItem("Receive channel",
                     "Settings → MIDI Receive & Control. The app only reacts to messages on this channel (or everything, with Omni). Set your controller to match."),
            HelpItem("Snapshot numbers",
                     "Snapshots use 12 numbers in a row. By default Snapshot 1 is CC 20, Snapshot 2 is CC 21, up to Snapshot 12 on CC 31. You can switch to Program Change or Note, and pick any starting number."),
            HelpItem("One pedal, one snapshot",
                     "Pedals not in a row? Long-press a snapshot in a song → Learn MIDI Trigger, then press the pedal. That snapshot now answers to that pedal in every song. You can also do this under Settings → MIDI Receive & Control → Individual Snapshots."),
            HelpItem("Previous / Next",
                     "By default CC 102 / 103 change song and CC 104 / 105 step through snapshots. Tap ⋯ → Learn next to any of them, then press the pedal to assign it."),
            HelpItem("Which song?",
                     "MIDI acts on the song playing in Perform. When nothing is playing, it acts on the song you have open in Songs."),
        ]),
        HelpSection(title: "Bluetooth foot controllers", icon: "wave.3.right", items: [
            HelpItem("Pairing",
                     "Tap the wave button in Perform or MIDI Devices and pair the controller there. Bluetooth MIDI gear won't work if you only pair it in the iOS Bluetooth settings."),
            HelpItem("Pedal fires twice",
                     "Momentary footswitches send a value on press and 0 on release. Keep \"Ignore Value 0\" on so only the press counts."),
            HelpItem("Nothing happens",
                     "Open Settings → MIDI Receive & Control and press the pedal. \"Last Received\" shows exactly what arrived and why it was used or ignored — usually a channel mismatch."),
        ]),
    ]
)

private let midiClockTopic = HelpTopic(
    title: "MIDI Clock",
    subtitle: "Tempo sync troubleshooting and setup",
    icon: "metronome",
    color: .blue,
    sections: [
        HelpSection(title: "BPM reads too high", icon: "exclamationmark.triangle", items: [
            HelpItem("MIDI Thru loopback",
                     "If a device in your chain has MIDI Thru or Clock Output enabled, it forwards the clock it receives back out. The next device in the chain sees every pulse twice — doubling the apparent BPM. Fix: go into the settings of any intermediate device (e.g. HX Stomp, MidiCaptain, effects unit) and turn off MIDI Thru or Clock Output."),
            HelpItem("Two clock sources at once",
                     "If two devices are both sending MIDI clock at the same time, the receiving device adds the pulses together and shows a much higher BPM. Make sure only one device in your rig is set as the clock master."),
        ]),
        HelpSection(title: "Clock only vs. Start / Stop", icon: "play.fill", items: [
            HelpItem("Clock only (recommended for drum machines)",
                     "Sending only the tempo pulse lets connected devices follow your BPM without being remotely started or stopped. Your drum machine controls its own playback. Use this when you want tempo sync but don't want the app to trigger play/stop."),
            HelpItem("Send Start / Stop",
                     "Turn this on if you want the app to remotely trigger play and stop on connected devices — loopers, sequencers, and similar gear. Avoid it for drum machines you prefer to start and stop by hand."),
        ]),
        HelpSection(title: "Bluetooth MIDI and clock", icon: "wave.3.right", items: [
            HelpItem("Jitter at high tempos",
                     "Bluetooth MIDI has a small built-in delay that can cause slight timing wobble, especially at tempos above 120 BPM. If tight clock sync is critical, connect your devices with a wired USB MIDI interface instead."),
        ]),
    ]
)

private let bluetoothMIDITopic = HelpTopic(
    title: "Bluetooth MIDI",
    subtitle: "Pairing and connecting BLE MIDI devices",
    icon: "wave.3.right",
    color: .blue,
    sections: [
        HelpSection(title: "Pairing for the first time", icon: "gear", items: [
            HelpItem("How to pair",
                     "Go to the MIDI Devices tab, tap the '•••' menu, and choose 'Bluetooth MIDI'. A pairing sheet appears — tap your device's name to connect. Once paired, it shows up in the MIDI Devices list automatically."),
            HelpItem("Device doesn't appear in the list",
                     "Make sure your MIDI device is powered on and in Bluetooth pairing mode. Some devices need you to enable Bluetooth MIDI in their own menu before they broadcast. Try toggling Bluetooth off and back on in iOS Settings if it still doesn't show."),
        ]),
        HelpSection(title: "Staying connected", icon: "link", items: [
            HelpItem("Device dropped from the list",
                     "If a Bluetooth MIDI device disappears after being away or powered off, it should reconnect automatically when it comes back in range. If it doesn't re-appear, go to MIDI Devices and pull down to refresh, or navigate away and back to the tab."),
            HelpItem("Commands not sending after reconnect",
                     "If the device shows as connected but MIDI is not getting through, tap the device row and use the Test button to verify the connection. You may need to disconnect and reconnect once to re-establish the session."),
        ]),
    ]
)

private let oscXR18Topic = HelpTopic(
    title: "OSC Setup",
    subtitle: "Connecting to mixers and OSC devices",
    icon: "network",
    color: .green,
    sections: [
        HelpSection(title: "Network setup", icon: "wifi", items: [
            HelpItem("Same Wi-Fi network required",
                     "Your iPhone/iPad and your OSC device (e.g. a Behringer XR18 or similar mixer) must be on the same Wi-Fi network. Many mixers broadcast their own Wi-Fi hotspot — connecting to that directly is the simplest option and avoids any router configuration."),
            HelpItem("Finding your device's IP address",
                     "The IP address is usually shown in the mixer's own network settings screen or companion app. Enter that address when adding an OSC Target in the app's Devices tab."),
        ]),
        HelpSection(title: "Commands not reaching the device", icon: "exclamationmark.circle", items: [
            HelpItem("Check the OSC Target is enabled",
                     "Go to Devices → OSC Targets and confirm your target is listed and connected. If it shows a red indicator, tap it and verify the IP address and port match your device's settings."),
            HelpItem("Device stopped responding mid-session",
                     "Some OSC devices require a periodic check-in to keep the connection active. The app handles this automatically, but if the connection drops, go to OSC Targets and toggle the target off and back on to restart the session."),
        ]),
        HelpSection(title: "Capturing device moves as macros", icon: "plus.circle", items: [
            HelpItem("Activity log → Save as Macro",
                     "When your mixer or OSC device sends a message back to the app (e.g. you move a fader), it appears in the Activity tab with a green + button. Tap it to save that address and value as a macro in your device library — no need to type anything manually."),
        ]),
    ]
)

private let midiChainTopic = HelpTopic(
    title: "MIDI Chain Tips",
    subtitle: "Routing, thru, and device order",
    icon: "cable.connector",
    color: .orange,
    sections: [
        HelpSection(title: "Wrong device is responding", icon: "exclamationmark.circle", items: [
            HelpItem("Check the MIDI channel",
                     "Every device in your rig listens on a specific channel (1–16). If two devices share the same channel, both will respond to every command. Make sure each device is set to its own channel, and that the commands in the app match."),
            HelpItem("MIDI Thru is echoing commands",
                     "Some devices (pedals, effects units) have a MIDI Thru setting that passes incoming messages straight out to the next device. This can cause unintended double-triggering. If something unexpected is responding, check the Thru settings on each device in the chain."),
        ]),
        HelpSection(title: "Device loads the wrong patch", icon: "music.note", items: [
            HelpItem("Bank Select must come before Program Change",
                     "If your device uses banks, the Bank Select commands must be sent before the Program Change or the wrong patch will load. In the app, verify that MSB and LSB commands appear above the Program Change in the song's command list."),
            HelpItem("Add a small delay between commands",
                     "Some older or slower devices need a moment to process a bank change before they can act on a Program Change. If the wrong patch keeps loading, edit the command's delay setting and try 20–50 ms between Bank Select and PC."),
        ]),
        HelpSection(title: "Commands fire in the wrong order", icon: "arrow.up.arrow.down", items: [
            HelpItem("Reorder the command list",
                     "The app sends commands from top to bottom. Long-press a command row in the song's Commands list and drag it to the correct position."),
        ]),
    ]
)

private let formulasTopic = HelpTopic(
    title: "Formulas",
    subtitle: "Dynamic values for OSC and MIDI commands",
    icon: "function",
    color: .purple,
    sections: [
        HelpSection(title: "What they do", icon: "info.circle", items: [
            HelpItem("OSC commands",
                     "The Formula field overrides the fixed Float Value at send time. The evaluated result is sent as the OSC float argument."),
            HelpItem("MIDI CC / PC / Bank commands",
                     "Each MIDI command has an optional formula field for its value (CC value, program number, bank value). When set, the formula overrides the stepper at send time. The result is clamped to 0–127 automatically."),
        ]),
        HelpSection(title: "Variables", icon: "x.squareroot", items: [
            HelpItem("bpm", "The song's current BPM value (0 if not set). Useful for tempo-relative calculations."),
            HelpItem("pi", "3.14159… (π)"),
            HelpItem("e", "2.71828… (Euler's number)"),
        ]),
        HelpSection(title: "Operators", icon: "plusminus", items: [
            HelpItem("Arithmetic",
                     "+  −  *  /  ^  (exponent, right-associative)"),
            HelpItem("Comparison (return 1 if true, 0 if false)",
                     ">   >=   <   <=   ==   !="),
            HelpItem("Ternary",
                     "condition ? valueIfTrue : valueIfFalse\nExample: bpm >= 128 ? 1 : 0"),
        ]),
        HelpSection(title: "Functions", icon: "sum", items: [
            HelpItem("log(x)", "Natural logarithm"),
            HelpItem("log10(x) / log2(x)", "Base-10 and base-2 logarithms"),
            HelpItem("exp(x)", "e raised to the power x"),
            HelpItem("sqrt(x)", "Square root"),
            HelpItem("pow(x, y)", "x raised to the power y (also: x^y)"),
            HelpItem("clamp(x, lo, hi)", "Constrain x to the range [lo, hi]"),
            HelpItem("lognorm(v, min, max)", "Logarithmically normalize v from [min, max] to [0, 1]"),
            HelpItem("logmap(n, min, max)", "Map a [0, 1] normalized value to [min, max] logarithmically"),
            HelpItem("db(amplitude)", "Convert linear amplitude to dB (20 × log10)"),
            HelpItem("ampfromdb(db)", "Convert dB to linear amplitude"),
            HelpItem("sin(x) / cos(x) / tan(x)", "Trigonometric functions (radians)"),
            HelpItem("min(a, b) / max(a, b)", "Minimum and maximum of two values"),
            HelpItem("floor(x) / ceil(x) / round(x)", "Rounding functions"),
            HelpItem("abs(x)", "Absolute value"),
        ]),
        HelpSection(title: "OSC Examples", icon: "lightbulb", items: [
            HelpItem("BPM → fader delay time",
                     "60.0 / bpm  →  quarter note duration in seconds"),
            HelpItem("Logarithmic fader curve",
                     "lognorm(bpm, 60, 180)  →  maps 60–180 BPM to a 0–1 log curve"),
            HelpItem("dB to fader position (X-Air)",
                     "ampfromdb(-6)  →  the linear fader value for −6 dB"),
        ]),
        HelpSection(title: "MIDI CC Examples — BeatBuddy BPM", icon: "metronome", items: [
            HelpItem("Overview",
                     "The BeatBuddy accepts tempo via two CC messages: CC 106 (MSB) and CC 107 (LSB). For BPM ≤ 127: MSB = 0, LSB = BPM. For BPM > 127: MSB = 1, LSB = BPM − 128."),
            HelpItem("CC 106 (MSB) value formula",
                     "bpm > 127 ? 1 : 0\n\nSet up a Control Change command with CC# = 106. Enter this formula in 'CC Value Formula'. Result is 0 below 128 BPM, 1 above."),
            HelpItem("CC 107 (LSB) value formula",
                     "bpm > 127 ? bpm - 128 : bpm\n\nSet up a second CC command with CC# = 107. Enter this formula in 'CC Value Formula'. Result is the remainder after subtracting 128 for high tempos."),
            HelpItem("How to set it up",
                     "1. In a song's command list, add a CC command → CC# 106, then enter the MSB formula.\n2. Add another CC command → CC# 107, then enter the LSB formula.\n3. Make sure both commands send on the correct MIDI channel for your BeatBuddy.\n4. When the song is sent, both CCs fire in order and the BeatBuddy snaps to the song's BPM."),
        ]),
    ]
)
