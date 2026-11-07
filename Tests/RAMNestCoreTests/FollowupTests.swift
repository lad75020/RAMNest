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
#endif
