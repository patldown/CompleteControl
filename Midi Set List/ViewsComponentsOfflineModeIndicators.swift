//
//  OfflineModeIndicators.swift
//  Midi Set List
//
//  Shared visuals shown on every AI surface while there's no network connection,
//  so it's always obvious that AI has fallen back to the on-device model.
//

import SwiftUI

extension Color {
    static let offlineMode = Color.teal
}

extension ShapeStyle where Self == LinearGradient {
    static var offlineModeGradient: LinearGradient {
        LinearGradient(colors: [.teal, .indigo], startPoint: .leading, endPoint: .trailing)
    }
}

// MARK: - Full-width banner (top of AI screens)

struct OfflineModeBanner: View {
    var detail: String = "No connection · using on-device AI"

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "wifi.slash")
                .font(.title2)
                .symbolEffect(.pulse, options: .repeating)
            VStack(alignment: .leading, spacing: 2) {
                Text("OFFLINE")
                    .font(.subheadline.weight(.heavy))
                    .tracking(1.2)
                Text(detail)
                    .font(.caption)
                    .opacity(0.9)
            }
            Spacer(minLength: 0)
            Image(systemName: "iphone")
                .font(.headline)
                .opacity(0.8)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(.offlineModeGradient)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Offline. \(detail)")
    }
}

// MARK: - Compact pill (toolbars, list rows)

struct OfflineModeBadge: View {
    var body: some View {
        Label("Offline", systemImage: "wifi.slash")
            .font(.caption2.weight(.bold))
            .textCase(.uppercase)
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.offlineModeGradient, in: Capsule())
            .accessibilityLabel("Offline, using on-device AI")
    }
}

// MARK: - Modifiers

extension View {
    /// Outlines an AI input or action with the offline colors when there's no connection.
    func offlineModeOutline(_ isOn: Bool, cornerRadius: CGFloat = 20) -> some View {
        overlay {
            if isOn {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(.offlineModeGradient, lineWidth: 2)
            }
        }
    }

    /// Adds a small no-connection dot to an AI toolbar button while offline.
    func offlineModeDot(_ isOn: Bool) -> some View {
        overlay(alignment: .topTrailing) {
            if isOn {
                Image(systemName: "wifi.slash")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(3)
                    .background(Color.offlineMode, in: Circle())
                    .offset(x: 6, y: -6)
            }
        }
    }
}

#Preview {
    VStack(spacing: 20) {
        OfflineModeBanner()
        OfflineModeBadge()
        Image(systemName: "wand.and.stars").font(.title2).offlineModeDot(true)
    }
}
