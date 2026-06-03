import AppKit
import ApplicationServices

/// Thin wrapper over the Accessibility API: read and write the frame of the
/// frontmost app's focused window. Kept as small as possible — all geometry
/// lives in `MagnetCore`.
@MainActor
enum WindowEngine {

    /// The focused window of the frontmost application, if any.
    static func focusedWindow() -> AXUIElement? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)

        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            appElement, kAXFocusedWindowAttribute as CFString, &value
        )
        guard result == .success, let value else { return nil }
        // CFTypeRef holding an AXUIElement.
        return (value as! AXUIElement)
    }

    /// Current frame of a window in Accessibility coords (top-left origin).
    static func frame(of window: AXUIElement) -> CGRect? {
        guard let position = copyPoint(window, kAXPositionAttribute),
              let size = copySize(window, kAXSizeAttribute) else { return nil }
        return CGRect(origin: position, size: size)
    }

    /// Moves and resizes a window. Position is set first, then size, then
    /// position again — some apps clamp position to the old size on the first
    /// pass. Failures (e.g. fixed-size windows) are ignored gracefully.
    static func setFrame(_ frame: CGRect, for window: AXUIElement) {
        setPoint(frame.origin, window, kAXPositionAttribute)
        setSize(frame.size, window, kAXSizeAttribute)
        let result = setPoint(frame.origin, window, kAXPositionAttribute)
        if result != .success {
            NSLog("Magnet: failed to set window frame (AXError \(result.rawValue))")
        }
    }

    // MARK: - AXValue helpers

    private static func copyPoint(_ element: AXUIElement, _ attr: String) -> CGPoint? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attr as CFString, &ref) == .success,
              let ref else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(ref as! AXValue, .cgPoint, &point) else { return nil }
        return point
    }

    private static func copySize(_ element: AXUIElement, _ attr: String) -> CGSize? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attr as CFString, &ref) == .success,
              let ref else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(ref as! AXValue, .cgSize, &size) else { return nil }
        return size
    }

    @discardableResult
    private static func setPoint(_ point: CGPoint, _ element: AXUIElement, _ attr: String) -> AXError {
        var p = point
        guard let value = AXValueCreate(.cgPoint, &p) else { return .failure }
        return AXUIElementSetAttributeValue(element, attr as CFString, value)
    }

    @discardableResult
    private static func setSize(_ size: CGSize, _ element: AXUIElement, _ attr: String) -> AXError {
        var s = size
        guard let value = AXValueCreate(.cgSize, &s) else { return .failure }
        return AXUIElementSetAttributeValue(element, attr as CFString, value)
    }
}
