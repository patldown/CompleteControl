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

    @State private var isAutoScrolling = false
    @State private var scrollSpeed: Double = 20.0
    @State private var showControls = true
    @State private var showingEditLyrics = false
    @State private var resetTrigger = false

    private var showingPDF: Bool { song.pdfFileURL != nil }

    var body: some View {
        // Stacked, not overlaid: the lyrics end where the controls begin, so text
        // never shows through behind the buttons
        VStack(spacing: 0) {
            if showControls {
                topBar
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            Group {
                if let pdfURL = song.pdfFileURL {
                    PDFKitView(url: pdfURL)
                } else {
                    AutoScrollingTextView(
                        text: song.lyrics ?? "No lyrics added yet.\n\nTap 'Edit' to add lyrics or tabs.",
                        isScrolling: $isAutoScrolling,
                        scrollSpeed: $scrollSpeed,
                        resetTrigger: $resetTrigger,
                        insets: UIEdgeInsets(top: 24, left: 32, bottom: 500, right: 32),
                        transpose: song.transpose,
                        chordsPreferFlats: song.chordsPreferFlats
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation {
                    showControls.toggle()
                }
            }

            if showControls && !showingPDF {
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
                    Text("\(Int(scrollSpeed))")
                        .font(.subheadline)
                        .monospacedDigit()
                }
                .foregroundStyle(.white)

                Slider(value: $scrollSpeed, in: 5...100, step: 5)
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
    /// Settings key for the blank lines shown above the lyrics (0–10)
    static let leadInLinesKey = "lyricsLeadInLines"
    static let defaultLeadInLines = 5

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
    @AppStorage(AutoScrollingTextView.leadInLinesKey) private var leadInLines = AutoScrollingTextView.defaultLeadInLines

    /// Blank lines first, so the opening lyrics start lower and auto-scroll eases into them
    private var displayText: String {
        String(repeating: "\n", count: min(max(leadInLines, 0), 10)) + text
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
            scrollView.setContentOffset(.zero, animated: true)
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

    class Coordinator {
        weak var scrollView: UIScrollView?
        weak var textView: UITextView?
        private var displayLink: CADisplayLink?
        private var currentSpeed: Double = 0
        var lastResetTrigger: Bool = false
        var lastRenderKey = ""

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

        @objc private func scroll() {
            guard let scrollView = scrollView else { return }

            let increment = CGFloat(currentSpeed / 60.0)
            var offset = scrollView.contentOffset
            offset.y += increment

            let maxOffset = scrollView.contentSize.height - scrollView.bounds.height
            if offset.y >= maxOffset {
                offset.y = maxOffset
                stopScrolling()
            }

            scrollView.setContentOffset(offset, animated: false)
        }

        deinit {
            stopScrolling()
        }
    }

    static func dismantleUIView(_ scrollView: UIScrollView, coordinator: Coordinator) {
        coordinator.stopScrolling()
    }
}

// MARK: - PDF Viewer

struct PDFKitView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.backgroundColor = .black
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.document = PDFDocument(url: url)
        return pdfView
    }

    func updateUIView(_ pdfView: PDFView, context: Context) {
        if pdfView.document?.documentURL != url {
            pdfView.document = PDFDocument(url: url)
        }
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
