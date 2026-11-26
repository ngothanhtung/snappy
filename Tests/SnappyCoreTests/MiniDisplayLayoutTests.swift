import XCTest
@testable import SnappyCore

final class MiniDisplayLayoutTests: XCTestCase {
    func testEqualColumnsAndFullHeightSingles() {
        let layout = MiniDisplayLayout(columns: [.init(.cpu, .gpu), .init(nil, .claude), .init(nil, nil),
                                                 .init(.calendar, .reminders)])
        let p = layout.placements(width: 1000, height: 462, gap: 16, photoAspect: 4.0 / 3)
        XCTAssertEqual(p.map(\.widget), [.cpu, .gpu, .claude, .calendar, .reminders])
        let half = (462 - 48) / 2.0
        XCTAssertEqual(p[0].height, half)
        XCTAssertEqual(p[1].y, 16 + half + 16)
        XCTAssertEqual(p[2].height, 462 - 32)                      // alone in its column
        // The empty column is skipped; the three shown share the width equally.
        let cw = (1000 - 4 * 16) / 3.0
        XCTAssertEqual(Set(p.map(\.width)), [cw])
        XCTAssertEqual(p[2].x, 16 + cw + 16)
        XCTAssertEqual(p[3].x, 16 + 2 * (cw + 16))
        XCTAssertEqual(p[4].x + p[4].width + 16, 1000, accuracy: 0.001)
    }

    func testPhotoColumnUsesAspect() {
        let layout = MiniDisplayLayout(columns: [.init(.clock, .network), .init(.photo, .cpu)])
        let p = layout.placements(width: 1920, height: 462, gap: 16, photoAspect: 4.0 / 3)
        XCTAssertEqual(p.map(\.widget), [.clock, .network, .photo])   // photo takes the whole column
        XCTAssertEqual(p[2].width, (430 * 4.0 / 3).rounded())
        XCTAssertEqual(p[2].x + p[2].width + 16, 1920, accuracy: 0.001)
        XCTAssertEqual(p[0].width, 1920 - 48 - p[2].width, accuracy: 0.001)
    }

    func testPhotoShrinksToLeaveRoom() {
        let layout = MiniDisplayLayout(columns: [.init(.photo, nil), .init(.cpu, nil)])
        let p = layout.placements(width: 500, height: 462, gap: 16, photoAspect: 16.0 / 9)
        XCTAssertEqual(p[1].width, 120, accuracy: 0.001)
        XCTAssertEqual(p[0].width, 500 - 48 - 120, accuracy: 0.001)
        XCTAssertTrue(MiniDisplayLayout(columns: []).placements(width: 500, height: 462, gap: 16, photoAspect: 1).isEmpty)
    }

    func testMigrationFromOldSwitches() {
        let all = MiniDisplayLayout.migrated(photos: true, topApps: true, calendar: true, reminders: false, claude: true)
        XCTAssertEqual(all.columns.count, 7)
        XCTAssertEqual(all.columns[3], .init(.topCPU, .topMemory))
        XCTAssertEqual(all.columns[5], .init(.calendar, nil))
        XCTAssertEqual(all.columns[6], .init(.photo, nil))
        XCTAssertEqual(MiniDisplayLayout.migrated(photos: false, topApps: false, calendar: false,
                                                  reminders: false, claude: false), .standard)
    }

    func testSettingSlots() {
        var l = MiniDisplayLayout.standard
        l.set(.claude, column: 0, top: false)
        XCTAssertEqual(l.columns[0], .init(.cpu, .claude))
        l.set(nil, column: 0, top: true)
        XCTAssertEqual(l.columns[0], .init(nil, .claude))
        // Photo takes the column; anything placed there replaces it.
        l.set(.photo, column: 1, top: false)
        XCTAssertEqual(l.columns[1], .init(.photo, nil))
        XCTAssertTrue(l.isPhotoColumn(1))
        l.set(.ram, column: 1, top: false)
        XCTAssertEqual(l.columns[1], .init(.ram, nil))
        XCTAssertFalse(l.isPhotoColumn(1))
        l.set(.gpu, column: 9, top: true)   // out of range: ignored
        XCTAssertEqual(l.columns.count, 3)
    }

    func testCodingAndColumnCount() {
        var l = MiniDisplayLayout.standard
        l.setColumnCount(5)
        XCTAssertEqual(l.columns.count, 5)
        XCTAssertEqual(l.columns[4], .init(nil, nil))
        l.columns[4].top = .reminders
        XCTAssertEqual(MiniDisplayLayout.decode(l.encoded()), l)
        l.setColumnCount(99)
        XCTAssertEqual(l.columns.count, MiniDisplayLayout.maxColumns)
        l.setColumnCount(0)
        XCTAssertEqual(l.columns.count, 1)
        // Unknown widgets (from a newer version) become empty slots.
        let odd = #"{"columns":[{"top":"cpu","bottom":"weather"}]}"#.data(using: .utf8)
        XCTAssertEqual(MiniDisplayLayout.decode(odd), MiniDisplayLayout(columns: [.init(.cpu, nil)]))
        XCTAssertNil(MiniDisplayLayout.decode(nil))
        XCTAssertTrue(l.contains(.cpu))
        XCTAssertFalse(l.contains(.photo))
    }
}
