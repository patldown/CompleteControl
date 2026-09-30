//
//  AutoScrollingCharts.swift
//  Midi Set List
//
//  Hands-free scrolling for everything a song can show while performing: lyrics text,
//  a sheet-music PDF, or a set of sheet-music images. All three share one AutoScroller,
//  so play / pause, speed and reset behave the same whichever you're reading.
//

import SwiftUI
import UIKit
import PDFKit

// MARK: - Scroll motor

/// A one-off "turn the page" request, e.g. from a page-turner pedal. Each has its own
/// id so pressing the same direction twice turns two pages.
struct PageRequest: Equatable {
    let id = UUID()
    /// +1 down a page, -1 up a page
    let direction: Int
}

/// Drives a UIScrollView downward at a steady speed, in points per second.
///
/// The position is tracked unrounded in `exactY` and advanced by real frame time.
/// UIScrollView snaps contentOffset to whole pixels, so adding a fraction of a point to
/// contentOffset itself each frame loses the fraction: slow speeds never moved, and a
/// range of faster speeds all snapped to the same one-pixel step.
class AutoScroller: NSObject {
    weak var scrollView: UIScrollView?
    /// For views whose scroll view only exists after layout, such as PDFView's
    var findScrollView: (() -> UIScrollView?)?
    var lastResetTrigger = false
    var lastPageRequestID: UUID?

    private var displayLink: CADisplayLink?
    private var currentSpeed: Double = 0

    // Live Follow: the chart this scroll view shows, so a leader can report its position
    // and followers showing the same chart can move to it
    private var liveChartID: UUID?
    private var offsetObservation: NSKeyValueObservation?
    private weak var observedScrollView: UIScrollView?
    private var liveScrollObserver: NSObjectProtocol?
    private var isApplyingRemoteScroll = false
    /// Unrounded scroll position; nil until the first frame reads the real offset
    private var exactY: Double?
    /// What was last applied, to notice when the person drags the chart themselves
    private var lastAppliedY: CGFloat?
    private var lastTimestamp: CFTimeInterval?

    private var target: UIScrollView? {
        if scrollView == nil { scrollView = findScrollView?() }
        return scrollView
    }

    func startScrolling(speed: Double) {
        currentSpeed = speed
        if displayLink == nil {
            displayLink = CADisplayLink(target: self, selector: #selector(scroll(_:)))
            displayLink?.add(to: .main, forMode: .common)
        }
    }

    func stopScrolling() {
        displayLink?.invalidate()
        displayLink = nil
        exactY = nil
        lastAppliedY = nil
        lastTimestamp = nil
    }

    func scrollToTop() {
        guard let scrollView = target else { return }
        scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: -scrollView.adjustedContentInset.top),
                                    animated: true)
    }

    @objc private func scroll(_ link: CADisplayLink) {
        guard let scrollView = target else { return }

        // Real time since the last frame, so ProMotion (120 Hz) runs at the same speed as 60 Hz.
        // Capped so a stall (app in background, heavy layout) doesn't jump the chart.
        let elapsed = lastTimestamp.map { min(link.timestamp - $0, 0.1) } ?? 0
        lastTimestamp = link.timestamp

        // Start from, or pick up after, wherever the chart really is — e.g. after a drag
        let current = scrollView.contentOffset.y
        if exactY == nil || lastAppliedY.map({ abs(current - $0) > 1 }) ?? true
            || scrollView.isDragging || scrollView.isDecelerating {
            exactY = Double(current)
        }
        guard !scrollView.isDragging, !scrollView.isDecelerating, var y = exactY else { return }

        y += currentSpeed * elapsed

        let minOffset = Double(-scrollView.adjustedContentInset.top)
        let maxOffset = max(minOffset, Double(scrollView.contentSize.height - scrollView.bounds.height
                                              + scrollView.adjustedContentInset.bottom))
        let reachedEnd = y >= maxOffset
        y = min(max(y, minOffset), maxOffset)
        exactY = y

        scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: CGFloat(y)), animated: false)
        lastAppliedY = scrollView.contentOffset.y
        if reachedEnd { stopScrolling() }
    }

    /// Scrolls most of a screen up or down, keeping a few lines of overlap for your place
    func page(_ direction: Int) {
        guard let scrollView = target else { return }
        let minOffset = -scrollView.adjustedContentInset.top
        let maxOffset = max(minOffset, scrollView.contentSize.height - scrollView.bounds.height
                                       + scrollView.adjustedContentInset.bottom)
        let step = scrollView.bounds.height * 0.85 * CGFloat(direction)
        let y = min(max(scrollView.contentOffset.y + step, minOffset), maxOffset)
        scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: y), animated: true)
    }

    /// Applies the SwiftUI state on each update
    func sync(isScrolling: Bool, speed: Double, resetTrigger: Bool, pageRequest: PageRequest? = nil) {
        if resetTrigger != lastResetTrigger {
            lastResetTrigger = resetTrigger
            scrollToTop()
        }
        if let pageRequest, pageRequest.id != lastPageRequestID {
            lastPageRequestID = pageRequest.id
            page(pageRequest.direction)
        }
        if isScrolling {
            startScrolling(speed: speed)
        } else {
            stopScrolling()
        }
    }

    // MARK: Live Follow scrolling

    /// Call on each update with the chart shown; safe to repeat
    func attachLiveScroll(chartID: UUID?) {
        liveChartID = chartID
        guard let scrollView = target else { return }
        if observedScrollView !== scrollView {
            observedScrollView = scrollView
            offsetObservation = scrollView.observe(\.contentOffset, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.reportLiveScroll(view) }
            }
        }
        if liveScrollObserver == nil {
            liveScrollObserver = NotificationCenter.default.addObserver(
                forName: LiveFollowSession.scrollNotification, object: nil, queue: .main
            ) { [weak self] note in
                let chartID = note.userInfo?["chartID"] as? UUID
                let fraction = note.userInfo?["fraction"] as? Double
                MainActor.assumeIsolated { self?.applyLiveScroll(chartID: chartID, fraction: fraction) }
            }
        }
    }

    private func scrollRange(_ scrollView: UIScrollView) -> ClosedRange<CGFloat> {
        let minOffset = -scrollView.adjustedContentInset.top
        let maxOffset = max(minOffset, scrollView.contentSize.height - scrollView.bounds.height
                                       + scrollView.adjustedContentInset.bottom)
        return minOffset...maxOffset
    }

    private func reportLiveScroll(_ scrollView: UIScrollView) {
        guard let liveChartID, !isApplyingRemoteScroll else { return }
        let range = scrollRange(scrollView)
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return }
        let fraction = Double((scrollView.contentOffset.y - range.lowerBound) / span)
        LiveFollowSession.shared.reportScroll(chartID: liveChartID, fraction: min(max(fraction, 0), 1))
    }

    private func applyLiveScroll(chartID: UUID?, fraction: Double?) {
        guard let chartID, chartID == liveChartID, let fraction, let scrollView = target,
              !scrollView.isDragging else { return }
        let range = scrollRange(scrollView)
        let y = range.lowerBound + (range.upperBound - range.lowerBound) * CGFloat(fraction)
        guard abs(y - scrollView.contentOffset.y) > 2 else { return }
        isApplyingRemoteScroll = true
        scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: y), animated: true)
        isApplyingRemoteScroll = false
    }

    deinit {
        stopScrolling()
        offsetObservation?.invalidate()
        if let liveScrollObserver { NotificationCenter.default.removeObserver(liveScrollObserver) }
    }
}

// MARK: - PDF

struct AutoScrollingPDFView: UIViewRepresentable {
    let url: URL
    @Binding var isScrolling: Bool
    @Binding var scrollSpeed: Double
    @Binding var resetTrigger: Bool
    var pageRequest: PageRequest? = nil
    /// The chart shown, for Live Follow scrolling
    var liveChartID: UUID? = nil

    func makeUIView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.backgroundColor = .black
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.document = PDFDocument(url: url)
        context.coordinator.lastPageRequestID = pageRequest?.id
        context.coordinator.findScrollView = { [weak pdfView] in
            pdfView.flatMap { Self.firstScrollView(in: $0) }
        }
        context.coordinator.lastResetTrigger = resetTrigger
        return pdfView
    }

    func updateUIView(_ pdfView: PDFView, context: Context) {
        if pdfView.document?.documentURL != url {
            pdfView.document = PDFDocument(url: url)
            context.coordinator.scrollView = nil
        }
        context.coordinator.sync(isScrolling: isScrolling, speed: scrollSpeed, resetTrigger: resetTrigger,
                                 pageRequest: pageRequest)
        context.coordinator.attachLiveScroll(chartID: liveChartID)
    }

    func makeCoordinator() -> AutoScroller { AutoScroller() }

    static func dismantleUIView(_ pdfView: PDFView, coordinator: AutoScroller) {
        coordinator.stopScrolling()
    }

    private static func firstScrollView(in view: UIView) -> UIScrollView? {
        for sub in view.subviews {
            if let scroll = sub as? UIScrollView { return scroll }
            if let found = firstScrollView(in: sub) { return found }
        }
        return nil
    }
}

// MARK: - Images

/// Sheet-music pages as images, stacked top to bottom at full width. Pinch to zoom.
struct AutoScrollingImagesView: UIViewRepresentable {
    let urls: [URL]
    @Binding var isScrolling: Bool
    @Binding var scrollSpeed: Double
    @Binding var resetTrigger: Bool
    var pageRequest: PageRequest? = nil
    /// The chart shown, for Live Follow scrolling
    var liveChartID: UUID? = nil

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.backgroundColor = .black
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 4
        scrollView.delegate = context.coordinator

        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
        ])

        context.coordinator.scrollView = scrollView
        context.coordinator.stack = stack
        context.coordinator.lastResetTrigger = resetTrigger
        context.coordinator.lastPageRequestID = pageRequest?.id
        context.coordinator.load(urls)
        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        if context.coordinator.urls != urls {
            context.coordinator.load(urls)
        }
        context.coordinator.sync(isScrolling: isScrolling, speed: scrollSpeed, resetTrigger: resetTrigger,
                                 pageRequest: pageRequest)
        context.coordinator.attachLiveScroll(chartID: liveChartID)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    static func dismantleUIView(_ scrollView: UIScrollView, coordinator: Coordinator) {
        coordinator.stopScrolling()
    }

    final class Coordinator: AutoScroller, UIScrollViewDelegate {
        weak var stack: UIStackView?
        private(set) var urls: [URL] = []

        func load(_ urls: [URL]) {
            self.urls = urls
            guard let stack else { return }
            stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
            for url in urls {
                guard let image = UIImage(contentsOfFile: url.path), image.size.width > 0 else { continue }
                let imageView = UIImageView(image: image)
                imageView.contentMode = .scaleAspectFit
                imageView.backgroundColor = .white
                imageView.translatesAutoresizingMaskIntoConstraints = false
                imageView.heightAnchor.constraint(equalTo: imageView.widthAnchor,
                                                  multiplier: image.size.height / image.size.width).isActive = true
                stack.addArrangedSubview(imageView)
            }
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { stack }
    }
}

// MARK: - Shared content

/// Shows one chart of a song — its own, or a part — as lyrics or sheet music, with the
/// right auto-scroller. Speed is this person's last speed on this chart, kept separately
/// for lyrics and sheet music.
struct ChartContentView: View {
    @ObservedObject var song: Song
    /// The chart to show; nil shows the song's own chart
    var chart: (any ChartSource)? = nil
    let mode: PerformChartMode
    @Binding var isScrolling: Bool
    @Binding var resetTrigger: Bool
    var fontSize: CGFloat = 24
    var insets = UIEdgeInsets(top: 24, left: 32, bottom: 500, right: 32)
    var pageRequest: PageRequest? = nil

    @ObservedObject private var prefs = UserPreferences.shared
    @ObservedObject private var band = BandSettings.shared

    private var source: any ChartSource { chart ?? song }

    private var speed: Binding<Double> {
        Binding(get: { prefs.scrollSpeed(for: mode, song: source) },
                set: { prefs.setScrollSpeed($0, for: mode, song: source) })
    }

    var body: some View {
        switch mode {
        case .lyrics:
            // Capo shapes or concert pitch, per this device (Settings › Band)
            let chords = band.chordRendering(for: song)
            AutoScrollingTextView(
                text: source.lyrics ?? "",
                isScrolling: $isScrolling,
                scrollSpeed: speed,
                resetTrigger: $resetTrigger,
                fontSize: fontSize,
                insets: insets,
                transpose: chords.transpose,
                chordsPreferFlats: chords.flats,
                pageRequest: pageRequest,
                liveChartID: source.id
            )
        case .sheetMusic:
            if let pdfURL = source.pdfFileURL {
                AutoScrollingPDFView(url: pdfURL, isScrolling: $isScrolling,
                                     scrollSpeed: speed, resetTrigger: $resetTrigger, pageRequest: pageRequest,
                                     liveChartID: source.id)
            } else {
                AutoScrollingImagesView(urls: source.chartImageURLs, isScrolling: $isScrolling,
                                        scrollSpeed: speed, resetTrigger: $resetTrigger, pageRequest: pageRequest,
                                        liveChartID: source.id)
            }
        }
    }
}

/// Lyrics / Sheet Music switch, shown when a chart has both. Remembers the choice for this
/// person on this chart — or, while the Settings override is on, just for this visit.
struct ChartModeMenu: View {
    @ObservedObject private var prefs = UserPreferences.shared
    let chart: any ChartSource
    let current: PerformChartMode
    var onChange: () -> Void = {}

    var body: some View {
        Menu {
            Picker("Show", selection: Binding(
                get: { current },
                set: { prefs.setChartMode($0, for: chart); onChange() }
            )) {
                ForEach(PerformChartMode.allCases) { mode in
                    Label(mode.title, systemImage: mode.systemImage).tag(mode)
                }
            }
            if prefs.isOverriding(chart) {
                Text("Settings is set to always show \(prefs.chartModeOverride?.title ?? ""). A change here lasts for this visit only.")
            }
        } label: {
            Label("Show \(current.title)", systemImage: current.systemImage)
        }
        .menuIndicator(.hidden)
        .accessibilityLabel("Lyrics or Sheet Music")
        .accessibilityValue(current.title)
    }
}

/// Switches between the charts this device sees for a song (the song's own and its
/// parts). Shown only when there's more than one. Remembers the pick per song.
struct ChartPartMenu: View {
    @ObservedObject var song: Song
    let current: any ChartSource
    var onChange: () -> Void = {}
    @ObservedObject private var band = BandSettings.shared

    var body: some View {
        Menu {
            Picker("Part", selection: Binding(
                get: { current.id },
                set: { id in
                    if let chart = song.chartSource(id: id) {
                        band.selectChart(chart, for: song)
                        onChange()
                    }
                }
            )) {
                ForEach(band.visibleCharts(for: song), id: \.id) { chart in
                    Text(chart.seenBy.isEmpty ? chart.chartName : "\(chart.chartName) · \(chart.seenBy.map(\.emoji).joined())")
                        .tag(chart.id)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "person.2.crop.square.stack")
                    .font(.caption.weight(.bold))
                Text(current.chartName)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.white.opacity(0.18), in: Capsule())
        }
        .menuIndicator(.hidden)
        .accessibilityLabel("Part")
        .accessibilityValue(current.chartName)
    }
}

/// Edits whichever chart is showing: a part, or the song's own chart
struct ChartEditorSheet: View {
    @ObservedObject var song: Song
    let chartID: UUID?

    var body: some View {
        if let chartID, let part = song.parts.first(where: { $0.id == chartID }) {
            EditLyricsView(source: part)
        } else {
            EditLyricsView(song: song)
        }
    }
}
