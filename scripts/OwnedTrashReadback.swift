import Foundation
import Darwin
@testable import RAMNestCore

// Built beside the owned release CLI, against its exact Core module/dylib.
@main struct OwnedTrashReadback {
    static func main() {
        do {
            let a = CommandLine.arguments
            guard a.count == 4 else { throw NestError("expected SOURCE STORE UUID") }
            let selected = URL(fileURLWithPath:a[1]),store = try Store(root:URL(fileURLWithPath:a[2])),id = UUID(uuidString:a[3])!
            let folder = try Engine(store:store).folder(id.uuidString)
            guard folder.path == selected.path else { throw NestError("Owned source binding mismatch") }
            let journal = try store.journal(id)
            guard let revision = journal.revision else { throw NestError("No owned checkpoint") }
            let (data,expected) = try Snapshot.verified(store:store,id:id,revision:revision)
            let actual = try Snapshot.manifest(selected,matching:expected,phase:"owned-mounted-consumer")
            guard actual.matchesExpected(expected) else { throw NestError("Owned consumer strict included manifest mismatch") }
            guard try Snapshot.excludedDirectoryPaths(data).isEmpty else { throw NestError("New checkpoint physically contains Trash") }
            // Ordinary Foundation consumer after activation: normal directory
            // enumeration, URL metadata, regular bytes, xattrs and alias inodes.
            let normal = selected.appendingPathComponent("normal"),payload = normal.appendingPathComponent("payload")
            guard try FileManager.default.contentsOfDirectory(atPath:normal.path).contains("payload"),
                  try payload.resourceValues(forKeys:[.isRegularFileKey,.fileSizeKey]).isRegularFile == true,
                  try Data(contentsOf:payload) == Data("included payload\n".utf8) else { throw NestError("Foundation consumer readback failed") }
            var first = stat(),alias = stat()
            guard lstat(payload.path,&first) == 0,lstat(selected.appendingPathComponent("alias").path,&alias) == 0,first.st_ino == alias.st_ino else { throw NestError("Consumer hardlink class changed") }
            guard actual.entries.first(where:{$0.path == "alias"})?.attributes["user.trash-test"] == Snapshot.digest(Data("included metadata".utf8)) else { throw NestError("Consumer xattr changed") }
            print("PASS strict included manifest, physical checkpoint omission, Foundation consumer, xattr and hardlinks")
        } catch { FileHandle.standardError.write(Data((error.localizedDescription+"\n").utf8));exit(1) }
    }
}
