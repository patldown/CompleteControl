//
//  LiveFollowViews.swift
//  Midi Set List
//
//  Perform's Band button and sheet (lead, or follow a nearby leader), and the prompt
//  when a leader's set list would update songs already on this device.
//

import SwiftUI

/// Toolbar button: shows Live Follow's state at a glance and opens its sheet
struct LiveFollowButton: View {
    private let live = LiveFollowSession.shared
    @State private var showingSheet = false

    var body: some View {
        Button {
            showingSheet = true
        } label: {
            switch live.mode {
            case .off:
                Label("Band", systemImage: "dot.radiowaves.left.and.right")
            case .leading:
                Label("Leading · \(live.followerNames.count)", systemImage: "dot.radiowaves.left.and.right")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.green)
            case .following:
                if live.isConnected {
                    Label("Following \(live.leaderName ?? "")", systemImage: "dot.radiowaves.right")
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(.green)
                } else {
                    Label(live.leaderName == nil ? "Find a Leader" : "Reconnecting…",
                          systemImage: "exclamationmark.triangle")
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(.orange)
                }
            }
        }
        .sheet(isPresented: $showingSheet) {
            LiveFollowSheet()
        }
    }
}

struct LiveFollowSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(PerformanceSession.self) private var performance
    @Bindable private var live = LiveFollowSession.shared

    var body: some View {
        NavigationStack {
            List {
                if let message = live.statusMessage {
                    Section {
                        Label(message, systemImage: "info.circle")
                            .font(.subheadline)
                    }
                }

                switch live.mode {
                case .off: offContent
                case .leading: leadingContent
                case .following: followingContent
                }

                Section {
                    Toggle("Send My Commands While Following", isOn: $live.followerSendsCommands)
                    Toggle("Follow the Leader's Scrolling", isOn: $live.followScroll)
                } header: {
                    Text("When Following")
                } footer: {
                    Text("Leave commands off when the leader's device already drives your gear — otherwise every change would be sent twice. Scrolling follows only when you're both showing the same chart.")
                }
            }
            .navigationTitle("Live Follow")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    // MARK: Off

    @ViewBuilder
    private var offContent: some View {
        Section {
            TextField("Your name on stage", text: $live.stageName)
        } header: {
            Text("Your Name")
        } footer: {
            Text("Bandmates see this when they look for a leader.")
        }

        Section {
            Button {
                live.startLeading()
            } label: {
                Label("Lead the Band", systemImage: "dot.radiowaves.left.and.right")
                    .font(.headline)
            }
            Button {
                live.startBrowsing()
            } label: {
                Label("Follow a Leader", systemImage: "dot.radiowaves.right")
                    .font(.headline)
            }
        } footer: {
            Text("The leader's device picks the set list, song and snapshot; followers move with it, each showing the parts for their own role. Works over Wi-Fi or Bluetooth — no internet needed.")
        }
    }

    // MARK: Leading

    @ViewBuilder
    private var leadingContent: some View {
        Section {
            if live.followerNames.isEmpty {
                Text("Waiting for bandmates to follow \(live.stageName)…")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(live.followerNames, id: \.self) { name in
                    Label(name, systemImage: "person.fill.checkmark")
                }
            }
        } header: {
            Text("Following You")
        } footer: {
            Text(performance.isPlaying
                 ? "They follow \"\(performance.setList?.name ?? "")\" as you move through it. New followers get the set list sent to them."
                 : "Play a set list and followers get it sent to them, then move with you.")
        }

        Section {
            Button("Stop Leading", role: .destructive) { live.stop() }
        }
    }

    // MARK: Following

    @ViewBuilder
    private var followingContent: some View {
        if let leader = live.leaderName {
            Section {
                LabeledContent("Leader", value: leader)
                LabeledContent("Status", value: live.isConnected ? "Connected" : "Reconnecting…")
            }
        }

        Section {
            if live.nearbyLeaders.isEmpty {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Looking for leaders nearby…").foregroundStyle(.secondary)
                }
            }
            ForEach(live.nearbyLeaders) { leader in
                Button {
                    live.join(leader)
                } label: {
                    HStack {
                        Label(leader.name, systemImage: "person.wave.2")
                            .foregroundStyle(.primary)
                        Spacer()
                        if leader.name == live.leaderName && live.isConnected {
                            Image(systemName: "checkmark").foregroundStyle(.green)
                        } else {
                            Text("Join").foregroundStyle(Color.accentColor)
                        }
                    }
                }
            }
        } header: {
            Text("Leaders Nearby")
        } footer: {
            Text("Ask the leader to tap Lead the Band. Their set list comes over when you join.")
        }

        Section {
            Button("Stop Following", role: .destructive) { live.stop() }
        }
    }
}

/// "Update songs from the leader?" — shown anywhere in the app
struct LiveFollowPrompts: ViewModifier {
    @Bindable private var live = LiveFollowSession.shared

    func body(content: Content) -> some View {
        content.alert(
            "Update Songs from \(live.pendingSet?.from ?? "the Leader")?",
            isPresented: Binding(get: { live.pendingSet != nil }, set: { _ in }),
            presenting: live.pendingSet
        ) { _ in
            Button("Update") { live.resolvePendingSet(update: true) }
            Button("Keep Mine", role: .cancel) { live.resolvePendingSet(update: false) }
        } message: { pending in
            let songs = pending.existingCount == 1 ? "1 song" : "\(pending.existingCount) songs"
            let added = pending.newCount > 0 ? " \(pending.newCount) new song\(pending.newCount == 1 ? "" : "s") will be added either way." : ""
            Text("\"\(pending.archive.title)\" includes \(songs) you already have. Update them to the leader's versions, or keep yours?\(added)")
        }
    }
}

extension View {
    func liveFollowPrompts() -> some View { modifier(LiveFollowPrompts()) }
}
