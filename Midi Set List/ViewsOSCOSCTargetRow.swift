//
//  OSCTargetRow.swift
//  Midi Set List
//

import SwiftUI
import CoreData

// MARK: - Row

struct OSCTargetRow: View {
    @Environment(OSCManager.self) private var oscManager
    let target: OSCTarget

    var isConnected: Bool { oscManager.isConnected(target) }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isConnected ? "network" : "network.slash")
                .font(.title3)
                .foregroundStyle(isConnected ? .green : .secondary)
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text(target.name).font(.headline)
                Text(target.displayAddress)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fontDesign(.monospaced)
            }

            Spacer()

            Button {
                oscManager.toggleConnection(for: target)
            } label: {
                Image(systemName: isConnected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isConnected ? .green : .secondary)
                    .imageScale(.large)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
        .contextMenu {
            if isConnected {
                Button {
                    oscManager.sendTest(address: "/xinfo", to: target)
                } label: {
                    Label("Send /xinfo (Test)", systemImage: "antenna.radiowaves.left.and.right")
                }
                Button {
                    oscManager.sendTest(address: "/xremote", to: target)
                } label: {
                    Label("Send /xremote Now", systemImage: "clock.arrow.2.circlepath")
                }
            }
        }
    }
}
