import XCTest
@testable import SnappyCore

final class JunkTreeTests: XCTestCase {

    private let base = URL(fileURLWithPath: "/Users/test/Library/Caches/com.example.app")

    private func file(_ path: String, _ bytes: Int64) -> JunkNode {
        JunkNode(url: base.appendingPathComponent(path), isDirectory: false, bytes: bytes)
    }

    /// app cache folder (.contents) → [a/ (.whole, children x,y), b]
    private func makeCacheTree() -> (root: JunkNode, a: JunkNode, b: JunkNode) {
        let a = JunkNode(url: base.appendingPathComponent("a"), isDirectory: true, bytes: 30)
        let b = file("b", 5)
        let root = JunkNode(url: base, isDirectory: true, bytes: 0, removal: .contents,
                            children: [a, b])
        a.setChildren([file("a/x", 20), file("a/y", 10)])
        return (root, a, b)
    }

    private func paths(_ nodes: [JunkNode]) -> [String] {
        nodes.map { String($0.url.path.dropFirst(base.path.count + 1)) }.sorted()
    }

    func testFullyTickedContentsFolderRemovesChildrenNotItself() {
        let (root, _, _) = makeCacheTree()
        XCTAssertEqual(root.check, .on)
        XCTAssertEqual(paths(root.removalTargets()), ["a", "b"])
        XCTAssertEqual(root.bytes, 35)
    }

    func testUntickingOneGrandchildRemovesOnlyItsSiblings() {
        let (root, a, _) = makeCacheTree()
        a.children![1].toggle() // untick a/y
        XCTAssertEqual(a.check, .mixed)
        XCTAssertEqual(root.check, .mixed)
        XCTAssertEqual(paths(root.removalTargets()), ["a/x", "b"])
        XCTAssertEqual(root.selectedBytes, 25)
    }

    func testTogglingMixedNodeTicksEverything() {
        let (root, a, _) = makeCacheTree()
        a.children![0].toggle()
        root.toggle() // mixed → on
        XCTAssertEqual(root.check, .on)
        XCTAssertEqual(paths(root.removalTargets()), ["a", "b"])
    }

    func testUntickedTreeRemovesNothing() {
        let (root, _, _) = makeCacheTree()
        root.toggle()
        XCTAssertEqual(root.check, .off)
        XCTAssertTrue(root.removalTargets().isEmpty)
        XCTAssertEqual(root.selectedBytes, 0)
    }

    func testLazyChildrenInheritParentTick() {
        let folder = JunkNode(url: base.appendingPathComponent("d"), isDirectory: true, bytes: 9)
        XCTAssertTrue(folder.canLoadChildren)
        folder.setSelected(false)
        folder.setChildren([file("d/1", 9)])
        XCTAssertFalse(folder.canLoadChildren)
        XCTAssertEqual(folder.check, .off)
    }

    func testWholeFolderSizeIsKeptAfterLoadingChildren() {
        // Its own recursive size may include entries not shown as children.
        let folder = JunkNode(url: base.appendingPathComponent("d"), isDirectory: true, bytes: 100)
        folder.setChildren([file("d/1", 60)])
        XCTAssertEqual(folder.bytes, 100)
    }

    func testFileTreeGroupsNestedFilesAndNeverRemovesFolders() {
        let logs = URL(fileURLWithPath: "/Users/test/Library/Logs/App")
        let tree = JunkNode.fileTree(folder: logs, files: [
            (logs.appendingPathComponent("old.log"), 4),
            (logs.appendingPathComponent("sub/deep/a.log"), 2),
            (logs.appendingPathComponent("sub/b.log"), 1),
            (URL(fileURLWithPath: "/elsewhere/c.log"), 99), // outside: dropped
        ])
        XCTAssertEqual(tree.bytes, 7)
        XCTAssertEqual(tree.removalTargets().map(\.name).sorted(), ["a.log", "b.log", "old.log"])
        XCTAssertTrue(tree.removalTargets().allSatisfy { !$0.isDirectory })

        let sub = tree.children!.first { $0.name == "sub" }!
        sub.toggle()
        XCTAssertEqual(tree.removalTargets().map(\.name), ["old.log"])
    }

    func testChildrenAreSortedLargestFirst() {
        let (root, _, _) = makeCacheTree()
        XCTAssertEqual(root.children!.map(\.name), ["a", "b"])
    }
}
