import AppKit

final class AnnotationCanvasView: NSView {
    private let image: NSImage

    init(image: NSImage) {
        self.image = image
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    var activeTool: Int = 0
    var activeColor: NSColor = .systemRed
    var activeLineWidth: CGFloat = 3

    @objc func changeTool(_ sender: NSSegmentedControl) { activeTool = sender.selectedSegment }
    @objc func changeWidth(_ sender: NSStepper) { activeLineWidth = CGFloat(sender.intValue) }
    @objc func undoLast() {}
    @objc func copyToClipboard() {}
    @objc func saveImage() {}

    override func draw(_ dirtyRect: NSRect) {
        image.draw(in: bounds, from: .zero, operation: .copy, fraction: 1)
    }
}
