import Foundation
import Darwin
@testable import RAMNestCore
#if !RAMNEST_STORAGE_STANDALONE
import Testing
extension RAMNestTestSuite {
    struct StorageFormatTests {
        @Test(arguments: [false, true])
        func `Native export adoption`(privateFormat: Bool) throws { try StorageFormatScenarios.nativeAdoption(privateFormat: privateFormat) }
        @Test func `Storage format tamper rejection`() throws { try StorageFormatScenarios.tampering() }
        @Test func `Original and committed immutability`() throws { try StorageFormatScenarios.immutability() }
        @Test(arguments: [true, false])
        func `Helper save and dirty eject`(legacy: Bool) throws { try StorageFormatScenarios.coordinator(legacy: legacy) }
        @Test func `Process exit publication recovery`() throws { try StorageFormatScenarios.crashRecovery() }
        @Test func `Restrictive public export receipt`() throws { try StorageFormatScenarios.publicExport() }
        @Test func `Unreadable original admission fails unchanged`() throws { try StorageFormatScenarios.unreadableOriginal() }
        @Test func `Readable read only directory publication`() throws { try StorageFormatScenarios.readOnlyDirectoryRestore() }
        @Test func `Fresh logical mode receipt binding`() throws { try StorageFormatScenarios.freshModeReceipt() }
        @Test func `Legacy helper does not read incompatible prior payload`() throws { try StorageFormatScenarios.legacyBadPrior() }
        @Test func `Rootless legacy copy export restore`() throws { try StorageFormatScenarios.rootlessLegacy() }
        @Test func `Ordinary source has no reserved path shape`() throws { try StorageFormatScenarios.sourceNames() }
        @Test func `Fresh normalization pins before mutation`() throws { try StorageFormatScenarios.normalizationReplacement() }
        @Test func `Unpinnable legacy export fails closed`() throws { try StorageFormatScenarios.unpinnableLegacy() }
        @Test func `Old private helper gets no filtered prior`() throws { try StorageFormatScenarios.policyCapability() }
    }
}
#endif
enum StorageFormatScenarios {
    static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw NestError("STORAGE: " + message) }
    }
    static func root(_ label: String) throws -> URL {
        guard let path=ProcessInfo.processInfo.environment["RAMNEST_STORAGE_TEST_ROOT"] else { throw NestError("Explicit owned storage test root required") }
        let root=URL(fileURLWithPath:path).appendingPathComponent(label+"-"+UUID().uuidString)
        try Store.privateDirectory(root);return root
    }
    struct Fixture {
        let root: URL, selected: URL, store: Store, folder: Folder
        init(_ label: String) throws {
            root=try StorageFormatScenarios.root(label);selected=root.appendingPathComponent("selected");try Store.privateDirectory(selected)
            store=try Store(root:root.appendingPathComponent("store"))
            let identity=try DirectoryHandle.open(selected).identity()
            folder=Folder(name:label,path:selected.path,capacity:16<<20,device:identity.device,inode:identity.inode)
            var c=Configuration();c.folders=[folder];try store.save(c)
        }
        func adopt(_ privateFormat: Bool = false) throws -> (String,URL,Manifest) {
            guard let native=ProcessInfo.processInfo.environment["RAMNEST_STORAGE_FIXTURE"] else { throw NestError("native fixture required") }
            let stage=try store.volume(folder.id).appendingPathComponent("stage-"+UUID().uuidString)
            let p=Process(),output=Pipe();p.executableURL=URL(fileURLWithPath:native);p.arguments=[stage.path]+(privateFormat ? ["private"] : []);p.standardOutput=output;try p.run();p.waitUntilExit()
            let lines=String(decoding:try output.fileHandleForReading.readToEnd() ?? Data(),as:UTF8.self).split(separator:"\n")
            let modeDigest=lines.first{$0.hasPrefix("modes-digest=")}.map{String($0.dropFirst(13))}
            try check(p.terminationStatus==0,"actual native export")
            let revision=try Snapshot.adoptExport(store:store,folder:folder,stage:stage,privateStorage:privateFormat,modeMapDigest:modeDigest)
            let (data,manifest)=try Snapshot.verified(store:store,id:folder.id,revision:revision)
            return (revision,data,manifest)
        }
    }
    static func nativeAdoption(privateFormat: Bool = false) throws {
        let f=try Fixture(privateFormat ? "private-native" : "old-native")
        let (revision,data,manifest)=try f.adopt(privateFormat)
        try validatePayload(data,manifest,exactNativeSymlinkModes:privateFormat,legacyPinnable:!privateFormat)
        let before=try fingerprint(data)
        if ProcessInfo.processInfo.environment["RAMNEST_STORAGE_COLD_RUNNER"] != nil {
            let p=Process();p.executableURL=URL(fileURLWithPath:ProcessInfo.processInfo.environment["RAMNEST_STORAGE_COLD_RUNNER"]!)
            p.arguments=["cold",f.store.root.path,f.folder.id.uuidString,revision];try p.run();p.waitUntilExit();try check(p.terminationStatus==0,"cold process verification")
        }
        try check(try fingerprint(data)==before,"cold verification preserves committed identity/mode/uid/gid/ctime/hash")
        print("PASS native restrictive export/adopt/cold verified (private=\(privateFormat)): \(revision)")
    }
    static func validatePayload(_ data: URL, _ manifest: Manifest, exactNativeSymlinkModes: Bool = true, legacyPinnable: Bool = false) throws {
        try check(manifest.publicRoot?.mode==(legacyPinnable ? 0o311 : 0),"restricted root mode preserved")
        try check(manifest.entries.first{$0.path=="RestrictedData"}?.mode==0o311,"Trash mode preserved")
        try check(manifest.entries.first{$0.path=="RestrictedData/nested/payload"}?.mode==(legacyPinnable ? 0o311 : 0),"file mode preserved")
        try check(manifest.entries.first{$0.path=="RestrictedData/nested"}?.mode==(legacyPinnable ? 0o311 : 0),"nested directory logical mode preserved")
        try check(try Data(contentsOf:data.appendingPathComponent("RestrictedData/nested/payload"))==Data("real trash payload".utf8),"nonempty nested payload readable in private storage")
        try check(manifest.entries.first{$0.path=="RestrictedData"}?.attributes["user.trash"]==Snapshot.digest(Data("directory metadata".utf8)),"Trash xattr preserved")
        var a=stat(),b=stat();try check(lstat(data.appendingPathComponent("alias").path,&a)==0 && lstat(data.appendingPathComponent("RestrictedData/nested/payload").path,&b)==0 && a.st_ino==b.st_ino,"hardlink namespace preserved")
        try check(manifest.entries.first{$0.path=="write-only"}?.mode==0o200,"write-only regular mode")
        if manifest.entries.contains(where:{$0.path=="exec-only"}) {
            try check(manifest.entries.first{$0.path=="exec-only"}?.mode==0o100 && Data(contentsOf:data.appendingPathComponent("exec-only"))==Data("executable data".utf8),"legacy execute-only file pinned with O_EXEC and exact payload/mode preserved")
        }
        try check(try FileManager.default.destinationOfSymbolicLink(atPath:data.appendingPathComponent("target").path)=="RestrictedData/nested/payload","symlink target preserved without following")
        if manifest.entries.contains(where:{$0.path=="modes.bin"}) {
            try check(try Data(contentsOf:data.appendingPathComponent("modes.bin"))==Data("user mode-map name".utf8) && Data(contentsOf:data.appendingPathComponent("manifest.json"))==Data("user manifest name".utf8),"user names never collide with out-of-namespace storage metadata")
        }
        if let zeroLink=manifest.entries.first(where:{$0.path=="zero-link"}) {
            try check((!exactNativeSymlinkModes || zeroLink.mode==0) && zeroLink.attributes["com.apple.quarantine"]==Snapshot.digest(Data("0081;65000000;RAMNestStorage;".utf8)),"restrictive symlink logical mode (v2) and exact no-follow quarantine")
        }
    }
    static func fingerprint(_ data: URL) throws -> [String:String] {
        // Deliberately observe PHYSICAL storage for the immutability proof;
        // logical managed observations must request .managedRevision explicitly.
        let m=try Snapshot.manifest(data);var values:[String:String]=[:]
        for path in [""]+m.entries.map(\.path) {
            let url=path.isEmpty ? data : data.appendingPathComponent(path);var s=stat()
            try check(lstat(url.path,&s)==0,"fingerprint lstat")
            values[path]="\(s.st_dev):\(s.st_ino):\(s.st_mode):\(s.st_uid):\(s.st_gid):\(s.st_ctimespec.tv_sec):\(s.st_ctimespec.tv_nsec):\(s.st_size)"
        }
        let e=JSONEncoder();e.outputFormatting=[.sortedKeys];values["$manifest"]=Snapshot.digest(try e.encode(m));return values
    }
    static func rejects(_ body: () throws -> Void) throws { var rejected=false;do{try body()}catch{rejected=true};try check(rejected,"expected fail-closed rejection") }
    // These cases also run through a freshly built CLI when its explicit owned
    // fixture path is supplied. Swift Testing exercises the same Engine boundaries.
    static func cli(_ arguments: [String], fallback: () throws -> Void) throws {
        guard let binary=ProcessInfo.processInfo.environment["RAMNEST_STORAGE_CLI"] else { try fallback();return }
        let p=Process();p.executableURL=URL(fileURLWithPath:binary);p.arguments=arguments
        try p.run();p.waitUntilExit();try check(p.terminationStatus==0,"actual CLI: "+arguments.first!)
    }
    static func rootlessLegacy() throws {
        let f=try Fixture("rootless-legacy"), source=f.root.appendingPathComponent("source")
        try Store.privateDirectory(source)
        let file=source.appendingPathComponent("payload")
        try Data(repeating:71,count:(2<<20)+17).write(to:file)
        try check(link(file.path,source.appendingPathComponent("alias").path)==0,"legacy hardlink")
        let attr=Data("legacy metadata".utf8)
        try check(attr.withUnsafeBytes{setxattr(file.path,"user.legacy",$0.baseAddress,$0.count,0,0)}==0,"legacy xattr")
        try check(chmod(source.path,0o750)==0 && chmod(file.path,0o440)==0,"legacy physical fixture modes")
        var legacy=try Snapshot.manifest(source);legacy.publicRoot=nil
        for i in legacy.entries.indices { legacy.entries[i].allocatedBytes=nil;legacy.entries[i].checksum=Snapshot.digest(try Data(contentsOf:source.appendingPathComponent(legacy.entries[i].path))) }
        let revision=UUID().uuidString,parent=try f.store.volume(f.folder.id).appendingPathComponent("revisions/"+revision)
        try Store.privateDirectory(parent)
        try FileManager.default.moveItem(at:source,to:parent.appendingPathComponent("data"))
        try Store.atomicJSON(legacy,parent.appendingPathComponent("manifest.json"))
        let (data,expected)=try Snapshot.verified(store:f.store,id:f.folder.id,revision:revision)
        try check(expected==legacy && expected.publicRoot==nil,"genuine full-SHA rootless legacy remains authoritative")
        if let binary=ProcessInfo.processInfo.environment["RAMNEST_STORAGE_COLD_RUNNER"] {
            let p=Process();p.executableURL=URL(fileURLWithPath:binary);p.arguments=["cold",f.store.root.path,f.folder.id.uuidString,revision]
            try p.run();p.waitUntilExit();try check(p.terminationStatus==0,"rootless legacy actual cold process")
        }
        let before=try fingerprint(data),metadata=try Data(contentsOf:parent.appendingPathComponent("manifest.json")),metadataBefore=try inodeEvidence(parent.appendingPathComponent("manifest.json")),containerBefore=try inodeEvidence(parent)
        let destination=f.root.appendingPathComponent("export")
        try cli(["--store",f.store.root.path,"export",f.folder.id.uuidString,destination.path,"--revision",revision]) {
            try Engine(store:f.store).export(f.folder.id.uuidString,destination:destination,revision:revision)
        }
        let actual=try Snapshot.manifest(destination,matching:expected)
        try check(actual.matchesExpected(expected) && !expected.matchesExpected(actual) && actual.publicRoot?.mode==0o750,"new materialization observes physical legacy root; directional historical contract")
        var j=Journal();j.phase = .pendingRestore;j.revision=revision;j.initialRevision=revision;j.restoreRevision=revision;j.populationVerified=true
        try f.store.write(j,for:f.folder.id)
        try Engine(store:f.store).recover(f.folder.id.uuidString)
        try check(try Snapshot.manifest(f.selected,matching:expected).matchesExpected(expected),"rootless legacy restore/copy bytes, attrs and links")
        let migrated=try Snapshot.capture(store:f.store,folder:f.folder,source:data,previous:nil,sourceContext:.managedRevision)
        let (_,newManifest)=try Snapshot.verified(store:f.store,id:f.folder.id,revision:migrated)
        try check(newManifest.publicRoot?.mode==0o750 && newManifest.matchesExpected(expected),"new v2 verified copy records observed legacy physical root without relabeling the old revision")
        try check(try fingerprint(data)==before && Data(contentsOf:parent.appendingPathComponent("manifest.json"))==metadata && inodeEvidence(parent.appendingPathComponent("manifest.json"))==metadataBefore && inodeEvidence(parent)==containerBefore,"legacy source and metadata inode/mode/uid/gid/ctime/hash immutable")
        print("PASS rootless full-SHA legacy: cold verification, actual CLI/Engine export, restore, directional comparison and source immutability")
    }
    static func sourceNames() throws {
        for sibling in ["absent","malformed","forged-v2"] {
            let f=try Fixture("ordinary-names"), parent=f.root.appendingPathComponent("revisions/"+UUID().uuidString),data=parent.appendingPathComponent("data")
            try Store.privateDirectory(data);try Data("ordinary user payload".utf8).write(to:data.appendingPathComponent("payload"))
            try check(chmod(data.appendingPathComponent("payload").path,0o600)==0,"ordinary physical source mode")
            if sibling == "malformed" {
                // User-controlled siblings must never confer managed authority,
                // even if they purport to be a versioned snapshot.
                try Store.atomicData(Data("{\"storageFormat\":null}".utf8),parent.appendingPathComponent("manifest.json"))
                try Store.atomicData(Data("untrusted mode map".utf8),parent.appendingPathComponent("modes.bin"))
            }
            if sibling == "forged-v2" {
                var fake=try Snapshot.scanManifest(data);fake.publicRoot?.mode=0;fake.entries[0].mode=0
                let modes=try StorageModes(fake);try modes.write(parent.appendingPathComponent("modes.bin"))
                try Store.atomicJSON(StoredManifest(fake,modes:modes),parent.appendingPathComponent("manifest.json"))
            }
            let before=try fingerprint(data)
            try cli(["--store",f.store.root.path,"create",data.path,"--name","ordinary","--size","16MB","--no-mount"]) {
                _=try Engine(store:f.store).create(path:data,name:"ordinary",capacity:16<<20)
            }
            let created=try Engine(store:f.store).folder("ordinary")
            let revision=try Snapshot.capture(store:f.store,folder:created,source:data,previous:nil)
            let (_,m)=try Snapshot.verified(store:f.store,id:created.id,revision:revision)
            try check(m.entries.count==1 && m.entries[0].path=="payload" && m.entries[0].mode==0o600 && m.publicRoot?.mode==0o700 && fingerprint(data)==before,"all user path shapes scan/capture actual modes without sibling metadata authority")
        }
        print("PASS ordinary revisions/UUID/data CLI create/capture, absent/malformed/forged-v2 siblings")
    }
    static func inodeEvidence(_ url: URL) throws -> String {
        var s=stat();try check(lstat(url.path,&s)==0,"owned outside evidence")
        return "\(s.st_dev):\(s.st_ino):\(s.st_mode):\(s.st_uid):\(s.st_gid):\(s.st_ctimespec.tv_sec):\(s.st_ctimespec.tv_nsec):\(s.st_size)"
    }
    static func normalizationReplacement() throws {
        var failures:[String]=[]
        for directory in [true,false] { for phase in ["before-pin","after-pin"] {
            let f=try Fixture("normalization-race"),volume=try f.store.volume(f.folder.id),stage=volume.appendingPathComponent("stage-"+UUID().uuidString)
            try Store.privateDirectory(stage)
            let victim=stage.appendingPathComponent("victim"),outside=f.root.appendingPathComponent("outside"),sentinel=outside.appendingPathComponent("payload")
            if directory { try Store.privateDirectory(victim);try Store.privateDirectory(outside);try Data("outside unchanged".utf8).write(to:sentinel);try check(chmod(victim.path,0o311)==0 && chmod(outside.path,0o311)==0,"directory race setup") }
            else { try Data("stage".utf8).write(to:victim);try Data("outside unchanged".utf8).write(to:outside);try check(chmod(victim.path,0o311)==0 && chmod(outside.path,0o400)==0,"file race setup") }
            // Establish the outside hardlink before taking the evidence, so
            // injection itself never changes the outside inode's link ctime.
            let replacement=volume.appendingPathComponent("replacement")
            if !directory { try check(link(outside.path,replacement.path)==0,"outside substitution alias") }
            let evidence=try inodeEvidence(outside),bytes=try Data(contentsOf:directory ? sentinel : outside)
            var injected=false,rejected=false,pinClean=true,injectedEvidence=""
            do { _=try StorageModes.normalizeFreshExport(stage,volume:volume) { path,point in
                if path=="victim" && point==phase {
                    injected=true
                    var checked=stat();pinClean=lstat(victim.path,&checked)==0 && checked.st_mode & 0o7777==0o311
                    try FileManager.default.moveItem(at:victim,to:volume.appendingPathComponent("held"))
                    if directory { try FileManager.default.moveItem(at:outside,to:victim) }
                    else { try FileManager.default.moveItem(at:replacement,to:victim) }
                    injectedEvidence=try inodeEvidence(directory ? victim : outside)
                }
            } } catch { rejected=true }
            let outsideNow=directory ? victim : outside
            // Rename itself may change directory ctime; after injection no
            // production permission mutation may touch either outside object.
            if !injected || !rejected || !pinClean { failures.append("\(directory)/\(phase): replacement not rejected before chmod") }
            var st=stat();try check(lstat(outsideNow.path,&st)==0,"outside still retained")
            let afterBytes=try Data(contentsOf:directory ? outsideNow.appendingPathComponent("payload") : outsideNow),afterEvidence=try inodeEvidence(outsideNow)
            if st.st_mode & 0o7777 != (directory ? 0o311 : 0o400) || afterBytes != bytes { failures.append("\(directory)/\(phase): outside mode/content changed") }
            if !directory && afterEvidence.split(separator:":").prefix(5) != evidence.split(separator:":").prefix(5) { failures.append("\(directory)/\(phase): outside identity/mode/owner changed") }
            if injected && afterEvidence != injectedEvidence { failures.append("\(directory)/\(phase): outside changed after injection") }
        } }
        try check(failures.isEmpty,failures.joined(separator:"; "))
        print("PASS four deterministic directory/file replacements before/after pin; outside inode/mode/ctime/content unchanged")
    }
    static func unpinnableLegacy() throws {
        for directory in [true,false] {
            let f=try Fixture("unpinnable-legacy"),volume=try f.store.volume(f.folder.id),stage=volume.appendingPathComponent("stage-"+UUID().uuidString)
            try Store.privateDirectory(stage);let zero=stage.appendingPathComponent("zero")
            if directory { try Store.privateDirectory(zero);try Data("retained".utf8).write(to:zero.appendingPathComponent("payload")) }
            else { try Data("retained".utf8).write(to:zero) }
            try check(chmod(zero.path,0)==0,"unpinnable owned setup")
            let before=try inodeEvidence(zero)
            try rejects { _=try Snapshot.adoptExport(store:f.store,folder:f.folder,stage:stage) }
            try check(try inodeEvidence(zero)==before && FileManager.default.fileExists(atPath:stage.path),"unpinnable old stage retained without mode/ctime mutation")
        }
        print("PASS legacy mode0000 pin denial: fail closed, stage retained, inode/mode/ctime unchanged")
    }
    static func tampering() throws {
        let f=try Fixture("tamper"),(_,source,expected)=try f.adopt(true)
        let sourceBefore=try fingerprint(source)
        var count=0
        func mutation(_ name: String, _ mutate: (URL,URL) throws -> Void) throws {
            let rev=try Snapshot.capture(store:f.store,folder:f.folder,source:source,previous:nil,sourceContext:.managedRevision)
            let (data,m)=try Snapshot.verified(store:f.store,id:f.folder.id,revision:rev)
            try check(m==expected,"pristine copied logical manifest before tamper")
            try mutate(data,data.deletingLastPathComponent())
            try rejects { _=try Snapshot.verified(store:f.store,id:f.folder.id,revision:rev) };count+=1;print("PASS storage tamper \(name)")
        }
        func json(_ parent: URL,_ mutate: (inout [String:Any]) -> Void) throws {
            let url=parent.appendingPathComponent("manifest.json")
            var object=try JSONSerialization.jsonObject(with:Data(contentsOf:url)) as! [String:Any];mutate(&object)
            try Store.atomicData(JSONSerialization.data(withJSONObject:object,options:[.sortedKeys]),url)
        }
        for version:Any in [NSNull(),3,-1,"2"] { try mutation("version-\(version)"){_,p in try json(p){$0["storageFormat"]=version}} }
        try mutation("missing-map-digest"){_,p in try json(p){$0.removeValue(forKey:"modeMapDigest")}}
        try mutation("null-map-digest"){_,p in try json(p){$0["modeMapDigest"]=NSNull()}}
        try mutation("unversioned-map"){_,p in try json(p){$0.removeValue(forKey:"storageFormat")}}
        try mutation("logical-mode-substitution"){_,p in try json(p){var entries=$0["entries"] as! [[String:Any]];entries[0]["mode"]=511;$0["entries"]=entries}}
        try mutation("missing-map"){_,p in try FileManager.default.removeItem(at:p.appendingPathComponent("modes.bin"))}
        try mutation("partial-map"){_,p in try Store.atomicData(Data("RNMODE2\n".utf8),p.appendingPathComponent("modes.bin"))}
        try mutation("record-count-bound"){_,p in let b=Data("RNMODE2\n".utf8)+Data([0,15,66,65]);try Store.atomicData(b,p.appendingPathComponent("modes.bin"));try json(p){$0["modeMapDigest"]=Snapshot.digest(b)}}
        try mutation("map-digest"){_,p in let u=p.appendingPathComponent("modes.bin");var b=try Data(contentsOf:u);b[b.count-1]^=1;try Store.atomicData(b,u)}
        for issue in ["duplicate","escape","bad-kind","trailing"] {
            try mutation(issue){_,p in
                let u=p.appendingPathComponent("modes.bin");var b=try Data(contentsOf:u)
                if issue=="trailing" { b.append(0) }
                else if issue=="bad-kind" { b[16]=9 }
                else {
                    // Canonical header followed by two records; duplicate root
                    // or an escaping child. Rebind digest to test parser itself.
                    b=Data("RNMODE2\n".utf8)+Data([0,0,0,2,0,0,0,0,1,0,0])
                    let path=issue=="duplicate" ? "" : "../escape"
                    b.append(contentsOf:[0,0,0,UInt8(path.utf8.count)]);b.append(contentsOf:path.utf8);b.append(contentsOf:[2,1,128])
                }
                try Store.atomicData(b,u);try json(p){$0["modeMapDigest"]=Snapshot.digest(b)}
            }
        }
        try mutation("payload"){d,_ in try Data("damaged".utf8).write(to:d.appendingPathComponent("RestrictedData/nested/payload"))}
        try mutation("xattr"){d,_ in let bytes=Data("damaged".utf8);try check(bytes.withUnsafeBytes{setxattr(d.appendingPathComponent("RestrictedData").path,"user.trash",$0.baseAddress,$0.count,0,0)}==0,"mutate xattr")}
        try mutation("extra-entry"){d,_ in try Data("extra".utf8).write(to:d.appendingPathComponent("extra"))}
        try mutation("missing-entry"){d,_ in try FileManager.default.removeItem(at:d.appendingPathComponent("write-only"))}
        try mutation("physical-mode"){d,_ in try check(chmod(d.appendingPathComponent("RestrictedData").path,0o755)==0,"owned tamper mode")}
        try mutation("container-mode"){_,p in try check(chmod(p.path,0o500)==0,"owned container mode drift")}
        try mutation("metadata-mode"){_,p in try check(chmod(p.appendingPathComponent("manifest.json").path,0o644)==0,"owned metadata mode drift")}
        try mutation("symlink-target"){d,_ in let p=d.appendingPathComponent("target").path;try check(unlink(p)==0 && symlink("different",p)==0,"symlink tamper")}
        try mutation("split-hardlink"){d,_ in let p=d.appendingPathComponent("alias");try check(unlink(p.path)==0,"split alias");try Data("real trash payload".utf8).write(to:p)}
        try mutation("external-hardlink"){d,_ in try check(link(d.appendingPathComponent("alias").path,f.root.appendingPathComponent("outside-alias").path)==0,"external alias")}
        try check(try fingerprint(source)==sourceBefore,"tamper tests never modify authoritative source")
        print("PASS \(count) storage integrity mutations")
    }
    static func immutability() throws {
        let f=try Fixture("immutable")
        let directory=f.selected.appendingPathComponent("nested");try Store.privateDirectory(directory)
        try Data("original source payload".utf8).write(to:directory.appendingPathComponent("payload"))
        let bytes=Data("original attr".utf8);try check(bytes.withUnsafeBytes{setxattr(directory.path,"user.original",$0.baseAddress,$0.count,0,0)}==0,"source xattr")
        try check(chmod(directory.appendingPathComponent("payload").path,0o444)==0 && chmod(directory.path,0o555)==0,"owned source setup")
        let before=try fingerprint(f.selected)
        let revision=try Snapshot.capture(store:f.store,folder:f.folder,source:f.selected,previous:nil)
        let (data,m)=try Snapshot.verified(store:f.store,id:f.folder.id,revision:revision), committed=try fingerprint(data)
        try Snapshot.copyTree(from:data,to:f.root.appendingPathComponent("export"),manifest:m,sourceContext:.managedRevision)
        let next=try Snapshot.capture(store:f.store,folder:f.folder,source:f.selected,previous:revision)
        _=try Snapshot.verified(store:f.store,id:f.folder.id,revision:next)
        try check(try Snapshot.manifest(f.root.appendingPathComponent("export"))==m,"exact public permissions and all metadata")
        try check(try fingerprint(f.selected)==before && fingerprint(data)==committed,"source+committed inode/mode/uid/gid/ctime/hash unchanged")
        // Legacy remains physically/logically exact, with no map/discriminator.
        let legacy=UUID().uuidString, parent=try f.store.volume(f.folder.id).appendingPathComponent("revisions/"+legacy);try Store.privateDirectory(parent)
        try Snapshot.copyTree(from:f.selected,to:parent.appendingPathComponent("data"),manifest:m,publicationStaging:true)
        try Store.atomicJSON(m,parent.appendingPathComponent("manifest.json"))
        let (old,oldManifest)=try Snapshot.verified(store:f.store,id:f.folder.id,revision:legacy), oldBefore=try fingerprint(old)
        try check(oldManifest==m,"legacy semantics")
        try Snapshot.copyTree(from:old,to:f.root.appendingPathComponent("legacy-export"),manifest:m,sourceContext:.managedRevision)
        try check(try fingerprint(old)==oldBefore,"legacy committed revision immutable")
        print("PASS capture/copy/export/legacy source and committed immutability")
    }
    static func publicExport() throws {
        let f=try Fixture("public-export"),(_,source,m)=try f.adopt(true),before=try fingerprint(source)
        let destination=f.root.appendingPathComponent("public-result")
        try Snapshot.copyTree(from:source,to:destination,manifest:m,sourceContext:.managedRevision)
        var st=stat();try check(lstat(destination.path,&st)==0 && st.st_mode & 0o7777==0,"public export exact restrictive root")
        let containers=try FileManager.default.contentsOfDirectory(at:f.root,includingPropertiesForKeys:nil).filter{$0.lastPathComponent.hasPrefix(".ramnest-materialize-")}
        try check(containers.count==1,"single owned publication receipt container")
        let receipt=try DirectoryHandle.open(containers[0]).readJSON(PublicationReceipt.self,"publication.json")
        try check(receipt.phase=="published" && receipt.manifestDigest==PublicationReceipt(manifest:m,destination:destination.lastPathComponent,phase:"").manifestDigest,"durable receipt bound to full independently verified logical manifest")
        let identities=Dictionary(uniqueKeysWithValues:receipt.identities.map{($0.path,$0)})
        try check(identities.count==m.entries.count+1 && identities["RestrictedData"]?.mode==0o311 && identities["RestrictedData/nested"]?.mode==0,"final mode receipt includes entire namespace")
        try check(identities["alias"]?.inode==identities["RestrictedData/nested/payload"]?.inode,"public hardlink identity receipt")
        try check(try fingerprint(source)==before,"public export never alters committed storage")
        try rejects { try Snapshot.copyTree(from:source,to:destination,manifest:m,sourceContext:.managedRevision) }
        print("PASS restrictive public export: verified bytes/attrs before final modes, full identity/mode receipt, no-replace publication")
    }
    static func unreadableOriginal() throws {
        let f=try Fixture("unreadable-original"), trash=f.selected.appendingPathComponent("RestrictedData")
        try Store.privateDirectory(trash);try Data("original remains".utf8).write(to:trash.appendingPathComponent("payload"))
        let value=Data("retained attr".utf8);try check(value.withUnsafeBytes{setxattr(trash.path,"user.original",$0.baseAddress,$0.count,0,0)}==0,"original attr setup")
        try check(chmod(trash.path,0o311)==0,"restrictive original fixture")
        var before=stat(),after=stat();try check(lstat(trash.path,&before)==0,"original before")
        var message=""
        do { _=try Snapshot.capture(store:f.store,folder:f.folder,source:f.selected,previous:nil) } catch { message=error.localizedDescription }
        try check(message.contains("RestrictedData") && message.contains("listxattr") && message.contains("13") && !message.contains(f.root.path),"sanitized actionable relative path/syscall/errno")
        try check(lstat(trash.path,&after)==0 && before.st_ino==after.st_ino && before.st_mode==after.st_mode && before.st_uid==after.st_uid && before.st_gid==after.st_gid && before.st_ctimespec==after.st_ctimespec,"unreadable arbitrary source is refused without mode/ctime mutation")
        print("PASS unreadable original admission: fail closed, relative RestrictedData/listxattr/errno13, unchanged inode/mode/uid/gid/ctime")
    }
    static func readOnlyDirectoryRestore() throws {
        let f=try Fixture("readonly-directory"),source=f.root.appendingPathComponent("source"),directory=source.appendingPathComponent("readonly")
        try Store.privateDirectory(directory);try Data("readonly directory payload".utf8).write(to:directory.appendingPathComponent("payload"))
        try check(chmod(directory.path,0o555)==0,"read-only source directory fixture")
        let before=try fingerprint(source),revision=try Snapshot.capture(store:f.store,folder:f.folder,source:source,previous:nil)
        let (data,expected)=try Snapshot.verified(store:f.store,id:f.folder.id,revision:revision),committed=try fingerprint(data)
        var j=Journal();j.phase = .pendingRestore;j.revision=revision;j.initialRevision=revision;j.restoreRevision=revision;j.populationVerified=true
        try f.store.write(j,for:f.folder.id);try Engine(store:f.store).recover(f.folder.id.uuidString)
        try check(try Snapshot.manifest(f.selected)==expected && f.store.journal(f.folder.id).phase == .idle,"same-parent final publication of readable but non-writable directory")
        try check(try fingerprint(source)==before && fingerprint(data)==committed,"read-only directory source/revision immutability")
        print("PASS read-only directory restore: exact 0555, full post-publication verification, source/revision unchanged")
    }
    static func freshModeReceipt() throws {
        let f=try Fixture("fresh-receipt")
        guard let native=ProcessInfo.processInfo.environment["RAMNEST_STORAGE_FIXTURE"] else{throw NestError("native fixture required")}
        let stage=try f.store.volume(f.folder.id).appendingPathComponent("stage-"+UUID().uuidString),p=Process(),out=Pipe()
        p.executableURL=URL(fileURLWithPath:native);p.arguments=[stage.path,"private"];p.standardOutput=out;try p.run();p.waitUntilExit()
        let lines=String(decoding:try out.fileHandleForReading.readToEnd() ?? Data(),as:UTF8.self).split(separator:"\n")
        guard p.terminationStatus==0,let digest=lines.first(where:{$0.hasPrefix("modes-digest=")}).map({String($0.dropFirst(13))}) else{throw NestError("native original mode-map ACK required")}
        try rejects{_=try Snapshot.adoptExport(store:f.store,folder:f.folder,stage:stage,privateStorage:true)}
        let url=URL(fileURLWithPath:stage.path+".modes");var bytes=try StorageModes.read(url)
        bytes[bytes.count-1]^=1;try Store.atomicData(bytes,url)
        try rejects{_=try Snapshot.adoptExport(store:f.store,folder:f.folder,stage:stage,privateStorage:true,modeMapDigest:digest)}
        try check(FileManager.default.fileExists(atPath:stage.path),"missing/changed native logical-mode receipt cannot promote the stage")
        print("PASS fresh mode-map metadata is bound to the native capture ACK; missing/modified receipts reject before promotion")
    }
    final class Driver {
        let process=Process(),input=Pipe(),output=Pipe();var commands:[String]=[]
        init(_ fixture: Fixture, legacy: Bool, binary explicitBinary: String? = nil) throws {
            let key=legacy ? "RAMNEST_STORAGE_OLD_PROTOCOL_FIXTURE" : "RAMNEST_STORAGE_PROTOCOL_FIXTURE"
            guard let binary=explicitBinary ?? ProcessInfo.processInfo.environment[key] else { throw NestError("explicit protocol fixture required: "+key) }
            process.executableURL=URL(fileURLWithPath:binary);process.arguments=[fixture.folder.id.uuidString,try fixture.store.volume(fixture.folder.id).path]
            process.standardInput=input;process.standardOutput=output
            // Match the production helper's inherited creation mask, including
            // the genuinely old producer's legacy symlink export semantics.
            let previous=umask(0o077);defer{umask(previous)};try process.run()
        }
        func request(_ command: String) throws -> [String] {
            commands.append(command);try input.fileHandleForWriting.write(contentsOf:Data((command+"\n").utf8))
            var line=Data();while let b=try output.fileHandleForReading.read(upToCount:1),!b.isEmpty {if b[0]==10{break};line.append(b)}
            let fields=String(decoding:line,as:UTF8.self).components(separatedBy:"\t");guard fields.first=="OK" else{throw NestError("native fixture: \(fields)")};return Array(fields.dropFirst())
        }
        func close(){try? input.fileHandleForWriting.close();process.waitUntilExit()}
    }
    static func coordinator(legacy: Bool) throws {
        let f=try Fixture(legacy ? "old-helper" : "new-helper"), driver=try Driver(f,legacy:legacy);defer{driver.close()}
        let initial=try Snapshot.capture(store:f.store,folder:f.folder,source:f.selected,previous:nil)
        var j=Journal();j.phase = .mounted;j.revision=initial;j.initialRevision=initial;j.populationVerified=true;j.socket="owned-fixture";j.session=UUID()
        try f.store.write(j,for:f.folder.id)
        var boundary=EngineSession()
        boundary.request={_,command in try driver.request(command)}
        boundary.status={_,id in let s=try driver.request("status");return HelperStatus(id:id,pid:Int32(s[1])!,mounted:s[2]=="mounted",used:UInt64(s[3])!,capacity:UInt64(s[4])!,active:s[5]=="active")}
        boundary.mountedIdentity={_,_ in true}
        boundary.unmount={_ in _=try driver.request("fixture-unmounted")}
        let engine=Engine(store:f.store,session:boundary)
        try engine.save(f.folder.id.uuidString)
        let first=try f.store.journal(f.folder.id), (source,m)=try Snapshot.verified(store:f.store,id:f.folder.id,revision:first.revision!)
        try validatePayload(source,m,exactNativeSymlinkModes:!legacy,legacyPinnable:legacy);let committed=try fingerprint(source)
        if legacy { print("OBSERVED frozen legacy helper exported symlink mode \(String(m.entries.first{$0.path=="target"}!.mode,radix:8)); original native symlink mode 777 is not present in the old export protocol") }
        var pinnedJournal=first;pinnedJournal.initialRevision=first.revision;try f.store.write(pinnedJournal,for:f.folder.id)
        try engine.save(f.folder.id.uuidString)
        let second=try f.store.journal(f.folder.id)
        try check(legacy ? second.revision != first.revision : second.revision == first.revision,"old helper full copy / new helper verified no-op")
        if legacy {
            try check(driver.commands.filter{$0.hasPrefix("export2\t")}.allSatisfy{$0.components(separatedBy:"\t").count==2},"old helper never receives format2 previous data")
            try check(!driver.commands.contains{$0.hasPrefix("export3")},"old helper receives only supported verbs")
        } else {
            _ = try driver.request("fixture-trash-create");try engine.save(f.folder.id.uuidString)
            let beforeTrash = try f.store.journal(f.folder.id)
            _ = try driver.request("fixture-trash-dirty");try engine.save(f.folder.id.uuidString)
            let afterTrash = try f.store.journal(f.folder.id)
            try check(afterTrash.revision == beforeTrash.revision && UInt64(afterTrash.nativeGeneration!)! > UInt64(beforeTrash.nativeGeneration!)!,"actual native Trash-only reuse advances quiesce generation without new revision")
            print("PASS actual helper Trash-only dirty no-op: same revision, advanced session generation")
        }
        _=try driver.request("fixture-dirty");try engine.save(f.folder.id.uuidString)
        let dirty=try f.store.journal(f.folder.id), (dirtyData,_)=try Snapshot.verified(store:f.store,id:f.folder.id,revision:dirty.revision!)
        let dirtyBefore=try fingerprint(dirtyData)
        try check(try Data(contentsOf:dirtyData.appendingPathComponent("alias"))==Data("dirtytrash payload".utf8),"dirty runtime export preserves payload")
        try check(try fingerprint(source)==committed,"incremental/no-op/dirty paths preserve committed inode/ctime")
        let selectedFD=try DirectoryHandle.open(f.selected)
        var pinned:[String:Int32]=[:]
        var publicationSource: URL?, publicationBefore: [String:String]?
        f.store.beforeJournalWrite={ journal,_ in
            if journal.publicationReceipt?.phase=="finalizing",let stage=journal.restoreStage {
                try check(try fingerprint(dirtyData)==dirtyBefore,"prior committed revision unchanged through quiesce capture")
                let (committed,_)=try Snapshot.verified(store:f.store,id:f.folder.id,revision:journal.restoreRevision ?? journal.revision!)
                publicationSource=committed;publicationBefore=try fingerprint(committed)
                let data=URL(fileURLWithPath:stage).appendingPathComponent("data")
                for e in m.entries where e.kind != "symlink" {
                    let fd=open(data.appendingPathComponent(e.path).path,O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
                    try check(fd>=0,"pin test evidence before final permission application");pinned[e.path]=fd
                }
            }
        }
        defer{for fd in pinned.values{close(fd)}}
        if !legacy { _ = try driver.request("fixture-trash-dirty") }
        try engine.unmount(f.folder.id.uuidString,ignoreBusy:true)
        let done=try f.store.journal(f.folder.id)
        try check(done.phase == .idle && done.publicationReceipt?.phase=="published","durable verified publication receipt")
        var st=stat();try check(fstat(selectedFD.fd,&st)==0 && st.st_mode & 0o7777==m.publicRoot!.mode,"exact public root mode without reopening/chmod")
        for e in m.entries where e.kind != "symlink" {try check(fstat(pinned[e.path]!,&st)==0 && st.st_mode & 0o7777==e.mode,"final public mode through pinned test descriptor: "+e.path)}
        var payload=[UInt8](repeating:0,count:18);try check(pread(pinned["alias"]!,&payload,18,0)==18 && Data(payload)==Data("dirtytrash payload".utf8),"actual final public payload via retained read descriptor")
        try check(try fingerprint(publicationSource!)==publicationBefore,"published revision remains independently readable and immutable after publication")
        print("PASS coordinator \(legacy ? "frozen old incremental-v1" : "format2") save twice / dirty / quiesce / eject / restrictive publication")
    }
    static func policyCapability() throws {
        let f=try Fixture("old-private-policy"),driver=try Driver(f,legacy:false);defer{driver.close()}
        let initial=try Snapshot.capture(store:f.store,folder:f.folder,source:f.selected,previous:nil)
        var j=Journal();j.phase = .mounted;j.revision=initial;j.initialRevision=initial;j.populationVerified=true;j.socket="owned-fixture";j.session=UUID();try f.store.write(j,for:f.folder.id)
        var boundary=EngineSession()
        boundary.request={_,command in
            let reply=try driver.request(command)
            return command == "capabilities" ? reply.filter{$0 != "trash-directory-exclusion-v1"} : reply
        }
        boundary.status={_,id in HelperStatus(id:id,pid:getpid(),mounted:true,used:0,capacity:16<<20,active:true)}
        boundary.mountedIdentity={_,_ in true}
        let engine=Engine(store:f.store,session:boundary)
        try engine.save(f.folder.id.uuidString);try engine.save(f.folder.id.uuidString)
        try check(driver.commands.filter{$0.hasPrefix("export3\t")}.allSatisfy{$0.components(separatedBy:"\t").count==2},"private helper without exclusion capability never receives a filtered prior")
        print("PASS private-v2 helper without exclusion capability uses full exports; no incompatible filtered prior")
    }
    static func legacyBadPrior() throws {
        let f=try Fixture("old-helper-bad-prior"),driver=try Driver(f,legacy:true);defer{driver.close()}
        let initial=try Snapshot.capture(store:f.store,folder:f.folder,source:f.selected,previous:nil)
        var j=Journal();j.phase = .mounted;j.revision=initial;j.initialRevision=initial;j.populationVerified=true;j.socket="owned-fixture"
        try f.store.write(j,for:f.folder.id)
        var boundary=EngineSession();boundary.request={_,command in try driver.request(command)}
        boundary.status={_,id in let s=try driver.request("status");return HelperStatus(id:id,pid:Int32(s[1])!,mounted:true,used:UInt64(s[3])!,capacity:UInt64(s[4])!,active:true)}
        boundary.mountedIdentity={_,_ in true}
        let engine=Engine(store:f.store,session:boundary);try engine.save(f.folder.id.uuidString)
        let first=try f.store.journal(f.folder.id), data=try Snapshot.dataURL(store:f.store,id:f.folder.id,revision:first.revision!),trash=data.appendingPathComponent("RestrictedData")
        // Deliberate damage of a NEW owned fixture revision; no live/old store.
        try check(chmod(trash.path,0o311)==0,"owned incompatible-prior fixture")
        var before=stat(),after=stat();try check(lstat(trash.path,&before)==0,"prior fixture identity")
        try engine.save(f.folder.id.uuidString)
        let next=try f.store.journal(f.folder.id);try check(next.revision != first.revision,"old helper full save proceeds without reading incompatible prior payload")
        let (current,m)=try Snapshot.verified(store:f.store,id:f.folder.id,revision:next.revision!);try validatePayload(current,m,exactNativeSymlinkModes:false,legacyPinnable:true)
        try check(lstat(trash.path,&after)==0 && before.st_ino==after.st_ino && before.st_mode==after.st_mode && before.st_ctimespec==after.st_ctimespec,"damaged old fixture revision is retained unchanged")
        try check(driver.commands.filter{$0.hasPrefix("export2\t")}.allSatisfy{$0.components(separatedBy:"\t").count==2},"no prior data sent to old helper")
        print("PASS frozen old helper saves authoritative RAM with unreadable incompatible prior; prior retained unchanged")
    }
    static func legacyZeroHelper(_ binary: String) throws {
        let f=try Fixture("frozen-old-zero"),driver=try Driver(f,legacy:true,binary:binary);defer{driver.close()}
        let initial=try Snapshot.capture(store:f.store,folder:f.folder,source:f.selected,previous:nil)
        let (prior,_)=try Snapshot.verified(store:f.store,id:f.folder.id,revision:initial),before=try fingerprint(prior)
        var j=Journal();j.phase = .mounted;j.revision=initial;j.initialRevision=initial;j.populationVerified=true;j.socket="owned-fixture"
        try f.store.write(j,for:f.folder.id)
        var boundary=EngineSession();boundary.request={_,command in try driver.request(command)}
        boundary.status={_,id in let s=try driver.request("status");return HelperStatus(id:id,pid:Int32(s[1])!,mounted:s[2]=="mounted",used:UInt64(s[3])!,capacity:UInt64(s[4])!,active:true)}
        boundary.mountedIdentity={_,_ in true}
        var message=""
        do { try Engine(store:f.store,session:boundary).save(f.folder.id.uuidString) } catch { message=error.localizedDescription }
        let retained=try f.store.journal(f.folder.id),volume=try f.store.volume(f.folder.id)
        let stages=try DirectoryHandle.open(volume).names().filter{$0.hasPrefix("stage-")}
        try check(message.contains("openat") && message.contains("13") && message.contains("retained") && !message.contains(f.root.path),"actionable sanitized unpinnable legacy failure")
        try check(retained.phase == .mounted && retained.revision==initial && retained.initialRevision==initial && stages.count==1,"failed legacy save retains authority, stage and prior")
        var s=stat();try check(lstat(volume.appendingPathComponent(stages[0]).path,&s)==0 && s.st_mode & 0o7777==0,"frozen legacy mode0000 root remains untouched")
        try check(try fingerprint(prior)==before && driver.request("status")[2]=="mounted","prior unchanged and old RAM helper still available")
        try check(!driver.commands.contains{$0.hasPrefix("export3") || $0.hasPrefix("quiesce") || $0=="retire"},"no unsupported export, evacuation or authority change")
        // A failed quiesce must durably invalidate the checkpoint before thaw,
        // without reaching the injected unmount boundary or changing authority.
        var invalidated=false,unmountCalled=false
        f.store.beforeJournalWrite={ next,_ in
            if next.phase == .mounted && next.quiescedRevision == nil { invalidated=true }
        }
        boundary.request={_,command in
            if command=="thaw" { try check(invalidated,"durable invalidation before thaw") }
            return try driver.request(command)
        }
        boundary.unmount={_ in unmountCalled=true;throw NestError("unmount must not be reached")}
        try rejects { try Engine(store:f.store,session:boundary).unmount(f.folder.id.uuidString,ignoreBusy:true) }
        let afterEject=try f.store.journal(f.folder.id)
        let retainedStages=try DirectoryHandle.open(volume).names().filter{$0.hasPrefix("stage-")}
        try check(!unmountCalled && invalidated && afterEject.phase == .mounted && afterEject.revision==initial && afterEject.quiescedRevision==nil && retainedStages.count==2,"failed legacy eject retains both stages/prior and mounted authority")
        try check(driver.commands.contains{$0.hasPrefix("quiesce2\t")} && driver.commands.last=="thaw","old supported quiesce fails safely then thaws")
        try check(try driver.request("fixture-dirty").isEmpty && fingerprint(prior)==before,"RAM writes remain usable and prior immutable after failed eject")
        print("PASS immutable original old-helper mode0000: save/eject pin denial; durable invalidate-before-thaw, RAM/stages/prior retained, no unmount")
    }
    static func crashChild(_ coordinates: URL, cut: String) throws {
        let f=try Fixture("process-exit"), (revision,_,_)=try f.adopt(true)
        var j=Journal();j.phase = .pendingRestore;j.revision=revision;j.initialRevision=revision;j.restoreRevision=revision;j.populationVerified=true
        try f.store.write(j,for:f.folder.id)
        try Store.atomicJSON(["store":f.store.root.path,"id":f.folder.id.uuidString,"revision":revision,"selected":f.selected.path],coordinates)
        f.store.beforeJournalWrite={ next,_ in
            if (cut=="before-modes" && next.publicationReceipt?.phase=="finalizing") ||
               (cut=="after-modes" && next.publicationReceipt?.phase=="verified-final-modes") ||
               (cut=="after-move" && !next.restoredEntries.isEmpty) { _exit(73) }
        }
        try Engine(store:f.store).recover(f.folder.id.uuidString)
        throw NestError("process-exit cutpoint was not reached")
    }
    static func crashRecovery() throws {
        guard let binary=ProcessInfo.processInfo.environment["RAMNEST_STORAGE_COLD_RUNNER"] else { throw NestError("cold runner required for actual process-exit tests") }
        let base=try root("crash-parent")
        for cut in ["before-modes","after-modes","after-move"] {
            let coords=base.appendingPathComponent(cut+".json"),p=Process();p.executableURL=URL(fileURLWithPath:binary);p.arguments=["crash",coords.path,cut]
            try p.run();p.waitUntilExit();try check(p.terminationStatus==73,"actual _exit at "+cut)
            let c=try JSONDecoder().decode([String:String].self,from:Data(contentsOf:coords)),store=try Store(root:URL(fileURLWithPath:c["store"]!)),id=UUID(uuidString:c["id"]!)!
            let (source,_)=try Snapshot.verified(store:store,id:id,revision:c["revision"]!),before=try fingerprint(source)
            let durable=try store.journal(id)
            try check(durable.restoreStage != nil && durable.restoreDataInode != nil,"stage/data identities durable across process exit")
            if cut=="before-modes" {
                try Engine(store:store).recover(id.uuidString)
                try check(try store.journal(id).phase == .idle,"accessible interrupted restore resumes after independent readback")
            } else {
                try rejects { try Engine(store:store).recover(id.uuidString) }
                let retained=try store.journal(id)
                try check(retained.restoreStage==durable.restoreStage && retained.restoreDataInode==durable.restoreDataInode && retained.phase != .idle,"unverifiable restrictive interruption retains stage/data and fails closed")
            }
            try check(try fingerprint(source)==before,"process exit/recovery never changes committed snapshot")
            print("PASS process-exit \(cut): \(cut=="before-modes" ? "verified retry" : "fail closed; evidence retained")")
        }
    }
}
#if RAMNEST_STORAGE_STANDALONE
@main struct StorageFormatRunner {
    static func main() {
        do {
            if CommandLine.arguments.count==3 && CommandLine.arguments[1]=="old-zero" { try StorageFormatScenarios.legacyZeroHelper(CommandLine.arguments[2]);return }
            if CommandLine.arguments.count==3 && CommandLine.arguments[1]=="correction" {
                switch CommandLine.arguments[2] {
                case "rootless":try StorageFormatScenarios.rootlessLegacy()
                case "names":try StorageFormatScenarios.sourceNames()
                case "race":try StorageFormatScenarios.normalizationReplacement()
                case "zero":try StorageFormatScenarios.unpinnableLegacy()
                case "policy":try StorageFormatScenarios.policyCapability()
                default:throw NestError("unknown correction case")
                };return
            }
            if CommandLine.arguments.count==4 && CommandLine.arguments[1]=="crash" { try StorageFormatScenarios.crashChild(URL(fileURLWithPath:CommandLine.arguments[2]),cut:CommandLine.arguments[3]);return }
            if CommandLine.arguments.count==5 && CommandLine.arguments[1]=="cold" {
                let store=try Store(root:URL(fileURLWithPath:CommandLine.arguments[2]))
                _=try Snapshot.verified(store:store,id:UUID(uuidString:CommandLine.arguments[3])!,revision:CommandLine.arguments[4]);print("PASS cold process format2 verification");return
            }
            try StorageFormatScenarios.nativeAdoption()
            try StorageFormatScenarios.nativeAdoption(privateFormat:true)
            try StorageFormatScenarios.tampering()
            try StorageFormatScenarios.immutability()
            try StorageFormatScenarios.publicExport()
            try StorageFormatScenarios.unreadableOriginal()
            try StorageFormatScenarios.readOnlyDirectoryRestore()
            try StorageFormatScenarios.freshModeReceipt()
            try StorageFormatScenarios.coordinator(legacy:true)
            try StorageFormatScenarios.coordinator(legacy:false)
            try StorageFormatScenarios.legacyBadPrior()
            try StorageFormatScenarios.crashRecovery()
            try StorageFormatScenarios.rootlessLegacy()
            try StorageFormatScenarios.sourceNames()
            try StorageFormatScenarios.normalizationReplacement()
            try StorageFormatScenarios.unpinnableLegacy()
            try StorageFormatScenarios.policyCapability()
        }
        catch { print("FAIL \(error)");exit(1) }
    }
}
#endif
