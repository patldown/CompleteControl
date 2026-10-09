//
//  ViewsSettingsMixerLinkView.swift
//  Midi Set List
//
//  Settings for linking routing channels to an OSC mixer: which strip controls show,
//  the OSC address templates (with the {ch} channel token), value ranges, Auto Gain,
//  and each channel's mixer number.
//

import SwiftUI

struct MixerLinkSettingsView: View {
    @Bindable private var link = MixerLink.shared
    private let store = AudioRoutingStore.shared

    var body: some View {
        Form {
            Section {
                Toggle("Gain Knobs", isOn: $link.settings.showGain)
                Toggle("Faders", isOn: $link.settings.showFader)
            } header: {
                Text("On Each Channel Strip")
            } footer: {
                Text("Shows the mixer's preamp gain and channel fader under each channel's name in Routing. Moving them sends OSC to every connected OSC device (add your mixer under Devices › OSC, with keepalive /xremote for Behringer).")
            }

            Section {
                Menu {
                    ForEach(MixerLinkSettings.templates) { template in
                        Button(template.name) {
                            link.settings.gainPath = template.gainPath
                            link.settings.faderPath = template.faderPath
                            link.settings.faderLaw = template.law
                        }
                    }
                } label: {
                    Label("Use a Mixer Template", systemImage: "list.bullet.rectangle")
                }
                pathField("Gain", text: $link.settings.gainPath)
                pathField("Fader", text: $link.settings.faderPath)
            } header: {
                Text("OSC Addresses")
            } footer: {
                Text("""
                {ch} is replaced by each channel's mixer number. Format it inside the braces:
                {ch} → 1, 2 … 16
                {ch:02} → 01, 02 … 16 (zero-padded to 2 digits, as the XR18 uses)
                {ch:03-1} → 000, 001 … (3 digits, counting from 0, as X32 preamps use)
                {ch+16} → adds 16 (e.g. a second bank)
                """)
            }

            Section("Example") {
                ForEach(1...3, id: \.self) { n in
                    LabeledContent("Mixer channel \(n)") {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(OSCPathTemplate.resolve(link.settings.gainPath, channel: n))
                            Text(OSCPathTemplate.resolve(link.settings.faderPath, channel: n))
                        }
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                Stepper(value: $link.settings.gainMinDB, in: -60...0, step: 1) {
                    LabeledContent("Lowest", value: String(format: "%+.0f dB", link.settings.gainMinDB))
                }
                Stepper(value: $link.settings.gainMaxDB, in: 0...80, step: 1) {
                    LabeledContent("Highest", value: String(format: "%+.0f dB", link.settings.gainMaxDB))
                }
            } header: {
                Text("Gain Range")
            } footer: {
                Text("The gain sent is 0–1 across this range. XR18 and X32 preamps: −12 to +60 dB.")
            }

            Section {
                Picker("Fader Law", selection: $link.settings.faderLaw) {
                    ForEach(FaderLaw.allCases) { Text($0.displayName).tag($0) }
                }
                if link.settings.faderLaw == .linear {
                    Stepper(value: $link.settings.faderMinDB, in: -120...0, step: 1) {
                        LabeledContent("Bottom", value: String(format: "%+.0f dB", link.settings.faderMinDB))
                    }
                    Stepper(value: $link.settings.faderMaxDB, in: 0...20, step: 1) {
                        LabeledContent("Top", value: String(format: "%+.0f dB", link.settings.faderMaxDB))
                    }
                }
            } header: {
                Text("Fader")
            } footer: {
                Text(link.settings.faderLaw == .behringer
                     ? "Behringer X faders: −∞ at the bottom, 0 dB at 3/4, +10 dB at the top."
                     : "The fader sent is 0–1, linear in dB across this range.")
            }

            Section {
                Stepper(value: $link.settings.autoGainSeconds, in: 3...20, step: 1) {
                    LabeledContent("Listen For", value: "\(Int(link.settings.autoGainSeconds)) s")
                }
                Stepper(value: $link.settings.autoGainTargetDB, in: -24...(-6), step: 1) {
                    LabeledContent("Loudest Peaks At", value: "\(Int(link.settings.autoGainTargetDB)) dBFS")
                }
            } header: {
                Text("Auto Gain")
            } footer: {
                Text("Tap the A next to a gain knob, then sing or play your loudest part. The gain moves so those peaks land at this level: −12 dBFS leaves room for the big moments. It listens to what reaches this iPad from the mixer, so its USB/routing sends must be taken after the preamp (the XR18's default).")
            }

            Section {
                if store.channels.isEmpty {
                    Text("Add channels in Routing first.").foregroundStyle(.secondary)
                }
                ForEach(store.channels) { channel in
                    Stepper(value: mixerChannelBinding(channel), in: 1...128) {
                        LabeledContent(channel.displayName) {
                            Text("Mixer Ch \(link.mixerChannel(for: channel))"
                                 + (channel.mixerChannel == nil ? " (auto)" : ""))
                                .monospacedDigit()
                        }
                    }
                }
            } header: {
                Text("Channel Numbers")
            } footer: {
                Text("Which mixer channel each routing channel controls. Auto = the interface input it records from (XR18 USB input 1 = mixer channel 1).")
            }

            Section {
                LabeledContent("Mixer Connection") {
                    Text(link.isConnected ? "Connected" : "No OSC device connected")
                        .foregroundStyle(link.isConnected ? Color.green : Color.secondary)
                }
                Button("Read Values from Mixer") { link.requestCurrentValues() }
                    .disabled(!link.isConnected)
            } footer: {
                Text("Asks the mixer for every linked gain and fader so the controls match it. Behringer mixers also send changes made on the mixer itself while /xremote keepalive is on.")
            }
        }
        .navigationTitle("Mixer Link")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func pathField(_ label: String, text: Binding<String>) -> some View {
        LabeledContent(label) {
            TextField(label, text: text)
                .font(.callout.monospaced())
                .multilineTextAlignment(.trailing)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
    }

    private func mixerChannelBinding(_ channel: AudioChannel) -> Binding<Int> {
        Binding(
            get: { link.mixerChannel(for: channel) },
            set: { value in
                guard var c = store.channels.first(where: { $0.id == channel.id }) else { return }
                c.mixerChannel = value == c.inputIndex + 1 ? nil : value
                store.update(c)
            }
        )
    }
}
