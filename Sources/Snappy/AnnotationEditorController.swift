import AppKit

// MARK: - Color swatch button

final class ColorSwatchButton: NSButton {
    let swatchColor: NSColor

    var isActive: Bool = false {
        didSet { needsDisplay = true }
    }

    init(color: NSColor, label: String) {
        self.swatchColor = color
        super.init(frame: .zero)
        title = ""
        isBordered = false
        setAccessibilityLabel(label)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        if isActive {
            // White ring + inset color circle to indicate active
            NSColor.white.setFill()
            NSBezierPath(ovalIn: bounds).fill()
            swatchColor.setFill()
            NSBezierPath(ovalIn: bounds.insetBy(dx: 3, dy: 3)).fill()
        } else {
            swatchColor.setFill()
            NSBezierPath(ovalIn: bounds).fill()
        }
    }
}

// MARK: - Editor controller

@MainActor
final class AnnotationEditorController {
    static let shared = AnnotationEditorController()
    private init() {}

    private var window: NSWindow?
    private var canvas: AnnotationCanvasView?
    private var swatchButtons: [ColorSwatchButton] = []

    func open(image: NSImage) {
        // Scale image to fit visible screen, never upscale
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let maxSize = screen.visibleFrame.insetBy(dx: 40, dy: 40).size
        let scale = min(maxSize.width / image.size.width,
                        maxSize.height / image.size.height, 1.0)
        let displaySize = CGSize(
            width: (image.size.width * scale).rounded(),
            height: (image.size.height * scale).rounded()
        )

        let canvasView = AnnotationCanvasView(image: image)
        canvasView.frame = CGRect(origin: .zero, size: displaySize)
        self.canvas = canvasView

        let toolbarH: CGFloat = 52
        let winSize = CGSize(width: displaySize.width,
                             height: displaySize.height + toolbarH)
        let win = NSWindow(
            contentRect: CGRect(origin: .zero, size: winSize),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        win.title = "Snappy \u{2014} Annotate"
        win.isReleasedWhenClosed = false

        let content = NSView(frame: CGRect(origin: .zero, size: winSize))
        win.contentView = content

        canvasView.autoresizingMask = [.width, .height]
        content.addSubview(canvasView)

        let toolbar = buildToolbar(width: displaySize.width, canvas: canvasView)
        toolbar.frame = CGRect(x: 0, y: displaySize.height,
                               width: displaySize.width, height: toolbarH)
        toolbar.autoresizingMask = [.width, .minYMargin]
        content.addSubview(toolbar)

        self.window = win
        win.center()
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }

    private func buildToolbar(width: CGFloat, canvas: AnnotationCanvasView) -> NSView {
        let bar = NSView()
        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        // Bottom border line
        let sep = NSBox()
        sep.boxType = .separator
        sep.frame = CGRect(x: 0, y: 0, width: width, height: 1)
        sep.autoresizingMask = .width
        bar.addSubview(sep)

        var x: CGFloat = 12

        // Tool selector (arrow / rect / circle / text)
        let toolImages: [NSImage] = [
            NSImage(systemSymbolName: "arrow.up.right",         accessibilityDescription: "Arrow")!,
            NSImage(systemSymbolName: "rectangle",             accessibilityDescription: "Rectangle")!,
            NSImage(systemSymbolName: "circle",                accessibilityDescription: "Circle")!,
            NSImage(systemSymbolName: "character.cursor.ibeam", accessibilityDescription: "Text")!,
        ]
        let toolCtrl = NSSegmentedControl(
            images: toolImages, trackingMode: .selectOne,
            target: canvas, action: #selector(AnnotationCanvasView.changeTool(_:))
        )
        toolCtrl.selectedSegment = 0
        toolCtrl.frame = CGRect(x: x, y: 11, width: 140, height: 30)
        bar.addSubview(toolCtrl)
        x += 152

        addVSep(to: bar, at: x); x += 16

        // 5 color swatches
        swatchButtons = []
        let swatches: [(NSColor, String)] = [
            (.systemRed, "Red"), (.systemOrange, "Orange"),
            (.systemYellow, "Yellow"), (.systemGreen, "Green"), (.systemBlue, "Blue"),
        ]
        for (color, label) in swatches {
            let btn = ColorSwatchButton(color: color, label: label)
            btn.frame = CGRect(x: x, y: 15, width: 22, height: 22)
            btn.target = self
            btn.action = #selector(swatchClicked(_:))
            bar.addSubview(btn)
            swatchButtons.append(btn)
            x += 28
        }
        swatchButtons.first?.isActive = true
        x += 4

        addVSep(to: bar, at: x); x += 16

        // Line width: label + stepper
        let wLabel = NSTextField(labelWithString: "Width:")
        wLabel.frame = CGRect(x: x, y: 18, width: 44, height: 17)
        bar.addSubview(wLabel)
        x += 48

        let stepper = NSStepper()
        stepper.minValue = 1; stepper.maxValue = 12; stepper.intValue = 3
        stepper.frame = CGRect(x: x, y: 13, width: 19, height: 26)
        stepper.target = canvas
        stepper.action = #selector(AnnotationCanvasView.changeWidth(_:))
        bar.addSubview(stepper)
        x += 28

        addVSep(to: bar, at: x); x += 16

        // Action buttons
        for (title, action) in [
            ("Undo",      #selector(AnnotationCanvasView.undoLast)),
            ("Copy",      #selector(AnnotationCanvasView.copyToClipboard)),
            ("Save\u{2026}", #selector(AnnotationCanvasView.saveImage)),
        ] as [(String, Selector)] {
            let btn = NSButton(title: title, target: canvas, action: action)
            btn.bezelStyle = .rounded
            btn.frame = CGRect(x: x, y: 12, width: 62, height: 28)
            bar.addSubview(btn)
            x += 70
        }

        return bar
    }

    @objc private func swatchClicked(_ sender: NSButton) {
        guard let swatch = sender as? ColorSwatchButton else { return }
        canvas?.activeColor = swatch.swatchColor
        swatchButtons.forEach { $0.isActive = ($0 === swatch) }
    }

    private func addVSep(to view: NSView, at x: CGFloat) {
        let sep = NSBox()
        sep.boxType = .separator
        sep.frame = CGRect(x: x, y: 8, width: 1, height: 36)
        view.addSubview(sep)
    }
}
