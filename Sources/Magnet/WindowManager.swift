import AppKit
import MagnetCore

/// Orchestrates a layout action: find the focused window and its screen,
/// compute the target frame with `MagnetCore`, and apply it.
@MainActor
enum WindowManager {

    static func apply(_ layout: WindowLayout) {
        guard let window = WindowEngine.focusedWindow(),
              let axFrame = WindowEngine.frame(of: window) else {
            NSSound.beep() // no focusable window (e.g. desktop) — signal and bail
            return
        }

        // AppKit global origin is the bottom-left of the primary screen.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0

        // Locate the screen the window currently lives on (work in AppKit coords).
        let windowAppKit = Geometry.flipY(axFrame, primaryHeight: primaryHeight)
        let screen = ScreenProvider.screen(containing: windowAppKit)

        // Usable area (minus menu bar / dock) → AX coords for the calculator.
        let usableAX = Geometry.flipY(screen.visibleFrame, primaryHeight: primaryHeight)
        let target = LayoutCalculator.frame(for: layout, in: usableAX)

        WindowEngine.setFrame(target, for: window)
    }
}
