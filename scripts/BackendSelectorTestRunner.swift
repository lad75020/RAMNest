import Foundation
@testable import RAMNestCore

@main struct BackendSelectorTests {
    static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw NestError("TEST: " + message) }
    }
    static func object<T: Encodable>(_ value: T) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as! [String: Any]
    }
    static func decode(_ object: [String: Any]) throws -> Configuration {
        try JSONDecoder().decode(Configuration.self, from: JSONSerialization.data(withJSONObject: object))
    }
    static func main() {
        do {
            if CommandLine.arguments.count == 4 && CommandLine.arguments[1] == "--set-backend" {
                guard let backend = Configuration.Backend(rawValue: CommandLine.arguments[3]) else { throw NestError("Invalid test backend") }
                let engine = Engine(store: try Store(root: URL(fileURLWithPath: CommandLine.arguments[2])))
                try engine.setBackend(backend)
            } else { try run() }
        }
        catch { FileHandle.standardError.write(Data("FAIL backend selector: \(error)\n".utf8)); exit(1) }
    }
    static func run() throws {
        var options = FolderOptions()
        options.compression = false; options.mountAtLaunch = false; options.nobrowse = false
        options.sync = false; options.periodicSave = true; options.intervalMinutes = 60; options.comparison = .checksum
        let folder = Folder(name: "Original alias", path: "/fixture/original,folder", capacity: 32<<20, device: 42, inode: 99, bookmark: Data([1, 2, 3]), options: options)
        var config = Configuration(); config.menuBarMode = true; config.folders = [folder]
        var old = try object(config); old.removeValue(forKey: "backend")
        let decoded = try decode(old)
        try check(try object(decoded)["backend"] as? String == "nfs", "old configuration missing backend must decode as NFS")
        try check(decoded.version == config.version && decoded.menuBarMode && decoded.folders == [folder], "legacy configuration must preserve all existing fields")
        print("PASS old configuration missing backend -> NFS, all fields preserved")
        for backend in Configuration.Backend.allCases {
            config.backend = backend
            let roundtrip = try decode(object(config))
            try check(roundtrip.backend == backend && roundtrip.folders == [folder] && roundtrip.menuBarMode, "each backend must roundtrip without changing fields")
        }
        for invalid: Any in ["fsdisk", "smb3", "NFS", "", "unknown", "nfs,backend=smb", NSNull(), 1, true, [], [:]] {
            var input = old; input["backend"] = invalid
            var rejected = false
            do { _ = try decode(input) } catch { rejected = true }
            try check(rejected, "invalid backend must reject: \(invalid)")
        }
        print("PASS nfs/fskit/smb roundtrips; 11 unknown/malformed values rejected")
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("artifacts/backend-selector/fixtures/\(UUID().uuidString)")
        let store = try Store(root: root)
        let engine = Engine(store: store, helper: root.appendingPathComponent("must-not-launch"))
        let configurationURL = root.appendingPathComponent("configuration.json")
        let oldBytes = try JSONSerialization.data(withJSONObject: old)
        try Store.atomicData(oldBytes, configurationURL)
        let loadedOld = try store.load()
        try check(loadedOld.backend == .nfs && loadedOld.folders == [folder], "repository must load legacy JSON without migrating folder options")
        try check(try Data(contentsOf: configurationURL) == oldBytes, "reading legacy configuration must not rewrite it")
        try store.save(config)
        var journal = Journal(); journal.phase = .mounted; journal.session = UUID(); journal.socket = root.appendingPathComponent("must-not-contact.sock").path
        try store.write(journal, for: folder.id)
        let journalURL = try store.volume(folder.id).appendingPathComponent("journal.json")
        let journalBefore = try Data(contentsOf: journalURL)
        for backend in Configuration.Backend.allCases {
            let readback = try engine.setBackend(backend)
            let saved = try store.load()
            try check(readback == backend && saved.backend == backend && saved.folders == [folder] && saved.menuBarMode, "setBackend must persist and read back through repository lock")
            try check(try Data(contentsOf: journalURL) == journalBefore, "setBackend must not change live journal")
        }
        print("PASS setBackend persistence/readback preserves live journal and unrelated configuration")
        let legacyJournal = try JSONDecoder().decode(Journal.self, from: JSONEncoder().encode(Journal()))
        try check(legacyJournal.backend == nil, "legacy journal must have unknown backend")
        for backend in Configuration.Backend.allCases {
            let sessionRoot = root.appendingPathComponent("session-\(backend.rawValue)")
            try FileManager.default.createDirectory(at: sessionRoot, withIntermediateDirectories: true)
            let sessionStore = try Store(root: sessionRoot.appendingPathComponent("support"))
            let sessionEngine = Engine(store: sessionStore, helper: URL(fileURLWithPath: "/usr/bin/false"))
            let selected = sessionRoot.appendingPathComponent("original,backend=smb")
            try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
            let entry = try sessionEngine.create(path: selected, name: "Different alias", capacity: 16<<20)
            try sessionEngine.setBackend(backend)
            // Capacity failure at snapshot capture stops before evacuation/socket/launch.
            let large = selected.appendingPathComponent("oversized-fixture")
            try Data().write(to: large)
            let handle = try FileHandle(forWritingTo: large)
            try handle.truncate(atOffset: (16<<20) + 1); try handle.close()
            var failed = false
            do { try sessionEngine.mount(entry.id.uuidString) } catch { failed = true }
            try check(failed, "oversized snapshot must reject before mounting")
            let captured = try sessionStore.journal(entry.id)
            try check(captured.backend == backend && captured.session != nil && captured.phase == .idle, "Engine.mount must capture the selected backend at session preparation")
            let bytesBefore = try Data(contentsOf: sessionStore.volume(entry.id).appendingPathComponent("journal.json"))
            try sessionEngine.setBackend(backend == .smb ? .nfs : .smb)
            try check(try Data(contentsOf: sessionStore.volume(entry.id).appendingPathComponent("journal.json")) == bytesBefore, "next preference must leave recorded session unchanged")
            var prepared = captured; prepared.socket = sessionRoot.appendingPathComponent("fixture.sock").path
            let args = try sessionEngine.helperArguments(entry, journal: prepared, source: selected)
            try check(args.filter { $0 == "--backend" }.count == 1, "launch must include exactly one backend argument")
            try check(args[args.firstIndex(of: "--backend")! + 1] == backend.rawValue, "launch must use recorded backend, not next preference")
            try check(args[args.firstIndex(of: "--mount")! + 1] == entry.path, "launch must preserve original mount path")
            try check(args[args.firstIndex(of: "--compression")! + 1] == "true", "existing helper options preserved")
            try check(try large.resourceValues(forKeys: [.fileSizeKey]).fileSize == (16<<20) + 1, "preparation failure leaves source intact")
        }
        print("PASS Engine.mount captures each backend before snapshot; helper arguments retain recorded backend after preference changes, exact path/options preserved; no mounts or helper launch")
        for backend in Configuration.Backend.allCases {
            let message = backend.mountFailureMessage
            try check(message.contains("FUSE-T \(backend.displayName) did not mount"), "failure must identify selected backend")
            try check(message.contains("recover") && message.contains("does not retry"), "failure must retain recovery/no-fallback guidance")
            try check(message.contains("extension") == (backend == .fskit), "only FSKit failure should ask for FSKit extension")
        }
        print("PASS backend-specific failure messages retain recovery/no-fallback and FSKit extension guidance")
    }
}
