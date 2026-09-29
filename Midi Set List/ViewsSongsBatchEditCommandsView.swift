//
//  BatchEditCommandsView.swift
//  Midi Set List
//
//  Created by Patrick Downey on 9/25/26.
//

import SwiftUI
import CoreData

struct BatchEditCommandsView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.dismiss) private var dismiss
    let song: Song
    let selectedCommands: [MIDICommand]

    @State private var applyChannel = false
    @State private var newChannel: Int = 1
    @State private var useOmni = false

    @State private var applyDelay = false
    @State private var newDelay: Int = 50

    @State private var addToDelay = false
    @State private var delayAdjustment: Int = 0

    var commandsToEdit: [MIDICommand] {
        if selectedCommands.isEmpty {
            return song.sortedCommands
        }
        return selectedCommands
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Editing \(commandsToEdit.count) command(s)")
                        .font(.headline)
                } header: {
                    Text("Batch Edit")
                }

                Section {
                    Toggle("Update Channel", isOn: $applyChannel)

                    if applyChannel {
                        Toggle("Omni (All Channels)", isOn: $useOmni)

                        if !useOmni {
                            Picker("MIDI Channel", selection: $newChannel) {
                                ForEach(1...16, id: \.self) { ch in
                                    Text("Channel \(ch)").tag(ch)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Channel")
                }

                Section {
                    Toggle("Set Delay", isOn: $applyDelay)

                    if applyDelay {
                        Stepper("New Delay: \(newDelay)ms", value: $newDelay, in: 0...1000, step: 10)
                    }

                    Toggle("Adjust All Delays", isOn: $addToDelay)

                    if addToDelay {
                        Stepper("Adjustment: \(delayAdjustment >= 0 ? "+" : "")\(delayAdjustment)ms",
                               value: $delayAdjustment, in: -500...500, step: 10)

                        Text("This will add \(delayAdjustment)ms to each command's current delay")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Timing")
                }

                Section {
                    Button("Apply Changes", role: applyChannel || applyDelay || addToDelay ? nil : .cancel) {
                        applyBatchEdit()
                    }
                    .disabled(!applyChannel && !applyDelay && !addToDelay)
                } footer: {
                    if !applyChannel && !applyDelay && !addToDelay {
                        Text("Select at least one option to apply changes")
                    }
                }
            }
            .navigationTitle("Batch Edit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
    }

    private func applyBatchEdit() {
        for command in commandsToEdit {
            if applyChannel {
                command.channel = useOmni ? nil : newChannel
            }

            if applyDelay {
                command.delayMilliseconds = newDelay
            }

            if addToDelay {
                let adjusted = command.delayMilliseconds + delayAdjustment
                command.delayMilliseconds = max(0, min(1000, adjusted))
            }
        }

        song.dateModified = Date()
        try? viewContext.save()
        dismiss()
    }
}

#Preview {
    let ctx = PersistenceController.preview.viewContext
    let song = Song.create(name: "Test Song", in: ctx)
    let cmd1 = MIDICommand(commandType: .programChange, channel: 1, value1: 5, context: ctx)
    let cmd2 = MIDICommand(commandType: .controlChange, channel: 2, value1: 10, value2: 64, context: ctx)
    song.addCommand(cmd1)
    song.addCommand(cmd2)
    try? ctx.save()
    return BatchEditCommandsView(song: song, selectedCommands: [])
        .environment(\.managedObjectContext, ctx)
}
