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
        print("PASS snapshot ACL, public-root and hardlink hashing acceptance; native checkpoint ordering is covered separately")
    }
}
