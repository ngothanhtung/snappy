import AppKit

final class RegionOverlayWindow: NSWindow {
    var onRegionSelected: ((CGRect) -> Void)?
    var onCancelled: (() -> Void)?

    init() {
        super.init(contentRect: .zero, styleMask: .borderless,
                   backing: .buffered, defer: false)
        // Full implementation in Task 3
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
