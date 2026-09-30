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

/// Drives a UIScrollView downward at a steady speed (points per second at 60 fps).
class AutoScroller: NSObject {
    weak var scrollView: UIScrollView?
    /// For views whose scroll view only exists after layout, such as PDFView's
    var findScrollView: (() -> UIScrollView?)?
    var lastResetTrigger = false
    var lastPageRequestID: UUID?

    private var displayLink: CADisplayLink?
    private var currentSpeed: Double = 0

    private var target: UIScrollView? {
        if scrollView == nil { scrollView = findScrollView?() }
        return scrollView
    }

    func startScrolling(speed: Double) {
        currentSpeed = speed
        if displayLink == nil {
            displayLink = CADisplayLink(target: self, selector: #selector(scroll))
            displayLink?.add(to: .main, forMode: .common)
        }
    }

    func stopScrolling() {
        displayLink?.invalidate()
        displayLink = nil
    }

    func scrollToTop() {
        guard let scrollView = target else { return }
        scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: -scrollView.adjustedContentInset.top),
                                    animated: true)
    }

    @objc private func scroll() {
        guard let scrollView = target else { return }

        var offset = scrollView.contentOffset
        offset.y += CGFloat(currentSpeed / 60.0)

        let minOffset = -scrollView.adjustedContentInset.top
        let maxOffset = max(minOffset, scrollView.contentSize.height - scrollView.bounds.height
                                       + scrollView.adjustedContentInset.bottom)
        if offset.y >= maxOffset {
            offset.y = maxOffset
            stopScrolling()
        }
        scrollView.setContentOffset(offset, animated: false)
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

    deinit {
        stopScrolling()
    }
}

// MARK: - PDF

struct AutoScrollingPDFView: UIViewRepresentable {
    let url: URL
    @Binding var isScrolling: Bool
    @Binding var scrollSpeed: Double
    @Binding var resetTrigger: Bool
    var pageRequest: PageRequest? = nil

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

/// Shows a song's lyrics or sheet music with the right auto-scroller. Speed is this
/// person's last speed on this song, kept separately for lyrics and sheet music.
struct ChartContentView: View {
    @ObservedObject var song: Song
    let mode: PerformChartMode
    @Binding var isScrolling: Bool
    @Binding var resetTrigger: Bool
    var fontSize: CGFloat = 24
    var insets = UIEdgeInsets(top: 24, left: 32, bottom: 500, right: 32)
    var pageRequest: PageRequest? = nil

    @ObservedObject private var prefs = UserPreferences.shared

    private var speed: Binding<Double> {
        Binding(get: { prefs.scrollSpeed(for: mode, song: song) },
                set: { prefs.setScrollSpeed($0, for: mode, song: song) })
    }

    var body: some View {
        switch mode {
        case .lyrics:
            AutoScrollingTextView(
                text: song.lyrics ?? "",
                isScrolling: $isScrolling,
                scrollSpeed: speed,
                resetTrigger: $resetTrigger,
                fontSize: fontSize,
                insets: insets,
                transpose: song.transpose,
                chordsPreferFlats: song.chordsPreferFlats,
                pageRequest: pageRequest
            )
        case .sheetMusic:
            if let pdfURL = song.pdfFileURL {
                AutoScrollingPDFView(url: pdfURL, isScrolling: $isScrolling,
                                     scrollSpeed: speed, resetTrigger: $resetTrigger, pageRequest: pageRequest)
            } else {
                AutoScrollingImagesView(urls: song.chartImageURLs, isScrolling: $isScrolling,
                                        scrollSpeed: speed, resetTrigger: $resetTrigger, pageRequest: pageRequest)
            }
        }
    }
}

/// Lyrics / Sheet Music switch, shown when a song has both. Remembers the choice for this
/// person on this song — or, while the Settings override is on, just for this visit.
struct ChartModeMenu: View {
    @ObservedObject private var prefs = UserPreferences.shared
    @ObservedObject var song: Song
    let current: PerformChartMode
    var onChange: () -> Void = {}

    var body: some View {
        Menu {
            Picker("Show", selection: Binding(
                get: { current },
                set: { prefs.setChartMode($0, for: song); onChange() }
            )) {
                ForEach(PerformChartMode.allCases) { mode in
                    Label(mode.title, systemImage: mode.systemImage).tag(mode)
                }
            }
            if prefs.isOverriding(song) {
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
