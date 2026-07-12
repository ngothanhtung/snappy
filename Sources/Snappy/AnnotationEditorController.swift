import AppKit
import OSLog
import UniformTypeIdentifiers

// MARK: - Appearance-aware toolbar background

private final class ToolbarView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        // clipsToBounds defaults to false on macOS 14+, so dirtyRect can extend
        // over the whole window; filling it unclipped paints over the sibling
        // canvas below. Fill only within our own bounds.
        NSColor.windowBackgroundColor.setFill()
        bounds.intersection(dirtyRect).fill()
    }
}

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
            // labelColor ring adapts to both light and dark mode
            NSColor.labelColor.setFill()
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
    private let logger = Logger(subsystem: "com.ngothanhtung.snappy", category: "AnnotationEditor")
    private init() {}

    private var window: NSWindow?
    private var canvas: AnnotationCanvasView?
    private var swatchButtons: [ColorSwatchButton] = []

    func open(fileURL: URL) throws {
        guard let image = NSImage(contentsOf: fileURL) else {
            throw NSError(
                domain: "Snappy", code: 5,
                userInfo: [NSLocalizedDescriptionKey: "Could not read the saved screenshot."]
            )
        }
        logger.info("Loaded annotation image from \(fileURL.path, privacy: .public)")
        open(image: image, fileURL: fileURL)
    }

    func chooseFileAndOpen() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose an image to edit in Annotate"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try open(fileURL: url)
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
        }
    }

    func open(image: NSImage, fileURL: URL? = nil,
              on preferredScreen: NSScreen? = nil) {
        logger.info("Opening editor for image \(image.size.width, privacy: .public)x\(image.size.height, privacy: .public)")
        NSLog("Snappy: AnnotationEditorController.open image.size=%@", NSStringFromSize(image.size))
        window?.close()
        window = nil
        canvas = nil
        swatchButtons = []

        // Scale image to fit visible screen, never upscale
        guard let screen = preferredScreen ?? NSScreen.main ?? NSScreen.screens.first else {
            logger.error("Cannot open editor because no NSScreen is available")
            return
        }
        let toolbarH: CGFloat = 52
        let visibleFrame = screen.visibleFrame.insetBy(dx: 40, dy: 40)
        let maxSize = CGSize(width: visibleFrame.width,
                             height: max(1, visibleFrame.height - toolbarH))
        let scale = min(maxSize.width / image.size.width,
                        maxSize.height / image.size.height, 1.0)
        let displaySize = CGSize(
            width: (image.size.width * scale).rounded(),
            height: (image.size.height * scale).rounded()
        )

        let minimumToolbarWidth: CGFloat = 920
        let contentWidth = max(displaySize.width, minimumToolbarWidth)

        let canvasView = AnnotationCanvasView(image: image, fileURL: fileURL)
        canvasView.frame = CGRect(
            x: ((contentWidth - displaySize.width) / 2).rounded(),
            y: 0,
            width: displaySize.width,
            height: displaySize.height
        )
        self.canvas = canvasView

        let winSize = CGSize(width: contentWidth,
                             height: displaySize.height + toolbarH)
        let win = NSWindow(
            contentRect: CGRect(origin: .zero, size: winSize),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        win.title = "Snappy \u{2014} Annotate"
        win.isReleasedWhenClosed = false
        win.level = .floating
        win.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]

        let content = NSView(frame: CGRect(origin: .zero, size: winSize))
        win.contentView = content

        content.addSubview(canvasView)

        let toolbar = buildToolbar(width: contentWidth, canvas: canvasView)
        toolbar.frame = CGRect(x: 0, y: displaySize.height,
                               width: contentWidth, height: toolbarH)
        toolbar.autoresizingMask = [.width, .minYMargin]
        content.addSubview(toolbar)

        self.window = win
        let screenFrame = screen.visibleFrame
        let origin = CGPoint(
            x: screenFrame.midX - win.frame.width / 2,
            y: screenFrame.midY - win.frame.height / 2
        )
        win.setFrameOrigin(origin)
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
        win.orderFrontRegardless()
        logger.info("Editor window ordered front on display \(screen.localizedName, privacy: .public); frame=\(NSStringFromRect(win.frame), privacy: .public), visible=\(win.isVisible, privacy: .public), key=\(win.isKeyWindow, privacy: .public)")
    }

    private func buildToolbar(width: CGFloat, canvas: AnnotationCanvasView) -> NSView {
        let bar = ToolbarView()

        // Bottom border line
        let sep = NSBox()
        sep.boxType = .separator
        sep.frame = CGRect(x: 0, y: 0, width: width, height: 1)
        sep.autoresizingMask = .width
        bar.addSubview(sep)

        var x: CGFloat = 12

        // Tool selector (select / arrow / rect / circle / text / stamp / step)
        let toolImages: [NSImage] = [
            NSImage(systemSymbolName: "cursorarrow",            accessibilityDescription: "Select")!,
            NSImage(systemSymbolName: "arrow.up.right",         accessibilityDescription: "Arrow")!,
            NSImage(systemSymbolName: "rectangle",             accessibilityDescription: "Rectangle")!,
            NSImage(systemSymbolName: "circle",                accessibilityDescription: "Circle")!,
            NSImage(systemSymbolName: "character.cursor.ibeam", accessibilityDescription: "Label")!,
            NSImage(systemSymbolName: "face.smiling",           accessibilityDescription: "Stamp")!,
            NSImage(systemSymbolName: "1.circle",               accessibilityDescription: "Step")!,
        ]
        let toolCtrl = NSSegmentedControl(
            images: toolImages, trackingMode: .selectOne,
            target: canvas, action: #selector(AnnotationCanvasView.changeTool(_:))
        )
        toolCtrl.selectedSegment = AnnotationTool.arrow.rawValue
        toolCtrl.frame = CGRect(x: x, y: 11, width: 245, height: 30)
        bar.addSubview(toolCtrl)
        x += 253

        // Arrow style picker
        let stylePopup = NSPopUpButton(frame: CGRect(x: x, y: 12, width: 76, height: 28))
        for title in ["\u{2192}", "\u{2194}", "\u{2014}", "\u{25CF}\u{2192}"] {
            stylePopup.addItem(withTitle: title)
        }
        stylePopup.target = canvas
        stylePopup.action = #selector(AnnotationCanvasView.changeArrowStyle(_:))
        stylePopup.setAccessibilityLabel("Arrow Style")
        bar.addSubview(stylePopup)
        x += 84

        // Emoji stamp picker
        let emojiPopup = NSPopUpButton(frame: CGRect(x: x, y: 12, width: 64, height: 28))
        for emoji in AnnotationCanvasView.stampEmojis {
            emojiPopup.addItem(withTitle: emoji)
        }
        emojiPopup.target = canvas
        emojiPopup.action = #selector(AnnotationCanvasView.changeEmoji(_:))
        emojiPopup.setAccessibilityLabel("Stamp Emoji")
        bar.addSubview(emojiPopup)
        x += 72

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
        canvas?.applyColor(swatch.swatchColor)
        swatchButtons.forEach { $0.isActive = ($0 === swatch) }
    }

    private func addVSep(to view: NSView, at x: CGFloat) {
        let sep = NSBox()
        sep.boxType = .separator
        sep.frame = CGRect(x: x, y: 8, width: 1, height: 36)
        view.addSubview(sep)
    }
}
