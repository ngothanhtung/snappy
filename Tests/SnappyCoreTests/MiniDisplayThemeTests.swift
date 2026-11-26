import XCTest
@testable import SnappyCore

final class MiniDisplayThemeTests: XCTestCase {
    private func luminance(_ hex: UInt32) -> Double {
        func ch(_ v: UInt32) -> Double {
            let c = Double(v) / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * ch((hex >> 16) & 0xFF) + 0.7152 * ch((hex >> 8) & 0xFF) + 0.0722 * ch(hex & 0xFF)
    }

    private func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        let (x, y) = (luminance(a), luminance(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    func testThemesAreReadable() {
        for t in MiniDisplayTheme.all {
            for bg in [t.backgroundTop, t.backgroundBottom] {
                XCTAssertGreaterThanOrEqual(contrast(t.text, bg), 7, "\(t.id) text")
                XCTAssertGreaterThanOrEqual(contrast(t.textDim, bg), 3, "\(t.id) dim text")
                for (name, c) in [("cpu", t.cpu), ("gpu", t.gpu), ("memory", t.memory), ("network", t.network),
                                  ("storage", t.storage), ("lunar", t.lunar), ("claude", t.claude),
                                  ("good", t.good), ("warning", t.warning), ("critical", t.critical)] {
                    XCTAssertGreaterThanOrEqual(contrast(c, bg), 3, "\(t.id) \(name)")
                }
            }
        }
    }

    func testLookup() {
        XCTAssertEqual(MiniDisplayTheme.named("ocean"), .ocean)
        XCTAssertEqual(MiniDisplayTheme.named("nope"), .midnight)
        XCTAssertEqual(MiniDisplayTheme.named(nil), .midnight)
        XCTAssertEqual(Set(MiniDisplayTheme.all.map(\.id)).count, MiniDisplayTheme.all.count)
    }
}
