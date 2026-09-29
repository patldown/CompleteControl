//
//  PerformLyricsPanel.swift
//  Midi Set List
//
//  Lyrics / chart shown inline on the Perform screen, below the snapshots. It can
//  auto-scroll in place, or expand to fill the app window while the snapshot strip
//  stays reachable above it.
//

import SwiftUI
import CoreData

struct PerformLyricsPanel: View {
    @ObservedObject var song: Song
    @Binding var isExpanded: Bool
    /// Shown in the control bar while expanded, since the song header is hidden then
    var title: String?

    @State private var isAutoScrolling = false
    @AppStorage("performLyricsScrollSpeed") private var scrollSpeed: Double = 20
    @State private var resetTrigger = false
    @State private var showingEditLyrics = false

    private var hasLyrics: Bool { song.pdfFileURL != nil || !(song.lyrics ?? "").isEmpty }
    private var cornerRadius: CGFloat { isExpanded ? 0 : 14 }

    var body: some View {
        Group {
            if hasLyrics {
                VStack(spacing: 0) {
                    controlBar
                    content
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

    @ViewBuilder
    private var content: some View {
        if let pdfURL = song.pdfFileURL {
            PDFKitView(url: pdfURL)
        } else {
            AutoScrollingTextView(
                text: song.lyrics ?? "",
                isScrolling: $isAutoScrolling,
                scrollSpeed: $scrollSpeed,
                resetTrigger: $resetTrigger,
                fontSize: isExpanded ? 24 : 19,
                insets: isExpanded
                    ? UIEdgeInsets(top: 24, left: 32, bottom: 400, right: 32)
                    : UIEdgeInsets(top: 12, left: 16, bottom: 200, right: 16)
            )
        }
    }

    // MARK: Controls

    private var controlBar: some View {
        HStack(spacing: 16) {
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

            if song.pdfFileURL == nil {
                Button {
                    isAutoScrolling = false
                    resetTrigger.toggle()
                } label: {
                    Label("Reset to Top", systemImage: "arrow.up.to.line")
                }

                speedControl

                Button {
                    isAutoScrolling.toggle()
                } label: {
                    Label(isAutoScrolling ? "Pause Scrolling" : "Start Scrolling",
                          systemImage: isAutoScrolling ? "pause.fill" : "play.fill")
                        .frame(width: 22)
                }
                .foregroundStyle(isAutoScrolling ? Color.orange : Color.green)
            }

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

    private var speedControl: some View {
        HStack(spacing: 6) {
            Button {
                scrollSpeed = max(5, scrollSpeed - 5)
            } label: {
                Label("Slower", systemImage: "minus")
            }
            .disabled(scrollSpeed <= 5)

            Text("\(Int(scrollSpeed))")
                .font(.caption.monospacedDigit().weight(.semibold))
                .frame(minWidth: 24)
                .accessibilityLabel("Scroll speed \(Int(scrollSpeed))")

            Button {
                scrollSpeed = min(100, scrollSpeed + 5)
            } label: {
                Label("Faster", systemImage: "plus")
            }
            .disabled(scrollSpeed >= 100)
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
            Text("No lyrics or chart for this song")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("Add Lyrics") {
                showingEditLyrics = true
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: cornerRadius))
    }
}
