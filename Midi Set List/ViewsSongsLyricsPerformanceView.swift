//
//  LyricsPerformanceView.swift
//  Midi Set List
//
//  Created by Patrick Downey on 9/25/26.
//

import SwiftUI
import CoreData
import UIKit
import PDFKit

struct LyricsPerformanceView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var song: Song

    @ObservedObject private var prefs = UserPreferences.shared
    @State private var isAutoScrolling = false
    @State private var showControls = true
    @State private var showingEditLyrics = false
    @State private var resetTrigger = false

    /// Lyrics or sheet music — this person's last choice when the song has both
    private var mode: PerformChartMode { song.chartMode(preferred: prefs.performChartMode) ?? .lyrics }

    private var scrollSpeed: Binding<Double> {
        Binding(get: { prefs.scrollSpeed(for: mode) },
                set: { prefs.setScrollSpeed($0, for: mode) })
    }

    var body: some View {
        // Stacked, not overlaid: the lyrics end where the controls begin, so text
        // never shows through behind the buttons
        VStack(spacing: 0) {
            if showControls {
                topBar
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            Group {
                if song.chartMode(preferred: prefs.performChartMode) == nil {
                    Text("No lyrics or sheet music yet.\n\nTap Edit to add lyrics, a PDF or images.")
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                        .padding()
                } else {
                    ChartContentView(song: song, mode: mode,
                                     isScrolling: $isAutoScrolling, resetTrigger: $resetTrigger)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation {
                    showControls.toggle()
                }
            }

            if showControls && song.chartMode(preferred: prefs.performChartMode) != nil {
                bottomControls
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .background(Color.black.ignoresSafeArea())
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .sheet(isPresented: $showingEditLyrics) {
            EditLyricsView(song: song)
        }
    }

    private var topBar: some View {
        HStack {
            Button {
                isAutoScrolling = false
                dismiss()
            } label: {
                Label("Close", systemImage: "xmark.circle.fill")
                    .font(.title2)
                    .labelStyle(.iconOnly)
            }
            .tint(.white)

            Spacer()

            if song.hasLyricsText && song.hasSheetMusic {
                Picker("Show", selection: Binding(
                    get: { mode },
                    set: { isAutoScrolling = false; prefs.performChartMode = $0 }
                )) {
                    ForEach(PerformChartMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 260)

                Spacer()
            }

            Button {
                isAutoScrolling = false
                showingEditLyrics = true
            } label: {
                Label("Edit Lyrics", systemImage: "pencil.circle.fill")
                    .font(.title2)
                    .labelStyle(.iconOnly)
            }
            .tint(.white)
        }
        .padding()
        .background(Color(white: 0.12))
    }

    private var bottomControls: some View {
        VStack(spacing: 16) {
            VStack(spacing: 8) {
                HStack {
                    Image(systemName: "speedometer")
                    Text("Scroll Speed")
                        .font(.subheadline)
                    Spacer()
                    Text("\(Int(scrollSpeed.wrappedValue))")
                        .font(.subheadline)
                        .monospacedDigit()
                }
                .foregroundStyle(.white)

                Slider(value: scrollSpeed, in: UserPreferences.scrollSpeedRange, step: 5)
                    .tint(.white)
            }
            .padding(.horizontal)

            Button {
                isAutoScrolling.toggle()
            } label: {
                HStack {
                    Image(systemName: isAutoScrolling ? "pause.fill" : "play.fill")
                        .font(.title2)
                    Text(isAutoScrolling ? "Pause Scrolling" : "Start Scrolling")
                        .font(.headline)
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(isAutoScrolling ? Color.orange : Color.green)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .padding(.horizontal)

            Button {
                isAutoScrolling = false
                resetTrigger.toggle()
            } label: {
                Label("Reset to Top", systemImage: "arrow.up.to.line")
                    .font(.subheadline)
            }
            .tint(.white)
        }
        .padding(.vertical)
        .background(Color(white: 0.12))
    }
}

// MARK: - UIKit Auto-Scrolling Text View

struct AutoScrollingTextView: UIViewRepresentable {
    let text: String
    @Binding var isScrolling: Bool
    @Binding var scrollSpeed: Double
    @Binding var resetTrigger: Bool
    var fontSize: CGFloat = 24
    var insets = UIEdgeInsets(top: 100, left: 32, bottom: 500, right: 32)
    /// Semitones to shift recognised chords by
    var transpose: Int = 0
    /// Chord spelling from the song's key; nil lets each chord decide
    var chordsPreferFlats: Bool? = nil
    /// Blank lines above the lyrics come from this person's preferences
    @ObservedObject private var prefs = UserPreferences.shared

    /// Blank lines first, so the opening lyrics start lower and auto-scroll eases into them
    private var displayText: String {
        String(repeating: "\n", count: min(max(prefs.lyricsLeadInLines, 0), 10)) + text
    }

    /// Recognised chords are tinted and bold, so it's clear which ones will transpose
    static let chordColor = UIColor.systemYellow

    private var renderKey: String {
        "\(displayText.hashValue)|\(fontSize)|\(insets)|\(transpose)|\(String(describing: chordsPreferFlats))"
    }

    private func applyText(to textView: UITextView) {
        let rendered = ChordEngine.render(displayText, transpose: transpose, flats: chordsPreferFlats)
        let attributed = NSMutableAttributedString(string: rendered.text, attributes: [
            .font: UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular),
            .foregroundColor: UIColor.white,
        ])
        let chordFont = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .bold)
        for range in rendered.chordRanges {
            attributed.addAttributes([.foregroundColor: Self.chordColor, .font: chordFont], range: range)
        }
        textView.attributedText = attributed
        textView.textContainerInset = insets
    }

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.backgroundColor = .black
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false

        let textView = UITextView()
        textView.backgroundColor = .clear
        textView.isEditable = false
        textView.isSelectable = false
        textView.isScrollEnabled = false
        applyText(to: textView)
        context.coordinator.lastRenderKey = renderKey
        textView.textContainer.lineBreakMode = .byWordWrapping
        textView.translatesAutoresizingMaskIntoConstraints = false

        scrollView.addSubview(textView)

        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            textView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            textView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            textView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
        ])

        context.coordinator.scrollView = scrollView
        context.coordinator.textView = textView

        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }

        if context.coordinator.lastRenderKey != renderKey {
            context.coordinator.lastRenderKey = renderKey
            applyText(to: textView)
            scrollView.setNeedsLayout()
            scrollView.layoutIfNeeded()
        }

        if resetTrigger != context.coordinator.lastResetTrigger {
            context.coordinator.lastResetTrigger = resetTrigger
            context.coordinator.scrollToTop()
        }

        if isScrolling {
            context.coordinator.startScrolling(speed: scrollSpeed)
        } else {
            context.coordinator.stopScrolling()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: AutoScroller {
        weak var textView: UITextView?
        var lastRenderKey = ""
    }

    static func dismantleUIView(_ scrollView: UIScrollView, coordinator: Coordinator) {
        coordinator.stopScrolling()
    }
}

#Preview {
    let ctx = PersistenceController.preview.viewContext
    let song = Song.create(
        name: "Sweet Home Alabama",
        artist: "Lynyrd Skynyrd",
        lyrics: """
        [Intro]
        D C G (x4)

        [Chorus]
        D        C         G
        Sweet Home Alabama
        D               C             G
        Where the skies are so blue
        """,
        in: ctx
    )
    let _ = try? ctx.save()
    LyricsPerformanceView(song: song)
        .environment(\.managedObjectContext, ctx)
}
