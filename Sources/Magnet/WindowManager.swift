import AppKit
import MagnetCore

/// Orchestrates window actions: find the focused window + its screen, compute
/// the target frame with `MagnetCore`, and apply it.
@MainActor
enum WindowManager {

    static func perform(_ action: AppAction) {
        switch action {
        case .layout(let layout):        apply(layout)
        case .moveToDisplay(let direction): moveToDisplay(direction)
        }
    }

    // MARK: - Snap to a layout on the current screen

    static func apply(_ layout: WindowLayout) {
        guard let context = focusedWindowContext() else { return }
        let usableAX = flipped(context.screen.visibleFrame, context.primaryHeight)
        let target = LayoutCalculator.frame(for: layout, in: usableAX)
        WindowEngine.setFrame(target, for: context.window)
    }

    // MARK: - Move to an adjacent display

    static func moveToDisplay(_ direction: DisplayOrdering.Direction) {
        guard let context = focusedWindowContext() else { return }

        let screensAX = NSScreen.screens.map { flipped($0.visibleFrame, context.primaryHeight) }
        let currentAX = flipped(context.screen.visibleFrame, context.primaryHeight)

        guard let targetAX = DisplayOrdering.target(from: currentAX, in: screensAX,
                                                    direction: direction) else {
            NSSound.beep() // only one display
            return
        }

        let mapped = DisplayMapper.mappedFrame(of: context.axFrame, from: currentAX, to: targetAX)
        WindowEngine.setFrame(mapped, for: context.window)
    }

    // MARK: - Shared lookup

    private struct Context {
        let window: AXUIElement
        let axFrame: CGRect
        let screen: NSScreen
        let primaryHeight: CGFloat
    }

    private static func focusedWindowContext() -> Context? {
        guard let window = WindowEngine.focusedWindow(),
              let axFrame = WindowEngine.frame(of: window) else {
            NSSound.beep() // no focusable window (e.g. desktop)
            return nil
        }
        // AppKit global origin is the bottom-left of the primary screen.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let windowAppKit = Geometry.flipY(axFrame, primaryHeight: primaryHeight)
        let screen = ScreenProvider.screen(containing: windowAppKit)
        return Context(window: window, axFrame: axFrame, screen: screen, primaryHeight: primaryHeight)
    }

    private static func flipped(_ rect: CGRect, _ primaryHeight: CGFloat) -> CGRect {
        Geometry.flipY(rect, primaryHeight: primaryHeight)
    }
}
