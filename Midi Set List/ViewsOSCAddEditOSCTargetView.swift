//
//  AddEditOSCTargetView.swift
//  Midi Set List
//

import SwiftUI
import CoreData

struct AddEditOSCTargetView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.dismiss) private var dismiss
    @Environment(OSCManager.self) private var oscManager

    var target: OSCTarget?

    @State private var name: String
    @State private var host: String
    @State private var sendPort: Int
    @State private var receivePort: Int
    @State private var enableKeepalive: Bool
    @State private var keepaliveAddress: String
    @State private var keepaliveInterval: Int

    init(target: OSCTarget? = nil) {
        self.target = target
        _name             = State(initialValue: target?.name ?? "")
        _host             = State(initialValue: target?.host ?? "")
        _sendPort         = State(initialValue: target?.sendPort ?? 10024)
        _receivePort      = State(initialValue: target?.receivePort ?? 10024)
        _enableKeepalive  = State(initialValue: target?.keepaliveAddress != nil)
        _keepaliveAddress = State(initialValue: target?.keepaliveAddress ?? "/xremote")
        _keepaliveInterval = State(initialValue: target?.keepaliveIntervalSeconds ?? 8)
    }

    var isEditing: Bool { target != nil }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty &&
        !host.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Target Info") {
                    TextField("Name (e.g. XR18 Stage)", text: $name)
                }

                Section {
                    TextField("IP Address (e.g. 192.168.1.100)", text: $host)
                        .keyboardType(.numbersAndPunctuation)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } header: {
                    Text("Host / IP Address")
                } footer: {
                    Text("Make sure your device is on the same WiFi network.")
                }

                Section {
                    LabeledContent("Send port") {
                        TextField("10024", value: $sendPort, format: .number)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Receive port") {
                        TextField("10024", value: $receivePort, format: .number)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                    }
                } header: {
                    Text("UDP Ports")
                } footer: {
                    Text("Behringer XR18/X32: send 10024, receive 10024. Send is where the mixer listens; receive is where the app listens for responses.")
                }

                Section {
                    Toggle("Send keepalive", isOn: $enableKeepalive)

                    if enableKeepalive {
                        TextField("/xremote", text: $keepaliveAddress)
                            .keyboardType(.URL)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)

                        LabeledContent("Interval (seconds)") {
                            TextField("8", value: $keepaliveInterval, format: .number)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                } header: {
                    Text("Keepalive")
                } footer: {
                    if enableKeepalive {
                        Text("Sends \"\(keepaliveAddress)\" every \(keepaliveInterval) seconds while connected. Required by Behringer XR18/X32 to maintain the OSC subscription.")
                    } else {
                        Text("Some devices (e.g. Behringer XR18) require a periodic ping to keep the connection active.")
                    }
                }
            }
            .navigationTitle(isEditing ? "Edit Target" : "New OSC Target")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(!canSave)
                }
            }
        }
    }

    private func save() {
        let trimName = name.trimmingCharacters(in: .whitespaces)
        let trimHost = host.trimmingCharacters(in: .whitespaces)
        let trimAddr = keepaliveAddress.trimmingCharacters(in: .whitespaces)
        let resolvedAddr: String? = (enableKeepalive && !trimAddr.isEmpty) ? trimAddr : nil

        if let target {
            target.name = trimName
            target.host = trimHost
            target.sendPort = sendPort
            target.receivePort = receivePort
            target.keepaliveAddress = resolvedAddr
            target.keepaliveIntervalSeconds = keepaliveInterval
            try? viewContext.save()
            oscManager.updateKeepalive(for: target)
        } else {
            let _ = OSCTarget.create(
                name: trimName,
                host: trimHost,
                sendPort: sendPort,
                receivePort: receivePort,
                keepaliveAddress: resolvedAddr,
                keepaliveIntervalSeconds: keepaliveInterval,
                in: viewContext
            )
            try? viewContext.save()
        }
        dismiss()
    }
}
