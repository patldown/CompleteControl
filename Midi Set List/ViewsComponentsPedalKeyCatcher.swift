//
//  PedalKeyCatcher.swift
//  Midi Set List
//
//  An invisible view that listens for hardware key presses — which is what Bluetooth
//  page-turner pedals send — while it's on screen. Keys it doesn't handle carry on to
//  the rest of the app as normal.
//

import SwiftUI
import UIKit

struct PedalKeyCatcher: UIViewRepresentable {
    /// Return true if the key was used
    var onKey: (PedalKey) -> Bool

    func makeUIView(context: Context) -> KeyCatcherView {
        let view = KeyCatcherView()
        view.onKey = onKey
        return view
    }

    func updateUIView(_ view: KeyCatcherView, context: Context) {
        view.onKey = onKey
        // Take listening back after a sheet or text field had it
        view.claimFocusSoon()
    }

    final class KeyCatcherView: UIView {
        var onKey: ((PedalKey) -> Bool)?
        private var observers: [NSObjectProtocol] = []

        override init(frame: CGRect) {
            super.init(frame: frame)
            // Coming back to the app, or a keyboard closing, can leave nothing listening
            let center = NotificationCenter.default
            for name in [UIScene.didActivateNotification, UIResponder.keyboardDidHideNotification] {
                observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    self?.claimFocusSoon()
                })
            }
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        deinit {
            observers.forEach(NotificationCenter.default.removeObserver)
        }

        override var canBecomeFirstResponder: Bool { true }

        /// Listens for keys only; never takes a touch
        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            claimFocusSoon()
        }

        /// Becomes first responder unless something that needs typing (a text field) has it
        func claimFocusSoon() {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window != nil, !self.isFirstResponder else { return }
                if let current = self.window?.firstResponderView, current is UIKeyInput { return }
                self.becomeFirstResponder()
            }
        }

        override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            var unhandled = Set<UIPress>()
            for press in presses {
                guard let key = press.key,
                      // Leave shortcuts like ⌘-Tab to the system
                      key.modifierFlags.intersection([.command, .control, .alternate]).isEmpty,
                      onKey?(PedalKey(code: key.keyCode.rawValue)) == true
                else {
                    unhandled.insert(press)
                    continue
                }
            }
            if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
        }
    }
}

private extension UIView {
    /// The view currently receiving keyboard input in this view's hierarchy, if any
    var firstResponderView: UIView? {
        if isFirstResponder { return self }
        for sub in subviews {
            if let found = sub.firstResponderView { return found }
        }
        return nil
    }
}
