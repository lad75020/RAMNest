import Foundation
import Darwin
import Testing
@testable import RAMNestCore
extension RAMNestTestSuite {
    struct StorageFormatTests {
        private func fixture() throws -> (URL, Store, Folder, String) {
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("artifacts/storage-format/" + UUID().uuidString)
            try Store.privateDirectory(root)
            let source = root.appendingPathComponent("source"); try Store.privateDirectory(source)
            try Data("verified payload".utf8).write(to: source.appendingPathComponent("payload"))
            try FileManager.default.linkItem(at: source.appendingPathComponent("payload"), to: source.appendingPathComponent("alias"))
            try FileManager.default.createSymbolicLink(atPath: source.appendingPathComponent("sym").path, withDestinationPath: "payload")
            let store = try Store(root: root.appendingPathComponent("store"))
            let folder = try Engine(store: store).create(path: source, name: "format", capacity: 32 << 20)
            let revision = try Snapshot.capture(store: store, folder: folder, source: source, previous: nil)
            return (root, store, folder, revision)
        }
        @Test func `Private mode map authenticated before copy and immutable source preserved`() throws {
            let (root, store, folder, revision) = try fixture()
            let (data, expected) = try Snapshot.verified(store: store, id: folder.id, revision: revision)
            let manifestURL = data.deletingLastPathComponent().appendingPathComponent("manifest.json")
            let mapURL = data.deletingLastPathComponent().appendingPathComponent("modes.bin")
            let raw = try Data(contentsOf: manifestURL), modes = try Data(contentsOf: mapURL)
            let output = root.appendingPathComponent("export")
            try Snapshot.copyTree(from: data, to: output, manifest: expected, sourceContext: .managedRevision)
            #expect(try Snapshot.manifest(output, matching: expected).matchesCopy(of: expected))
            #expect(try Data(contentsOf: manifestURL) == raw && Data(contentsOf: mapURL) == modes)
            #expect(try Snapshot.verified(store: store, id: folder.id, revision: revision).1 == expected)
        }
        @Test(arguments: ["payload", "mode-map", "manifest", "unknown-entry"])
        func `Corruption rejects without repairing committed data`(kind: String) throws {
            let (_, store, folder, revision) = try fixture()
            let data = try Snapshot.dataURL(store: store, id: folder.id, revision: revision)
            if kind == "payload" { try Data("corrupt payload!".utf8).write(to: data.appendingPathComponent("payload")) }
            if kind == "mode-map" { try Data([0, 1, 2]).write(to: data.deletingLastPathComponent().appendingPathComponent("modes.bin")) }
            if kind == "manifest" { try Data("{broken".utf8).write(to: data.deletingLastPathComponent().appendingPathComponent("manifest.json")) }
            if kind == "unknown-entry" { try Data("unknown".utf8).write(to: data.appendingPathComponent("unexpected")) }
            #expect(throws: (any Error).self) { try Snapshot.verified(store: store, id: folder.id, revision: revision) }
            #expect(FileManager.default.fileExists(atPath: data.path))
        }
        @Test func `Stored unknown null and partial format authority reject`() throws {
            let (_, store, folder, revision) = try fixture()
            let data = try Snapshot.dataURL(store: store, id: folder.id, revision: revision)
            let metadata = data.deletingLastPathComponent().appendingPathComponent("manifest.json")
            let original = try JSONSerialization.jsonObject(with: Data(contentsOf: metadata)) as! [String: Any]
            for key in ["storageFormat", "modeMapDigest"] {
                var changed = original; changed[key] = NSNull()
                #expect(throws: (any Error).self) { try JSONDecoder().decode(StoredManifest.self, from: JSONSerialization.data(withJSONObject: changed)) }
            }
            var unknown = original; unknown["storageFormat"] = 99
            #expect(throws: (any Error).self) { try JSONDecoder().decode(StoredManifest.self, from: JSONSerialization.data(withJSONObject: unknown)) }
        }
        @Test func `Unversioned stored data remains readable without engine implementation`() throws {
            let (root, store, folder, revision) = try fixture()
            let (data, expected) = try Snapshot.verified(store: store, id: folder.id, revision: revision)
            let legacy = root.appendingPathComponent("legacy"); try Snapshot.copyTree(from: data, to: legacy, manifest: expected, publicationStaging: true, sourceContext: .managedRevision)
            let old = Manifest(entries: try Snapshot.manifest(legacy).entries)
            let container = try store.volume(folder.id).appendingPathComponent("revisions/" + UUID().uuidString)
            try Store.privateDirectory(container)
            try FileManager.default.moveItem(at: legacy, to: container.appendingPathComponent("data"))
            try Store.atomicJSON(old, container.appendingPathComponent("manifest.json"))
            let verified = try Snapshot.verified(store: store, id: folder.id, revision: container.lastPathComponent)
            #expect(verified.1.publicRoot == nil && verified.1.entries == old.entries)
        }
    }
}
