import Foundation
import Darwin
import RAMNestCore

@main struct RAMNestCLI {
    static let help = """
    RAMNest 1.0 — local-only RAM folders powered by FUSE-T
    Usage: ramnest [--store PATH] COMMAND [arguments] [--json]
      --help / help / --version
      list | ls [--all | -a] [--json]
      info REF [--json]
      create PATH --size 512MB [--name NAME] [--no-mount]
          [--no-sync-folder] [--no-compression] [--no-nobrowse] [--no-mount-at-launch]
          [--periodic MINUTES] [--file-comparison-method checksum|sizeAndModTime]
      mount REF
      unmount | eject REF [--ignore-busy]
      save REF
      resize REF --size 1GB
      rename REF --name NAME
      options REF [--sync-folder|--no-sync-folder] [--nobrowse|--no-nobrowse]
          [--mount-at-launch|--no-mount-at-launch] [--compression|--no-compression] [--periodic MINUTES|--no-periodic]
      delete REF [--keep] [--destroy --confirm-delete]
      recover REF
      export REF DESTINATION [--revision UUID] [--live]
      busy REF
      file-verification [sha256|sizeAndModTime]
      install-cli DIRECTORY
    REF is a name, original path, UUID, or ram://percent-encoded-name.
    create uses an existing directory; defaults: sync/nobrowse/startup on,
    periodic off (15 minutes). Capacity: integer MB/GB, 16 MiB–75% RAM.
    FSEvents suppression is unsupported by FUSE-T; no remote storage.
    Delete defaults to keep. Snapshots are retained for manual recovery.
    Exit codes: 0 success, 1 error, 2 helper, 4 unsafe path, 6 persistence/recovery,
    7 busy processes, 64 invalid usage. JSON errors go to stderr.
    """
    static func main() {
        var args = Array(CommandLine.arguments.dropFirst())
        let json = args.contains("--json")
        do {
            let root: URL?
            if let i = args.firstIndex(of: "--store") {
                guard i+1 < args.count else { throw NestError("--store requires a directory.", code: 64) }
                root = URL(fileURLWithPath: args[i+1]); args.removeSubrange(i...i+1)
            } else { root = nil }
            if args.isEmpty || ["--help", "help", "-h"].contains(args[0]) { print(help); return }
            if args[0] == "--version" { print("RAMNest 1.0.0"); return }
            let command = args.removeFirst()
            var values: [String: String] = [:]; var flags: Set<String> = []; var positional: [String] = []
            let valued: Set<String> = ["--size", "-s", "--name", "-n", "--periodic", "--file-comparison-method", "--revision"]
            let allowed: Set<String> = ["--compression", "--no-compression", "--json", "--all", "-a", "--no-mount", "--keep", "--destroy", "--confirm-delete", "--ignore-busy", "--live", "--sync-folder", "--no-sync-folder", "--nobrowse", "--no-nobrowse", "--mount-at-launch", "--no-mount-at-launch", "--no-periodic"]
            var i = 0
            while i < args.count {
                let value = args[i]
                if valued.contains(value) { guard i+1 < args.count else { throw NestError("\(value) requires a value.", code: 64) }; values[value] = args[i+1]; i += 2 }
                else if allowed.contains(value) { flags.insert(value); i += 1 }
                else if value.hasPrefix("-") { throw NestError("Unknown option: \(value)", code: 64) }
                else { positional.append(value); i += 1 }
            }
            func require(_ count: Int) throws { guard positional.count == count else { throw NestError("\(command) requires \(count) positional arguments. See --help.", code: 64) } }
            func size() throws -> UInt64 { guard let s = values["--size"] ?? values["-s"] else { throw NestError("--size is required.", code: 64) }; return try SizeParser.parse(s) }
            func options(_ initial: FolderOptions) throws -> FolderOptions {
                var o = initial
                for (yes, no) in [("--sync-folder", "--no-sync-folder"), ("--nobrowse", "--no-nobrowse"), ("--mount-at-launch", "--no-mount-at-launch")] where flags.contains(yes) && flags.contains(no) { throw NestError("Conflicting options: \(yes) and \(no)", code: 64) }
                if flags.contains("--compression") { o.compression = true }; if flags.contains("--no-compression") { o.compression = false }
                if flags.contains("--sync-folder") { o.sync = true }; if flags.contains("--no-sync-folder") { o.sync = false }
                if flags.contains("--nobrowse") { o.nobrowse = true }; if flags.contains("--no-nobrowse") { o.nobrowse = false }
                if flags.contains("--mount-at-launch") { o.mountAtLaunch = true }; if flags.contains("--no-mount-at-launch") { o.mountAtLaunch = false }
                if flags.contains("--no-periodic") { o.periodicSave = false }
                if let minutes = values["--periodic"] { guard let n = Int(minutes), FolderOptions.intervals.contains(n) else { throw NestError("Periodic interval must be 5/15/30/60/360/720/1440 minutes.", code: 64) }; o.intervalMinutes = n; o.periodicSave = true }
                if let method = values["--file-comparison-method"] { guard let c = Comparison(rawValue: method) else { throw NestError("Unknown comparison method.", code: 64) }; o.comparison = c }
                return o
            }
            let engine = Engine(store: try StoreLocation().open(explicitRoot: root))
            switch command {
            case "file-verification":
                guard positional.count <= 1 else { throw NestError("file-verification accepts one policy.", code: 64) }
                if let raw = positional.first {
                    guard let policy = FileVerification(rawValue: raw) else { throw NestError("Unknown file verification policy.", code: 64) }
                    _ = try engine.setFileVerification(policy)
                }
                let policy = try engine.fileVerification()
                if json { try output(policy) } else { print("\(policy.rawValue) (next mount; existing sessions and revisions retain their policy)") }
            case "list", "ls":
                try require(0)
                let statuses = try engine.statuses().filter { flags.contains("--all") || flags.contains("-a") || $0.mounted }
                if json { try output(statuses) } else { for s in statuses { print("\(s.folder.name)\t\(s.mounted ? "mounted" : s.journal.phase.rawValue)\t\(s.folder.path)\t\(s.used)/\(s.folder.capacity)") } }
            case "info":
                try require(1); let f = try engine.folder(positional[0]); guard let status = try engine.statuses().first(where: { $0.id == f.id }) else { throw NestError("Folder disappeared.") }
                if json { try output(status) } else { print("\(f.name)\nPath: \(f.path)\nID: \(f.id)\nState: \(status.journal.phase.rawValue), helper \(status.connected ? "connected" : "absent")\nCapacity: \(f.capacity), allocated: \(status.used)\nSnapshot: \(status.journal.revision ?? "none")\nError: \(status.journal.lastError ?? "none")") }
            case "create":
                try require(1); let f = try engine.create(path: URL(fileURLWithPath: (positional[0] as NSString).expandingTildeInPath), name: values["--name"] ?? values["-n"], capacity: size(), options: options(.init()))
                if !flags.contains("--no-mount") { try engine.mount(f.id.uuidString) }
                if json { try output(f) } else { print("Created \(f.name) (\(f.id))") }
            case "mount": try require(1); try engine.mount(positional[0]); try success(json)
            case "unmount", "eject": try require(1); try engine.unmount(positional[0], ignoreBusy: flags.contains("--ignore-busy")); try success(json)
            case "save": try require(1); try engine.save(positional[0]); try success(json)
            case "resize": try require(1); try engine.resize(positional[0], capacity: size()); try success(json)
            case "rename":
                try require(1); guard let name = values["--name"] ?? values["-n"] else { throw NestError("--name is required.", code: 64) }; var f = try engine.folder(positional[0]); f.name = name; try engine.update(f); try success(json)
            case "options": try require(1); var f = try engine.folder(positional[0]); f.options = try options(f.options); try engine.update(f); try success(json)
            case "delete": try require(1); try engine.delete(positional[0], destroy: flags.contains("--destroy"), confirmed: flags.contains("--confirm-delete")); try success(json)
            case "recover": try require(1); try engine.recover(positional[0]); try success(json)
            case "export": try require(2); try engine.export(positional[0], destination: URL(fileURLWithPath: positional[1]), revision: values["--revision"], live: flags.contains("--live")); try success(json)
            case "busy": try require(1); let busy = try engine.busyProcesses(positional[0]); if json { try output(["processes": busy]) } else { print(busy) }
            case "internal-finalize": try require(1); try engine.finalize(positional[0])
            case "install-cli":
                try require(1); let directory = URL(fileURLWithPath: (positional[0] as NSString).expandingTildeInPath); try Paths.rejectSymlinks(directory.path)
                let installed = directory.appendingPathComponent("ramnest")
                guard !FileManager.default.fileExists(atPath: installed.path) else { throw NestError("Destination already exists; remove it explicitly before reinstalling.", code: 4) }
                try FileManager.default.createSymbolicLink(at: installed, withDestinationURL: BinaryLocation.executable)
                if json { try output(["installed": installed.path]) } else { print("Installed launcher at \(installed.path)") }
            default: throw NestError("Unknown command: \(command). See --help.", code: 64)
            }
        } catch {
            let e = error as? NestError ?? NestError(error.localizedDescription)
            if json, let data = try? JSONEncoder().encode(["error": e.message, "exitCode": String(e.code)]) { FileHandle.standardError.write(data + Data([10])) }
            else { FileHandle.standardError.write(Data("ramnest: \(e.message)\n".utf8)) }
            exit(e.code)
        }
    }
    static func output<T: Encodable>(_ value: T) throws { let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; print(String(decoding: try e.encode(value), as: UTF8.self)) }
    static func success(_ json: Bool) throws { if json { try output(["ok": true]) } }
}
