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
    @ObservedObject private var band = BandSettings.shared
    @State private var isAutoScrolling = false
    @State private var showControls = true
    @State private var showingEditLyrics = false
    @State private var resetTrigger = false
    @State private var pageRequest: PageRequest?

    /// The chart for this device's band roles, or the one picked in the switcher
    private var chart: any ChartSource { band.currentChart(for: song) ?? song }

    /// Lyrics or sheet music — this person's last choice on this chart when it has both
    private var mode: PerformChartMode { prefs.chartMode(for: chart) ?? .lyrics }
    private var hasChart: Bool { prefs.chartMode(for: chart) != nil }

    private var scrollSpeed: Binding<Double> {
        Binding(get: { prefs.scrollSpeed(for: mode, song: chart) },
                set: { prefs.setScrollSpeed($0, for: mode, song: chart) })
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
                if !hasChart {
                    Text("No lyrics or sheet music yet.\n\nTap Edit to add lyrics, a PDF or images.")
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                        .padding()
                } else {
                    ChartContentView(song: song, chart: chart, mode: mode,
                                     isScrolling: $isAutoScrolling, resetTrigger: $resetTrigger,
                                     pageRequest: pageRequest)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation {
                    showControls.toggle()
                }
            }

            if showControls && hasChart {
                bottomControls
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .background(Color.black.ignoresSafeArea())
        // Page-turner pedals: page up / down and start / pause work here too
        .background(PedalKeyCatcher(onKey: handlePedal).frame(width: 0, height: 0))
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .sheet(isPresented: $showingEditLyrics) {
            ChartEditorSheet(song: song, chartID: chart.id)
        }
    }

    private func handlePedal(_ key: PedalKey) -> Bool {
        switch PedalSettings.shared.action(for: key) {
        case .pageDown?: pageRequest = PageRequest(direction: 1)
        case .pageUp?: pageRequest = PageRequest(direction: -1)
        case .toggleAutoScroll?: isAutoScrolling.toggle()
        default: return false
        }
        return true
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

            if band.visibleCharts(for: song).count > 1 {
                ChartPartMenu(song: song, current: chart) { isAutoScrolling = false }
                    .foregroundStyle(.white)
            }

            if mode == .lyrics && hasChart {
                LyricsDisplayMenu()
                    .font(.title2)
                    .labelStyle(.iconOnly)
                    .tint(.white)
                    .foregroundStyle(.white)
                    .padding(.trailing, 8)
            }

            if chart.hasLyricsText && chart.hasSheetMusic {
                Picker("Show", selection: Binding(
                    get: { mode },
                    set: { isAutoScrolling = false; prefs.setChartMode($0, for: chart) }
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
    /// The largest size the lyrics start at. Smaller when needed so the longest line fits
    /// the width without wrapping, then scaled by this person's size preference.
    var fontSize: CGFloat = 24
    var insets = UIEdgeInsets(top: 100, left: 32, bottom: 500, right: 32)
    /// Semitones to shift recognised chords by
    var transpose: Int = 0
    /// Chord spelling from the song's key; nil lets each chord decide
    var chordsPreferFlats: Bool? = nil
    /// Turn-the-page requests, e.g. from a page-turner pedal
    var pageRequest: PageRequest? = nil
    /// The chart shown, for Live Follow scrolling
    var liveChartID: UUID? = nil
    /// Blank lines, size and hidden chords come from this person's preferences
    @ObservedObject private var prefs = UserPreferences.shared

    /// Blank lines first, so the opening lyrics start lower and auto-scroll eases into them
    private var displayText: String {
        String(repeating: "\n", count: min(max(prefs.lyricsLeadInLines, 0), 10)) + text
    }

    /// Recognised chords are tinted and bold, so it's clear which ones will transpose
    static let chordColor = UIColor.systemYellow
    /// Fitting a very long line never shrinks the lyrics below this; past it they wrap
    static let minimumFittedFontSize: CGFloat = 11

    private var config: TextConfig {
        TextConfig(text: displayText, maxFontSize: fontSize, scale: CGFloat(prefs.lyricsTextScale),
                   insets: insets, transpose: transpose, flats: chordsPreferFlats,
                   hideChords: prefs.lyricsHideChords)
    }

    /// Everything the rendered text depends on except the view's width
    struct TextConfig: Equatable {
        var text: String
        var maxFontSize: CGFloat
        var scale: CGFloat
        var insets: UIEdgeInsets
        var transpose: Int
        var flats: Bool?
        var hideChords: Bool
    }

    /// Width of one character of the (monospaced) lyrics font per point of font size
    private static let characterAdvance: CGFloat = {
        let probe = UIFont.monospacedSystemFont(ofSize: 100, weight: .bold)
        return ("0" as NSString).size(withAttributes: [.font: probe]).width / 100
    }()

    /// The largest size up to `maxSize` at which the longest line fits in `width`
    static func fittedFontSize(for text: String, maxSize: CGFloat, width: CGFloat) -> CGFloat {
        guard width > 0 else { return maxSize }
        let longest = text.split(separator: "\n").map { line in
            line.reversed().drop(while: \.isWhitespace).count
        }.max() ?? 0
        guard longest > 0 else { return maxSize }
        // A little slack so rounding never pushes the last character onto a new line
        let fits = (width * 0.98 / (CGFloat(longest) * characterAdvance) * 2).rounded(.down) / 2
        return min(maxSize, max(minimumFittedFontSize, fits))
    }

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = WidthReportingScrollView()
        scrollView.backgroundColor = .black
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false

        let textView = UITextView()
        textView.backgroundColor = .clear
        textView.isEditable = false
        textView.isSelectable = false
        textView.isScrollEnabled = false
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
        context.coordinator.lastPageRequestID = pageRequest?.id
        context.coordinator.update(config)
        // Rotation, Full View and window resizing change the width: fit the lyrics again.
        // Next turn of the run loop, so the text isn't replaced in the middle of layout.
        scrollView.onWidthChange = { [weak coordinator = context.coordinator] in
            DispatchQueue.main.async { coordinator?.render() }
        }

        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        context.coordinator.update(config)

        if resetTrigger != context.coordinator.lastResetTrigger {
            context.coordinator.lastResetTrigger = resetTrigger
            context.coordinator.scrollToTop()
        }

        if let pageRequest, pageRequest.id != context.coordinator.lastPageRequestID {
            context.coordinator.lastPageRequestID = pageRequest.id
            context.coordinator.page(pageRequest.direction)
        }

        if isScrolling {
            context.coordinator.startScrolling(speed: scrollSpeed)
        } else {
            context.coordinator.stopScrolling()
        }
        context.coordinator.attachLiveScroll(chartID: liveChartID)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: AutoScroller {
        weak var textView: UITextView?
        private var config: TextConfig?
        /// What's on screen now, to skip redrawing identical text
        private var rendered: (config: TextConfig, width: CGFloat)?

        func update(_ config: TextConfig) {
            guard config != self.config else { return }
            self.config = config
            render()
        }

        /// Lays out the lyrics at the size that fits the current width
        func render() {
            guard let config, let textView, let scrollView else { return }
            let width = scrollView.bounds.width
            if let rendered, rendered.config == config, abs(rendered.width - width) < 0.5 { return }
            rendered = (config, width)

            let result = ChordEngine.render(config.text, transpose: config.transpose, flats: config.flats,
                                            hideChords: config.hideChords)
            let textWidth = width - config.insets.left - config.insets.right
                - textView.textContainer.lineFragmentPadding * 2
            let size = AutoScrollingTextView.fittedFontSize(for: result.text, maxSize: config.maxFontSize,
                                                            width: textWidth) * config.scale

            let attributed = NSMutableAttributedString(string: result.text, attributes: [
                .font: UIFont.monospacedSystemFont(ofSize: size, weight: .regular),
                .foregroundColor: UIColor.white,
            ])
            let chordFont = UIFont.monospacedSystemFont(ofSize: size, weight: .bold)
            for range in result.chordRanges {
                attributed.addAttributes([.foregroundColor: AutoScrollingTextView.chordColor, .font: chordFont],
                                         range: range)
            }
            textView.attributedText = attributed
            textView.textContainerInset = config.insets
            scrollView.setNeedsLayout()
            scrollView.layoutIfNeeded()
        }
    }

    static func dismantleUIView(_ scrollView: UIScrollView, coordinator: Coordinator) {
        coordinator.stopScrolling()
    }
}

/// Tells its owner when its width changes, e.g. on rotation
final class WidthReportingScrollView: UIScrollView {
    var onWidthChange: (() -> Void)?
    private var reportedWidth: CGFloat = 0

    override func layoutSubviews() {
        super.layoutSubviews()
        guard abs(bounds.width - reportedWidth) > 0.5 else { return }
        reportedWidth = bounds.width
        onWidthChange?()
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
