//
//  OfflineModeIndicators.swift
//  Midi Set List
//
//  Shared visuals shown on every AI surface while offline mode is on,
//  so it's always obvious that only the on-device model is in use.
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
    var detail: String = "Using on-device AI only · nothing leaves this device"

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "airplane.circle.fill")
                .font(.title2)
                .symbolEffect(.pulse, options: .repeating)
            VStack(alignment: .leading, spacing: 2) {
                Text("OFFLINE MODE")
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
        .accessibilityLabel("Offline mode on. \(detail)")
    }
}

// MARK: - Compact pill (toolbars, list rows)

struct OfflineModeBadge: View {
    var body: some View {
        Label("Offline", systemImage: "airplane")
            .font(.caption2.weight(.bold))
            .textCase(.uppercase)
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.offlineModeGradient, in: Capsule())
            .accessibilityLabel("Offline mode on")
    }
}

// MARK: - Modifiers

extension View {
    /// Outlines an AI input or action with the offline colors when offline mode is on.
    func offlineModeOutline(_ isOn: Bool, cornerRadius: CGFloat = 20) -> some View {
        overlay {
            if isOn {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(.offlineModeGradient, lineWidth: 2)
            }
        }
    }

    /// Adds a small airplane dot to an AI toolbar button when offline mode is on.
    func offlineModeDot(_ isOn: Bool) -> some View {
        overlay(alignment: .topTrailing) {
            if isOn {
                Image(systemName: "airplane.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.white, Color.offlineMode)
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
