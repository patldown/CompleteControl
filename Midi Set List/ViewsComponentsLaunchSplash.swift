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

struct LaunchSplashView: View {
    let status: String
    @State private var breathe = false

    private var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "Midi Set List"
    }

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            ZStack {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(LinearGradient(colors: [.accentColor, .accentColor.opacity(0.6)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 104, height: 104)
                    .shadow(color: .accentColor.opacity(0.35), radius: breathe ? 18 : 8)
                Image(systemName: "pianokeys")
                    .font(.system(size: 46, weight: .semibold))
                    .foregroundStyle(.white)
                    .symbolEffect(.pulse, options: .repeating)
            }
            .scaleEffect(breathe ? 1.04 : 0.98)

            Text(appName)
                .font(.title2.bold())

            Spacer()

            VStack(spacing: 10) {
                ProgressView()
                    .controlSize(.regular)
                Text(status)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .contentTransition(.opacity)
                    .animation(.default, value: status)
            }
            .padding(.bottom, 48)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground).ignoresSafeArea())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Loading. \(status)")
        .onAppear {
            withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                breathe = true
            }
        }
    }
}

#Preview {
    LaunchSplashView(status: "Loading your library…")
}
