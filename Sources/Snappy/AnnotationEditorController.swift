import AppKit

@MainActor
final class AnnotationEditorController {
    static let shared = AnnotationEditorController()
    private init() {}

    func open(image: NSImage) {
        // Full implementation in Task 4
        NSLog("Snappy: annotation editor opened with image \(image.size)")
    }
}
