//
//  PerformShortcut.swift
//  Midi Set List
//
//  On iPad, a Perform button is always within reach: in the top bar of every tab's
//  main screen, and — on screens drilled into from there, where the Back button takes
//  that spot — as a floating button in the corner. On iPhone, Perform is already the
//  first tab in the bottom bar, so neither is shown.
//

import SwiftUI

/// Tab identifiers, matching the values the TabView uses
enum AppTab {
    static let perform = "perform"
    static let setLists = "setlists"
}

/// Which tab is selected, and whether a tab's main screen is showing, shared app-wide
@Observable
final class AppNavigation {
    var selectedTab = AppTab.setLists
    /// Tab main screens currently on screen. Zero means the user has drilled into a
    /// detail screen, so the top-bar Perform button isn't visible.
    fileprivate(set) var visibleTabRoots = 0

    func showPerform() { selectedTab = AppTab.perform }
}

// MARK: - Button

private struct PerformShortcutLabel: View {
    @Environment(PerformanceSession.self) private var performance

    var body: some View {
        Label(performance.isPlaying ? "Now Playing" : "Perform",
              systemImage: performance.isPlaying ? "waveform" : "play.fill")
            .symbolEffect(.variableColor.iterative, isActive: performance.isPlaying)
    }
}

// MARK: - Top bar (tab main screens)

private struct PerformShortcutToolbar: ViewModifier {
    @Environment(AppNavigation.self) private var navigation: AppNavigation?
    @Environment(\.horizontalSizeClass) private var sizeClass

    func body(content: Content) -> some View {
        content
            .toolbar {
                if sizeClass == .regular, let navigation {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            navigation.showPerform()
                        } label: {
                            PerformShortcutLabel()
                                .labelStyle(.titleAndIcon)
                                .font(.subheadline.weight(.semibold))
                        }
                        .tint(.green)
                        .accessibilityHint("Opens the Perform tab")
                    }
                }
            }
            .onAppear { navigation?.visibleTabRoots += 1 }
            .onDisappear { navigation?.visibleTabRoots -= 1 }
    }
}

extension View {
    /// Adds the iPad Perform button to a tab's main screen. Apply to the root view inside
    /// each tab's NavigationStack (not the Perform tab itself).
    func performShortcut() -> some View {
        modifier(PerformShortcutToolbar())
    }

    /// Floats a Perform button in the corner on iPad while a detail screen is showing.
    /// Apply once, to the TabView.
    func floatingPerformShortcut(_ navigation: AppNavigation) -> some View {
        modifier(FloatingPerformShortcut(navigation: navigation))
    }
}

// MARK: - Floating (detail screens)

private struct FloatingPerformShortcut: ViewModifier {
    let navigation: AppNavigation
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(PerformanceSession.self) private var performance

    private var isShowing: Bool {
        sizeClass == .regular
            && navigation.selectedTab != AppTab.perform
            && navigation.visibleTabRoots <= 0
    }

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottomTrailing) {
            if isShowing {
                Button {
                    navigation.showPerform()
                } label: {
                    PerformShortcutLabel()
                        .labelStyle(.iconOnly)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 60, height: 60)
                        .background(Color.green.gradient, in: Circle())
                        .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
                }
                .buttonStyle(.plain)
                .padding(24)
                .accessibilityLabel(performance.isPlaying ? "Now Playing" : "Perform")
                .accessibilityHint("Opens the Perform tab")
                .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.3), value: isShowing)
    }
}
