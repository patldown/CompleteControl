//
//  PerformView.swift
//  Midi Set List
//
//  Pick a set list and press Play. The first song loads (its Snapshot 1 is sent),
//  then step through songs with Previous / Next and recall snapshots — by touch
//  or from a MIDI / Bluetooth foot controller.
//

import SwiftUI
import CoreData
import UIKit

struct PerformView: View {
    @Environment(PerformanceSession.self) private var performance

    var body: some View {
        NavigationStack {
            Group {
                if performance.isPlaying {
                    PerformPlayingView()
                } else {
                    PerformSetListPicker()
                }
            }
        }
        // Keep the screen on while a set is playing
        .onChange(of: performance.isPlaying, initial: true) { _, playing in
            UIApplication.shared.isIdleTimerDisabled = playing
        }
    }
}

// MARK: - Choose a set list

private struct PerformSetListPicker: View {
    @Environment(PerformanceSession.self) private var performance
    @FetchRequest(sortDescriptors: [SortDescriptor(\.dateModified, order: .reverse)])
    private var setLists: FetchedResults<SetList>
    @ObservedObject private var remote = MIDIRemoteSettings.shared

    @State private var selectedID: NSManagedObjectID?
    @State private var showingBTMIDI = false

    private var selected: SetList? {
        setLists.first { $0.objectID == selectedID }
    }

    var body: some View {
        List {
            Section {
                ForEach(setLists) { setList in
                    Button {
                        selectedID = setList.objectID
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(setList.name)
                                    .font(.headline)
                                    .foregroundStyle(.primary)
                                Text("\(setList.songs.count) song\(setList.songs.count == 1 ? "" : "s")")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: selectedID == setList.objectID ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selectedID == setList.objectID ? Color.accentColor : .secondary)
                                .imageScale(.large)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("Choose a Set List")
            }

            Section {
                NavigationLink {
                    MIDIRemoteSettingsView()
                } label: {
                    LabeledContent {
                        Text(remote.isEnabled ? remote.receiveChannelLabel : "Off")
                    } label: {
                        Label("MIDI Control", systemImage: "slider.horizontal.below.rectangle")
                    }
                }
            } footer: {
                if remote.isEnabled {
                    Text("Snapshots on \(remote.snapshotRangeLabel). Previous / Next song on \(remote.binding(for: .previousSong)?.label ?? "—") / \(remote.binding(for: .nextSong)?.label ?? "—").")
                }
            }
        }
        .navigationTitle("Perform")
        .offlineStatusBadge()
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                LiveFollowButton()
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingBTMIDI = true
                } label: {
                    Label("Bluetooth MIDI", systemImage: "wave.3.right")
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                if let selected { performance.play(selected) }
            } label: {
                Label("Play", systemImage: "play.fill")
                    .font(.title2.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .disabled(selected == nil || selected?.songs.isEmpty == true)
            .padding()
            .background(.bar)
        }
        .overlay {
            if setLists.isEmpty {
                ContentUnavailableView {
                    Label("No Set Lists", systemImage: "list.bullet")
                } description: {
                    Text("Create a set list in the Set Lists tab, then come back here to play it.")
                }
            }
        }
        .sheet(isPresented: $showingBTMIDI) {
            BTMIDIConnectSheet()
        }
        .onAppear {
            if selectedID == nil { selectedID = setLists.first?.objectID }
        }
    }
}

// MARK: - Playing

private struct PerformPlayingView: View {
    @Environment(PerformanceSession.self) private var performance
    @Environment(MIDIManager.self) private var midiManager
    @ObservedObject private var remote = MIDIRemoteSettings.shared
    private let music = AppleMusicReference.shared

    @State private var showingBTMIDI = false
    @State private var showingReferencePlayer = false
    /// Lyrics fill the window; the snapshot strip stays above them
    @State private var lyricsExpanded = false
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    /// Edges full view extends past the safe area to. Not the sides of a landscape iPhone,
    /// where the notch or Dynamic Island would cover the start of each line.
    private var fullViewEdges: Edge.Set {
        let landscapePhone = verticalSizeClass == .compact && horizontalSizeClass != .regular
        return landscapePhone ? .bottom : [.bottom, .horizontal]
    }
    @State private var panelCommand: LyricsPanelCommand?

    var body: some View {
        let songs = performance.songs
        VStack(spacing: 0) {
            if let song = performance.currentSong {
                if !lyricsExpanded {
                    VStack(alignment: .leading, spacing: 8) {
                        PerformSongHeader(song: song, index: performance.songIndex, total: songs.count,
                                          nextSongName: name(in: songs, at: performance.songIndex + 1))
                        if let error = performance.lastError {
                            errorBanner(error)
                        }
                        if showingReferencePlayer {
                            Divider()
                            PracticePlayerPanel(song: song)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.top, 12)
                } else {
                    if let error = performance.lastError {
                        errorBanner(error)
                            .padding(.horizontal)
                            .padding(.top, 8)
                    }
                    if showingReferencePlayer {
                        PracticePlayerPanel(song: song)
                            .padding(.horizontal)
                            .padding(.top, 8)
                    }
                }

                PerformSnapshotStrip(song: song)
                    .id(song.objectID)
                    .padding(.vertical, 10)

                PerformLyricsPanel(song: song, isExpanded: $lyricsExpanded,
                                   title: "\(performance.songIndex + 1)/\(songs.count) · \(song.name)",
                                   command: panelCommand)
                    .id(song.objectID)  // new song, fresh scroll position
                    .padding(.horizontal, lyricsExpanded ? 0 : 16)
                    // Full view runs to the screen's edges: under the home indicator, and to
                    // the sides where there's no notch in the way (iPad, or iPhone portrait)
                    .ignoresSafeArea(edges: lyricsExpanded ? fullViewEdges : [])
                    .overlay {
                        if lyricsExpanded { songArrows(songs: songs) }
                    }

                if !lyricsExpanded {
                    remoteStatus
                        .padding(.horizontal)
                        .padding(.top, 8)
                }
            } else {
                ContentUnavailableView("No Songs", systemImage: "music.note",
                                       description: Text("This set list has no songs."))
            }

            if !lyricsExpanded {
                navigationBar(songs: songs)
            }
        }
        .animation(.default, value: lyricsExpanded)
        // Full view also takes the status bar's strip, and dims the home indicator
        .statusBarHidden(lyricsExpanded)
        .persistentSystemOverlays(lyricsExpanded ? .hidden : .automatic)
        // Bluetooth page-turner pedals arrive as key presses
        .background(PedalKeyCatcher(onKey: handlePedal).frame(width: 0, height: 0))
        .toolbar(lyricsExpanded ? .hidden : .visible, for: .navigationBar)
        .toolbar(lyricsExpanded ? .hidden : .visible, for: .tabBar)
        .navigationTitle(performance.setList?.name ?? "Perform")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(role: .destructive) {
                    performance.stop()
                } label: {
                    Label("End Set", systemImage: "stop.fill")
                }
                .tint(.red)
            }
            ToolbarItem(placement: .primaryAction) {
                songListMenu(songs: songs)
            }
            ToolbarItem(placement: .primaryAction) {
                LiveFollowButton()
            }
            ToolbarItem(placement: .secondaryAction) {
                Button {
                    showingBTMIDI = true
                } label: {
                    Label("Bluetooth MIDI", systemImage: "wave.3.right")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingReferencePlayer.toggle()
                    if !showingReferencePlayer {
                        music.stop()
                        performance.practiceRate = 1.0
                        performance.applyPracticeRate()
                    }
                } label: {
                    Label("Reference Track", systemImage: showingReferencePlayer ? "headphones.circle.fill" : "headphones.circle")
                        .foregroundStyle(showingReferencePlayer ? Color.accentColor : .primary)
                }
                .accessibilityValue(showingReferencePlayer ? "On" : "Off")
            }
        }
        .sheet(isPresented: $showingBTMIDI) {
            BTMIDIConnectSheet()
        }
        .onChange(of: performance.songIndex) { _, _ in
            if showingReferencePlayer { music.stop() }
        }
        .onDisappear {
            music.stop()
        }
    }

    private func songListMenu(songs: [Song]) -> some View {
        Menu {
            ForEach(Array(songs.enumerated()), id: \.element.objectID) { index, song in
                Button {
                    performance.goToSong(index)
                } label: {
                    if index == performance.songIndex {
                        Label("\(index + 1). \(song.name)", systemImage: "play.fill")
                    } else {
                        Text("\(index + 1). \(song.name)")
                    }
                }
            }
        } label: {
            Label("Songs", systemImage: "list.number")
        }
    }

    /// Previous / next song arrows over the expanded lyrics, since the song bar is hidden then
    private func songArrows(songs: [Song]) -> some View {
        HStack {
            songArrow("chevron.left", label: "Previous Song",
                      detail: name(in: songs, at: performance.songIndex - 1)) {
                performance.previousSong()
            }
            .opacity(performance.hasPreviousSong ? 1 : 0)
            .disabled(!performance.hasPreviousSong)

            Spacer()

            songArrow("chevron.right", label: "Next Song",
                      detail: name(in: songs, at: performance.songIndex + 1)) {
                performance.nextSong()
            }
            .opacity(performance.hasNextSong ? 1 : 0)
            .disabled(!performance.hasNextSong)
        }
        .padding(.horizontal, 8)
    }

    private func songArrow(_ icon: String, label: String, detail: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.title3.weight(.bold))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 40, height: 64)
                .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.2)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(detail ?? "")
    }

    private func handlePedal(_ key: PedalKey) -> Bool {
        guard let action = PedalSettings.shared.action(for: key) else { return false }
        switch action {
        case .nextSong: performance.nextSong()
        case .previousSong: performance.previousSong()
        case .nextSnapshot: performance.nextSnapshot()
        case .previousSnapshot: performance.previousSnapshot()
        case .pageDown, .pageUp, .toggleAutoScroll, .toggleFullView:
            panelCommand = LyricsPanelCommand(action: action)
        }
        return true
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.subheadline)
            Spacer()
            Button {
                performance.clearError()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private var remoteStatus: some View {
        HStack(spacing: 8) {
            Image(systemName: remote.isEnabled ? "dot.radiowaves.left.and.right" : "slash.circle")
                .foregroundStyle(remote.isEnabled ? .green : .secondary)
            if remote.isEnabled {
                if let event = performance.lastRemoteEvent {
                    Text("\(event.message.description) → \(event.outcome)")
                        .lineLimit(1)
                } else {
                    Text("MIDI control on \(remote.receiveChannelLabel) · \(midiManager.availableSources.count) input\(midiManager.availableSources.count == 1 ? "" : "s")")
                }
            } else {
                Text("MIDI control is off")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func navigationBar(songs: [Song]) -> some View {
        HStack(spacing: 10) {
            Button {
                performance.previousSong()
            } label: {
                navLabel(title: "Previous", icon: "backward.fill",
                         detail: performance.hasPreviousSong ? name(in: songs, at: performance.songIndex - 1) : nil,
                         iconFirst: true)
            }
            .disabled(!performance.hasPreviousSong)
            .opacity(performance.hasPreviousSong ? 1 : 0)

            Button {
                performance.nextSong()
            } label: {
                navLabel(title: performance.hasNextSong ? "Next" : "End of Set", icon: "forward.fill",
                         detail: performance.hasNextSong ? name(in: songs, at: performance.songIndex + 1) : nil,
                         iconFirst: false)
            }
            .disabled(!performance.hasNextSong)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.regular)
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func name(in songs: [Song], at index: Int) -> String? {
        songs.indices.contains(index) ? songs[index].name : nil
    }

    private func navLabel(title: String, icon: String, detail: String?, iconFirst: Bool) -> some View {
        HStack(spacing: 6) {
            if iconFirst { Image(systemName: icon) }
            VStack(spacing: 1) {
                Text(title).font(.subheadline.weight(.semibold))
                if let detail {
                    Text(detail).font(.caption2).lineLimit(1).opacity(0.8)
                }
            }
            if !iconFirst { Image(systemName: icon) }
        }
        .frame(maxWidth: .infinity, minHeight: 36)
    }
}

// MARK: - Song header

private struct PerformSongHeader: View {
    @ObservedObject var song: Song
    let index: Int
    let total: Int
    var nextSongName: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Song \(index + 1) of \(total)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            // Bold title + secondary metadata, all on one line
            compactInfoLine
                .lineLimit(1)
                .minimumScaleFactor(0.6)

            if song.bpm != nil {
                MetronomeControl(song: song)
            }
            if let notes = song.notes, !notes.isEmpty {
                Text(notes)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if let next = nextSongName {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                    Text("Up next: \(next)")
                        .lineLimit(1)
                }
                .font(.subheadline)
                .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Title is bold+primary at title3 size; artist, BPM, time sig, key are
    /// regular+secondary at the same size. Built with AttributedString so each
    /// segment keeps its own styling without using the deprecated Text + operator.
    private var compactInfoLine: Text {
        var result = AttributedString(song.name)
        result.font = .title3.bold()

        func secondary(_ s: String) -> AttributedString {
            var a = AttributedString(s)
            a.font = .title3
            a.foregroundColor = Color.secondary
            return a
        }

        if let artist = song.artist, !artist.isEmpty {
            result += secondary(" · \(artist)")
        }
        if let bpm = song.bpm {
            var seg = " · \(bpm) BPM"
            if let sig = song.timeSignature { seg += " · \(sig)" }
            result += secondary(seg)
        }
        if let key = song.currentKey {
            var keySeg = " · \(key.displayName)"
            if song.transpose != 0 && !song.isCapoKeepingKey {
                keySeg += " (\(TransposeMenu.offsetLabel(song.transpose)))"
            }
            result += secondary(keySeg)
        }
        if song.capoEnabled {
            if let fret = song.effectiveCapo {
                result += secondary(fret == 0 ? " · No Capo" : " · Capo \(fret)")
            }
        }
        return Text(result)
    }
}

// MARK: - Snapshot strip

/// One scrolling row of compact snapshot cards. Selecting a snapshot — by tap or MIDI
/// pedal — scrolls so the next card is in view too, so you can see what's coming.
private struct PerformSnapshotStrip: View {
    @Environment(PerformanceSession.self) private var performance
    @ObservedObject var song: Song
    @ObservedObject private var remote = MIDIRemoteSettings.shared
    @State private var flashingIndex: Int? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if performance.snapshotsLocked {
                Label("The leader controls snapshots", systemImage: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
            }
            strip
        }
    }

    private var strip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(0..<song.snapshotCount, id: \.self) { index in
                        snapshotButton(index, proxy: proxy)
                            .id(index)
                    }
                }
                .padding(.horizontal, 16)
            }
            .onChange(of: performance.activeSnapshot) { old, new in
                reveal(new, movingForward: new >= old, proxy: proxy)
                flash(new)
            }
            .onAppear {
                reveal(performance.activeSnapshot, movingForward: true, proxy: proxy, animated: false)
            }
        }
    }

    /// Scrolls just enough to show the selected card and, moving forward, the one after it.
    /// Moving back, the selected card lands at the leading edge with the next one beside it.
    private func reveal(_ index: Int, movingForward: Bool, proxy: ScrollViewProxy, animated: Bool = true) {
        let last = song.snapshotCount - 1
        guard last >= 0 else { return }
        let target = movingForward ? min(index + 1, last) : min(index, last)
        if animated {
            withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(target) }
        } else {
            proxy.scrollTo(target)
        }
    }

    private func flash(_ index: Int) {
        flashingIndex = index
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            withAnimation(.easeOut(duration: 0.3)) { flashingIndex = nil }
        }
    }

    private func snapshotButton(_ index: Int, proxy: ScrollViewProxy) -> some View {
        let isActive = performance.isActive(snapshot: index, of: song)
        let count = song.commands(inSnapshot: index).count
        // Following: greyed out, with the leader's live snapshot still marked
        let locked = performance.snapshotsLocked
        let activeColor = locked ? Color.gray : Color.accentColor
        return Button {
            let previous = performance.activeSnapshot
            performance.selectSnapshot(index)
            reveal(index, movingForward: index >= previous, proxy: proxy)
            flash(index)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text("\(index + 1)")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(isActive ? Color.white.opacity(0.25) : Color.secondary.opacity(0.15),
                                    in: Capsule())
                    Spacer(minLength: 0)
                    if isActive && performance.isSending {
                        ProgressView().controlSize(.mini).tint(.white)
                    } else if remote.isEnabled, let binding = remote.snapshotBinding(for: index) {
                        Text(binding.label)
                            .font(.caption2.monospacedDigit())
                            .lineLimit(1)
                            .opacity(0.8)
                    }
                }
                Text(song.snapshotName(index))
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(count == 0 ? "Empty" : "\(count) command\(count == 1 ? "" : "s")")
                    .font(.caption2)
                    .opacity(0.8)
            }
            .foregroundStyle(isActive ? Color.white : Color.primary)
            .frame(width: 128, alignment: .topLeading)
            .padding(8)
            .background(isActive ? activeColor : Color(.secondarySystemBackground),
                        in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isActive ? Color.clear : Color.secondary.opacity(0.2))
            )
            .overlay {
                if flashingIndex == index {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(.white.opacity(0.45))
                }
            }
            .animation(.easeOut(duration: 0.3), value: flashingIndex == index)
            .opacity(locked && !isActive ? 0.45 : 1)
        }
        .buttonStyle(.plain)
        .disabled(locked)
        .accessibilityAddTraits(isActive ? .isSelected : [])
        .accessibilityHint(locked ? "The leader controls snapshots" : "")
    }
}

// MARK: - Practice player panel

private struct PracticePlayerPanel: View {
    @ObservedObject var song: Song
    @Environment(PerformanceSession.self) private var performance
    private let music = AppleMusicReference.shared

    @State private var isDragging = false
    @State private var dragTime: TimeInterval = 0
    @State private var loopIn: TimeInterval? = nil
    @State private var loopOut: TimeInterval? = nil

    private var trackID: String? { song.referenceTrackID }
    private var hasTrack: Bool { trackID != nil }
    private var isThisTrackPlaying: Bool { music.isPlaying(trackID ?? "") }
    private var isLoading: Bool { music.loadingTrackID != nil && music.loadingTrackID == trackID }
    private var duration: TimeInterval? { song.referenceTrack?.duration }
    private var hasLoop: Bool { music.loopRegion != nil }

    var body: some View {
        let rate = performance.practiceRate
        VStack(alignment: .leading, spacing: 8) {
            // Practice tempo slider (60%–110%) with notched tick marks at each 5% step
            HStack(spacing: 8) {
                Image(systemName: "tortoise.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                VStack(spacing: 2) {
                    Slider(
                        value: Binding(get: { performance.practiceRate },
                                       set: { performance.practiceRate = $0 }),
                        in: 0.6...1.1,
                        step: 0.05
                    ) { editing in
                        if !editing { performance.applyPracticeRate() }
                    }
                    .tint(rate == 1.0 ? Color.secondary : Color.accentColor)
                    // Tick marks: 11 positions (0.60, 0.65 … 1.10); 100% mark is taller
                    GeometryReader { geo in
                        let steps = 10
                        let thumbR: CGFloat = 14
                        let trackW = geo.size.width - 2 * thumbR
                        ZStack(alignment: .topLeading) {
                            ForEach(0...steps, id: \.self) { i in
                                let x = thumbR + CGFloat(i) / CGFloat(steps) * trackW
                                let isCenter = i == 8  // step 8 = 100%
                                Rectangle()
                                    .fill(isCenter
                                          ? Color.secondary.opacity(0.65)
                                          : Color.secondary.opacity(0.3))
                                    .frame(width: isCenter ? 2 : 1.5,
                                           height: isCenter ? 7 : 4)
                                    .position(x: x, y: isCenter ? 3.5 : 2)
                            }
                        }
                    }
                    .frame(height: 7)
                }
                Image(systemName: "hare.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("\(Int((rate * 100).rounded()))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(rate == 1.0 ? .secondary : .primary)
                    .frame(minWidth: 36, alignment: .trailing)
            }

            // Track info + total duration
            HStack(alignment: .firstTextBaseline) {
                if let title = song.referenceTrack?.title {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        if let artist = song.referenceTrack?.artist {
                            Text(artist)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                } else {
                    Text("No reference track")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .italic()
                }
                Spacer()
                if let dur = duration {
                    Text(timeLabel(dur))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            // Transport controls + scrub bar + loop, all in one row
            TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                let current = isDragging ? dragTime : music.currentPlaybackTime
                HStack(spacing: 10) {
                    Button { music.restart() } label: {
                        Image(systemName: "backward.end.fill").font(.subheadline.weight(.semibold))
                    }
                    .disabled(!hasTrack)

                    Button { music.skip(by: -15) } label: {
                        Image(systemName: "gobackward.15").font(.subheadline)
                    }
                    .disabled(!hasTrack)

                    Button {
                        guard let id = trackID else { return }
                        Task { await music.togglePlayback(of: id) }
                    } label: {
                        if isLoading {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: isThisTrackPlaying ? "pause.circle.fill" : "play.circle.fill")
                                .font(.title2)
                        }
                    }
                    .disabled(!hasTrack)

                    Button { music.skip(by: 15) } label: {
                        Image(systemName: "goforward.15").font(.subheadline)
                    }
                    .disabled(!hasTrack)

                    if let dur = duration, dur > 0 {
                        scrubBar(current: current, duration: dur)
                            .frame(maxWidth: .infinity)
                    } else {
                        Spacer()
                    }

                    if hasTrack { loopControls }
                }
                .buttonStyle(.plain)
                .foregroundStyle(hasTrack ? Color.primary : Color.secondary)
            }

            if let error = music.lastError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity)
        .onChange(of: song.referenceTrackID) { _, _ in
            music.clearLoopRegion()
            loopIn = nil
            loopOut = nil
        }
        .padding(.bottom, 4)
    }

    // MARK: Scrub bar

    private func scrubBar(current: TimeInterval, duration: TimeInterval) -> some View {
        GeometryReader { geo in
            let w = geo.size.width
            let progress = CGFloat(max(0, min(1, current / duration)))

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.secondary.opacity(0.25))
                    .frame(height: 6)

                if let region = music.loopRegion {
                    let lx = CGFloat(region.lowerBound / duration) * w
                    let rw = CGFloat((region.upperBound - region.lowerBound) / duration) * w
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.accentColor.opacity(0.4))
                        .frame(width: max(0, rw), height: 6)
                        .offset(x: lx)
                }

                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.primary.opacity(0.7))
                    .frame(width: max(0, progress * w), height: 6)

                Circle()
                    .fill(Color.primary)
                    .frame(width: 14, height: 14)
                    .offset(x: max(0, min(w - 14, progress * w - 7)))
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        isDragging = true
                        dragTime = max(0, min(duration, Double(value.location.x / w) * duration))
                    }
                    .onEnded { value in
                        let t = max(0, min(duration, Double(value.location.x / w) * duration))
                        music.seek(to: t)
                        isDragging = false
                    }
            )
        }
        .frame(maxWidth: .infinity, minHeight: 20, maxHeight: 20)
    }

    // MARK: Loop controls

    @ViewBuilder
    private var loopControls: some View {
        if hasLoop {
            Button {
                music.clearLoopRegion()
                loopIn = nil
                loopOut = nil
            } label: {
                Image(systemName: "repeat.circle.fill")
                    .font(.body)
                    .foregroundStyle(Color.accentColor)
            }
        } else {
            HStack(spacing: 6) {
                loopPointButton("IN", isSet: loopIn != nil) {
                    loopIn = music.currentPlaybackTime
                    tryActivateLoop()
                }
                loopPointButton("OUT", isSet: loopOut != nil) {
                    loopOut = music.currentPlaybackTime
                    tryActivateLoop()
                }
            }
        }
    }

    private func loopPointButton(_ label: String, isSet: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.caption.weight(.bold).monospacedDigit())
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(
                    isSet ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 5)
                )
                .foregroundStyle(isSet ? Color.accentColor : Color.secondary)
        }
    }

    private func tryActivateLoop() {
        guard let inTime = loopIn, let outTime = loopOut, outTime > inTime else { return }
        music.setLoopRegion(start: inTime, end: outTime)
    }

    private func timeLabel(_ t: TimeInterval) -> String {
        let s = Int(max(0, t))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

#Preview {
    let ctx = PersistenceController.preview.viewContext
    let s1 = Song.create(name: "Sweet Home Alabama", artist: "Lynyrd Skynyrd", bpm: 98, in: ctx)
    let s2 = Song.create(name: "Wonderwall", artist: "Oasis", in: ctx)
    let sl = SetList.create(name: "Friday Night Gig", in: ctx)
    sl.addSong(s1); sl.addSong(s2)
    try? ctx.save()
    return PerformView()
        .environment(\.managedObjectContext, ctx)
        .environment(MIDIManager())
        .environment(PerformanceSession())
}
