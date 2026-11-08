import Foundation
import Darwin
@testable import RAMNestCore

#if !RAMNEST_REVIEW_STANDALONE
import Testing

extension RAMNestTestSuite {
    struct ReviewAcceptanceTests {
        @Test func `Review acceptance scenarios`() throws { try ReviewAcceptanceRunner.main() }
    }
}
#endif

#if RAMNEST_REVIEW_STANDALONE
@main
#endif
struct ReviewAcceptanceRunner {
    static func check(_ value: @autoclosure () throws -> Bool, _ reason: String) throws {
        if try !value() { throw NestError("Review acceptance: " + reason) }
    }
    static func rejects(_ body: () throws -> Void) throws {
        do { try body() } catch { return };throw NestError("Review acceptance: expected rejection")
    }
    static func main() throws {
        #if RAMNEST_REVIEW_STANDALONE
        let parent = URL(fileURLWithPath: CommandLine.arguments[1])
        #else
        let parent = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("artifacts")
        #endif
        let base = parent.appendingPathComponent("review-swift-" + UUID().uuidString)
        try Store.privateDirectory(base)
        let source = base.appendingPathComponent("source");try Store.privateDirectory(source)
        let nested = source.appendingPathComponent("nested");try Store.privateDirectory(nested)
        let file = nested.appendingPathComponent("payload");try Data("kept".utf8).write(to: file)
        var original = stat();try check(lstat(file.path, &original)==0,"fixture stat")
        for (path,rule) in [(source,"user:laurent allow read"),(nested,"user:laurent deny write"),(file,"user:laurent allow read") ] {
            let p=Process();p.executableURL=URL(fileURLWithPath:"/bin/chmod");p.arguments=["+a",rule,path.path];try p.run();p.waitUntilExit();try check(p.terminationStatus==0,"ACL fixture")
            try rejects { _ = try Snapshot.manifest(source) }
            var after=stat();try check(lstat(file.path,&after)==0 && after.st_ino==original.st_ino && after.st_size==4,"rejection preserves identity/data")
            let clear=Process();clear.executableURL=URL(fileURLWithPath:"/bin/chmod");clear.arguments=["-N",path.path];try clear.run();clear.waitUntilExit();try check(clear.terminationStatus==0,"ACL cleanup")
        }
        try check(chmod(source.path,0o750)==0,"public root mode")
        let store=try Store(root:base.appendingPathComponent("store"));let engine=Engine(store:store)
        let folder=try engine.create(path:source,name:"public root",capacity:16<<20)
        let revision=try Snapshot.capture(store:store,folder:folder,source:source,previous:nil)
        let (data,manifest)=try Snapshot.verified(store:store,id:folder.id,revision:revision)
        var st=stat();try check(lstat(data.path,&st)==0 && st.st_mode & 0o7777 == 0o700 && manifest.publicRoot?.mode == 0o750,"physical private root and exact logical public root are independently preserved")
        let storage=try Snapshot.storedMetadata(data)
        let checkedModes=try Snapshot.checkedModes(data,storage!)
        try check(storage?.storageFormat == 2 && checkedModes != nil,"versioned, integrity-bound logical modes")
        try check(lstat(data.deletingLastPathComponent().path,&st)==0 && st.st_mode & 0o7777 == 0o700,"private revision mode")
        var legacy=manifest;legacy.publicRoot=nil
        for i in legacy.entries.indices { legacy.entries[i].allocatedBytes=nil }
        let legacyRevision=UUID().uuidString, legacyContainer=try store.volume(folder.id).appendingPathComponent("revisions/"+legacyRevision)
        try Store.privateDirectory(legacyContainer)
        try Snapshot.copyTree(from:source,to:legacyContainer.appendingPathComponent("data"),manifest:manifest,publicationStaging:true)
        try Store.atomicJSON(legacy,legacyContainer.appendingPathComponent("manifest.json"))
        _ = try Snapshot.verified(store:store,id:folder.id,revision:legacyRevision)
        print("PASS item2 root/nested/file ACL rejection with original identity/content, public root mode, private container, legacy manifest")
        let sparse=source.appendingPathComponent("sparse");let fd=open(sparse.path,O_RDWR|O_CREAT|O_EXCL,0o600);try check(fd>=0,"sparse create");defer{close(fd)}
        try check(pwrite(fd,"x",1,Int64(8)<<30)==1,"high sparse offset")
        let sparseManifest=try Snapshot.manifest(source,maximumLogical:16<<20);try sparseManifest.preflight(capacity:16<<20)
        try check(sparseManifest.allocatedEstimate<4*65536,"allocated sparse quota")
        let sparseCopy=base.appendingPathComponent("sparse-copy");try Snapshot.copyTree(from:source,to:sparseCopy,manifest:sparseManifest)
        try check(try Snapshot.manifest(sparseCopy)==sparseManifest,"sparse copy integrity")
        // Both comparison preferences must converge after content and metadata edits.
        let old=base.appendingPathComponent("old");try Snapshot.copyTree(from:source,to:old,manifest:sparseManifest)
        var before=stat();try check(lstat(file.path,&before)==0,"reuse stat")
        try Data("EDIT".utf8).write(to:file);var times=[before.st_atimespec,before.st_mtimespec];try check(utimensat(AT_FDCWD,file.path,&times,AT_SYMLINK_NOFOLLOW)==0 && chmod(file.path,0o640)==0,"same-size/mtime edit")
        try check("new".withCString { setxattr(file.path,"user.current",$0,3,0,0) }==0 && lchflags(file.path,UInt32(UF_HIDDEN|UF_NODUMP))==0,"current metadata")
        for mode in Comparison.allCases {
            let current=try Snapshot.manifest(source)
            let dest=base.appendingPathComponent("reuse-"+mode.rawValue)
            try Snapshot.copyTree(from:source,to:dest,manifest:current,previous:old,comparison:mode)
            try check(try Snapshot.manifest(dest)==current,"reuse current exact data and metadata")
        }
        print("PASS items5/6 8GiB apparent sparse copy/preflight, legacy compatibility, same-size/mtime bytes plus mode/xattrs/flags in both preferences")
        let aliases=base.appendingPathComponent("aliases");try Store.privateDirectory(aliases)
        let large=aliases.appendingPathComponent("0-anchor");try Data(repeating:65,count:2<<20).write(to:large)
        for i in 1...16 { try FileManager.default.linkItem(at:large,to:aliases.appendingPathComponent("alias-\(i)")) }
        let trace=base.appendingPathComponent("hash.jsonl")
        let links = try { () throws -> Manifest in
            let previous = getenv("RAMNEST_HASH_TRACE").map { String(cString: $0) }
            try check(setenv("RAMNEST_HASH_TRACE", trace.path, 1) == 0, "set owned hash trace")
            defer {
                if let previous { setenv("RAMNEST_HASH_TRACE", previous, 1) }
                else { unsetenv("RAMNEST_HASH_TRACE") }
            }
            return try Snapshot.manifest(aliases, phase: "hardlink-proof")
        }()
        let event=try JSONSerialization.jsonObject(with:Data(contentsOf:trace)) as! [String:Any]
        try check((event["bytesRead"] as? Int)==2<<20 && (event["hardlinkDigestsReused"] as? Int)==16,"one stable inode digest per walk")
        try check(links.allocatedEstimate<UInt64(3<<20),"aliases not charged twice")
        print("PASS item7 17 aliases: 2MiB read instead of 34MiB, 16 inode-stable cache hits; independent manifests/readback retained")
        let coordinatorRoot=base.appendingPathComponent("coordinator");try Store.privateDirectory(coordinatorRoot)
        try coordinator(coordinatorRoot)
        try volumes(base.appendingPathComponent("volumes"))
        print("PASS review Swift acceptance; fixtures: \(base.path)")
    }
    static func coordinator(_ root: URL) throws {
        let f=try LatestSnapshotScenarios.Fixture(root,"normal-eject")
        var boundary=f.helper.boundary;boundary.unmount={ _ in f.helper.mounted=false }
        let engine=Engine(store:f.store,session:boundary)
        try engine.unmount(f.folder.id.uuidString,ignoreBusy:true)
        try check(f.helper.commands.filter{$0=="quiesce"}.count==1,"successful eject performs exactly one quiesce/export")
        let failed=try LatestSnapshotScenarios.Fixture(root,"failed-eject")
        var fail=failed.helper.boundary;fail.unmount={ _ in throw NestError("injected unmount failure") }
        try rejects { try Engine(store:failed.store,session:fail).unmount(failed.folder.id.uuidString,ignoreBusy:true) }
        let j=try failed.store.journal(failed.folder.id)
        try check(j.phase == .mounted && j.quiescedRevision == nil && failed.helper.commands.contains("thaw"),"failed eject invalidates quiesced receipt before thaw")
        _ = try failed.save("changed-after-thaw")
        try failed.finish()
        try check(failed.helper.commands.filter{$0=="quiesce"}.count==2,"retry captures newer data")
        print("PASS item8 successful eject one quiesce; failed unmount/thaw invalidates receipt, write/save/finalize captures newer generation")
    }
    final class Gate: @unchecked Sendable {
        let status=DispatchSemaphore(value:0),entered=DispatchSemaphore(value:0),release=DispatchSemaphore(value:0),done=DispatchSemaphore(value:0),second=DispatchSemaphore(value:0)
        let lock=NSLock();var failures:[String]=[]
        func failure(_ error: Error){lock.lock();failures.append(error.localizedDescription);lock.unlock()}
    }
    static func volumes(_ root: URL) throws {
        try Store.privateDirectory(root);let store=try Store(root:root.appendingPathComponent("store")),gate=Gate()
        var folders:[Folder]=[],live:[String:URL]=[:]
        for i in 1...2 {
            let selected=root.appendingPathComponent("selected\(i)");try Store.privateDirectory(selected)
            let identity=try DirectoryHandle.open(selected).identity()
            let f=Folder(name:"volume\(i)",path:selected.path,capacity:16<<20,device:identity.device,inode:identity.inode);folders.append(f)
            try Data("payload\(i)".utf8).write(to:selected.appendingPathComponent("payload"))
            let initial=try Snapshot.capture(store:store,folder:f,source:selected,previous:nil)
            let ram=root.appendingPathComponent("live\(i)");try Store.privateDirectory(ram);try FileManager.default.moveItem(at:selected.appendingPathComponent("payload"),to:ram.appendingPathComponent("payload"));live["owned-\(i)"]=ram
            var j=Journal();j.phase = .mounted;j.populationVerified=true;j.revision=initial;j.initialRevision=initial;j.socket="owned-\(i)";try store.write(j,for:f.id)
        }
        var c=Configuration();c.folders=folders;try store.save(c)
        let session=EngineSession(request:{ socket,command in
            let fields=command.components(separatedBy:"\t")
            if fields[0]=="export" {
                if socket=="owned-1" { gate.entered.signal();guard gate.release.wait(timeout:.now()+10) == .success else { throw NestError("export gate timeout") } }
                guard let source=live[socket] else { throw NestError("unknown fixture") }
                try Snapshot.copyTree(from:source,to:URL(fileURLWithPath:fields[1]),manifest:Snapshot.manifest(source))
            };return []
        },status:{ j,id in HelperStatus(id:id,pid:getpid(),mounted:true,used:0,capacity:16<<20,active:true) },mountedIdentity:{_,_ in true})
        let engine=Engine(store:store,session:session),first=folders[0].id.uuidString,second=folders[1].id.uuidString
        let work = DispatchGroup()
        // Drain every callback even if an earlier bounded observation fails.
        // A confirmation would count callbacks but would not wait for them.
        defer { gate.release.signal(); work.wait() }
        DispatchQueue.global().async(group: work) { do{try engine.save(first)}catch{gate.failure(error)};gate.done.signal() }
        try check(gate.entered.wait(timeout:.now()+5) == .success,"first volume export entered")
        let started=ProcessInfo.processInfo.systemUptime
        DispatchQueue.global().async(group: work) { do { _ = try engine.statuses() } catch { gate.failure(error) };gate.status.signal() }
        let statusResult=gate.status.wait(timeout:.now()+5)
        DispatchQueue.global().async(group: work) { do{try engine.save(second)}catch{gate.failure(error)};gate.second.signal() }
        let result=gate.second.wait(timeout:.now()+5)
        gate.release.signal(); work.wait()
        try check(gate.done.wait(timeout:.now()+5) == .success,"first save completed")
        try check(statusResult == .success && result == .success && gate.failures.isEmpty,"independent volume completes while first export blocked: \(gate.failures)")
        print("PASS item10 two volumes in same store: status and second save progress while first export paused; seconds=\(ProcessInfo.processInfo.systemUptime-started)")
    }
}
