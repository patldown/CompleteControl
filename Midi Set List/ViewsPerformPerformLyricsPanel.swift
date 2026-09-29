//
//  PerformLyricsPanel.swift
//  Midi Set List
//
//  Lyrics or sheet music shown inline on the Perform screen, below the snapshots. It
//  can auto-scroll in place, or expand to fill the app window while the snapshot strip
//  stays reachable above it. When a song has both, this person's last choice is shown.
//

import SwiftUI
import CoreData

struct PerformLyricsPanel: View {
    @Environment(\.managedObjectContext) private var viewContext
    @ObservedObject var song: Song
    @Binding var isExpanded: Bool
    /// Shown in the control bar while expanded, since the song header is hidden then
    var title: String?

    @ObservedObject private var prefs = UserPreferences.shared
    @State private var isAutoScrolling = false
    @State private var resetTrigger = false
    @State private var showingEditLyrics = false

    private var mode: PerformChartMode? { prefs.chartMode(for: song) }
    private var cornerRadius: CGFloat { isExpanded ? 0 : 14 }

    var body: some View {
        Group {
            if let mode {
                VStack(spacing: 0) {
                    controlBar(mode)
                    ChartContentView(
                        song: song, mode: mode,
                        isScrolling: $isAutoScrolling, resetTrigger: $resetTrigger,
                        fontSize: isExpanded ? 24 : 19,
                        insets: isExpanded
                            ? UIEdgeInsets(top: 24, left: 32, bottom: 400, right: 32)
                            : UIEdgeInsets(top: 12, left: 16, bottom: 200, right: 16)
                    )
                }
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showingEditLyrics) {
            EditLyricsView(song: song)
        }
    }

    // MARK: Controls

    private func controlBar(_ mode: PerformChartMode) -> some View {
        HStack(spacing: 12) {
            Button {
                isAutoScrolling = false
                showingEditLyrics = true
            } label: {
                Label("Edit Lyrics", systemImage: "pencil")
            }

            if isExpanded, let title {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            if song.hasLyricsText && song.hasSheetMusic {
                ChartModeMenu(song: song, current: mode) { isAutoScrolling = false }
            }

            if mode == .lyrics {
                TransposeMenu(song: song) { try? viewContext.save() }
            }

            Button {
                isAutoScrolling = false
                resetTrigger.toggle()
            } label: {
                Label("Reset to Top", systemImage: "arrow.up.to.line")
            }

            speedControl(mode)

            Button {
                isAutoScrolling.toggle()
            } label: {
                Label(isAutoScrolling ? "Pause Scrolling" : "Start Scrolling",
                      systemImage: isAutoScrolling ? "pause.fill" : "play.fill")
                    .frame(width: 22)
            }
            .foregroundStyle(isAutoScrolling ? Color.orange : Color.green)

            Button {
                isExpanded.toggle()
            } label: {
                Label(isExpanded ? "Exit Full View" : "Full View",
                      systemImage: isExpanded ? "arrow.down.right.and.arrow.up.left"
                                              : "arrow.up.left.and.arrow.down.right")
            }
        }
        .labelStyle(.iconOnly)
        .font(.body.weight(.semibold))
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.08))
    }

    private func speedControl(_ mode: PerformChartMode) -> some View {
        let speed = prefs.scrollSpeed(for: mode, song: song)
        let range = UserPreferences.scrollSpeedRange
        return HStack(spacing: 6) {
            Button {
                prefs.setScrollSpeed(speed - 5, for: mode, song: song)
            } label: {
                Label("Slower", systemImage: "minus")
            }
            .disabled(speed <= range.lowerBound)

            Text("\(Int(speed))")
                .font(.caption.monospacedDigit().weight(.semibold))
                .frame(minWidth: 24)
                .accessibilityLabel("Scroll speed \(Int(speed))")

            Button {
                prefs.setScrollSpeed(speed + 5, for: mode, song: song)
            } label: {
                Label("Faster", systemImage: "plus")
            }
            .disabled(speed >= range.upperBound)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.white.opacity(0.12), in: Capsule())
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "text.alignleft")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("No lyrics or sheet music for this song")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("Add Lyrics or Sheet Music") {
                showingEditLyrics = true
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: cornerRadius))
    }
}

// MARK: - Transpose

/// Compact transpose control: shows the offset, opens a menu that stays open while
/// you step up or down so several semitones take one visit.
struct TransposeMenu: View {
    @ObservedObject var song: Song
    var onChange: () -> Void = {}

    var body: some View {
        Menu {
            if let key = song.currentKey {
                Text("Key: \(key.displayName)")
            }
            Button {
                step(1)
            } label: {
                Label("Up a Semitone", systemImage: "arrow.up")
            }
            .disabled(song.transpose >= Song.transposeRange.upperBound)
            .menuActionDismissBehavior(.disabled)

            Button {
                step(-1)
            } label: {
                Label("Down a Semitone", systemImage: "arrow.down")
            }
            .disabled(song.transpose <= Song.transposeRange.lowerBound)
            .menuActionDismissBehavior(.disabled)

            if song.transpose != 0 {
                Button {
                    song.transpose = 0
                    changed()
                } label: {
                    Label("Back to Original", systemImage: "arrow.uturn.backward")
                }
            }
        } label: {
            HStack(spacing: 2) {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.caption.weight(.bold))
                Text(Self.offsetLabel(song.transpose))
                    .font(.caption.monospacedDigit().weight(.semibold))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.white.opacity(song.transpose == 0 ? 0.12 : 0.25), in: Capsule())
        }
        .menuIndicator(.hidden)
        .accessibilityLabel("Transpose")
        .accessibilityValue(Self.offsetLabel(song.transpose))
    }

    static func offsetLabel(_ semitones: Int) -> String {
        semitones == 0 ? "0" : String(format: "%+d", semitones)
    }

    private func step(_ delta: Int) {
        song.transpose += delta
        changed()
    }

    private func changed() {
        song.dateModified = Date()
        onChange()
    }
}
