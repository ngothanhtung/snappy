import XCTest
@testable import SnappyCore

final class AppLeftoversTests: XCTestCase {

    private let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)
    private let slack = AppIdentity(bundleID: "com.tinyspeck.slackmacgap", name: "Slack",
                                    teamID: "BQR82RBBHL")

    private func location(_ path: String) -> LeftoverLocation {
        AppLeftoverRules.locations.first { $0.path == path }!
    }

    // MARK: Matching

    func testBundleIDMatchesWithKnownExtensions() {
        let prefs = location("Preferences")
        XCTAssertEqual(AppLeftoverRules.match(name: "com.tinyspeck.slackmacgap.plist",
                                              in: prefs, app: slack), .bundleID)
        XCTAssertEqual(AppLeftoverRules.match(name: "com.tinyspeck.slackmacgap.savedState",
                                              in: location("Saved Application State"), app: slack),
                       .bundleID)
        XCTAssertEqual(AppLeftoverRules.match(name: "com.tinyspeck.slackmacgap.binarycookies",
                                              in: location("Cookies"), app: slack), .bundleID)
    }

    func testEmbeddedHelperDataIsTickedCaseInsensitively() {
        var app = slack
        app.embeddedBundleIDs = ["com.tinyspeck.slackmacgap.ShipIt"]
        XCTAssertEqual(AppLeftoverRules.match(name: "COM.TinySpeck.SlackMacGap.ShipIt",
                                              in: location("Caches"), app: app), .bundleID)
    }

    func testPrefixThatIsNotABundledHelperStartsUnticked() {
        // "Chrome for Testing" is a different product sharing Chrome's prefix.
        let chrome = AppIdentity(bundleID: "com.google.Chrome", name: "Google Chrome")
        let match = AppLeftoverRules.match(name: "com.google.chrome.for.testing.plist",
                                           in: location("Preferences"), app: chrome)
        XCTAssertEqual(match, .relatedBundleID)
        XCTAssertEqual(match?.isSelectedByDefault, false)
    }

    func testUnrelatedPrefixIsNotMatched() {
        // Shares leading characters but is a different identifier.
        XCTAssertNil(AppLeftoverRules.match(name: "com.tinyspeck.slackmacgapbeta",
                                            in: location("Caches"), app: slack))
    }

    func testDataOfAnotherInstalledAppIsNotClaimed() {
        let chrome = AppIdentity(bundleID: "com.google.Chrome", name: "Google Chrome")
        let others: Set<String> = ["com.google.Chrome.canary"]
        let caches = location("Caches")
        XCTAssertNil(AppLeftoverRules.match(name: "com.google.Chrome.canary", in: caches,
                                            app: chrome, otherBundleIDs: others))
        XCTAssertNil(AppLeftoverRules.match(name: "com.google.Chrome.canary.helper", in: caches,
                                            app: chrome, otherBundleIDs: others))
        XCTAssertEqual(AppLeftoverRules.match(name: "com.google.Chrome.helper", in: caches,
                                              app: chrome, otherBundleIDs: others),
                       .relatedBundleID)
    }

    func testAppNameMatchesOnlyWhereAllowed() {
        XCTAssertEqual(AppLeftoverRules.match(name: "Slack", in: location("Application Support"),
                                              app: slack), .appName)
        XCTAssertNil(AppLeftoverRules.match(name: "Slack", in: location("Preferences"), app: slack))
    }

    func testGenericOrShortAppNamesNeverMatchByName() {
        let google = AppIdentity(bundleID: "com.google.drivefs", name: "Google")
        XCTAssertNil(AppLeftoverRules.match(name: "Google", in: location("Application Support"),
                                            app: google))
        let tiny = AppIdentity(bundleID: "com.example.x", name: "X")
        XCTAssertNil(AppLeftoverRules.match(name: "X", in: location("Caches"), app: tiny))
    }

    func testGroupContainers() {
        let groups = location("Group Containers")
        XCTAssertEqual(AppLeftoverRules.match(name: "group.com.tinyspeck.slackmacgap",
                                              in: groups, app: slack), .bundleID)
        XCTAssertEqual(AppLeftoverRules.match(name: "BQR82RBBHL.com.tinyspeck.slackmacgap",
                                              in: groups, app: slack), .bundleID)
        let shared = AppLeftoverRules.match(name: "BQR82RBBHL.shared", in: groups, app: slack)
        XCTAssertEqual(shared, .sharedWithVendor)
        XCTAssertEqual(shared?.isSelectedByDefault, false)
        // Another installed app from the same developer may still use it: hide it.
        XCTAssertNil(AppLeftoverRules.match(name: "BQR82RBBHL.shared", in: groups, app: slack,
                                            otherTeamIDs: ["BQR82RBBHL"]))
        // Team-prefix rule only applies to group-style folders.
        XCTAssertNil(AppLeftoverRules.match(name: "BQR82RBBHL.shared", in: location("Caches"),
                                            app: slack))
    }

    func testTeamPrefixedEmbeddedExtensionIsTicked() {
        let edge = AppIdentity(bundleID: "com.microsoft.edgemac", name: "Microsoft Edge",
                               teamID: "UBF8T346G9",
                               embeddedBundleIDs: ["com.microsoft.edgemac.widgets"])
        XCTAssertEqual(AppLeftoverRules.match(name: "UBF8T346G9.com.microsoft.edgemac.widgets",
                                              in: location("Group Containers"), app: edge,
                                              otherTeamIDs: ["UBF8T346G9"]), .bundleID)
        // Office's shared container is not Edge's, and Office is installed.
        XCTAssertNil(AppLeftoverRules.match(name: "UBF8T346G9.Office",
                                            in: location("Group Containers"), app: edge,
                                            otherTeamIDs: ["UBF8T346G9"]))
    }

    func testBundledThirdPartyComponentStartsUnticked() {
        let chrome = AppIdentity(bundleID: "com.google.Chrome", name: "Google Chrome",
                                 embeddedBundleIDs: ["com.google.GoogleUpdater",
                                                     "org.sparkle-project.Sparkle"])
        XCTAssertEqual(AppLeftoverRules.match(name: "com.google.GoogleUpdater",
                                              in: location("Caches"), app: chrome),
                       .relatedBundleID)
        XCTAssertEqual(AppLeftoverRules.match(name: "org.sparkle-project.Sparkle",
                                              in: location("Caches"), app: chrome),
                       .relatedBundleID)
    }

    func testNestedVendorFolderCandidates() {
        let pairs = AppLeftoverRules.nestedFolderCandidates(appName: "Google Chrome")
        XCTAssertEqual(pairs.map(\.vendor), ["Google", "Google"])
        XCTAssertEqual(pairs.map(\.child), ["Chrome", "Google Chrome"])
        XCTAssertTrue(AppLeftoverRules.nestedFolderCandidates(appName: "Slack").isEmpty)
        // A generic remainder ("App") is never used on its own.
        XCTAssertEqual(AppLeftoverRules.nestedFolderCandidates(appName: "Foo App").map(\.child),
                       ["Foo App"])
    }

    func testEmptyBundleIDMatchesNothing() {
        let broken = AppIdentity(bundleID: "", name: "Broken")
        XCTAssertNil(AppLeftoverRules.match(name: ".plist", in: location("Preferences"),
                                            app: broken))
    }

    // MARK: Refusals

    func testRefusals() {
        let ok = URL(fileURLWithPath: "/Applications/Slack.app")
        XCTAssertNil(AppLeftoverRules.refusal(appURL: ok, bundleID: slack.bundleID, home: home,
                                              ownBundleID: "com.ngothanhtung.snappy"))
        XCTAssertNil(AppLeftoverRules.refusal(
            appURL: home.appendingPathComponent("Applications/Tool.app"),
            bundleID: "com.example.tool", home: home, ownBundleID: nil))
        XCTAssertEqual(AppLeftoverRules.refusal(
            appURL: URL(fileURLWithPath: "/Applications/Safari.app"),
            bundleID: "com.apple.Safari", home: home, ownBundleID: nil), .systemApp)
        XCTAssertEqual(AppLeftoverRules.refusal(
            appURL: URL(fileURLWithPath: "/Applications/Snappy.app"),
            bundleID: "com.ngothanhtung.snappy", home: home,
            ownBundleID: "com.ngothanhtung.snappy"), .snappyItself)
        XCTAssertEqual(AppLeftoverRules.refusal(
            appURL: URL(fileURLWithPath: "/Users/test/Downloads/Thing.app"),
            bundleID: "com.example.thing", home: home, ownBundleID: nil),
            .outsideApplicationsFolders)
        XCTAssertEqual(AppLeftoverRules.refusal(
            appURL: URL(fileURLWithPath: "/Applications"),
            bundleID: "com.example.thing", home: home, ownBundleID: nil), .notAnApp)
    }

    // MARK: Removal gate

    func testRemovalGate() {
        let app = URL(fileURLWithPath: "/Applications/Slack.app")
        XCTAssertTrue(AppLeftoverRules.isRemovable(app, appURL: app, home: home))
        XCTAssertTrue(AppLeftoverRules.isRemovable(
            home.appendingPathComponent("Library/Caches/com.tinyspeck.slackmacgap"),
            appURL: app, home: home))
        // The leftover folders themselves, and anything else, are never removed.
        XCTAssertFalse(AppLeftoverRules.isRemovable(
            home.appendingPathComponent("Library/Caches"), appURL: app, home: home))
        XCTAssertFalse(AppLeftoverRules.isRemovable(
            home.appendingPathComponent("Documents/notes.txt"), appURL: app, home: home))
        XCTAssertFalse(AppLeftoverRules.isRemovable(
            URL(fileURLWithPath: "/Applications/Other.app"), appURL: app, home: home))
        XCTAssertFalse(AppLeftoverRules.isRemovable(
            URL(fileURLWithPath: home.path + "/Library/Caches/../Keychains/login.keychain-db"),
            appURL: app, home: home))
    }

    func testNoLocationIsAUserDataFolder() {
        for loc in AppLeftoverRules.locations {
            let path = loc.path.lowercased()
            XCTAssertFalse(["keychains", "mail", "messages", "mobile documents", "photos"]
                .contains { path.hasPrefix($0) }, loc.path)
        }
    }
}
