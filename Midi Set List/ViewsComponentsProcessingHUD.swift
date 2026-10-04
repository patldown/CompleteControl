//
//  ProcessingHUD.swift
//  Midi Set List
//
//  A "working on it" card shown above everything — sheets and menus included — while a
//  slow share, export or import runs, so it's clear the app is busy and hasn't frozen.
//

import SwiftUI
import UIKit

@MainActor
enum ProcessingHUD {
    @Observable
    final class Status {
        var message = ""
    }

    private static let status = Status()
    private static var window: UIWindow?
    /// Nested runs share one card; it goes away when the outermost one finishes
    private static var depth = 0

    /// Shows the card with `message`, gives it a moment to draw, runs `work`, then hides it
    static func run<T>(_ message: String, _ work: () async throws -> T) async rethrows -> T {
        show(message)
        defer { hide() }
        try? await Task.sleep(for: .milliseconds(80))
        return try await work()
    }

    private static func show(_ message: String) {
        status.message = message
        depth += 1
        guard window == nil else { return }
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })
            ?? UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first
        else { return }

        let host = UIHostingController(rootView: ProcessingCard(status: status))
        host.view.backgroundColor = .clear
        let overlay = UIWindow(windowScene: scene)
        overlay.windowLevel = .alert + 1
        overlay.backgroundColor = .clear
        overlay.rootViewController = host
        overlay.alpha = 0
        overlay.isHidden = false
        UIView.animate(withDuration: 0.15) { overlay.alpha = 1 }
        window = overlay
    }

    private static func hide() {
        depth = max(0, depth - 1)
        guard depth == 0, let overlay = window else { return }
        window = nil
        UIView.animate(withDuration: 0.15) {
            overlay.alpha = 0
        } completion: { _ in
            overlay.isHidden = true
        }
    }
}

/// Dims the screen (and blocks taps, so the action can't be started twice) with a spinner card
private struct ProcessingCard: View {
    let status: ProcessingHUD.Status

    var body: some View {
        ZStack {
            Color.black.opacity(0.25).ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView()
                    .controlSize(.large)
                Text(status.message)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                Text("This can take a few seconds")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .frame(minWidth: 200)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
            .shadow(radius: 12)
            .padding(32)
            .accessibilityElement(children: .combine)
        }
    }
}
