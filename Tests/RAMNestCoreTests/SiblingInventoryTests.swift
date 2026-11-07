import Foundation
#if !RAMNEST_INVENTORY_STANDALONE
import XCTest
#endif
@testable import RAMNestCore

#if !RAMNEST_INVENTORY_STANDALONE
final class SiblingInventoryTests: XCTestCase {
    func testNestedHardlinksMatchSnapshotManifest() throws { try InventoryScenarios.run() }
}
#endif
enum InventoryScenarios {
    static func run() throws {
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().resolvingSymlinksInPath()
        let root = project.appendingPathComponent("artifacts/holding-cleanup/hardlinks-\(UUID().uuidString)")
        try Store.privateDirectory(root)
        let nested = root.appendingPathComponent("alpha")
        try Store.privateDirectory(nested)
        let payload = nested.appendingPathComponent("payload")
        try Data("Generated hardlink canonicalization fixture".utf8).write(to: payload)
        try FileManager.default.linkItem(at: payload, to: root.appendingPathComponent("alpha-link"))
        let expected = try Snapshot.manifest(root)
        let inventory = try DirectoryHandle.open(root).cleanupInventory()
        guard inventory.manifest.contentsMatchExpected(expected), inventory.manifest.publicRoot == nil, !inventory.manifest.matchesExpected(expected) else { throw NestError("Cleanup hardlink canonicalization differs from snapshot manifest.") }
        print("PASS standalone sibling inventory: hierarchical hardlink anchors")
    }
}

#if RAMNEST_INVENTORY_STANDALONE
@main struct InventoryRunner { static func main() throws { try InventoryScenarios.run() } }
#endif
