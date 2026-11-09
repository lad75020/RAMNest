import Foundation
import Darwin
@testable import RAMNestCore
#if !RAMNEST_TRASH_STANDALONE
import Testing
extension RAMNestTestSuite {
    struct TrashExclusionTests {
        @Test func `Exact directory capture`() throws { try TrashScenarios.capture() }
        @Test func `Old revision views`() throws { try TrashScenarios.oldRevisions() }
        @Test func `Original holding retention`() throws { try TrashScenarios.holding() }
        @Test func `Owned simulated lifecycle and rollback`() throws { try TrashScenarios.lifecycle() }
        @Test func `Cross boundary hardlinks`() throws { try TrashScenarios.crossBoundary() }
    }
}
#endif
enum TrashScenarios {
    static func check(_ ok: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !ok() { throw NestError("TRASH: " + message) }
    }
    static func root() throws -> URL {
        let path = ProcessInfo.processInfo.environment["RAMNEST_TRASH_TEST_ROOT"] ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("artifacts/trash-tests").path
        let url = URL(fileURLWithPath:path).appendingPathComponent(UUID().uuidString)
        try Store.privateDirectory(url);return url
    }
    static func evidence(_ url: URL) throws -> String {
        var s = stat();try check(lstat(url.path,&s) == 0,"lstat")
        return "\(s.st_dev):\(s.st_ino):\(s.st_mode):\(s.st_ctimespec.tv_sec):\(s.st_ctimespec.tv_nsec)"
    }
    static func rejects(_ f: () throws -> Void) throws {
        var failed = false;do { try f() } catch { failed = true };try check(failed,"must reject")
    }
    static func capture() throws {
        let r = try root(), source = r.appendingPathComponent("source"), store = try Store(root:r.appendingPathComponent("store"))
        try Store.privateDirectory(source)
        let outside = r.appendingPathComponent("outside");try Store.privateDirectory(outside)
        try Data("outside sentinel".utf8).write(to:outside.appendingPathComponent("sentinel"));try check(chmod(outside.path,0) == 0,"opaque symlink target")
        let outsideBefore = try evidence(outside)
        for path in [".Trashes","normal/.Trashes"] {
            let d = source.appendingPathComponent(path);try Store.privateDirectory(d)
            try Data("never captured".utf8).write(to:d.appendingPathComponent("sentinel"))
            try check(chmod(d.path,path == ".Trashes" ? 0o311 : 0) == 0,"restrict Trash")
        }
        let names = ["normal/payload",".trashes",".Trash",".TrashesBackup","file/.Trashes"]
        try Store.privateDirectory(source.appendingPathComponent("file"));try Store.privateDirectory(source.appendingPathComponent("link"))
        for name in names { try Data(name.utf8).write(to:source.appendingPathComponent(name)) }
        try check(symlink("../../outside",source.appendingPathComponent("link/.Trashes").path) == 0,"symlink")
        try check(link(source.appendingPathComponent("normal/payload").path,source.appendingPathComponent("alias").path) == 0,"hardlink")
        let bytes = Data("metadata".utf8)
        try check(bytes.withUnsafeBytes { setxattr(source.appendingPathComponent("alias").path,"user.trash-test",$0.baseAddress,$0.count,0,0) } == 0,"xattr")
        let before = try [".Trashes","normal/.Trashes"].map { try evidence(source.appendingPathComponent($0)) }
        let f = try Engine(store:store).create(path:source,name:"trash",capacity:16<<20)
        let rev = try Snapshot.capture(store:store,folder:f,source:source,previous:nil)
        let (data,m) = try Snapshot.verified(store:store,id:f.id,revision:rev)
        try check(!m.entries.contains { $0.path == ".Trashes" || $0.path.hasPrefix(".Trashes/") || $0.path.hasPrefix("normal/.Trashes") },"only excluded directories omitted")
        for name in names + ["link/.Trashes","alias"] { try check(m.entries.contains { $0.path == name },"near-name/file/link survives: " + name) }
        try check(m.entries.first { $0.path == "alias" }?.attributes["user.trash-test"] == Snapshot.digest(bytes),"included xattr")
        let exported = r.appendingPathComponent("export")
        try Engine(store:store).export(f.id.uuidString,destination:exported,revision:rev)
        try check(try Snapshot.manifest(exported).matchesExpected(m),"public export exact")
        try check(try Snapshot.manifest(data,context:.managedRevision) == m,"private view exact")
        try check(try [".Trashes","normal/.Trashes"].map { try evidence(source.appendingPathComponent($0)) } == before,"original Trash unchanged")
        try check(try evidence(outside) == outsideBefore,"symlink .Trashes never follows or mutates its opaque outside target")
        for name in [".trashes",".Trash",".TrashesBackup"] {
            let near = r.appendingPathComponent(UUID().uuidString),directory = near.appendingPathComponent(name)
            try Store.privateDirectory(directory);try check(chmod(directory.path,0o311) == 0,"near-case refusal fixture")
            let unchanged = try evidence(directory)
            try rejects { _ = try Snapshot.manifest(near) }
            try check(try evidence(directory) == unchanged,"near-case directory stays strict and unchanged")
        }
        let unreadable = source.appendingPathComponent("ordinary-unreadable");try Store.privateDirectory(unreadable)
        try check(chmod(unreadable.path,0o311) == 0,"ordinary restrict")
        var rejected = false
        do { _ = try Snapshot.manifest(source) }
        catch { rejected = true;try check(!error.localizedDescription.contains("Legacy restrictive") && !error.localizedDescription.contains(r.path),"ordinary phase diagnostic") }
        try check(rejected,"ordinary unreadable source fails closed")
        print("PASS exact directory admission/capture/export; case/file/symlink, xattr/hardlinks, immutable Trash, ordinary refusal")
    }
    static func oldRevisions() throws {
        for v2 in [false,true] {
            let r = try root(), source = r.appendingPathComponent("seed"), store = try Store(root:r.appendingPathComponent("store")), id = UUID(), revision = UUID().uuidString
            try Store.privateDirectory(source.appendingPathComponent("seed/nested"))
            try Data("old ignored bytes".utf8).write(to:source.appendingPathComponent("seed/nested/payload"))
            try Data("included".utf8).write(to:source.appendingPathComponent("payload"))
            try check(chmod(source.appendingPathComponent("payload").path,0o600) == 0 && chmod(source.appendingPathComponent("seed/nested/payload").path,0o600) == 0,"physical files")
            var m = try Snapshot.manifest(source)
            for i in m.entries.indices where m.entries[i].path == "seed" || m.entries[i].path.hasPrefix("seed/") { m.entries[i].path = ".Trashes" + m.entries[i].path.dropFirst(4) }
            m.entries.sort { $0.path < $1.path }
            let container = try store.volume(id).appendingPathComponent("revisions/" + revision);try Store.privateDirectory(container)
            try FileManager.default.moveItem(at:source.appendingPathComponent("seed"),to:source.appendingPathComponent(".Trashes"))
            let data = container.appendingPathComponent("data");try FileManager.default.moveItem(at:source,to:data)
            if v2 { let modes = try StorageModes(m);try modes.write(container.appendingPathComponent("modes.bin"));try Store.atomicJSON(StoredManifest(m,modes:modes),container.appendingPathComponent("manifest.json")) }
            else { try Store.atomicJSON(m,container.appendingPathComponent("manifest.json")) }
            // Opaque directory must be skipped even in an old checkpoint. No rewrite.
            try check(chmod(data.appendingPathComponent(".Trashes").path,0) == 0,"old opaque Trash")
            let before = try evidence(data.appendingPathComponent(".Trashes")), manifestBytes = try Data(contentsOf:container.appendingPathComponent("manifest.json"))
            let metadataPaths = [container,data,container.appendingPathComponent("manifest.json")] + (v2 ? [container.appendingPathComponent("modes.bin")] : [])
            let metadataEvidence = try metadataPaths.map(evidence)
            let mapBytes = v2 ? try Data(contentsOf:container.appendingPathComponent("modes.bin")) : nil
            let (_,view) = try Snapshot.verified(store:store,id:id,revision:revision)
            try check(view.entries.map(\.path) == ["payload"],"old filtered view")
            let f = Folder(name:"old-view",path:data.path,capacity:16<<20,device:0,inode:0)
            let copied = try Snapshot.capture(store:store,folder:f,source:data,previous:nil,sourceContext:.managedRevision)
            let (newData,newView) = try Snapshot.verified(store:store,id:f.id,revision:copied)
            try check(newView == view && Snapshot.excludedDirectoryPaths(newData).isEmpty,"new revision coherently omits old physical Trash and map entries")
            try check(try evidence(data.appendingPathComponent(".Trashes")) == before && Data(contentsOf:container.appendingPathComponent("manifest.json")) == manifestBytes,"old immutable")
            try check(try metadataPaths.map(evidence) == metadataEvidence,"old root/container/manifest/map inode, mode and ctime immutable through view and recapture")
            if let bytes = mapBytes { try check(try Data(contentsOf:container.appendingPathComponent("modes.bin")) == bytes,"old full mode-map bytes immutable") }
            if v2 {
                var changed = m;changed.entries[0].mode ^= 1
                let fullModes = try StorageModes(m)
                try Store.atomicJSON(StoredManifest(changed,modes:fullModes),container.appendingPathComponent("manifest.json"))
                try rejects { _ = try Snapshot.verified(store:store,id:id,revision:revision) }
                try Store.atomicData(manifestBytes,container.appendingPathComponent("manifest.json"))
            }
            try Data("corrupt".utf8).write(to:data.appendingPathComponent("payload"))
            try rejects { _ = try Snapshot.verified(store:store,id:id,revision:revision) }
        }
        print("PASS immutable old legacy/V2 excluded views and included corruption rejection")
    }
    static func holding() throws {
        let r = try root(), holding = r.appendingPathComponent("holding")
        try Store.privateDirectory(holding.appendingPathComponent("normal/.Trashes"))
        let trash = holding.appendingPathComponent("normal/.Trashes")
        try Data("preexisting disk data".utf8).write(to:trash.appendingPathComponent("sentinel"));try check(chmod(trash.path,0) == 0,"opaque")
        let before = try evidence(trash)
        try rejects { _ = try DirectoryHandle.open(holding).cleanupInventory() }
        try check(try evidence(trash) == before,"cleanup never opens/mutates excluded disk Trash")
        print("PASS original holding exclusion refuses deletion before opaque subtree access")
    }
    static func crossBoundary() throws {
        let r = try root(), stageParent = r.appendingPathComponent("volume"), stage = stageParent.appendingPathComponent("stage-"+UUID().uuidString)
        try Store.privateDirectory(stage.appendingPathComponent(".Trashes"))
        let outside = r.appendingPathComponent("outside")
        try Data("must stay read-only".utf8).write(to:outside);try check(chmod(outside.path,0o400) == 0,"outside mode")
        try check(link(outside.path,stage.appendingPathComponent("alias").path) == 0,"outside alias")
        let before = try evidence(outside)
        try rejects { _ = try Snapshot.scanManifest(stage, containedHardlinks: true) }
        try check(try evidence(outside) == before, "outside hardlink never authorizes metadata mutation")
        let source = r.appendingPathComponent("source"),store = try Store(root:r.appendingPathComponent("store"))
        try Store.privateDirectory(source.appendingPathComponent(".Trashes"))
        let payload = source.appendingPathComponent(".Trashes/payload")
        try Data("included alias".utf8).write(to:payload);try check(link(payload.path,source.appendingPathComponent("alias").path) == 0,"boundary alias")
        let saved = try evidence(payload)
        let f = try Engine(store:store).create(path:source,name:"cross",capacity:16<<20)
        let rev = try Snapshot.capture(store:store,folder:f,source:source,previous:nil)
        let (data,m) = try Snapshot.verified(store:store,id:f.id,revision:rev)
        try check(m.entries.map(\.path) == ["alias"] && Data(contentsOf:data.appendingPathComponent("alias")) == Data("included alias".utf8),"original cross-boundary alias safely copied")
        try check(try evidence(payload) == saved,"original cross-boundary source unchanged")
        // Committed physical normalization requires a contained namespace.
        // Adding an excluded hardlink cannot authorize widening an outside inode.
        try Store.privateDirectory(data.appendingPathComponent(".Trashes"))
        try check(link(data.appendingPathComponent("alias").path,data.appendingPathComponent(".Trashes/alias").path) == 0,"old private boundary link")
        let committed = try evidence(data.appendingPathComponent("alias"))
        try rejects { _ = try Snapshot.verified(store:store,id:f.id,revision:rev) }
        try check(try evidence(data.appendingPathComponent("alias")) == committed,"old private boundary fails without mutation")
        print("PASS original cross-boundary alias copies safely; private-tree outside hardlink fails without metadata mutation")
    }
    static func lifecycle() throws {
        let r = try root()
        let f = try LinkedTransactionDataFixture(r, "trash", temporary: true)
        let opaque = f.selected.appendingPathComponent(".Trashes")
        try Store.privateDirectory(opaque); try Data("retained opaque".utf8).write(to: opaque.appendingPathComponent("sentinel"))
        let before = try evidence(opaque)
        try f.prepare()
        _ = try f.evacuate()
        try f.publish()
        try f.discardWorkingCopy()
        try f.engine.recover(f.folder.id.uuidString)
        try check(try evidence(opaque) == before, "temporary whole-root rollback retains opaque Trash and original inode")
    }

}
#if RAMNEST_TRASH_STANDALONE
@main struct TrashRunner {
    static func main() { do { try TrashScenarios.capture();try TrashScenarios.oldRevisions();try TrashScenarios.holding();try TrashScenarios.crossBoundary();try TrashScenarios.lifecycle() } catch { print("FAIL \(error)");exit(1) } }
}
#endif
