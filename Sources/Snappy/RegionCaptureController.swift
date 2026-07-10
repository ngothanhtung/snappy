import AppKit

@MainActor
final class RegionCaptureController {
    static let shared = RegionCaptureController()
    private init() {}

    func start() {
        // TODO: implemented in Task 2
        NSLog("Snappy: captureRegion triggered")
    }
}
