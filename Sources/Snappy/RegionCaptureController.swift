import AppKit
import ScreenCaptureKit
import OSLog

@MainActor
final class RegionCaptureController {
    enum Destination {
        case preview
        case annotate
    }

    static let shared = RegionCaptureController()
    private let logger = Logger(subsystem: "com.ngothanhtung.snappy", category: "RegionCapture")
    private init() {}

    private var overlayWindow: RegionOverlayWindow?
    private var destination: Destination = .preview

    func start(destination: Destination) {
        guard overlayWindow == nil else { return }
        self.destination = destination
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
            return
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
        let captureDestination = destination
        overlayWindow?.orderOut(nil)
        overlayWindow = nil
        NSLog("Snappy: captureRegion queued for rect %@", NSStringFromRect(rectInAppKit))
        // Wait for the overlay to vanish from the compositor before capturing
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                do {
                    let img = try await self.captureScreen(rect: rectInAppKit)
                    NSLog("Snappy: captureScreen succeeded, image size %@", NSStringFromSize(img.size))
                    let fileURL = try self.saveToDownloads(img)
                    switch captureDestination {
                    case .preview:
                        self.logger.info("Capture saved to \(fileURL.path, privacy: .public); opening Preview")
                        self.openInPreview(fileURL)
                    case .annotate:
                        self.logger.info("Capture saved to \(fileURL.path, privacy: .public); opening Annotate")
                        try AnnotationEditorController.shared.open(fileURL: fileURL)
                    }
                } catch {
                    NSLog("Snappy: captureScreen failed: %@", String(describing: error))
                    self.presentCaptureError(error)
                }
            }
        }
    }

    // Uses ScreenCaptureKit (macOS 14+). Legacy CGDisplayCreateImage/CGWindowListCreateImage
    // return nil on macOS 15+ per the SCREEN_CAPTURE_OBSOLETE macro.
    private func captureScreen(rect rectInAppKit: CGRect) async throws -> NSImage {
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        // Convert AppKit (y-up) → Quartz global (y-down, origin = top-left of primary)
        let quartzRect = CGRect(
            x: rectInAppKit.minX,
            y: primaryH - rectInAppKit.maxY,
            width: rectInAppKit.width,
            height: rectInAppKit.height
        )
        NSLog("Snappy: captureScreen rectInAppKit=%@ primaryH=%.0f quartzRect=%@",
              NSStringFromRect(rectInAppKit), primaryH, NSStringFromRect(quartzRect))

        // Find the display containing the rect's center
        let center = CGPoint(x: quartzRect.midX, y: quartzRect.midY)
        let displays = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true).displays
        guard let display = displays.min(by: {
            let d1 = hypot($0.frame.midX - center.x, $0.frame.midY - center.y)
            let d2 = hypot($1.frame.midX - center.x, $1.frame.midY - center.y)
            return d1 < d2
        }) else { throw NSError(domain: "Snappy", code: 1, userInfo: [NSLocalizedDescriptionKey: "No display"]) }

        // Clamp rect to display bounds (Quartz coords), then convert to display-local.
        // ScreenCaptureKit accepts sourceRect in display-local points, so ask it for
        // the selected region directly instead of capturing and cropping a full display.
        let displayFrame = display.frame
        let clampedQuartz = quartzRect.intersection(displayFrame)
        guard !clampedQuartz.isNull, clampedQuartz.width > 0, clampedQuartz.height > 0 else {
            throw NSError(domain: "Snappy", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "The selected region is outside the display."])
        }
        let displayLocal = CGRect(
            x: clampedQuartz.minX - displayFrame.minX,
            y: clampedQuartz.minY - displayFrame.minY,
            width: clampedQuartz.width,
            height: clampedQuartz.height
        )

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        let pixelScale = NSScreen.screens.first(where: { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID)
                == display.displayID
        })?.backingScaleFactor ?? 1
        config.sourceRect = displayLocal
        config.width = max(1, Int((displayLocal.width * pixelScale).rounded()))
        config.height = max(1, Int((displayLocal.height * pixelScale).rounded()))
        config.scalesToFit = true
        config.preservesAspectRatio = true
        config.showsCursor = false
        config.backgroundColor = .clear

        let captured: CGImage = try await withCheckedThrowingContinuation { cont in
            SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) { image, error in
                if let image { cont.resume(returning: image) }
                else { cont.resume(throwing: error ?? NSError(domain: "Snappy", code: 99)) }
            }
        }
        NSLog("Snappy: captured cgImage %dx%d at %.1fx",
              captured.width, captured.height, pixelScale)

        let logicalSize = clampedQuartz.size
        let rep = NSBitmapImageRep(cgImage: captured)
        rep.size = logicalSize
        let img = NSImage(size: logicalSize)
        img.addRepresentation(rep)
        return img
    }

    private func saveToDownloads(_ image: NSImage) throws -> URL {
        guard let downloads = FileManager.default.urls(
            for: .downloadsDirectory, in: .userDomainMask
        ).first else {
            throw NSError(domain: "Snappy", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Downloads folder is unavailable."])
        }
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "Snappy", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "Could not encode the screenshot as PNG."])
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss.SSS"
        let filename = "Snappy \(formatter.string(from: Date())).png"
        let url = downloads.appendingPathComponent(filename)
        try png.write(to: url, options: .atomic)
        return url
    }

    private func openInPreview(_ fileURL: URL) {
        let previewURL = URL(fileURLWithPath: "/System/Applications/Preview.app")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(
            [fileURL], withApplicationAt: previewURL,
            configuration: configuration
        ) { [weak self] _, error in
            guard let error else { return }
            Task { @MainActor in
                self?.presentCaptureError(error)
            }
        }
    }

    private func presentCaptureError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Capture failed"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
