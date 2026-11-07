import Foundation
import Darwin
@testable import RAMNestCore

#if RAMNEST_SNAPSHOT_DESCRIPTOR_STANDALONE
@main enum SnapshotDescriptorTests {
    static func main() {
        do { try run() }
        catch { FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8)); exit(1) }
    }
    static func run() throws {
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().resolvingSymlinksInPath()
        let root = project.appendingPathComponent("artifacts/latest-snapshot/descriptor-\(UUID().uuidString)")
        try Store.privateDirectory(root)
        let source = root.appendingPathComponent("selected")
        try Store.privateDirectory(source)
        for i in 0..<160 {
            let directory = source.appendingPathComponent("dir-\(i)")
            try Store.privateDirectory(directory)
            try Data("Owned retention fixture".utf8).write(to: directory.appendingPathComponent("file"))
        }
        let store = try Store(root: root.appendingPathComponent("store"))
        let folder = try Engine(store: store).create(path: source, name: "Descriptor retention fixture", capacity: 16 << 20)
        let revision = try Snapshot.capture(store: store, folder: folder, source: source, previous: nil)
        try store.locked {
            let revisions = try store.managedVolume(folder.id).child("revisions")
            try revisions.removeCommittedRevision(revision)
            guard try !revisions.exists(revision) else { throw NestError("Obsolete revision remains.") }
        }
        print("PASS: 160-directory snapshot cleanup with a process-only 96-descriptor limit")
    }
}
#endif
