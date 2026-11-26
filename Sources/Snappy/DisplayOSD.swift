import AppKit
import SnappyCore

/// Small brightness/volume overlay (icon + 16-segment bar) shown near the
/// bottom of the display a hotkey acted on; fades out after a moment.
@MainActor
final class DisplayOSD {
    static let shared = DisplayOSD()

    private var panel: NSPanel?
    private let icon = NSImageView()
    private let bar = SegmentBar()
    private var hideWork: DispatchWorkItem?

    private static let size = NSSize(width: 220, height: 64)

    func show(symbol: String, level: Double, on displayID: CGDirectDisplayID) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 22, weight: .medium))
        bar.segments = DisplayLevel.segments(level)

        let screen = NSScreen.screens.first { $0.displayID == displayID } ?? NSScreen.main
        if let f = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: f.midX - Self.size.width / 2, y: f.minY + 120))
        }
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.35
                self?.panel?.animator().alphaValue = 0
            }, completionHandler: {
                MainActor.assumeIsolated { self?.panel?.orderOut(nil) }
            })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3, execute: work)
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.ignoresMouseEvents = true
        p.hasShadow = true
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

        let fx = NSVisualEffectView(frame: NSRect(origin: .zero, size: Self.size))
        fx.material = .hudWindow
        fx.blendingMode = .behindWindow
        fx.state = .active
        fx.wantsLayer = true
        fx.layer?.cornerRadius = 14
        fx.layer?.masksToBounds = true

        icon.frame = NSRect(x: 14, y: 16, width: 32, height: 32)
        icon.contentTintColor = .labelColor
        bar.frame = NSRect(x: 56, y: 26, width: Self.size.width - 56 - 18, height: 12)
        fx.addSubview(icon)
        fx.addSubview(bar)
        p.contentView = fx
        return p
    }
}

/// 16 rounded segments, the first `segments` lit.
private final class SegmentBar: NSView {
    var segments = 0 { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let n = DisplayLevel.steps
        let gap: CGFloat = 2
        let w = (bounds.width - gap * CGFloat(n - 1)) / CGFloat(n)
        for i in 0..<n {
            let r = NSRect(x: CGFloat(i) * (w + gap), y: 0, width: w, height: bounds.height)
            (i < segments ? NSColor.labelColor : NSColor.labelColor.withAlphaComponent(0.18)).setFill()
            NSBezierPath(roundedRect: r, xRadius: 1.5, yRadius: 1.5).fill()
        }
    }
}
