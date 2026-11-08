import Foundation
import Darwin
@testable import RAMNestCore
#if RAMNEST_FOLLOWUP_STANDALONE
@main
#endif
struct FollowupRunner {
    static func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws { if try !value() { throw NestError("FOLLOWUP: " + message) } }
    static func main() {
        do { try run(); print("PASS followup \(CommandLine.arguments[2])") }
        catch { print("FAIL followup \(CommandLine.arguments[2]): \(error)"); exit(1) }
    }
    final class NativeDriver {
        let process=Process(),input=Pipe(),output=Pipe();var commands:[String]=[]
        init(_ folder: Folder, _ store: Store) throws {
            guard let binary=ProcessInfo.processInfo.environment["RAMNEST_ENGINE_FIXTURE"] else { throw NestError("native protocol fixture required") }
            process.executableURL=URL(fileURLWithPath:binary);process.arguments=[folder.id.uuidString,try store.volume(folder.id).path]
            process.standardInput=input;process.standardOutput=output;try process.run()
        }
        func request(_ command: String) throws -> [String] {
            commands.append(command.components(separatedBy:"\t")[0]);try input.fileHandleForWriting.write(contentsOf:Data((command+"\n").utf8))
            var line=Data()
            while let byte=try output.fileHandleForReading.read(upToCount:1), !byte.isEmpty { if byte[0]==10 { break };line.append(byte) }
            let fields=String(decoding:line,as:UTF8.self).components(separatedBy:"\t")
            guard fields.first == "OK" else { throw NestError("native fixture error: \(fields)") };return Array(fields.dropFirst())
        }
        func close() { try? input.fileHandleForWriting.close();process.waitUntilExit() }
    }
    static func protocolEngine(_ root: URL, staleReceipt: Bool = false, refreeze: Bool = false) throws {
        let f=try LatestSnapshotScenarios.Fixture(root,"protocol"),driver=try NativeDriver(f.folder,f.store)
        defer { driver.close() }
        var mounted=true,lostACK=false,damageStage=false
        var boundary=f.helper.boundary
        boundary.request={ _,command in
            let response=try driver.request(command)
            if command.hasPrefix("quiesce3\t") && lostACK { lostACK=false;throw NestError("ACK lost after native completion") }
            if command.hasPrefix("export3\t") && damageStage { damageStage=false;let stage=command.components(separatedBy:"\t")[1];try check(mkfifo(stage+"/unsupported",0o600)==0,"adoption failure fixture") }
            return response
        }
        boundary.status={ _,id in
            let fields=try driver.request("status")
            return HelperStatus(id:id,pid:Int32(fields[1])!,mounted:fields[2]=="mounted",used:UInt64(fields[3])!,capacity:UInt64(fields[4])!,active:fields[5]=="active")
        }
        boundary.mountedIdentity={_,_ in mounted}
        boundary.unmount={_ in
            if staleReceipt { _ = try driver.request("thaw");_ = try driver.request("fixture-write\texternal-after-thaw");if refreeze {_ = try driver.request("freeze")} }
            mounted=false;_ = try driver.request("fixture-unmounted")
        }
        let engine=Engine(store:f.store,session:boundary)
        if staleReceipt {
            try engine.unmount(f.folder.id.uuidString,ignoreBusy:true)
            try check(try String(contentsOf:f.selected.appendingPathComponent("payload"),encoding:.utf8)=="external-after-thaw","native writable state disqualifies durable but stale quiesce receipt")
            try check(driver.commands.filter{$0 == "quiesce3"}.count==2,"stale receipt triggers fresh capture")
            return
        }
        try engine.save(f.folder.id.uuidString);let first=try f.store.journal(f.folder.id)
        try check(first.nativeGeneration != nil,"actual export3 receipt adopted")
        try engine.save(f.folder.id.uuidString);try check(try f.store.journal(f.folder.id).revision == first.revision,"actual export3 no-op reuses coherent revision")
        _ = try driver.request("fixture-write\tG+1")
        var inject=true
        f.store.beforeJournalWrite={j,_ in if inject && j.nativeGeneration != first.nativeGeneration { inject=false;throw NestError("journal publication failure") } }
        do { try engine.save(f.folder.id.uuidString) } catch {}
        try check(try f.store.journal(f.folder.id).revision == first.revision,"journal failure cannot advance committed generation")
        f.store.beforeJournalWrite=nil
        try engine.save(f.folder.id.uuidString);let second=try f.store.journal(f.folder.id)
        try check(second.revision != first.revision,"retry after journal failure captures authoritative RAM")
        _ = try driver.request("fixture-write\tG+2");damageStage=true
        do { try engine.save(f.folder.id.uuidString) } catch {}
        try check(try f.store.journal(f.folder.id).revision == second.revision,"stage/adoption failure retains durable revision")
        lostACK=true
        do { try engine.unmount(f.folder.id.uuidString,ignoreBusy:true) } catch {}
        try check(driver.commands.contains("thaw") && (try f.store.journal(f.folder.id)).quiescedRevision == nil,"lost quiesce3 ACK invalidated before thaw")
        _ = try driver.request("fixture-write\tafter-thaw")
        try engine.unmount(f.folder.id.uuidString,ignoreBusy:true)
        try check(try String(contentsOf:f.selected.appendingPathComponent("payload"),encoding:.utf8)=="after-thaw","actual protocol eject restores post-thaw generation")
        try check(driver.commands.filter{$0 == "quiesce3"}.count==2,"successful retry consumes single quiesce3")
    }
    final class AsyncResult: @unchecked Sendable {
        let engine: Engine, ref: String, entered=DispatchSemaphore(value:0),done=DispatchSemaphore(value:0)
        let lock=NSLock();var error: Error?
        init(_ engine: Engine, _ ref: String){self.engine=engine;self.ref=ref}
        func save(){do{try engine.save(ref)}catch{lock.lock();self.error=error;lock.unlock()};done.signal()}
    }
    static func waitFile(_ url: URL) throws {
        let deadline=ProcessInfo.processInfo.systemUptime+8
        while !FileManager.default.fileExists(atPath:url.path) {
            guard ProcessInfo.processInfo.systemUptime<deadline else { throw NestError("bounded lock fixture timed out") };usleep(1000)
        }
    }
    static func processLock(_ root: URL, removed: Bool) throws {
        let f=try LatestSnapshotScenarios.Fixture(root,"alpha")
        let selected=root.appendingPathComponent("replacement");try Store.privateDirectory(selected)
        let identity=try DirectoryHandle.open(selected).identity()
        let replacement=Folder(name:"alpha",path:selected.path,capacity:16<<20,device:identity.device,inode:identity.inode)
        _ = try f.store.volume(replacement.id)
        try Data("B-sentinel".utf8).write(to:selected.appendingPathComponent("payload"))
        let bRevision=try Snapshot.capture(store:f.store,folder:replacement,source:selected,previous:nil)
        var bJournal=Journal();bJournal.phase = .mounted;bJournal.revision=bRevision;bJournal.initialRevision=bRevision;bJournal.populationVerified=true;bJournal.socket="owned-B"
        try f.store.write(bJournal,for:replacement.id)
        let bReady=root.appendingPathComponent("B-ready"),bRelease=root.appendingPathComponent("B-release")
        let bChild=Process();bChild.executableURL=URL(fileURLWithPath:CommandLine.arguments[0]);bChild.arguments=[root.path,"lock-child",f.store.root.path,replacement.id.uuidString,bReady.path,bRelease.path]
        try bChild.run();defer{try? Data().write(to:bRelease);bChild.waitUntilExit()};try waitFile(bReady)
        let ready=root.appendingPathComponent("ready"),release=root.appendingPathComponent("release")
        let child=Process();child.executableURL=URL(fileURLWithPath:CommandLine.arguments[0]);child.arguments=[root.path,"lock-child",f.store.root.path,f.folder.id.uuidString,ready.path,release.path]
        try child.run();defer{try? Data().write(to:release);child.waitUntilExit()}
        try waitFile(ready)
        let entered=DispatchSemaphore(value:0)
        var boundary=f.helper.boundary;boundary.beforeVolumeLock={_ in entered.signal()}
        boundary.status={_,id in HelperStatus(id:id,pid:getpid(),mounted:true,used:0,capacity:16<<20,active:true)}
        boundary.mountedIdentity={_,_ in true}
        let result=AsyncResult(Engine(store:f.store,session:boundary),"alpha")
        DispatchQueue.global().async {result.save()}
        try check(entered.wait(timeout:.now()+5) == .success,"resolved before distinct-process volume lock")
        try check(result.done.wait(timeout:.now()+0.1) == .timedOut,"real cross-process flock excludes save")
        let otherStore=try Store(root:f.store.root)
        try otherStore.locked {
            var c=try otherStore.load()
            if removed { c.folders.removeAll{$0.id==f.folder.id} } else {c.folders[0].name="renamed"}
            c.folders.append(replacement);try otherStore.save(c)
        }
        try Data().write(to:release)
        try check(result.done.wait(timeout:.now()+8) == .success,"save released after child lock")
        if removed {try check(result.error != nil && !f.helper.commands.contains("export"),"deleted UUID rejected without replacement/resurrection")}
        else {try check(result.error == nil && f.helper.commands.contains("export"),"renamed original UUID saved under original lock")}
        let unchanged=try otherStore.journal(replacement.id)
        try check(unchanged.phase == .mounted && unchanged.revision == bRevision,"replacement mounted journal remains untouched while B lock is held by another process")
        try check(bChild.isRunning,"A completed independently while B transaction remained excluded")
    }
    final class ThreadResult: @unchecked Sendable {let done=DispatchSemaphore(value:0);var failure: Error?}
    static func deep(_ root: URL) throws {
        var limits=rlimit();try check(getrlimit(RLIMIT_NOFILE,&limits)==0,"read FD limit");limits.rlim_cur=96;try check(setrlimit(RLIMIT_NOFILE,&limits)==0,"owned process FD limit")
        let outcome=ThreadResult()
        let thread=Thread {
            do {
                let selected=root.appendingPathComponent("selected");try Store.privateDirectory(selected)
                var leaf=selected
                for _ in 0..<120 {leaf=leaf.appendingPathComponent("d");try Store.privateDirectory(leaf)}
                let payload=leaf.appendingPathComponent("payload");try Data("deep".utf8).write(to:payload)
                try FileManager.default.linkItem(at:payload,to:selected.appendingPathComponent("z-alias"))
                for i in 0..<256 {try Data().write(to:selected.appendingPathComponent("wide-\(i)"))}
                let store=try Store(root:root.appendingPathComponent("store")),engine=Engine(store:store)
                let folder=try engine.create(path:selected,name:"deep",capacity:16<<20)
                let obsolete=try Snapshot.capture(store:store,folder:folder,source:selected,previous:nil)
                let revision=try Snapshot.capture(store:store,folder:folder,source:selected,previous:nil)
                let moved=root.appendingPathComponent("holding");try Store.privateDirectory(moved)
                let from=try DirectoryHandle.open(selected),to=try DirectoryHandle.open(moved)
                for name in try from.names() {try from.renameNoReplace(name,to:to,as:name)}
                var j=Journal();j.phase = .pendingRestore;j.populationVerified=true;j.revision=revision;j.restoreRevision=revision;j.priorRevision=obsolete
                try store.write(j,for:folder.id);try engine.recover(folder.id.uuidString)
                try check(try Snapshot.manifest(selected)==Snapshot.manifest(moved),"deep/wide restore bytes/metadata/links")
                let plan=try to.cleanupInventory(),identity=try to.identity()
                try check(plan.manifest.contentsMatchExpected(Snapshot.manifest(selected)),"deep rootless inventory content policy")
                try to.removeCleanupTree(from:DirectoryHandle.open(root),name:"holding",plan:plan,device:identity.device,inode:identity.inode,fsid:to.cleanupFilesystem(),validateAnchor:{},beforeUnlink:nil)
                try check(!FileManager.default.fileExists(atPath:moved.path),"iterative deep sibling cleanup")
                let old=try Snapshot.dataURL(store:store,id:folder.id,revision:obsolete)
                try check(!FileManager.default.fileExists(atPath:old.path),"iterative deep committed-revision retirement")
                print("PASS Swift depth120/wide256 manifest/copy/recovery/inventory/cleanup at 96 FDs and 512KiB thread stack")
            } catch {outcome.failure=error}
            outcome.done.signal()
        }
        thread.stackSize=512*1024;thread.start()
        try check(outcome.done.wait(timeout:.now()+30) == .success,"bounded deep traversal")
        if let error=outcome.failure {throw error}
    }
    static func run() throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]).appendingPathComponent("followup-"+UUID().uuidString);try Store.privateDirectory(root)
        switch CommandLine.arguments[2] {
        case "lock-child":
            let store=try Store(root:URL(fileURLWithPath:CommandLine.arguments[3])),id=UUID(uuidString:CommandLine.arguments[4])!
            try store.volumeLocked(id) {try Data().write(to:URL(fileURLWithPath:CommandLine.arguments[5]));try waitFile(URL(fileURLWithPath:CommandLine.arguments[6]))}
        case "process-rename": try processLock(root,removed:false)
        case "process-delete": try processLock(root,removed:true)

        case "equality":
            let url=root.appendingPathComponent("data");try Store.privateDirectory(url);try Data([1]).write(to:url.appendingPathComponent("file"))
            let current=try Snapshot.manifest(url);var old=current;old.entries[0].allocatedBytes=nil
            try check(current != old && old != current,"Entry equality must include allocatedBytes exactly")
            var other=current;other.entries[0].allocatedBytes=2*65536
            try check(current != other && old != other,"nil cannot bridge incompatible allocated sizes")
            old=current;old.publicRoot=nil
            try check(old != current && current != old,"Manifest equality must include publicRoot exactly")
            var b=current;b.publicRoot?.mode=0o750
            try check(current != b && old != b,"rootless record cannot bridge different public metadata")
            try check(current.matchesExpected(old) && !old.matchesExpected(current),"only expected old root permits absent root metadata")
        case "thaw":
            let f=try LatestSnapshotScenarios.Fixture(root,"eject")
            var boundary=f.helper.boundary;boundary.unmount={_ in throw NestError("unmount cut")}
            let original=boundary.request;var stale=false
            boundary.request={socket,command in
                if command == "thaw" { let j=try f.store.journal(f.folder.id);stale = j.quiescedRevision != nil || j.phase == .ejecting }
                return try original(socket,command)
            }
            do { try Engine(store:f.store,session:boundary).unmount(f.folder.id.uuidString,ignoreBusy:true) } catch {}
            try check(!stale,"durable receipt invalidation must precede thaw callback/crash")
        case "invalidation-failure":
            let f=try LatestSnapshotScenarios.Fixture(root,"durability")
            var boundary=f.helper.boundary;boundary.unmount={_ in throw NestError("unmount cut")}
            f.store.beforeJournalWrite={j,_ in
                if j.phase == .mounted && j.lastError != nil && j.quiescedRevision == nil { throw NestError("injected journal sync failure") }
            }
            do { try Engine(store:f.store,session:boundary).unmount(f.folder.id.uuidString,ignoreBusy:true) } catch {}
            try check(!f.helper.commands.contains("thaw"),"durable invalidation failure must leave helper frozen")
            let j=try f.store.journal(f.folder.id)
            try check(j.phase == .ejecting && j.quiescedRevision == j.revision,"last durable frozen receipt remains recoverable")
        case "legacy-large", "occupied", "symlink":
            let source=root.appendingPathComponent("source");try Store.privateDirectory(source)
            let file=source.appendingPathComponent("a");try Data(repeating:83,count:2<<20).write(to:file)
            if CommandLine.arguments[2] == "occupied" {
                let m=try Snapshot.manifest(source)
                var rejected=false;do { try m.preflight(capacity:1<<20) } catch { rejected=true }
                try check(rejected,"occupied sparse pages must reject overquota")
            } else if CommandLine.arguments[2] == "symlink" {
                let a=source.appendingPathComponent("sym-a"),b=source.appendingPathComponent("sym-b")
                try FileManager.default.createSymbolicLink(atPath:a.path,withDestinationPath:"a")
                try check(linkat(AT_FDCWD,a.path,AT_FDCWD,b.path,0)==0,"hardlinked symlink fixture")
                var before=stat();try check(lstat(a.path,&before)==0,"link identity")
                var rejected=false;do { _ = try Snapshot.manifest(source) } catch { rejected=true }
                var after=stat();try check(rejected && lstat(b.path,&after)==0 && after.st_ino==before.st_ino && after.st_nlink==2,"unsupported aliases rejected without evacuation")
            } else {
                try FileManager.default.linkItem(at:file,to:source.appendingPathComponent("b"))
                let store=try Store(root:root.appendingPathComponent("store"));let engine=Engine(store:store)
                let folder=try engine.create(path:source,name:"legacy",capacity:16<<20)
                let revision=UUID().uuidString
                let container=try store.volume(folder.id).appendingPathComponent("revisions/"+revision);try Store.privateDirectory(container)
                let currentManifest=try Snapshot.manifest(source),data=container.appendingPathComponent("data")
                try Snapshot.copyTree(from:source,to:data,manifest:currentManifest,publicationStaging:true)
                var legacy=currentManifest;legacy.publicRoot=nil
                for i in legacy.entries.indices { legacy.entries[i].allocatedBytes=nil;legacy.entries[i].checksum=Snapshot.digest(try Data(contentsOf:data.appendingPathComponent(legacy.entries[i].path))) }
                try Store.atomicJSON(legacy,data.deletingLastPathComponent().appendingPathComponent("manifest.json"))
                let (_,verified)=try Snapshot.verified(store:store,id:folder.id,revision:revision)
                try check(verified == legacy && legacy.entries[1].hardlink == "a","historical full SHA >1MiB and hardlink aliases verified")
                let current=try Snapshot.manifest(data,matching:legacy,context:.managedRevision)
                try check(current.matchesExpected(legacy) && !legacy.matchesExpected(current),"legacy compatibility is explicitly directional")
            }
        case "cursor-replacement":
            let a=root.appendingPathComponent("a");try Store.privateDirectory(a);try Data("old".utf8).write(to:a.appendingPathComponent("file"))
            let cursor=DirectoryCursor(try DirectoryHandle.open(root));_ = try cursor.parent(of:"a/file")
            try FileManager.default.moveItem(at:a,to:root.appendingPathComponent("held"));try Store.privateDirectory(a);try Data("new".utf8).write(to:a.appendingPathComponent("file"))
            var rejected=false;do {_ = try cursor.parent(of:"a/file")}catch{rejected=true}
            try check(rejected,"bounded directory cache must reject replaced ancestors")
        case "deep": try deep(root)
        case "protocol": try protocolEngine(root)
        case "protocol-thawed-receipt": try protocolEngine(root,staleReceipt:true)
        case "protocol-refrozen-receipt": try protocolEngine(root,staleReceipt:true,refreeze:true)
        case "restore-replay", "restore-replay-split":
            let f=try LatestSnapshotScenarios.Fixture(root,"replay")
            try FileManager.default.linkItem(at:f.helper.live.appendingPathComponent("payload"),to:f.helper.live.appendingPathComponent("alias"))
            let revision=try Snapshot.capture(store:f.store,folder:f.folder,source:f.helper.live,previous:nil)
            let (source,expected)=try Snapshot.verified(store:f.store,id:f.folder.id,revision:revision)
            let stage=root.appendingPathComponent("stage");try Store.privateDirectory(stage)
            try Snapshot.copyTree(from:source,to:stage.appendingPathComponent("data"),manifest:expected,sourceContext:.managedRevision)
            let h=try DirectoryHandle.open(stage),data=try h.child("data"),a=try h.identity(),b=try data.identity()
            var j=try f.store.journal(f.folder.id);j.phase = .restoring;j.revision=revision;j.restoreRevision=revision;j.restoreStage=stage.path
            j.restoreStageDevice=a.device;j.restoreStageInode=a.inode;j.restoreDataDevice=b.device;j.restoreDataInode=b.inode
            try f.store.write(j,for:f.folder.id)
            try data.renameNoReplace("payload",to:DirectoryHandle.open(f.selected),as:"payload") // move before journal checkpoint
            if CommandLine.arguments[2] == "restore-replay-split" {
                let alias=stage.appendingPathComponent("data/alias"),replacement=stage.appendingPathComponent("replacement")
                try check(copyfile(alias.path,replacement.path,nil,copyfile_flags_t(COPYFILE_ALL|COPYFILE_NOFOLLOW))==0,"split alias fixture")
                try check(rename(replacement.path,alias.path)==0,"split alias replace")
            }
            f.helper.mounted=false
            if CommandLine.arguments[2] == "restore-replay-split" {
                do {try f.engine.finalize(f.folder.id.uuidString)} catch {}
                try check(!FileManager.default.fileExists(atPath:f.selected.appendingPathComponent("alias").path),"cross-boundary split rejected before remaining move")
            } else {
                try f.engine.finalize(f.folder.id.uuidString)
                var a=stat(),b=stat();try check(lstat(f.selected.appendingPathComponent("alias").path,&a)==0 && lstat(f.selected.appendingPathComponent("payload").path,&b)==0 && a.st_ino==b.st_ino,"move-before-journal replay preserves aliases")
            }

        case "restore", "restore-corrupt":
            let f=try LatestSnapshotScenarios.Fixture(root,"restore")
            let (source,expected)=try Snapshot.verified(store:f.store,id:f.folder.id,revision:f.initial)
            let stage=root.appendingPathComponent("stage");try Store.privateDirectory(stage)
            try Snapshot.copyTree(from:source,to:stage.appendingPathComponent("data"),manifest:expected,sourceContext:.managedRevision)
            let stageID=try DirectoryHandle.open(stage).identity(),dataID=try DirectoryHandle.open(stage.appendingPathComponent("data")).identity()
            var j=try f.store.journal(f.folder.id);j.phase = .restoring;j.restoreRevision=f.initial;j.restoreStage=stage.path
            j.restoreStageDevice=stageID.device;j.restoreStageInode=stageID.inode;j.restoreDataDevice=dataID.device;j.restoreDataInode=dataID.inode
            try f.store.write(j,for:f.folder.id)
            if CommandLine.arguments[2] == "restore" {
                try FileManager.default.moveItem(at:stage.appendingPathComponent("data"),to:stage.appendingPathComponent("old-data"))
                try Snapshot.copyTree(from:source,to:stage.appendingPathComponent("data"),manifest:expected,sourceContext:.managedRevision)
            } else { try Data("CORRUPT!".utf8).write(to:stage.appendingPathComponent("data/payload")) }
            f.helper.mounted=false
            do { try f.engine.finalize(f.folder.id.uuidString) } catch {}
            try check(!FileManager.default.fileExists(atPath:f.selected.appendingPathComponent("payload").path),"invalid staged data must not be moved before rejection")
        case "uuid":
            let f=try LatestSnapshotScenarios.Fixture(root,"name")
            let selected=root.appendingPathComponent("replacement");try Store.privateDirectory(selected)
            let identity=try DirectoryHandle.open(selected).identity()
            let replacement=Folder(name:"replacement",path:selected.path,capacity:16<<20,device:identity.device,inode:identity.inode)
            _ = try f.store.volume(replacement.id)
            var boundary=f.helper.boundary
            boundary.beforeVolumeLock={ id in
                try check(id == f.folder.id,"lock selected by original UUID")
                let independent=try Store(root:f.store.root)
                try independent.locked {
                    var c=try independent.load();c.folders[0].name="renamed"
                    var renamed=replacement;renamed.name="name";c.folders.append(renamed);try independent.save(c)
                }
            }
            try Engine(store:f.store,session:boundary).save("name")
            try check(try f.store.journal(replacement.id).phase == .idle,"replacement untouched")
            try check(f.helper.commands.contains("export"),"original UUID exported under original lock")
        default: throw NestError("unknown followup case")
        }
    }
}

#if !RAMNEST_FOLLOWUP_STANDALONE
import XCTest

final class SparseExtentFallbackTests: XCTestCase {
    private let page = 65536
    private var length: Int { 20 * page + 37 }
    private struct Payload {
        let name: String, bytes: Data, checksum: String
        let pages: UInt64
    }
    private func payloads() -> [Payload] {
        var sparse = Data(repeating: 0, count: length)
        sparse[3 * page + 17] = 65; sparse[12 * page + 3] = 66
        var tail = sparse; tail[length - 1] = 67
        // Fixed reference digests include padded final pages and logical indices.
        return [
            Payload(name: "dense", bytes: Data(repeating: 90, count: length),
                    checksum: "b4a46de3ff39db4a7b03ca5f83e076b9a62c25b31111a822b561192901cc9e12", pages: 21),
            Payload(name: "sparse", bytes: tail,
                    checksum: "29f3ba0f44fb7f8e400c14aa46d6e889b4522aeb52e792d5515e3d0803fae8b2", pages: 3),
            Payload(name: "trailing-zero", bytes: sparse,
                    checksum: "a400a8dcb30f359dff80c704d37e9595d858b3d0fcafaa114b0d6504248992db", pages: 2),
            Payload(name: "zero", bytes: Data(repeating: 0, count: length),
                    checksum: "ed58828563a71e400ceb079b70c8d0816d2e55bb281afa7c598bb132dd9ad670", pages: 0)
        ]
    }
    private func fixture(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("ramnest-sparse-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }
    private func file(_ root: URL, _ name: String, _ bytes: Data, sparse: Bool = false) throws -> Int32 {
        let fd = open(root.appendingPathComponent(name).path, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw NestError("Sparse test fixture open failed") }
        do {
            guard ftruncate(fd, off_t(bytes.count)) == 0 else { throw NestError("Sparse test truncate failed") }
            for offset in stride(from: 0, to: bytes.count, by: page) {
                let count = min(page, bytes.count - offset)
                if sparse && !bytes[offset..<(offset + count)].contains(where: { $0 != 0 }) { continue }
                let wrote = bytes.withUnsafeBytes { pwrite(fd, $0.baseAddress!.advanced(by: offset), count, off_t(offset)) }
                guard wrote == count else { throw NestError("Sparse test fixture write failed") }
            }
            return fd
        } catch { close(fd); throw error }
    }
    private func supported(_ bytes: Data) -> SparseContent.ExtentSeeker {
        { _, offset, whence in
            XCTAssertEqual(whence, SEEK_DATA)
            guard let next = bytes[Int(offset)...].firstIndex(where: { $0 != 0 }) else {
                errno = ENXIO; return -1
            }
            return off_t(next)
        }
    }
    private func assertIdentity(_ result: SparseContent.Result, _ payload: Payload,
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(result.checksum, "sparse64-v1:" + payload.checksum, payload.name, file: file, line: line)
        XCTAssertEqual(result.allocated, payload.pages * UInt64(page), payload.name, file: file, line: line)
    }
    private func assertCopy(_ source: Int32, _ payload: Payload, _ root: URL, _ name: String,
                            seek: SparseContent.ExtentSeeker) throws {
        let destination = try file(root, name, Data())
        defer { close(destination) }
        try SparseContent.copy(source, to: destination, size: Int64(payload.bytes.count), seekExtent: seek)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(name)), payload.bytes, name)
        assertIdentity(try SparseContent.scan(destination, size: Int64(payload.bytes.count),
                                             seekExtent: supported(payload.bytes)), payload)
    }
    func testUnsupportedExtentsPreserveChecksumAllocationAndExactCopy() throws {
        try fixture { root in
            for payload in payloads() {
                for physicalSparse in [false, true] {
                    let label = payload.name + (physicalSparse ? "-holes" : "-dense")
                    let source = try file(root, label, payload.bytes, sparse: physicalSparse)
                    defer { close(source) }
                    let optimized = try SparseContent.scan(source, size: Int64(length), seekExtent: supported(payload.bytes))
                    assertIdentity(optimized, payload)
                    for code in [EINVAL, ENOTSUP, ENOTTY] {
                        var calls = 0
                        let seek: SparseContent.ExtentSeeker = { _, _, whence in
                            XCTAssertEqual(whence, SEEK_DATA); calls += 1; errno = code; return -1
                        }
                        let scanned = try SparseContent.scan(source, size: Int64(length), seekExtent: seek)
                        assertIdentity(scanned, payload)
                        XCTAssertEqual(scanned.checksum, optimized.checksum)
                        XCTAssertEqual(scanned.allocated, optimized.allocated)
                        XCTAssertEqual(scanned.bytesRead, UInt64(length))
                        XCTAssertEqual(calls, 1, "fallback must disable later extent queries")
                        calls = 0
                        try assertCopy(source, payload, root, label + "-copy-\(code)", seek: seek)
                        XCTAssertEqual(calls, 1)
                    }
                }
            }
        }
    }
    func testUnsupportedExtentsAfterSuccessfulSkip() throws {
        let payload = payloads()[1]
        try fixture { root in
            let source = try file(root, "source", payload.bytes, sparse: true)
            defer { close(source) }
            for code in [EINVAL, ENOTSUP, ENOTTY] {
                var offsets: [off_t] = []
                let seek: SparseContent.ExtentSeeker = { _, offset, whence in
                    XCTAssertEqual(whence, SEEK_DATA); offsets.append(offset)
                    if offsets.count == 1 { return off_t(3 * self.page + 17) }
                    errno = code; return -1
                }
                let result = try SparseContent.scan(source, size: Int64(length), seekExtent: seek)
                assertIdentity(result, payload)
                XCTAssertEqual(result.bytesRead, UInt64(length - 3 * page))
                XCTAssertEqual(offsets, [0, off_t(4 * page)])
                offsets = []
                try assertCopy(source, payload, root, "copy-\(code)", seek: seek)
                XCTAssertEqual(offsets, [0, off_t(4 * page)])
            }
        }
    }
    func testENXIOStillEndsExtentWalk() throws {
        try fixture { root in
            for payload in [payloads()[2], payloads()[3]] {
                let source = try file(root, payload.name, payload.bytes, sparse: true)
                defer { close(source) }
                var calls = 0
                let extent = supported(payload.bytes)
                let seek: SparseContent.ExtentSeeker = { fd, offset, whence in
                    calls += 1; return extent(fd, offset, whence)
                }
                let result = try SparseContent.scan(source, size: Int64(length), seekExtent: seek)
                assertIdentity(result, payload)
                XCTAssertEqual(result.bytesRead, payload.pages * UInt64(page))
                XCTAssertEqual(calls, Int(payload.pages) + 1)
                calls = 0
                try assertCopy(source, payload, root, payload.name + "-copy", seek: seek)
                XCTAssertEqual(calls, Int(payload.pages) + 1)
            }
        }
    }
    func testExtentHardErrorsRemainFatalBeforeAndAfterSkip() throws {
        let payload = payloads()[1]
        try fixture { root in
            let source = try file(root, "source", payload.bytes, sparse: true)
            defer { close(source) }
            for code in [EIO, EBADF, EPERM] {
                for skip in [false, true] {
                    var calls = 0
                    let seek: SparseContent.ExtentSeeker = { _, _, _ in
                        calls += 1
                        if skip && calls == 1 { return off_t(3 * self.page + 17) }
                        errno = code; return -1
                    }
                    func check(_ error: Error) {
                        XCTAssertEqual((error as? NestError)?.code, 6)
                        XCTAssertTrue(error.localizedDescription.contains("errno \(code)"))
                    }
                    XCTAssertThrowsError(try SparseContent.scan(source, size: Int64(length), seekExtent: seek)) { check($0) }
                    XCTAssertEqual(calls, skip ? 2 : 1)
                    calls = 0
                    let destination = try file(root, "error-\(code)-\(skip)", Data())
                    defer { close(destination) }
                    XCTAssertThrowsError(try SparseContent.copy(source, to: destination, size: Int64(length), seekExtent: seek)) { check($0) }
                    XCTAssertEqual(calls, skip ? 2 : 1)
                }
            }
        }
    }
    func testLegacyAndSmallHashesDoNotQueryExtents() throws {
        try fixture { root in
            let seek: SparseContent.ExtentSeeker = { _, _, _ in
                XCTFail("legacy and small hashes must retain sequential SHA256"); errno = EIO; return -1
            }
            let dense = try file(root, "dense", payloads()[0].bytes)
            defer { close(dense) }
            let legacy = try SparseContent.scan(dense, size: Int64(length), legacy: true, seekExtent: seek)
            XCTAssertEqual(legacy.checksum, "f1874f462d463d368ff5923cc6bc1bd5e16e948d2108fc31057dd8c11407633e")
            XCTAssertEqual(legacy.allocated, 21 * UInt64(page))
            let bytes = Data("small payload".utf8), small = try file(root, "small", bytes)
            defer { close(small) }
            let result = try SparseContent.scan(small, size: Int64(bytes.count), seekExtent: seek)
            XCTAssertEqual(result.checksum, "5bfcd728e8dd338dac05e838f287e56fe4fcb154754cbfb408bb72042df90935")
            XCTAssertEqual(result.allocated, UInt64(page))
        }
    }
}

final class FSKitSymlinkJournalTests: XCTestCase {
    func testMalformedSymlinkLayoutCannotFallBackToLegacyRecovery() throws {
        let base = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Journal())) as! [String: Any]
        let invalid: [Any] = [NSNull(), [:] as [String: Any], ["version": 999], ["version": NSNull()]]
        for record in invalid {
            var wire = base
            wire["fsKitLink"] = record
            let data = try JSONSerialization.data(withJSONObject: wire)
            XCTAssertThrowsError(try JSONDecoder().decode(Journal.self, from: data),
                                 "Present but invalid symlink authority must not select legacy recovery")
        }
    }

    func testAbsentSymlinkLayoutPreservesLegacyBackendJournal() throws {
        for backend in Configuration.Backend.allCases {
            var journal = Journal()
            journal.backend = backend
            let data = try JSONEncoder().encode(journal)
            let wire = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            XCTAssertNil(wire["fsKitLink"])
            XCTAssertEqual(try JSONDecoder().decode(Journal.self, from: data), journal)
        }
    }
}

/// Owned disk fixtures exercise production transaction helpers. The session
/// closures model protocol responses; they are not evidence of an OS mount.
final class FSKitSymlinkLifecycleTests: XCTestCase {
    final class Fixture {
        let root: URL, selected: URL, mountRoot: URL, store: Store, folder: Folder
        let initial: String, expected: Manifest
        var journal: Journal
        var mounted = true
        var active = false
        var commands: [String] = []
        var readPaths: [String] = []
        var failExport = false
        var failPopulationRead = false
        lazy var engine: Engine = {
            var boundary = EngineSession()
            boundary.fsKitMountRoot = mountRoot
            boundary.populationRead = { [unowned self] url in
                self.readPaths.append(url.path)
                if self.failPopulationRead { throw NestError("Injected physical readback failure") }
                return self.expected
            }
            boundary.mountedIdentity = { [unowned self] _, _ in self.mounted }
            boundary.status = { [unowned self] j, id in
                guard j.socket != nil else { throw NestError("No fixture helper") }
                return HelperStatus(id: id, pid: getpid(), mounted: self.mounted, used: 0, capacity: self.folder.capacity, active: self.active)
            }
            boundary.request = { [unowned self] _, command in
                let fields = command.components(separatedBy: "\t")
                self.commands.append(fields[0])
                if fields[0] == "freeze", !self.active {
                    // Match Helper.cpp: guarded pre-activation trees are already
                    // frozen, and the active-only freeze command returns EBUSY.
                    throw NestError("Native helper rejects freeze before activation", code: 6)
                }
                if fields[0] == "activate" {
                    let durable = try self.store.journal(self.folder.id)
                    guard durable.populationVerified, durable.fsKitLink?.stage == .linked else { throw NestError("Activation preceded durable link/readback") }
                    self.active = true
                }
                if fields[0] == "export" || fields[0] == "quiesce" {
                    if self.failExport { throw NestError("Injected checkpoint failure") }
                    let live = URL(fileURLWithPath: self.journal.fsKitLink!.mountPath)
                    let manifest = try Snapshot.manifest(live)
                    try Snapshot.copyTree(from: live, to: URL(fileURLWithPath: fields[1]), manifest: manifest)
                }
                return []
            }
            boundary.unmount = { [unowned self] path in
                guard path == self.journal.fsKitLink?.mountPath else { throw NestError("Unmount used original path") }
                self.mounted = false
                // Model disappearance of the mounted namespace, leaving the
                // recorded empty physical reservation. No OS mount is changed.
                try FileManager.default.removeItem(at: URL(fileURLWithPath: path).appendingPathComponent("payload"))
            }
            return Engine(store: store, session: boundary)
        }()
        init(temporary: Bool = false, trash: Bool = false, sourceMode: mode_t = 0o700, fixtureRoot: URL? = nil) throws {
            let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            root = fixtureRoot ?? project.appendingPathComponent("artifacts/debug-io-instrumentation/symlink-tests-\(UUID().uuidString)")
            try Store.privateDirectory(root)
            let sourceParent = root.appendingPathComponent("original-parent"); try Store.privateDirectory(sourceParent)
            selected = sourceParent.appendingPathComponent("selected"); try Store.privateDirectory(selected)
            mountRoot = root.appendingPathComponent("RAMNest-Mounts-\(getuid())")
            store = try Store(root: root.appendingPathComponent("store"))
            store.fsKitFixtureRoot = mountRoot
            let identity = try DirectoryHandle.open(selected).identity()
            var options = FolderOptions(); options.sync = !temporary
            folder = Folder(name: "Original label", path: selected.path, capacity: 16 << 20, device: identity.device, inode: identity.inode, options: options)
            var config = Configuration(); config.backend = .fskit; config.folders = [folder]; try store.save(config)
            try Data("original".utf8).write(to: selected.appendingPathComponent("payload"))
            if trash {
                try Store.privateDirectory(selected.appendingPathComponent(".Trashes"))
                try Data("opaque disk Trash".utf8).write(to: selected.appendingPathComponent(".Trashes/retained"))
            }
            // Establish only this owned fixture's initial admission metadata.
            guard chmod(selected.path, sourceMode) == 0 else { throw NestError("Cannot prepare owned source mode") }
            initial = try Snapshot.capture(store: store, folder: folder, source: selected, previous: nil)
            expected = try Snapshot.verified(store: store, id: folder.id, revision: initial).1
            journal = Journal(); journal.phase = .preparing; journal.backend = .fskit; journal.session = UUID()
            journal.revision = initial; journal.initialRevision = initial; journal.socket = "owned-fixture-socket"
            // Only the filesystem-location preflight is injected. Reservation,
            // inode binding, no-follow checks and all mutations are production.
            journal.fsKitLink = try FSKitLinks.reserve(folder, session: journal.session!, root: mountRoot, filesystemCheck: { _ in })
            try store.write(journal, for: folder.id)
        }
        func dispose() { try? FileManager.default.removeItem(at: root) }
        func evacuate() throws -> (DirectoryHandle, URL) { try engine.evacuateOriginal(folder, journal: &journal, expected: expected) }
        func activate() throws {
            let (source, holding) = try evacuate()
            let live = URL(fileURLWithPath: journal.fsKitLink!.mountPath)
            try Data("original".utf8).write(to: live.appendingPathComponent("payload"))
            journal.mountedDevice = 999; journal.phase = .mounting; try store.write(journal, for: folder.id)
            try engine.verifyAndActivatePopulation(folder, journal: &journal, expected: expected, source: source, original: holding)
        }
        func value() throws -> String { try String(contentsOf: selected.appendingPathComponent("payload"), encoding: .utf8) }
    }
    func testMountArgumentsMapPhysicalPathAndKeepSourceDistinct() throws {
        let f = try Fixture(); defer { f.dispose() }
        let source = try Snapshot.dataURL(store: f.store, id: f.folder.id, revision: f.initial)
        let args = try f.engine.helperArguments(f.folder, journal: f.journal, source: source)
        XCTAssertEqual(args[args.firstIndex(of: "--mount")! + 1], f.journal.fsKitLink!.mountPath)
        XCTAssertEqual(args[args.firstIndex(of: "--source")! + 1], source.path)
        XCTAssertEqual(URL(fileURLWithPath: f.journal.fsKitLink!.mountPath).lastPathComponent, "selected")
        f.journal.fsKitLink = nil
        XCTAssertEqual(try f.engine.helperArguments(f.folder, journal: f.journal, source: source)[args.firstIndex(of: "--mount")! + 1], f.selected.path)
    }
    func testWholeDirectoryEvacuationPreservesRootAndChildIdentities() throws {
        let f = try Fixture(); defer { f.dispose() }
        let before = try DirectoryHandle.open(f.selected).entryStat("payload")
        let (_, holding) = try f.evacuate()
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.selected.path))
        XCTAssertEqual(try DirectoryHandle.open(holding).identity().inode, f.folder.inode)
        XCTAssertEqual(try DirectoryHandle.open(holding).entryStat("payload").st_ino, before.st_ino)
        XCTAssertEqual(try f.store.journal(f.folder.id).fsKitLink?.stage, .evacuated)
    }
    func testLinkPublicationReadbackPrecedesActivationAndKeepsOriginalUsable() throws {
        let f = try Fixture(); defer { f.dispose() }; try f.activate()
        XCTAssertEqual(try f.value(), "original")
        XCTAssertEqual(f.readPaths, [f.journal.fsKitLink!.mountPath])
        XCTAssertEqual(f.commands, ["activate"])
        XCTAssertTrue(f.engine.mountedIdentity(f.folder, f.journal))
        XCTAssertThrowsError(try Paths.checkedIdentity(f.folder), "Global symlink rejection must remain strict")
    }
    func testExactBasenameCollisionRefusesWithoutTouchingSource() throws {
        let f = try Fixture(); defer { f.dispose() }
        XCTAssertThrowsError(try FSKitLinks.reserve(f.folder, session: UUID(), root: f.mountRoot, filesystemCheck: { _ in }))
        try Paths.checkedIdentity(f.folder)
        XCTAssertEqual(try f.value(), "original")
        XCTAssertEqual(try DirectoryHandle.open(f.mountRoot).names(), ["selected"])
    }
    func testTemporaryEjectPreservesOriginalRootAndChildObjects() throws {
        let f = try Fixture(temporary: true); defer { f.dispose() }
        let child = try DirectoryHandle.open(f.selected).entryStat("payload").st_ino
        try f.activate()
        try Data("discard RAM".utf8).write(to: f.selected.appendingPathComponent("payload"))
        try f.engine.unmount(f.folder.id.uuidString, ignoreBusy: true)
        XCTAssertEqual(try f.value(), "original")
        XCTAssertEqual(try DirectoryHandle.open(f.selected).identity().inode, f.folder.inode)
        XCTAssertEqual(try DirectoryHandle.open(f.selected).entryStat("payload").st_ino, child)
        XCTAssertFalse(f.commands.contains("quiesce"))
        XCTAssertTrue(f.commands.contains("retire"))
    }
    func testNormalEjectRestoresLatestRAMAndRefreshesConfigurationIdentity() throws {
        let f = try Fixture(); defer { f.dispose() }; try f.activate()
        try Data("latest RAM".utf8).write(to: f.selected.appendingPathComponent("payload"))
        try f.engine.unmount(f.folder.id.uuidString, ignoreBusy: true)
        XCTAssertEqual(try f.value(), "latest RAM")
        let updated = try f.engine.folder(f.folder.id.uuidString)
        XCTAssertNotEqual(updated.inode, f.folder.inode); try Paths.checkedIdentity(updated)
        let j = try f.store.journal(f.folder.id)
        XCTAssertEqual(j.phase, .idle); XCTAssertTrue(j.fsKitLink!.mountReleased)
        XCTAssertFalse(FileManager.default.fileExists(atPath: j.fsKitLink!.mountPath))
        XCTAssertTrue(f.commands.firstIndex(of: "quiesce")! < f.commands.firstIndex(of: "retire")!)
    }
    func testCheckpointFailureRetainsRAMLinkAndOriginalHolding() throws {
        let f = try Fixture(); defer { f.dispose() }; try f.activate(); f.failExport = true
        XCTAssertThrowsError(try f.engine.unmount(f.folder.id.uuidString, ignoreBusy: true))
        XCTAssertTrue(f.mounted); XCTAssertFalse(f.commands.contains("retire"))
        XCTAssertEqual(try f.value(), "original")
        XCTAssertEqual(try DirectoryHandle.open(f.journal.fsKitLink!.originalDataURL).identity().inode, f.folder.inode)
    }
    func testLinkReplacementBlocksSaveAndRetainsReplacement() throws {
        let f = try Fixture(); defer { f.dispose() }; try f.activate()
        try FileManager.default.removeItem(at: f.selected)
        try Store.privateDirectory(f.selected)
        try Data("foreign".utf8).write(to: f.selected.appendingPathComponent("payload"))
        XCTAssertThrowsError(try f.engine.save(f.folder.id.uuidString))
        XCTAssertEqual(try f.value(), "foreign"); XCTAssertFalse(f.commands.contains("export"))
    }
    func testHoldingAndMountRootReplacementFailClosed() throws {
        for replaceRoot in [false, true] {
            let f = try Fixture(); defer { f.dispose() }; _ = try f.evacuate()
            let target = replaceRoot ? f.mountRoot : URL(fileURLWithPath: f.journal.fsKitLink!.holdingPath)
            try FileManager.default.moveItem(at: target, to: target.appendingPathExtension("retained"))
            try Store.privateDirectory(target)
            XCTAssertThrowsError(try f.engine.restoreLinkedOriginal(f.folder, journal: &f.journal, temporary: true))
            XCTAssertTrue(FileManager.default.fileExists(atPath: target.appendingPathExtension("retained").path))
        }
    }
    func testDecoderRejectsUnknownFieldsBackendAndIncoherentStages() throws {
        let f = try Fixture(); defer { f.dispose() }
        let base = try JSONSerialization.jsonObject(with: JSONEncoder().encode(f.journal)) as! [String: Any]
        for mutation in ["version", "unknown", "stage", "backend", "null-identity"] {
            var wire = base, layout = wire["fsKitLink"] as! [String: Any]
            switch mutation {
            case "version": layout["version"] = 2
            case "unknown": layout["unrecognizedAuthority"] = true
            case "stage": layout["stage"] = "linked"
            case "backend": wire["backend"] = "nfs"
            default: layout["parent"] = NSNull()
            }
            wire["fsKitLink"] = layout
            XCTAssertThrowsError(try f.store.journalDecoder.decode(Journal.self, from: JSONSerialization.data(withJSONObject: wire)))
        }
    }
    func testEvacuationRenameCrashRecoversFromBoundHoldingIdentity() throws {
        let f = try Fixture(); defer { f.dispose() }
        f.store.beforeJournalWrite = { j, _ in if j.fsKitLink?.stage == .evacuated { throw NestError("Injected after rename before checkpoint") } }
        XCTAssertThrowsError(try f.evacuate()); f.store.beforeJournalWrite = nil
        var durable = try f.store.journal(f.folder.id)
        XCTAssertEqual(durable.fsKitLink?.stage, .evacuating)
        try f.engine.restoreLinkedOriginal(f.folder, journal: &durable, temporary: true)
        XCTAssertEqual(try f.value(), "original"); try Paths.checkedIdentity(f.folder)
    }
    func testPublicationSwapCrashResumesLatestDestinationBeforeConfig() throws {
        let f = try Fixture(); defer { f.dispose() }; try f.activate()
        try Data("committed RAM".utf8).write(to: f.selected.appendingPathComponent("payload"))
        f.store.beforeJournalWrite = { j, _ in if j.fsKitLink?.stage == .restored { throw NestError("Injected after swap before checkpoint") } }
        XCTAssertThrowsError(try f.engine.unmount(f.folder.id.uuidString, ignoreBusy: true))
        f.store.beforeJournalWrite = nil
        XCTAssertFalse(f.commands.contains("retire"))
        XCTAssertEqual(try f.value(), "committed RAM")
        try f.engine.finalize(f.folder.id.uuidString)
        XCTAssertEqual(try f.value(), "committed RAM")
        try Paths.checkedIdentity(f.engine.folder(f.folder.id.uuidString))
    }
    func testRestoredCheckpointRevalidatesCompletedRenameBeforeConfiguration() throws {
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for replace in [false, true] {
            let root = project.appendingPathComponent("artifacts/source-race-fix/review-restored-\(UUID().uuidString)")
            let f = try Fixture(fixtureRoot: root); defer { f.dispose() }
            try f.activate()
            try Data("committed RAM".utf8).write(to: f.selected.appendingPathComponent("payload"))
            var checkpoint: Journal?
            f.store.beforeJournalWrite = { journal, _ in
                if journal.fsKitLink?.stage == .restored {
                    checkpoint = journal
                    throw NestError("Injected restored checkpoint before configuration")
                }
            }
            XCTAssertThrowsError(try f.engine.unmount(f.folder.id.uuidString, ignoreBusy: true))
            f.store.beforeJournalWrite = nil
            var durable = try XCTUnwrap(checkpoint)
            XCTAssertNotNil(durable.publicationRename?.after)
            try f.store.write(durable, for: f.folder.id)
            let beforeConfig = try Data(contentsOf: f.store.root.appendingPathComponent("configuration.json"))
            if replace {
                let payload = f.selected.appendingPathComponent("payload")
                let before = try Snapshot.manifest(f.selected)
                let copy = f.root.appendingPathComponent("identical-replacement")
                try FileManager.default.copyItem(at: payload, to: copy)
                try FileManager.default.removeItem(at: payload)
                try FileManager.default.moveItem(at: copy, to: payload)
                XCTAssertTrue(try Snapshot.manifest(f.selected).matchesExpected(before), "Replacement is invisible to manifest-only checks")
                XCTAssertThrowsError(try f.engine.finishLinkedRestore(f.folder, journal: &durable))
                XCTAssertEqual(try Data(contentsOf: f.store.root.appendingPathComponent("configuration.json")), beforeConfig)
                XCTAssertEqual(try f.store.journal(f.folder.id).fsKitLink?.stage, .restored)
                XCTAssertTrue(FileManager.default.fileExists(atPath: f.journal.fsKitLink!.originalDataURL.path))
            } else {
                try f.engine.finishLinkedRestore(f.folder, journal: &durable)
                XCTAssertEqual(durable.phase, .idle)
                try Paths.checkedIdentity(f.engine.folder(f.folder.id.uuidString))
            }
        }
    }
    func testMountpointCleanupRefusesReplacedReservation() throws {
        let f = try Fixture(); defer { f.dispose() }
        let mount = URL(fileURLWithPath: f.journal.fsKitLink!.mountPath)
        try FileManager.default.moveItem(at: mount, to: mount.appendingPathExtension("retained"))
        try Store.privateDirectory(mount)
        XCTAssertThrowsError(try FSKitLinks.releaseMountpoint(f.journal.fsKitLink!))
        XCTAssertTrue(FileManager.default.fileExists(atPath: mount.path))
    }
    func testSourceParentReplacementRetainsBothTrees() throws {
        let f = try Fixture(); defer { f.dispose() }; _ = try f.evacuate()
        let parent = f.selected.deletingLastPathComponent(), retained = parent.appendingPathExtension("retained")
        try FileManager.default.moveItem(at: parent, to: retained)
        try Store.privateDirectory(parent); try Store.privateDirectory(f.selected)
        try Data("replacement".utf8).write(to: f.selected.appendingPathComponent("payload"))
        XCTAssertThrowsError(try f.engine.restoreLinkedOriginal(f.folder, journal: &f.journal, temporary: true))
        XCTAssertEqual(try f.value(), "replacement")
        XCTAssertTrue(FileManager.default.fileExists(atPath: retained.appendingPathComponent(URL(fileURLWithPath: f.journal.fsKitLink!.holdingPath).lastPathComponent).path))
    }
    func testExternalDisconnectFinalizationCapturesRetainedLatestRAM() throws {
        let f = try Fixture(); defer { f.dispose() }; try f.activate()
        try Data("externally ejected RAM".utf8).write(to: f.selected.appendingPathComponent("payload"))
        // Helper RAM is modeled separately from the now-empty mount reservation.
        let retained = f.root.appendingPathComponent("retained-ram")
        let physical = URL(fileURLWithPath: f.journal.fsKitLink!.mountPath)
        let manifest = try Snapshot.manifest(physical)
        try Snapshot.copyTree(from: physical, to: retained, manifest: manifest)
        try FileManager.default.removeItem(at: physical.appendingPathComponent("payload")); f.mounted = false
        var boundary = EngineSession(); boundary.fsKitMountRoot = f.mountRoot
        boundary.status = { j, id in HelperStatus(id: id, pid: getpid(), mounted: false, used: 0, capacity: f.folder.capacity, active: false) }
        boundary.request = { _, command in
            let fields = command.components(separatedBy: "\t")
            if fields[0] == "quiesce" { try Snapshot.copyTree(from: retained, to: URL(fileURLWithPath: fields[1]), manifest: Snapshot.manifest(retained)) }
            return []
        }
        try Engine(store: f.store, session: boundary).finalize(f.folder.id.uuidString)
        XCTAssertEqual(try f.value(), "externally ejected RAM")
        XCTAssertEqual(try f.store.journal(f.folder.id).phase, .idle)
    }
    func testDiskTrashBackupIsRetainedWithWarningAfterNormalRestore() throws {
        let f = try Fixture(trash: true); defer { f.dispose() }; try f.activate()
        let holding = URL(fileURLWithPath: f.journal.fsKitLink!.holdingPath)
        try f.engine.unmount(f.folder.id.uuidString, ignoreBusy: true)
        XCTAssertEqual(try String(contentsOf: holding.appendingPathComponent("data/.Trashes/retained"), encoding: .utf8), "opaque disk Trash")
        XCTAssertNotNil(try f.store.journal(f.folder.id).cleanupWarning)
    }
    func testInterruptedRestoreCopyRetainsBackupCheckpointAndHelper() throws {
        let f = try Fixture(); defer { f.dispose() }; try f.activate()
        f.store.beforeJournalWrite = { j, _ in
            if j.fsKitLink?.stage == .restoring, let stage = j.restoreStage {
                // A foreign child conflicts with copyTree's required new data
                // destination. The recorded stage itself remains pinned.
                try Store.privateDirectory(URL(fileURLWithPath: stage).appendingPathExtension("data"))
            }
        }
        XCTAssertThrowsError(try f.engine.unmount(f.folder.id.uuidString, ignoreBusy: true)); f.store.beforeJournalWrite = nil
        let durable = try f.store.journal(f.folder.id)
        XCTAssertNotNil(durable.restoreStage); XCTAssertNotNil(durable.restoreRevision)
        XCTAssertTrue(FileManager.default.fileExists(atPath: durable.fsKitLink!.holdingPath))
        XCTAssertFalse(f.commands.contains("retire"))
        XCTAssertThrowsError(try f.engine.finalize(f.folder.id.uuidString))
    }
    func testConfigWrittenBeforeIdleJournalCanResume() throws {
        let f = try Fixture(); defer { f.dispose() }; try f.activate()
        try Data("new committed content".utf8).write(to: f.selected.appendingPathComponent("payload"))
        f.store.beforeJournalWrite = { j, _ in if j.phase == .idle { throw NestError("Injected config-to-idle boundary") } }
        XCTAssertThrowsError(try f.engine.unmount(f.folder.id.uuidString, ignoreBusy: true)); f.store.beforeJournalWrite = nil
        let updated = try f.engine.folder(f.folder.id.uuidString)
        XCTAssertNotEqual(updated.inode, f.folder.inode)
        XCTAssertEqual(try f.store.journal(f.folder.id).fsKitLink?.stage, .restored)
        try f.engine.finalize(f.folder.id.uuidString)
        XCTAssertEqual(try f.value(), "new committed content"); try Paths.checkedIdentity(updated)
    }
    func testLinkRenameCrashRestoresOnlyBoundOriginal() throws {
        let f = try Fixture(); defer { f.dispose() }; _ = try f.evacuate()
        f.store.beforeJournalWrite = { j, _ in if j.fsKitLink?.stage == .linked { throw NestError("Injected after link rename") } }
        XCTAssertThrowsError(try f.engine.publishOriginalLink(f.folder, journal: &f.journal)); f.store.beforeJournalWrite = nil
        var durable = try f.store.journal(f.folder.id)
        XCTAssertEqual(durable.fsKitLink?.stage, .linking)
        try f.engine.restoreLinkedOriginal(f.folder, journal: &durable, temporary: true)
        XCTAssertEqual(try f.value(), "original"); try Paths.checkedIdentity(f.folder)
    }
    func testLinkIntentCrashBeforeRenameCleansOnlyOwnedStagedLink() throws {
        let f = try Fixture(); defer { f.dispose() }; _ = try f.evacuate()
        // Publish the linking intent, then simulate the rename not occurring.
        try f.engine.publishOriginalLink(f.folder, journal: &f.journal)
        let parent = try DirectoryHandle.open(f.selected.deletingLastPathComponent())
        let staged = URL(fileURLWithPath: f.journal.fsKitLink!.linkStagePath).lastPathComponent
        try parent.renameNoReplace(f.selected.lastPathComponent, to: parent, as: staged); try parent.sync()
        f.journal.fsKitLink!.stage = .linking; try f.store.write(f.journal, for: f.folder.id)
        try f.engine.restoreLinkedOriginal(f.folder, journal: &f.journal, temporary: true)
        XCTAssertEqual(try f.value(), "original"); XCTAssertFalse(try parent.exists(staged))
    }
    func testRestoredDestinationReplacementBlocksConfigTransition() throws {
        let f = try Fixture(); defer { f.dispose() }; try f.activate()
        f.store.beforeJournalWrite = { j, _ in if j.fsKitLink?.stage == .restored { throw NestError("Injected after restore swap") } }
        XCTAssertThrowsError(try f.engine.unmount(f.folder.id.uuidString, ignoreBusy: true)); f.store.beforeJournalWrite = nil
        let retained = f.selected.appendingPathExtension("restored-retained")
        try FileManager.default.moveItem(at: f.selected, to: retained); try Store.privateDirectory(f.selected)
        try Data("foreign destination".utf8).write(to: f.selected.appendingPathComponent("payload"))
        XCTAssertThrowsError(try f.engine.finalize(f.folder.id.uuidString))
        XCTAssertEqual(try f.value(), "foreign destination")
        XCTAssertEqual(try f.engine.folder(f.folder.id.uuidString).inode, f.folder.inode)
        XCTAssertTrue(FileManager.default.fileExists(atPath: retained.appendingPathComponent("payload").path))
    }
    func testUnjournaledStagedLinkIsRetainedWithoutAdoption() throws {
        let f = try Fixture(); defer { f.dispose() }; _ = try f.evacuate()
        f.store.beforeJournalWrite = { j, _ in if j.fsKitLink?.stage == .linking { throw NestError("Injected before link identity checkpoint") } }
        XCTAssertThrowsError(try f.engine.publishOriginalLink(f.folder, journal: &f.journal)); f.store.beforeJournalWrite = nil
        var durable = try f.store.journal(f.folder.id)
        XCTAssertNil(durable.fsKitLink?.link)
        XCTAssertThrowsError(try f.engine.restoreLinkedOriginal(f.folder, journal: &durable, temporary: true))
        XCTAssertEqual(try f.value(), "original", "Disk restoration may commit; unknown staging still blocks cleanup/retirement")
        var st = stat(); XCTAssertEqual(lstat(durable.fsKitLink!.linkStagePath, &st), 0); XCTAssertEqual(st.st_mode & S_IFMT, S_IFLNK)
    }
    func testInternalFilesystemPreflightFailureOccursBeforeReservation() throws {
        let f = try Fixture(); defer { f.dispose() }
        let other = f.root.appendingPathComponent("preflight-parent"); try Store.privateDirectory(other)
        let root = other.appendingPathComponent("RAMNest-Mounts-\(getuid())")
        XCTAssertThrowsError(try FSKitLinks.reserve(f.folder, session: UUID(), root: root, filesystemCheck: { _ in throw NestError("Injected external filesystem") }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path)); try Paths.checkedIdentity(f.folder)
    }
    func testFailedPhysicalReadbackNeverPublishesOrActivatesAndCanEjectGuarded() throws {
        let f = try Fixture(); defer { f.dispose() }; f.failPopulationRead = true
        XCTAssertThrowsError(try f.activate())
        XCTAssertFalse(f.active); XCTAssertFalse(f.commands.contains("activate"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.selected.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.journal.fsKitLink!.holdingPath))
        try f.engine.unmount(f.folder.id.uuidString, ignoreBusy: true)
        XCTAssertEqual(try f.value(), "original"); try Paths.checkedIdentity(f.folder)
        XCTAssertFalse(f.commands.contains("quiesce")); XCTAssertTrue(f.commands.contains("retire"))
    }
    func testUnsafeMountRootModeRefusesBeforeEvacuation() throws {
        let f = try Fixture(); defer { f.dispose() }
        let handle = try DirectoryHandle.open(f.mountRoot)
        XCTAssertEqual(fchmod(handle.fd, 0o755), 0)
        XCTAssertThrowsError(try f.evacuate()); try Paths.checkedIdentity(f.folder)
        XCTAssertEqual(try f.value(), "original")
    }
    func testCentralDecoderRejectsNonProductionRootWithoutFixtureContext() throws {
        let f = try Fixture(); defer { f.dispose() }
        let data = try JSONEncoder().encode(f.journal)
        XCTAssertThrowsError(try JSONDecoder().decode(Journal.self, from: data))
        XCTAssertEqual(try f.store.journalDecoder.decode(Journal.self, from: data), f.journal)
    }
    func testPublicSourceModeNormalAndTemporaryRestoresPreserveMetadataAndCleanWrapper() throws {
        for temporary in [false, true] {
            let f = try Fixture(temporary: temporary, sourceMode: 0o755); defer { f.dispose() }
            try f.activate()
            let layout = f.journal.fsKitLink!, wrapper = URL(fileURLWithPath: layout.holdingPath)
            let parent = try DirectoryHandle.open(wrapper.deletingLastPathComponent())
            XCTAssertEqual(try parent.entryStat(wrapper.lastPathComponent).st_mode & 0o7777, 0o700)
            XCTAssertEqual(try DirectoryHandle.open(wrapper).entryStat("data").st_mode & 0o7777, 0o755)
            let before = try DirectoryHandle.open(layout.originalDataURL).entryStat("payload").st_ino
            // Model the original logical root mode in the mounted view.
            try Snapshot.restorePublicRootMetadata(from: DirectoryHandle.open(layout.originalDataURL),
                to: DirectoryHandle.open(URL(fileURLWithPath: layout.mountPath)), manifest: f.expected)
            try f.engine.unmount(f.folder.id.uuidString, ignoreBusy: true)
            let updated = try f.engine.folder(f.folder.id.uuidString)
            XCTAssertEqual(try DirectoryHandle.open(f.selected.deletingLastPathComponent()).entryStat(f.selected.lastPathComponent).st_mode & 0o7777, 0o755)
            if temporary {
                XCTAssertEqual(updated.inode, f.folder.inode)
                XCTAssertEqual(try DirectoryHandle.open(f.selected).entryStat("payload").st_ino, before)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: wrapper.path))
            XCTAssertNil(try f.store.journal(f.folder.id).cleanupWarning)
            try f.engine.recover(f.folder.id.uuidString)
            XCTAssertFalse(FileManager.default.fileExists(atPath: wrapper.path))
        }
    }
    func testACLAddedAfterReservationBlocksOperationalReopen() throws {
        let f = try Fixture(); defer { f.dispose() }
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/chmod")
        p.arguments = ["+a", "everyone allow add_file,add_subdirectory,delete_child", f.mountRoot.path]
        try p.run(); p.waitUntilExit(); XCTAssertEqual(p.terminationStatus, 0)
        XCTAssertThrowsError(try FSKitLinks.root(f.journal.fsKitLink!))
        XCTAssertThrowsError(try f.evacuate()); try Paths.checkedIdentity(f.folder)
    }
    func testWrapperCheckpointFailureRetainsUnknownWrapperAndUntouchedSource() throws {
        let f = try Fixture(); defer { f.dispose() }
        f.store.beforeJournalWrite = { j, _ in if j.fsKitLink?.stage == .evacuating { throw NestError("Injected wrapper identity checkpoint failure") } }
        XCTAssertThrowsError(try f.evacuate()); f.store.beforeJournalWrite = nil
        var durable = try f.store.journal(f.folder.id)
        XCTAssertNil(durable.fsKitLink?.holding); try Paths.checkedIdentity(f.folder)
        XCTAssertThrowsError(try f.engine.restoreLinkedOriginal(f.folder, journal: &durable, temporary: true))
        XCTAssertTrue(FileManager.default.fileExists(atPath: durable.fsKitLink!.holdingPath))
        XCTAssertEqual(try f.value(), "original")
    }
    func testCaseCollidingReservationNeverSuffixesOrAdoptsExistingDirectory() throws {
        let f = try Fixture(); defer { f.dispose() }
        let otherParent = f.root.appendingPathComponent("other-parent"); try Store.privateDirectory(otherParent)
        let selected = otherParent.appendingPathComponent("SELECTED"); try Store.privateDirectory(selected)
        let identity = try DirectoryHandle.open(selected).identity()
        let other = Folder(name: "Case collision", path: selected.path, capacity: f.folder.capacity, device: identity.device, inode: identity.inode)
        let rootHandle = try DirectoryHandle.open(f.mountRoot)
        if try rootHandle.exists("SELECTED") {
            XCTAssertThrowsError(try FSKitLinks.reserve(other, session: UUID(), root: f.mountRoot, filesystemCheck: { _ in }))
            XCTAssertEqual(try rootHandle.names(), ["selected"])
        } else {
            // On case-sensitive storage these are genuinely distinct names;
            // repeated exact reservation must still refuse atomically.
            _ = try FSKitLinks.reserve(other, session: UUID(), root: f.mountRoot, filesystemCheck: { _ in })
            XCTAssertThrowsError(try FSKitLinks.reserve(other, session: UUID(), root: f.mountRoot, filesystemCheck: { _ in }))
            XCTAssertEqual(try rootHandle.names(), ["SELECTED", "selected"])
        }
        try Paths.checkedIdentity(other); try Paths.checkedIdentity(f.folder)
    }
    func testConcurrentExactReservationsHaveOneExclusiveWinner() throws {
        final class Results: @unchecked Sendable {
            let lock = NSLock()
            var successes = 0, failures = 0
            func record(_ success: Bool) {
                lock.lock(); defer { lock.unlock() }
                if success { successes += 1 } else { failures += 1 }
            }
        }
        let f = try Fixture(); defer { f.dispose() }
        try FSKitLinks.releaseMountpoint(f.journal.fsKitLink!)
        let folder = f.folder, root = f.mountRoot, results = Results()
        DispatchQueue.concurrentPerform(iterations: 2) { _ in
            do { _ = try FSKitLinks.reserve(folder, session: UUID(), root: root, filesystemCheck: { _ in }); results.record(true) }
            catch { results.record(false) }
        }
        XCTAssertEqual(results.successes, 1); XCTAssertEqual(results.failures, 1)
        XCTAssertEqual(try DirectoryHandle.open(root).names(), ["selected"])
        try Paths.checkedIdentity(folder)
    }
}
#endif
