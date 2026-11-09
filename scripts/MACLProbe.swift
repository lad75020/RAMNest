import AppKit
import Darwin
@testable import RAMNestCore

// Parent-assisted probe ONLY. No installed application or live directory is
// opened. All grants originate in this run's new user-selected fixture.
@main struct MACLProbe {
    @MainActor static func main() throws {
        let base = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("artifacts/scratch/macl-probe/" + UUID().uuidString)
        try Store.privateDirectory(base)
        let source = base.appendingPathComponent("grant-this-fixture")
        try Store.privateDirectory(source)
        try Data("owned fixture payload".utf8).write(to: source.appendingPathComponent("payload"))
        if CommandLine.arguments.contains("--panel") {
            let panel = NSOpenPanel()
            panel.title = "RAMNest owned MACL fixture"
            panel.message = "Select only grant-this-fixture in this newly created scratch directory. No live data is needed."
            panel.directoryURL = base; panel.canChooseDirectories = true; panel.canChooseFiles = false
            panel.allowsMultipleSelection = false; panel.canCreateDirectories = false
            guard panel.runModal() == .OK, panel.url?.standardizedFileURL == source.standardizedFileURL else {
                throw NestError("Probe cancelled or non-fixture selection rejected before inspection")
            }
        }
        let expected = try Snapshot.manifest(source)
        let copiedURL = base.appendingPathComponent("stage.data")
        let copied = try Snapshot.copyTree(from: source, to: copiedURL, manifest: expected, publicationStaging: true)
        let selected = base.appendingPathComponent("selected")
        try FileManager.default.createSymbolicLink(at: selected, withDestinationURL: base.appendingPathComponent("absent-owned-target"))
        let parent = try DirectoryHandle.open(base)
        let identity = try DirectoryHandle.open(copiedURL).identity()
        let folder = Folder(name: "owned MACL probe", path: selected.path, capacity: 16 << 20, device: identity.device, inode: identity.inode)
        var journal = Journal(); journal.session = UUID()
        var receipt = try VerifiedRenameReceipt(operation: .publication, folder: folder, journal: journal,
            source: copiedURL, destination: parent, wholeRoot: true, matching: copied)
        let name = "com.apple.macl", rawBefore = receipt.before
        print("fixture=\(base.path)")
        print("sourceHasMACL=\(expected.publicRoot?.attributes[name] != nil) stagedHasMACL=\(copied.publicRoot?.attributes[name] != nil)")
        guard renameatx_np(parent.fd, copiedURL.lastPathComponent, parent.fd, selected.lastPathComponent, UInt32(RENAME_SWAP)) == 0 else { throw NestError("fixture RENAME_SWAP errno \(errno)") }
        try parent.sync()
        let observed = try VerifiedRenameReceipt.observe(selected, matching: copied)
        let displacedCount = getxattr(copiedURL.path, name, nil, 0, 0, XATTR_NOFOLLOW | XATTR_SHOWCOMPRESSION)
        print("publishedHasMACL=\(observed.manifest.publicRoot?.attributes[name] != nil) displacedLinkHasMACL=\(displacedCount >= 0)")
        print("sourceUnchanged=\(try Snapshot.manifest(source) == expected) rootIdentityPreserved=\(rawBefore.nodes.first?.inode == observed.nodes.first?.inode)")
        do { try receipt.complete(at: selected); print("receiptComplete=true") }
        catch { print("receiptComplete=false error=\(error.localizedDescription)") }
        // Keep the raw evidence local; never print grant bytes or payloads.
        try Store.atomicJSON(rawBefore, base.appendingPathComponent("before.json"))
        try Store.atomicJSON(observed, base.appendingPathComponent("after.json"))
        try Store.atomicJSON(receipt, base.appendingPathComponent("receipt.json"))
        if CommandLine.arguments.contains("--panel"), copied.publicRoot?.attributes[name] == nil {
            throw NestError("NSOpenPanel did not produce a MACL on this host; no MACL inference is justified")
        }
    }
}
