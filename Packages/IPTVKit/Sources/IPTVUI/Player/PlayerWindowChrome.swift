import AppKit
import SwiftUI

/// While the player is showing, hides the toolbar, lets the video run under a transparent title bar
/// and fades the window buttons out together with the player controls. The window is restored when
/// the player goes away.
struct PlayerWindowChrome: NSViewRepresentable {
    var controlsVisible: Bool

    func makeNSView(context: Context) -> ChromeView { ChromeView() }

    func updateNSView(_ view: ChromeView, context: Context) {
        view.controlsVisible = controlsVisible
    }

    static func dismantleNSView(_ view: ChromeView, coordinator: ()) {
        view.restore()
    }

    final class ChromeView: NSView {
        private weak var configured: NSWindow?
        private var saved: (transparent: Bool, title: NSWindow.TitleVisibility, fullSize: Bool, toolbar: Bool)?

        var controlsVisible = true {
            didSet { if controlsVisible != oldValue { updateButtons(animated: true) } }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window !== configured { restore() }
            guard let window else { return }
            configured = window
            saved = (window.titlebarAppearsTransparent, window.titleVisibility, window.styleMask.contains(.fullSizeContentView),
                     window.toolbar?.isVisible ?? false)
            window.toolbar?.isVisible = false
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.styleMask.insert(.fullSizeContentView)
            updateButtons(animated: false)
        }

        func restore() {
            guard let window = configured, let saved else { return }
            window.titlebarAppearsTransparent = saved.transparent
            window.titleVisibility = saved.title
            if !saved.fullSize { window.styleMask.remove(.fullSizeContentView) }
            window.toolbar?.isVisible = saved.toolbar
            setButtonsAlpha(1, in: window, animated: false)
            configured = nil
            self.saved = nil
        }

        private func updateButtons(animated: Bool) {
            guard let window = configured else { return }
            setButtonsAlpha(controlsVisible ? 1 : 0, in: window, animated: animated)
        }

        private func setButtonsAlpha(_ alpha: CGFloat, in window: NSWindow, animated: Bool) {
            let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { window.standardWindowButton($0) }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = animated ? 0.2 : 0
                for button in buttons { button.animator().alphaValue = alpha }
            }
        }
    }
}
