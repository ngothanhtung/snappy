import XCTest
@testable import SnappyCore

final class JunkCleaningTests: XCTestCase {

    private let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)
    private let tmp = URL(fileURLWithPath: "/private/var/folders/ab/xyz/T", isDirectory: true)
    private var caches: URL { home.appendingPathComponent("Library/Caches") }

    // MARK: - Containment

    func testItemInsideRootIsContained() {
        let item = caches.appendingPathComponent("com.example.app/data.db")
        XCTAssertTrue(JunkSafety.isStrictlyInside(item, root: caches))
    }

    func testRootItselfIsNotContained() {
        XCTAssertFalse(JunkSafety.isStrictlyInside(caches, root: caches))
    }

    func testSiblingWithSharedPrefixIsNotContained() {
        // "/Library/CachesOld" must not count as inside "/Library/Caches".
        let sibling = home.appendingPathComponent("Library/CachesOld/x")
        XCTAssertFalse(JunkSafety.isStrictlyInside(sibling, root: caches))
    }

    func testDotDotTraversalEscapingRootIsRejected() {
        let escaped = URL(fileURLWithPath: caches.path + "/../Preferences/com.example.plist")
        XCTAssertFalse(JunkSafety.isStrictlyInside(escaped, root: caches))
    }

    // MARK: - Protection

    func testProtectedNamesAreRejected() {
        let item = caches.appendingPathComponent("CloudKit/records")
        XCTAssertFalse(JunkSafety.canRemove(item, root: caches, runningBundleIDs: []))
    }

    func testOrdinaryCacheIsRemovable() {
        let item = caches.appendingPathComponent("com.example.app/blob")
        XCTAssertTrue(JunkSafety.canRemove(item, root: caches, runningBundleIDs: []))
    }

    func testRunningAppCacheIsRejected() {
        let item = caches.appendingPathComponent("com.example.app/blob")
        XCTAssertFalse(JunkSafety.canRemove(item, root: caches,
                                            runningBundleIDs: ["com.example.app"]))
    }

    func testRunningAppMatchesHelperFoldersCaseInsensitively() {
        XCTAssertTrue(JunkSafety.belongsToRunningApp(name: "Com.Example.App.Helper",
                                                     runningBundleIDs: ["com.example.app"]))
    }

    func testRunningAppDoesNotMatchUnrelatedPrefix() {
        // "com.example.application" is a different app from "com.example.app".
        XCTAssertFalse(JunkSafety.belongsToRunningApp(name: "com.example.application",
                                                      runningBundleIDs: ["com.example.app"]))
    }

    func testTopLevelName() {
        let item = caches.appendingPathComponent("com.example.app/a/b")
        XCTAssertEqual(JunkSafety.topLevelName(of: item, root: caches), "com.example.app")
        XCTAssertNil(JunkSafety.topLevelName(of: caches, root: caches))
    }

    // MARK: - Age

    func testAgeLimit() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let week: TimeInterval = 7 * 24 * 3600
        XCTAssertTrue(JunkSafety.isOldEnough(modified: now - week, now: now, minimumAge: week))
        XCTAssertFalse(JunkSafety.isOldEnough(modified: now - week + 1, now: now, minimumAge: week))
        XCTAssertFalse(JunkSafety.isOldEnough(modified: nil, now: now, minimumAge: week))
        XCTAssertTrue(JunkSafety.isOldEnough(modified: nil, now: now, minimumAge: 0))
    }

    // MARK: - Categories

    func testEveryRootStaysInsideHomeOrTemporaryDirectory() {
        for category in JunkCategory.allCases {
            for root in category.roots(home: home, temporaryDirectory: tmp) {
                let inHome = JunkSafety.isStrictlyInside(root, root: home)
                let isTmp = root.standardizedFileURL == tmp.standardizedFileURL
                XCTAssertTrue(inHome || isTmp, "\(category) root \(root.path) escapes home")
            }
        }
    }

    func testNoRootIsAUserDataFolder() {
        let userData = ["Documents", "Desktop", "Downloads", "Pictures", "Movies", "Music",
                        "Library/Preferences", "Library/Application Support",
                        "Library/Containers", "Library/Mail", "Library/Keychains"]
        let forbidden = userData.map { home.appendingPathComponent($0) }
        for category in JunkCategory.allCases {
            for root in category.roots(home: home, temporaryDirectory: tmp) {
                for folder in forbidden {
                    XCTAssertFalse(root.standardizedFileURL == folder.standardizedFileURL
                                   || JunkSafety.isStrictlyInside(root, root: folder)
                                   || JunkSafety.isStrictlyInside(folder, root: root),
                                   "\(category) overlaps \(folder.path)")
                }
            }
        }
    }

    func testTimeSensitiveCategoriesHaveAgeLimits() {
        XCTAssertGreaterThan(JunkCategory.userLogs.minimumAge, 0)
        XCTAssertGreaterThan(JunkCategory.temporaryFiles.minimumAge, 0)
        XCTAssertEqual(JunkCategory.temporaryFiles.strategy, .oldFiles)
    }

    func testSlowToRestoreCategoriesAreOptIn() {
        XCTAssertFalse(JunkCategory.xcodeDeviceSupport.isSelectedByDefault)
        XCTAssertFalse(JunkCategory.packageManagerCaches.isSelectedByDefault)
        XCTAssertTrue(JunkCategory.userCaches.isSelectedByDefault)
    }
}
