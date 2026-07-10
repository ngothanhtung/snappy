import AppKit

@MainActor
final class RegionCaptureController {
    static let shared = RegionCaptureController()
    private init() {}

    private var overlayWindow: RegionOverlayWindow?

    func start() {
        guard overlayWindow == nil else { return }
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
            return   // system TCC sheet handles feedback; don't show our own alert too
        }
        showOverlay()
    }

    private func presentPermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "Screen Recording permission needed"
        alert.informativeText = """
            Snappy needs Screen Recording access to capture your screen.

            Open System Settings \u{25B8} Privacy & Security \u{25B8} Screen Recording \
            and enable Snappy, then try again.
            """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(
                URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
            )
        }
    }

    private func showOverlay() {
        let win = RegionOverlayWindow()
        overlayWindow = win
        win.onRegionSelected = { [weak self] rect in self?.captureRegion(rect) }
        win.onCancelled = { [weak self] in
            self?.overlayWindow?.orderOut(nil)
            self?.overlayWindow = nil
        }
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }

    // rect is in AppKit global coordinates (y-up, origin = bottom-left of primary screen)
    private func captureRegion(_ rectInAppKit: CGRect) {
        overlayWindow?.orderOut(nil)
        overlayWindow = nil
        // Wait one frame for the overlay to vanish before capturing
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let img = self?.captureScreen(rect: rectInAppKit) else { return }
            AnnotationEditorController.shared.open(image: img)
        }
    }

    private func captureScreen(rect rectInAppKit: CGRect) -> NSImage? {
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        // Convert AppKit (y-up) → Quartz global (y-down, origin = top-left of primary)
        let quartzRect = CGRect(
            x: rectInAppKit.minX,
            y: primaryH - rectInAppKit.maxY,
            width: rectInAppKit.width,
            height: rectInAppKit.height
        )

        // Pick the display with the largest overlap
        var bestID = CGMainDisplayID()
        var bestArea: CGFloat = 0
        for screen in NSScreen.screens {
            guard let id = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? CGDirectDisplayID else { continue }
            let area = CGDisplayBounds(id).intersection(quartzRect).area
            if area > bestArea { bestArea = area; bestID = id }
        }

        // Convert Quartz global → display-local (CGDisplayCreateImage expects local coords)
        let displayBounds = CGDisplayBounds(bestID)
        let localRect = CGRect(
            x: quartzRect.minX - displayBounds.minX,
            y: quartzRect.minY - displayBounds.minY,
            width: quartzRect.width,
            height: quartzRect.height
        )

        guard let cgImage = CGDisplayCreateImage(bestID, rect: localRect) else { return nil }
        return NSImage(cgImage: cgImage, size: rectInAppKit.size)
    }
}

private extension CGRect {
    var area: CGFloat { max(0, width) * max(0, height) }
}
