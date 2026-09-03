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

        let minimumToolbarWidth: CGFloat = 1206
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

        // Copy the flattened image to the clipboard, then delete the
        // backing file from disk (handled by the controller so it can
        // close the editor window afterward).
        let copyDeleteBtn = NSButton(title: "Copy & Delete", target: self,
                                     action: #selector(copyAndDelete(_:)))
        copyDeleteBtn.bezelStyle = .rounded
        copyDeleteBtn.frame = CGRect(x: x, y: 12, width: 108, height: 28)
        copyDeleteBtn.toolTip = "Copy image to clipboard, then delete the file from disk"
        bar.addSubview(copyDeleteBtn)
        x += 116

        // Upload to Google Drive (handled by the controller, not the canvas)
        let driveBtn = NSButton(title: "Drive", target: self, action: #selector(uploadToDrive(_:)))
        driveBtn.bezelStyle = .rounded
        driveBtn.image = NSImage(systemSymbolName: "icloud.and.arrow.up",
                                 accessibilityDescription: "Upload to Google Drive")
        driveBtn.imagePosition = .imageLeading
        driveBtn.frame = CGRect(x: x, y: 12, width: 84, height: 28)
        driveBtn.toolTip = "Upload to Google Drive"
        bar.addSubview(driveBtn)
        x += 92

        // Upload to a GitHub repository
        let githubBtn = NSButton(title: "GitHub", target: self, action: #selector(uploadToGitHub(_:)))
        githubBtn.bezelStyle = .rounded
        githubBtn.image = NSImage(systemSymbolName: "arrow.up.forward.square",
                                  accessibilityDescription: "Upload to GitHub")
        githubBtn.imagePosition = .imageLeading
        githubBtn.frame = CGRect(x: x, y: 12, width: 92, height: 28)
        githubBtn.toolTip = "Upload to GitHub repository"
        bar.addSubview(githubBtn)

        return bar
    }

    private var isUploading = false

    @objc private func uploadToDrive(_ sender: NSButton) {
        guard !isUploading else { return }
        guard GoogleDriveClient.shared.isConfigured else {
            let alert = NSAlert()
            alert.messageText = "Google Drive is not set up"
            alert.informativeText = """
                Open Snappy Settings and enter your OAuth Client ID and Client Secret.

                Create them in Google Cloud Console \u{25B8} APIs & Services \u{25B8} \
                Credentials \u{25B8} Create Credentials \u{25B8} OAuth client ID \
                (type: Desktop app), with the Google Drive API enabled.
                """
            alert.runModal()
            return
        }
        runUpload(sender: sender, serviceName: "Google Drive", openTitle: "Open in Drive") {
            try await GoogleDriveClient.shared.upload(png: $0, filename: $1)
        }
    }

    @objc private func uploadToGitHub(_ sender: NSButton) {
        guard !isUploading else { return }
        guard GitHubUploader.shared.isConfigured else {
            let alert = NSAlert()
            alert.messageText = "GitHub upload is not set up"
            alert.informativeText = """
                Open Snappy Settings and enter the repository (owner/name) plus a \
                personal access token.

                Create a fine-grained token at github.com \u{25B8} Settings \u{25B8} \
                Developer settings \u{25B8} Personal access tokens, limited to that \
                repository with Contents read & write permission.
                """
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            return
        }
        runUpload(sender: sender, serviceName: "GitHub", openTitle: "Open Raw File") {
            try await GitHubUploader.shared.upload(png: $0, filename: $1)
        }
    }

    /// Shared export → upload → result-alert flow for the upload buttons.
    private func runUpload(sender: NSButton, serviceName: String, openTitle: String,
                           task: @escaping (Data, String) async throws -> URL?) {
        guard let canvas, let png = canvas.exportPNGData() else {
            NSLog("Snappy: %@ upload aborted, could not render PNG", serviceName)
            return
        }
        let filename = canvas.exportFilename
        NSLog("Snappy: %@ upload starting for %@ (%ld bytes)", serviceName, filename, png.count)

        isUploading = true
        sender.isEnabled = false
        let originalTitle = sender.title
        sender.title = "Uploading\u{2026}"
        Task { @MainActor in
            defer {
                isUploading = false
                sender.isEnabled = true
                sender.title = originalTitle
            }
            do {
                let link = try await task(png, filename)
                NSLog("Snappy: %@ upload succeeded, link=%@",
                      serviceName, link?.absoluteString ?? "none")
                let alert = NSAlert()
                alert.messageText = "Uploaded to \(serviceName)"
                alert.informativeText = filename
                if link != nil {
                    alert.addButton(withTitle: openTitle)
                    alert.addButton(withTitle: "OK")
                } else {
                    alert.addButton(withTitle: "OK")
                }
                // Re-activate: a browser used for OAuth consent may be
                // frontmost, which would leave the alert buried behind it.
                NSApp.activate(ignoringOtherApps: true)
                if alert.runModal() == .alertFirstButtonReturn, let link {
                    NSWorkspace.shared.open(link)
                }
            } catch {
                NSLog("Snappy: %@ upload failed: %@", serviceName, String(describing: error))
                let alert = NSAlert()
                alert.messageText = "Upload failed"
                alert.informativeText = error.localizedDescription
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
            }
        }
    }

    @objc private func copyAndDelete(_ sender: NSButton) {
        guard let canvas else { return }
        do {
            try canvas.copyAndDelete()
            window?.close()
            window = nil
            self.canvas = nil
            swatchButtons = []
        } catch {
            NSLog("Snappy: Copy & Delete failed to remove file: %@", String(describing: error))
            let alert = NSAlert()
            alert.messageText = "Copied to clipboard, but couldn't delete the file"
            alert.informativeText = error.localizedDescription
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
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
