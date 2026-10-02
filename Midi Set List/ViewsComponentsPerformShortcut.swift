//
//  PerformShortcut.swift
//  Midi Set List
//
//  On iPad, a Perform button appears in the navigation bar of every screen:
//    - Tab main screens: icon + title at the leading edge
//    - Detail/pushed screens: icon only, immediately right of the back button
//  On iPhone, Perform is always the first tab in the tab bar, so no extra button is needed.
//

import SwiftUI

/// Tab identifiers, matching the values the TabView uses
enum AppTab {
    static let perform = "perform"
    static let setLists = "setlists"
}

/// Which tab is selected, shared app-wide
@Observable
final class AppNavigation {
    var selectedTab = AppTab.setLists

    func showPerform() { selectedTab = AppTab.perform }
}

// MARK: - Button label

private struct PerformShortcutLabel: View {
    @Environment(PerformanceSession.self) private var performance

    var body: some View {
        Label(performance.isPlaying ? "Now Playing" : "Perform",
              systemImage: performance.isPlaying ? "waveform" : "play.fill")
            .symbolEffect(.variableColor.iterative, isActive: performance.isPlaying)
    }
}

// MARK: - Tab main screens (icon + title)

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
                    .sharedBackgroundVisibility(.hidden)
                }
            }
    }
}

// MARK: - Detail / pushed screens (icon only, right of back button)

private struct PerformShortcutDetailToolbar: ViewModifier {
    @Environment(AppNavigation.self) private var navigation: AppNavigation?
    @Environment(\.horizontalSizeClass) private var sizeClass

    func body(content: Content) -> some View {
        content
            .toolbar {
                if sizeClass == .regular, let navigation,
                   navigation.selectedTab != AppTab.perform {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            navigation.showPerform()
                        } label: {
                            PerformShortcutLabel()
                                .labelStyle(.iconOnly)
                        }
                        .tint(.green)
                        .accessibilityHint("Opens the Perform tab")
                    }
                    .sharedBackgroundVisibility(.hidden)
                }
            }
    }
}

// MARK: - Public API

extension View {
    /// Adds the iPad Perform button (icon + title) to a tab's main screen.
    /// Apply to the root view inside each tab's NavigationStack.
    func performShortcut() -> some View {
        modifier(PerformShortcutToolbar())
    }

    /// Adds the iPad Perform button (icon only) to a pushed detail screen,
    /// positioned immediately to the right of the back button.
    func performShortcutDetail() -> some View {
        modifier(PerformShortcutDetailToolbar())
    }
}
