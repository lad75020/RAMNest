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
        @Test func `Legacy fresh export exclusion`() throws { try TrashScenarios.legacyExport() }
        @Test func `Cross boundary hardlinks`() throws { try TrashScenarios.crossBoundary() }
    }
}
#endif
enum TrashScenarios {
    static func check(_ ok: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !ok() { throw NestError("TRASH: " + message) }
    }
    static func root() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["RAMNEST_TRASH_TEST_ROOT"] else { throw NestError("Owned test root required") }
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
    static func legacyExport() throws {
        let r = try root(), store = try Store(root:r.appendingPathComponent("store")), selected = r.appendingPathComponent("selected")
        try Store.privateDirectory(selected);let identity = try DirectoryHandle.open(selected).identity()
        let f = Folder(name:"legacy-trash",path:selected.path,capacity:16<<20,device:identity.device,inode:identity.inode)
        let stage = try store.volume(f.id).appendingPathComponent("stage-"+UUID().uuidString)
        try Store.privateDirectory(stage.appendingPathComponent("normal/.Trashes"))
        try Store.privateDirectory(stage.appendingPathComponent(".Trashes"))
        try Data("ignored legacy Trash".utf8).write(to:stage.appendingPathComponent(".Trashes/sentinel"))
        try Data("ignored nested legacy Trash".utf8).write(to:stage.appendingPathComponent("normal/.Trashes/sentinel"))
        try Data("included".utf8).write(to:stage.appendingPathComponent("normal/payload"))
        try check(chmod(stage.appendingPathComponent(".Trashes").path,0o311) == 0 && chmod(stage.appendingPathComponent("normal/.Trashes").path,0) == 0,"legacy opaque")
        let before = try evidence(stage.appendingPathComponent(".Trashes"))
        let revision = try Snapshot.adoptExport(store:store,folder:f,stage:stage)
        let (data,m) = try Snapshot.verified(store:store,id:f.id,revision:revision)
        try check(m.entries.map(\.path) == ["normal","normal/payload"] && !FileManager.default.fileExists(atPath:data.appendingPathComponent(".Trashes").path),"new revision omits legacy physical Trash")
        try check(try evidence(stage.appendingPathComponent(".Trashes")) == before && FileManager.default.fileExists(atPath:stage.path+".trash-retained.json"),"legacy stage retained without Trash mutation and durable location")
        print("PASS legacy fresh export skips before normalization and copies an exact filtered revision; opaque stage retained")
    }
    static func crossBoundary() throws {
        let r = try root(), stageParent = r.appendingPathComponent("volume"), stage = stageParent.appendingPathComponent("stage-"+UUID().uuidString)
        try Store.privateDirectory(stage.appendingPathComponent(".Trashes"))
        let outside = r.appendingPathComponent("outside")
        try Data("must stay read-only".utf8).write(to:outside);try check(chmod(outside.path,0o400) == 0,"outside mode")
        try check(link(outside.path,stage.appendingPathComponent("alias").path) == 0,"outside alias")
        let before = try evidence(outside)
        try rejects { _ = try StorageModes.normalizeFreshExport(stage,volume:stageParent) }
        try check(try evidence(outside) == before,"outside inode mode/ctime never widened")
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
        print("PASS original cross-boundary alias copies safely; fresh normalization with outside inode fails before chmod")
    }
    static func lifecycle() throws {
        let r = try root(),source = r.appendingPathComponent("source"),store = try Store(root:r.appendingPathComponent("store"))
        try Store.privateDirectory(source.appendingPathComponent("normal/.Trashes"));try Store.privateDirectory(source.appendingPathComponent(".Trashes"))
        for path in [".Trashes/sentinel","normal/.Trashes/sentinel","normal/payload"] { try Data(path.utf8).write(to:source.appendingPathComponent(path)) }
        try check(chmod(source.appendingPathComponent(".Trashes").path,0o311) == 0 && chmod(source.appendingPathComponent("normal/.Trashes").path,0) == 0,"opaque original")
        try check(link(source.appendingPathComponent("normal/payload").path,source.appendingPathComponent("alias").path) == 0,"normal links")
        let attribute = Data("included lifecycle metadata".utf8)
        try check(attribute.withUnsafeBytes { setxattr(source.appendingPathComponent("alias").path,"user.lifecycle",$0.baseAddress,$0.count,0,0) } == 0,"included lifecycle xattr")
        let f = try Engine(store:store).create(path:source,name:"lifecycle",capacity:16<<20)
        let expected = try Snapshot.manifest(source)
        var firstHolding: URL?,trashEvidence: [String] = []
        for cycle in 0..<3 {
            let revision = try Snapshot.capture(store:store,folder:f,source:source,previous:try store.journal(f.id).revision)
            let (data,m) = try Snapshot.verified(store:store,id:f.id,revision:revision)
            var j = try store.journal(f.id);j.session = UUID();j.initialRevision = revision;j.revision = revision;j.populationVerified = false;j.socket = "simulated-owned-session";j.phase = .preparing
            try store.write(j,for:f.id)
            var boundary = EngineSession(),mounted = true
            boundary.mountedIdentity = { _,_ in true }
            boundary.status = { _,id in HelperStatus(id:id,pid:getpid(),mounted:mounted,used:0,capacity:16<<20,active:true) }
            boundary.populationRead = { _ in try Snapshot.manifest(data,context:.managedRevision) }
            boundary.unmount = { _ in mounted = false }
            boundary.request = { _,command in
                let fields = command.components(separatedBy:"\t")
                if fields[0] == "capabilities" { return [] }
                if fields[0] == "export" || fields[0] == "quiesce" {
                    try Snapshot.copyTree(from:data,to:URL(fileURLWithPath:fields[1]),manifest:m,publicationStaging:true,sourceContext:.managedRevision)
                }
                return []
            }
            let engine = Engine(store:store,session:boundary)
            let (selected,holding) = try engine.evacuateOriginal(f,journal:&j,expected:m)
            if cycle == 0 {
                firstHolding = holding
                trashEvidence = try [".Trashes","normal/.Trashes"].map { try evidence(holding.appendingPathComponent($0)) }
                try check(j.evacuatedEntries.contains(".Trashes"),"opaque root Trash included in durable evacuation journal")
            }
            try engine.verifyAndActivatePopulation(f,journal:&j,expected:m,source:selected,original:holding)
            try engine.save(f.id.uuidString);try engine.unmount(f.id.uuidString,ignoreBusy:true)
            let idle = try store.journal(f.id)
            try check(idle.phase == .idle && !idle.siblingCleanup!.isEmpty && idle.cleanupWarning?.contains(firstHolding!.path) == true,"idle nonfatal warning with durable original recovery location")
            try check(try Snapshot.manifest(source).matchesExpected(expected),"included restore exact cycle \(cycle)")
            try check(try [".Trashes","normal/.Trashes"].map { try evidence(firstHolding!.appendingPathComponent($0)) } == trashEvidence,"original excluded holdings immutable across repeated retirement")
        }
        // Journal a normal evacuation then recover before activation. Rollback
        // moves originals back, and never equates a filtered view with emptiness.
        var j = try store.journal(f.id);j.session = UUID();j.initialRevision = j.revision;j.populationVerified = false;j.phase = .preparing
        let engine = Engine(store:store);_ = try engine.evacuateOriginal(f,journal:&j,expected:expected)
        j.phase = .recoveryRequired;j.socket = nil;try store.write(j,for:f.id)
        try engine.recover(f.id.uuidString)
        try check(try Snapshot.manifest(source).matchesExpected(expected),"pre-activation rollback exact")
        print("PASS simulated activation/save/eject plus two remount cycles; pinned opaque originals retained with warning; pre-activation rollback")
    }
}
#if RAMNEST_TRASH_STANDALONE
@main struct TrashRunner {
    static func main() { do { try TrashScenarios.capture();try TrashScenarios.oldRevisions();try TrashScenarios.holding();try TrashScenarios.legacyExport();try TrashScenarios.crossBoundary();try TrashScenarios.lifecycle() } catch { print("FAIL \(error)");exit(1) } }
}
#endif
