//
//  MIDITestView.swift
//  Midi Set List
//
//  Created by Patrick Downey on 9/25/26.
//

import SwiftUI

struct MIDITestView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(MIDIManager.self) private var midiManager
    
    @State private var testChannel = 1
    @State private var testNote = 60
    @State private var testVelocity = 100
    @State private var isSending = false
    @State private var lastError: String?
    @State private var showingError = false
    @State private var testResult: String?
    
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(midiManager.connectedDevicesList) { device in
                        HStack {
                            Circle()
                                .fill(Color.green)
                                .frame(width: 8, height: 8)
                            Text(device.displayName)
                        }
                    }
                } header: {
                    Text("Connected Devices (\(midiManager.connectedDevices.count))")
                }
                
                Section {
                    Picker("Channel", selection: $testChannel) {
                        ForEach(1...16, id: \.self) { ch in
                            Text("Channel \(ch)").tag(ch)
                        }
                    }
                    
                    Stepper("Note: \(testNote) (\(noteName(testNote)))", value: $testNote, in: 0...127)
                    
                    Stepper("Velocity: \(testVelocity)", value: $testVelocity, in: 0...127)
                } header: {
                    Text("Test Note")
                }
                
                Section {
                    Button {
                        Task {
                            await sendTestNote()
                        }
                    } label: {
                        HStack {
                            if isSending {
                                ProgressView()
                            } else {
                                Image(systemName: "play.fill")
                            }
                            Text("Send Test Note")
                        }
                    }
                    .disabled(isSending || midiManager.connectedDevices.isEmpty)
                    
                    if let result = testResult {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text(result)
                                .font(.caption)
                        }
                    }
                } footer: {
                    Text("Sends a note on/off message to verify MIDI communication")
                }
            }
            .navigationTitle("Test MIDI")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .alert("Error", isPresented: $showingError) {
                Button("OK", role: .cancel) {}
            } message: {
                if let error = lastError {
                    Text(error)
                }
            }
        }
    }
    
    private func sendTestNote() async {
        isSending = true
        testResult = nil
        
        do {
            try await midiManager.sendTestNote(
                channel: testChannel,
                note: testNote,
                velocity: testVelocity
            )
            testResult = "✓ Test note sent successfully"
        } catch {
            lastError = error.localizedDescription
            showingError = true
        }
        
        isSending = false
    }
    
    private func noteName(_ note: Int) -> String {
        let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        let octave = (note / 12) - 1
        let noteName = names[note % 12]
        return "\(noteName)\(octave)"
    }
}

#Preview {
    MIDITestView()
        .environment(MIDIManager())
}
