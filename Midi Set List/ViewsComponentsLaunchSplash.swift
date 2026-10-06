//
//  LaunchSplash.swift
//  Midi Set List
//
//  A short loading screen over the app at launch, so startup reads as "loading"
//  rather than a blank screen. It reports the real startup steps and stays up for a
//  moment at minimum so it never just flashes.
//

import SwiftUI
import CoreData

struct LaunchContainer<Content: View>: View {
    @Environment(\.managedObjectContext) private var viewContext
    @Environment(MIDIManager.self) private var midiManager
    @ViewBuilder var content: Content

    @State private var isLoading = true
    @State private var status = "Starting up…"

    var body: some View {
        ZStack {
            content
            if isLoading {
                LaunchSplashView(status: status)
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .task {
            // UI tests need elements to be accessible immediately; skip the splash.
            if ProcessInfo.processInfo.arguments.contains("-ui-testing") {
                isLoading = false
                return
            }

            let started = Date()

            status = "Loading your library…"
            let songCount = (try? viewContext.count(for: NSFetchRequest<Song>(entityName: "Song"))) ?? 0
            let setListCount = (try? viewContext.count(for: NSFetchRequest<SetList>(entityName: "SetList"))) ?? 0
            try? await Task.sleep(for: .milliseconds(350))
            status = "\(songCount) song\(songCount == 1 ? "" : "s") · \(setListCount) set list\(setListCount == 1 ? "" : "s")"
            try? await Task.sleep(for: .milliseconds(300))

            status = "Connecting MIDI…"
            try? await Task.sleep(for: .milliseconds(250))
            let devices = midiManager.availableDevices.count
            status = midiManager.isInitialized
                ? "\(devices) MIDI device\(devices == 1 ? "" : "s") found"
                : "MIDI unavailable"

            // Never less than about a second in total, so it reads as a step, not a flicker
            let remaining = 1.1 - Date().timeIntervalSince(started)
            if remaining > 0 { try? await Task.sleep(for: .seconds(remaining)) }

            withAnimation(.easeOut(duration: 0.35)) { isLoading = false }
        }
    }
}

/// Picks up exactly where the iOS launch screen leaves off — same LaunchLogo, same size,
/// centred on the full screen over LaunchBackground — then adds the name and progress.
struct LaunchSplashView: View {
    let status: String
    /// Matches the launch-screen logo's point size, so the hand-off doesn't jump
    static let logoSize: CGFloat = 160

    @State private var breathe = false
    @State private var showDetails = false

    private var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "Complete Control"
    }

    var body: some View {
        ZStack {
            Color("LaunchBackground")

            Image("LaunchLogo")
                .resizable()
                .frame(width: Self.logoSize, height: Self.logoSize)
                .shadow(color: .black.opacity(breathe ? 0.25 : 0.1), radius: breathe ? 16 : 6)
                .scaleEffect(breathe ? 1.04 : 1.0)
                .accessibilityHidden(true)

            // Just below the centred logo
            Text(appName)
                .font(.title2.bold())
                .offset(y: Self.logoSize / 2 + 36)
                .opacity(showDetails ? 1 : 0)

            VStack(spacing: 10) {
                Spacer()
                ProgressView()
                Text(status)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .contentTransition(.opacity)
                    .animation(.default, value: status)
            }
            .padding(.bottom, 64)
            .opacity(showDetails ? 1 : 0)
        }
        .ignoresSafeArea()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Loading. \(status)")
        .onAppear {
            withAnimation(.easeIn(duration: 0.3)) { showDetails = true }
            withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true).delay(0.2)) {
                breathe = true
            }
        }
    }
}

#Preview {
    LaunchSplashView(status: "Loading your library…")
}
