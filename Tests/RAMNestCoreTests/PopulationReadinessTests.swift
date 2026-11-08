import Foundation
import Darwin
@testable import RAMNestCore
#if !RAMNEST_POPULATION_READINESS_STANDALONE
import Testing
extension RAMNestTestSuite {
    struct PopulationReadinessTests {
        @Test func `Transient reads require exact manifest`() throws { try PopulationReadinessScenarios.transientReads() }
        @Test func `Exhaustion and permissions`() throws { try PopulationReadinessScenarios.failures() }
        @Test func `Monotonic bounds`() throws { try PopulationReadinessScenarios.bounds() }
        @Test func `Snapshot preserves errno`() throws { try PopulationReadinessScenarios.structuredErrno() }
        @Test func `Activation ordering and original guards`() throws { try PopulationReadinessScenarios.activation() }
        @Test func `Session readiness and actions`() throws { try PopulationReadinessScenarios.statuses() }
        @Test(arguments: [true, false])
        func `Population order follows negotiated capability`(guarded: Bool) throws { try PopulationReadinessScenarios.startupOrder(guarded: guarded) }
        @Test func `Startup capability and ACK rejection`() throws { try PopulationReadinessScenarios.startupCapabilities() }
        @Test func `Startup import failure never requests mount`() throws { try PopulationReadinessScenarios.startupImportFailure() }
        @Test func `Abandoned startup requires sealed retirement`() throws { try PopulationReadinessScenarios.startupRetirement() }
        @Test func `Guarded startup recovery retires before rollback`() throws { try PopulationReadinessScenarios.startupRecovery() }
        @Test func `Native guarded startup command and order`() throws { try PopulationReadinessScenarios.nativeStartup() }
        @Test func `Startup journal wire presence and recovery consistency`() throws { try PopulationReadinessScenarios.startupJournalWire() }
    }
}
#endif

enum PopulationReadinessScenarios {
    static func startupJournalWire() throws {
        let root = projectRoot().appendingPathComponent("artifacts/trash-fix/startup-wire-\(UUID().uuidString)")
        try Store.privateDirectory(root)
        let startupKeys = ["startupProtocol", "startupHelperPID", "startupRetired"]
        var failures: [String] = []
        func expect(_ value: Bool, _ id: String, _ detail: String) {
            if !value { failures.append(id + ": " + detail) }
        }
        func rejects(_ body: () throws -> Void) -> Bool {
            do { try body(); return false } catch { return true }
        }
        func wire(_ journal: Journal) throws -> [String: Any] {
            var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(journal)) as! [String: Any]
            for key in startupKeys { json.removeValue(forKey: key) }
            return json
        }
        func encoded(_ json: [String: Any]) throws -> Data {
            try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        }
        // These are actual wire shapes, not Optional assignments followed by
        // encodeIfPresent (which would erase the explicit-null evidence).
        let invalid: [(String, [String: Any])] = [
            ("null-protocol-only", ["startupProtocol": NSNull()]),
            ("null-protocol-all-null", ["startupProtocol": NSNull(), "startupHelperPID": NSNull(), "startupRetired": NSNull()]),
            ("null-protocol-pid", ["startupProtocol": NSNull(), "startupHelperPID": getpid()]),
            ("missing-protocol-pid", ["startupHelperPID": getpid()]),
            ("missing-protocol-retired-false", ["startupRetired": false]),
            ("missing-protocol-retired-true", ["startupRetired": true]),
            ("missing-protocol-pid-null", ["startupHelperPID": NSNull()]),
            ("missing-protocol-retired-null", ["startupRetired": NSNull()]),
            ("unknown-protocol-verified-sync", ["startupProtocol": "pre-mount-population-unknown", "startupHelperPID": getpid()])
        ]
        // Run every case even on RED, so failed decode assertions do not hide
        // evidence of an unsafe rollback or a verified sync restore bypass.
        for (name, fields) in invalid {
            for route in ["finalize", "recover"] {
                let id = name + "/" + route
                let f = try LatestSnapshotScenarios.Fixture(root, name + "-" + route)
                var journal = try f.store.journal(f.folder.id)
                journal.phase = .recoveryRequired; journal.mountedDevice = nil
                journal.populationVerified = name == "unknown-protocol-verified-sync"
                let selectedBefore = try Snapshot.manifest(f.selected)
                let holding = URL(fileURLWithPath: journal.evacuation!)
                let holdingBefore = try Snapshot.manifest(holding)
                let (_, snapshotBefore) = try Snapshot.verified(store: f.store, id: f.folder.id, revision: f.initial)
                var json = try wire(journal)
                for (key, value) in fields { json[key] = value }
                let data = try encoded(json)
                let journalURL = try f.store.volume(f.folder.id).appendingPathComponent("journal.json")
                try Store.atomicData(data, journalURL)
                expect(rejects { _ = try JSONDecoder().decode(Journal.self, from: data) }, id, "direct Journal decode must reject")
                expect(rejects { _ = try f.store.journal(f.folder.id) }, id, "Store.journal must reject")
                var commands: [String] = [], statusReads = 0, cleanup = 0, writes = 0
                f.store.beforeJournalWrite = { _, _ in writes += 1 }
                var boundary = f.helper.boundary
                boundary.status = { _, actual in
                    statusReads += 1
                    if route == "recover" { throw NestError("owned disconnected startup") }
                    return HelperStatus(id: actual, pid: getpid(), mounted: false, used: 0, capacity: 16 << 20, active: false)
                }
                let request = boundary.request
                boundary.request = { socket, command in commands.append(command); return try request(socket, command) }
                boundary.beforeCleanupUnlink = { _, _ in cleanup += 1 }
                let engine = Engine(store: f.store, session: boundary)
                expect(rejects {
                    if route == "finalize" { try engine.finalize(f.folder.id.uuidString) }
                    else { try engine.recover(f.folder.id.uuidString) }
                }, id, "recovery entry point must fail closed while OS-unmounted")
                expect(commands.isEmpty && statusReads == 0 && cleanup == 0 && writes == 0, id,
                       "invalid wire must stop before helper commands, status, journal writes or cleanup")
                expect((try? Data(contentsOf: journalURL)) == data, id, "invalid journal bytes must remain untouched")
                expect((try? Snapshot.manifest(f.selected)) == selectedBefore, id, "selected namespace must remain untouched")
                expect((try? Snapshot.manifest(holding)) == holdingBefore, id, "original holding must remain untouched")
                let snapshotAfter = (try? Snapshot.verified(store: f.store, id: f.folder.id, revision: f.initial))?.1
                expect(snapshotAfter == snapshotBefore, id, "initial committed snapshot must remain verified and exact")
                print("CHECK startup-wire " + id)
            }
        }
        for route in ["finalize", "recover"] {
            let id = "legacy-all-startup-keys-absent/" + route
            let f = try LatestSnapshotScenarios.Fixture(root, "legacy-" + route)
            var journal = try f.store.journal(f.folder.id)
            journal.phase = .recoveryRequired; journal.populationVerified = false; journal.mountedDevice = nil
            let data = try encoded(wire(journal))
            let decoded = try JSONDecoder().decode(Journal.self, from: data)
            expect(decoded == journal, id, "genuine legacy fields must decode exactly")
            let holdingStat = try DirectoryHandle.open(URL(fileURLWithPath: journal.evacuation!)).entryStat("payload")
            try Store.atomicData(data, f.store.volume(f.folder.id).appendingPathComponent("journal.json"))
            var boundary = f.helper.boundary
            boundary.status = { _, _ in throw NestError("owned disconnected legacy helper") }
            let engine = Engine(store: f.store, session: boundary)
            if route == "finalize" { try engine.finalize(f.folder.id.uuidString) }
            else { try engine.recover(f.folder.id.uuidString) }
            let restored = try DirectoryHandle.open(f.selected).entryStat("payload")
            expect(restored.st_ino == holdingStat.st_ino && restored.st_dev == holdingStat.st_dev, id, "legacy rollback restores original inode")
            expect(try String(contentsOf: f.selected.appendingPathComponent("payload"), encoding: .utf8) == "original", id, "legacy bytes restore")
            expect(try f.store.journal(f.folder.id).phase == .idle, id, "legacy restore completes")
            _ = try Snapshot.verified(store: f.store, id: f.folder.id, revision: f.initial)
            print("CHECK startup-wire " + id)
        }
        for explicitNulls in [false, true] {
            let id = "known-intent-unpinned/" + (explicitNulls ? "null-optionals" : "absent-optionals")
            let f = try LatestSnapshotScenarios.Fixture(root, explicitNulls ? "intent-null" : "intent-absent")
            var journal = try f.store.journal(f.folder.id)
            journal.phase = .recoveryRequired; journal.populationVerified = false; journal.mountedDevice = nil
            journal.startupProtocol = GuardedPopulationStartup.version
            var json = try wire(journal); json["startupProtocol"] = GuardedPopulationStartup.version
            if explicitNulls { json["startupHelperPID"] = NSNull(); json["startupRetired"] = NSNull() }
            let data = try encoded(json)
            expect(try JSONDecoder().decode(Journal.self, from: data) == journal, id, "known intent remains readable before helper PID/retirement is pinned")
            let holding = URL(fileURLWithPath: journal.evacuation!)
            let before = try Snapshot.manifest(holding)
            let journalURL = try f.store.volume(f.folder.id).appendingPathComponent("journal.json")
            try Store.atomicData(data, journalURL)
            var boundary = f.helper.boundary
            boundary.status = { _, _ in throw NestError("owned disconnected unpinned intent") }
            var commands: [String] = []
            boundary.request = { _, command in commands.append(command); throw NestError("unexpected command") }
            let engine = Engine(store: f.store, session: boundary)
            expect(rejects { try engine.recover(f.folder.id.uuidString) }, id, "readable intent cannot recover without sealed retirement")
            expect(try commands.isEmpty && DirectoryHandle.open(f.selected).names().isEmpty, id, "no unproven intent publication")
            expect(try Snapshot.manifest(holding) == before, id, "unpinned intent retains originals")
            expect(try Data(contentsOf: journalURL) == data, id, "readable intent does not rewrite journal during failed disconnected recovery")
            _ = try Snapshot.verified(store: f.store, id: f.folder.id, revision: f.initial)
            print("CHECK startup-wire " + id)
        }
        // Keep the old synthesized contract: stored defaults are still required;
        // unrelated optional fields retain missing/null compatibility.
        let legacyJSON = try wire(Journal())
        for key in ["phase", "evacuatedEntries", "restoredEntries", "populationVerified", "updated"] {
            for explicitNull in [false, true] {
                var json = legacyJSON
                if explicitNull { json[key] = NSNull() } else { json.removeValue(forKey: key) }
                let data = try encoded(json)
                let id = "required-old-field/" + key + (explicitNull ? "/null" : "/missing")
                expect(rejects { _ = try JSONDecoder().decode(Journal.self, from: data) }, id, "missing/null remains invalid")
                print("CHECK startup-wire " + id)
            }
        }
        var nullOptional = legacyJSON; nullOptional["lastError"] = NSNull()
        expect(try JSONDecoder().decode(Journal.self, from: encoded(nullOptional)) == JSONDecoder().decode(Journal.self, from: encoded(legacyJSON)),
               "legacy-optional-null", "unrelated optional compatibility remains exact")
        print("CHECK startup-wire legacy-optional-null")
        try check(failures.isEmpty, failures.joined(separator: "\n"))
        print("PASS startup journal wire presence and recovery consistency")
    }
    static func nativeStartup() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let binary = environment["RAMNEST_STARTUP_CONTROL_FIXTURE"], let ownedRoot = environment["RAMNEST_TRASH_TEST_ROOT"] else {
            throw NestError("Explicit MCPO-built ramnest-control-tests and owned test root required; startup native regression is not skipped.")
        }
        let root = URL(fileURLWithPath: ownedRoot).appendingPathComponent("native-startup-\(UUID().uuidString)")
        try Store.privateDirectory(root)
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: binary); process.arguments = ["--startup-regressions"]
        process.environment = environment.merging(["RAMNEST_TEST_ROOT": root.path]) { _, new in new }
        process.standardOutput = output; process.standardError = output
        try process.run()
        let data = try output.fileHandleForReading.readToEnd() ?? Data(); process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        try check(process.terminationStatus == 0, "native startup command/order regression exited \(process.terminationStatus): \(text)")
        for marker in ["PASS guarded-startup CLI", "PASS guarded startup order", "PASS guarded startup import",
                       "PASS startup-timeout-reacquire/importing", "PASS startup-timeout-reacquire/renewed-deadline",
                       "PASS startup-timeout-reacquire/requested", "PASS startup-timeout-reacquire/idle-expired",
                       "PASS startup-timeout-reacquire/owner-exit", "PASS startup-timeout-reacquire/stopped",
                       "PASS startup-timeout-reacquire/abandoned"] {
            try check(text.contains(marker), "native production-dispatch evidence required: " + marker)
        }
        print(text)
    }
    static func startupRecovery() throws {
        let root = projectRoot().appendingPathComponent("artifacts/trash-fix/startup-recovery-\(UUID().uuidString)")
        try Store.privateDirectory(root)
        // Absence of the new optional journal keys keeps old journals readable.
        let legacyData = try JSONEncoder().encode(Journal())
        let legacy = try JSONDecoder().decode(Journal.self, from: legacyData)
        try check(legacy.startupProtocol == nil && legacy.startupRetired == nil && legacy.startupHelperPID == nil, "legacy journal has no startup contract")
        for scenario in ["sealed", "bad-seal", "lost-retire", "disconnected", "unknown"] {
            let f = try LatestSnapshotScenarios.Fixture(root, scenario)
            var j = try f.store.journal(f.folder.id)
            j.phase = .recoveryRequired; j.populationVerified = false; j.mountedDevice = nil
            j.startupProtocol = scenario == "unknown" ? "unknown" : GuardedPopulationStartup.version
            j.startupHelperPID = getpid(); try f.store.write(j, for: f.folder.id)
            let journalURL = try f.store.volume(f.folder.id).appendingPathComponent("journal.json")
            let originalWire = try Data(contentsOf: journalURL)
            var commands: [String] = []
            var boundary = f.helper.boundary
            boundary.status = { _, id in
                if scenario == "disconnected" { throw NestError("owned disconnected startup") }
                return HelperStatus(id: id, pid: getpid(), mounted: false, used: 0, capacity: 16 << 20, active: false)
            }
            boundary.request = { _, command in
                commands.append(command)
                try check(try DirectoryHandle.open(f.selected).names().isEmpty, "no original publication before seal and normal retirement")
                if command == "abort-startup" { return [GuardedPopulationStartup.version, scenario == "bad-seal" ? "mounting" : "retained"] }
                if scenario == "lost-retire" { throw NestError("owned missing retirement receipt") }
                return []
            }
            let engine = Engine(store: f.store, session: boundary)
            if scenario == "sealed" {
                try engine.recover(f.folder.id.uuidString)
                let final = try f.store.journal(f.folder.id)
                try check(commands == ["abort-startup", "retire"] && final.phase == .idle && final.startupRetired == true,
                          "actual recovery coordinator seals, retires, durably records receipt, then rolls back")
                try check(try String(contentsOf: f.selected.appendingPathComponent("payload"), encoding: .utf8) == "original", "original bytes restored")
            } else {
                _ = try failure { try engine.recover(f.folder.id.uuidString) }
                try check(try DirectoryHandle.open(f.selected).names().isEmpty, "uncertain startup never rolls originals into a possible future mount")
                let retained: Journal
                if scenario == "unknown" {
                    // Central rejection also applies to this older unverified
                    // regression. Verify raw preservation before using its
                    // pre-corruption values for the unchanged retention checks.
                    _ = try failure { _ = try f.store.journal(f.folder.id) }
                    try check(try Data(contentsOf: journalURL) == originalWire && commands.isEmpty,
                              "unknown protocol is rejected without rewriting the journal or helper commands")
                    retained = j
                } else { retained = try f.store.journal(f.folder.id) }
                try check(retained.phase == .recoveryRequired && retained.startupRetired != true && FileManager.default.fileExists(atPath: retained.evacuation! + "/payload"), "holding, startup journal and snapshot retained")
            }
            _ = try Snapshot.verified(store: f.store, id: f.folder.id, revision: f.initial)
        }
    }
    static func startupOrder(guarded: Bool) throws {
        let version = GuardedPopulationStartup.version
        let digests: [String?] = [nil, String(repeating: "a", count: 64)]
        for digest in digests {
            var calls: [String] = []
            try GuardedPopulationStartup.populate(enabled: guarded, digest: digest, controlReady: {
                calls.append("control-retained-guarded")
            }, request: { command in
                calls.append(command)
                if command == "capabilities" { return ["private-storage-v2", version] }
                if command == "startup-status" { return [version, "populated"] }
                if command == "mount-populated" { return [version, "mount-requested"] }
                return []
            }, mountReady: { calls.append("os-mount-ready") })
            var expected = guarded ? ["control-retained-guarded"] : ["os-mount-ready"]
            if digest != nil { expected.append("capabilities") }
            expected.append(digest.map { "populate2\t" + $0 } ?? "populate")
            if guarded { expected += ["startup-status", "mount-populated", "os-mount-ready"] }
            try check(calls == expected, "production coordinator call order for old/new helper and v1/v2 snapshot")
            try check(!calls.contains("activate") && !calls.contains("thaw"), "startup never activates before mounted full manifest and original verification")
        }
        try check(GuardedPopulationStartup.arguments(enabled: false).isEmpty, "old helper receives no new startup flags")
        try check(GuardedPopulationStartup.arguments(enabled: true, owner: 42) == ["--guarded-startup", version, "--startup-owner", "42"], "version and real owner are explicit startup inputs")
    }
    static func startupCapabilities() throws {
        let version = GuardedPopulationStartup.version
        try check(try GuardedPopulationStartup.negotiate { version + "\n" }, "new offline capability")
        try check(try !GuardedPopulationStartup.negotiate { throw NestError("unsupported legacy option") }, "missing capability follows old flow")
        for output in ["", "private-storage-v2", "pre-mount-population-v2", version + "\textra"] {
            _ = try failure { _ = try GuardedPopulationStartup.negotiate { output } }
        }
        for bad in ["capability", "populate", "status", "ack", "digest"] {
            var calls: [String] = []
            _ = try failure {
                try GuardedPopulationStartup.populate(enabled: true,
                    digest: bad == "digest" ? "invalid" : String(repeating: "b", count: 64), controlReady: {}, request: { command in
                        calls.append(command)
                        if command == "capabilities" { return bad == "capability" ? [] : ["private-storage-v2"] }
                        if command.hasPrefix("populate2") { return bad == "populate" ? ["unexpected"] : [] }
                        if command == "startup-status" { return [version, bad == "status" ? "waiting" : "populated"] }
                        return [version, "invalid"]
                    }, mountReady: { calls.append("os-mount-ready") })
            }
            try check(!calls.contains("os-mount-ready") && !calls.contains("activate"), "bad digest/capability/import/state/ACK never waits for mount or activates")
            if ["capability", "populate", "status", "digest"].contains(bad) {
                try check(!calls.contains("mount-populated"), "invalid prerequisites never request mount")
            }
        }
    }
    static func startupImportFailure() throws {
        for point in ["control", "import"] {
            var calls: [String] = []
            _ = try failure {
                try GuardedPopulationStartup.populate(enabled: true, digest: nil, controlReady: {
                    calls.append("control")
                    if point == "control" { throw NestError("owned control failure") }
                }, request: { command in
                    calls.append(command);throw NestError("owned import failure")
                }, mountReady: { calls.append("os-mount-ready") })
            }
            try check(calls == (point == "control" ? ["control"] : ["control", "populate"]), "failure stops production sequence before mount ACK and activation")
        }
    }
    static func startupRetirement() throws {
        let root = projectRoot().appendingPathComponent("artifacts/trash-fix/startup-retire-\(UUID().uuidString)")
        try Store.privateDirectory(root)
        for bad in ["none", "pid", "mounted", "active", "abort", "after", "retire"] {
            let f = try LatestSnapshotScenarios.Fixture(root, bad)
            let journal = try f.store.journal(f.folder.id)
            var calls: [String] = [], reads = 0
            var boundary = f.helper.boundary
            boundary.status = { _, id in
                reads += 1
                return HelperStatus(id: id, pid: bad == "after" && reads > 1 ? getpid() + 1 : getpid(),
                                    mounted: bad == "mounted", used: 0, capacity: 16 << 20, active: bad == "active")
            }
            boundary.request = { _, command in
                calls.append(command)
                if command == "abort-startup" { return [GuardedPopulationStartup.version, bad == "abort" ? "mounting" : "retained"] }
                if bad == "retire" { throw NestError("owned lost retirement ACK") }
                return []
            }
            let engine = Engine(store: f.store, session: boundary)
            let operation = { try engine.retireGuardedStartup(journal, id: f.folder.id, expectedPID: bad == "pid" ? getpid() + 1 : getpid()) }
            if bad == "none" { try operation();try check(calls == ["abort-startup", "retire"], "seal before normal retirement") }
            else { _ = try failure(operation) }
            if ["pid", "mounted", "active"].contains(bad) { try check(calls.isEmpty, "uncertain/live identity is never retired") }
            if ["abort", "after"].contains(bad) { try check(calls == ["abort-startup"], "missing seal or changed PID blocks retirement") }
            try check(!calls.contains("activate") && !calls.contains("thaw"), "abandoned cleanup never activates")
            _ = try Snapshot.verified(store: f.store, id: f.folder.id, revision: f.initial)
        }
    }
    static func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !value() { throw NestError("TEST: " + message) }
    }
    @discardableResult static func failure(_ body: () throws -> Void) throws -> Error {
        do { try body() } catch { return error }
        throw NestError("TEST: expected guarded failure")
    }
    final class Clock {
        var time = 100.0
        var sleeps: [TimeInterval] = []
        var advanceOnSleep = true
        func sleep(_ duration: TimeInterval) {
            sleeps.append(duration)
            if advanceOnSleep { time += duration }
        }
    }
    static var expected: Manifest {
        Manifest(entries: [Entry(path: "inert", kind: "file", size: 4, mode: 0o640, mtimeSeconds: 1,
            mtimeNanos: 2, checksum: "fixture-checksum", attributes: ["user.fixture": "fixture-xattr-digest"],
            hardlink: nil, flags: 0, attributeBytes: 12)])
    }
    static func cocoa(_ code: CocoaError.Code, underlying: Int32? = nil) -> NSError {
        NSError(domain: NSCocoaErrorDomain, code: code.rawValue,
                userInfo: underlying.map { [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int($0))] } ?? [:])
    }
    static func transientReads() throws {
        let clock = Clock()
        let errors: [Error] = [cocoa(.fileReadUnknown, underlying: EIO), cocoa(.fileReadNoSuchFile, underlying: EIO),
            NSError(domain: NSPOSIXErrorDomain, code: Int(EIO)), cocoa(.fileReadNoSuchFile)]
        var reads = 0
        var changed = expected; changed.entries[0].attributes = [:]
        try PopulationReadiness.verify(expected: expected, read: {
            reads += 1
            if reads <= errors.count { throw errors[reads - 1] }
            if reads == 5 { return Manifest(entries: []) }
            return reads == 6 ? changed : expected
        }, sleep: clock.sleep, uptime: { clock.time })
        try check(reads == 7 && clock.sleeps.count == 6, "transient Cocoa/POSIX errors and partial/xattr mismatch must settle to an exact full manifest")
        try check(clock.sleeps.allSatisfy { $0 >= 0.1 && $0 <= 0.2 }, "retry spacing stays conservative")
        let staleHandle = Clock(); var handleReads = 0
        try PopulationReadiness.verify(expected: expected, read: {
            handleReads += 1
            if handleReads == 1 { throw cocoa(.fileReadUnknown, underlying: EBADF) }
            return expected
        }, sleep: staleHandle.sleep, uptime: { staleHandle.time })
        try check(handleReads == 2 && staleHandle.sleeps.count == 1, "FSKit startup directory-handle EBADF settles before activation")
    }
    static func failures() throws {
        for error in [cocoa(.fileReadUnknown, underlying: EACCES), cocoa(.fileReadNoSuchFile, underlying: EPERM),
                      cocoa(.fileReadNoPermission), NSError(domain: NSPOSIXErrorDomain, code: Int(EINVAL)),
                      NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC)),
                      NSError(domain: "SecurityFixture", code: 1)] {
            let clock = Clock(); var reads = 0
            _ = try failure {
                try PopulationReadiness.verify(expected: expected, read: { reads += 1; throw error },
                    sleep: clock.sleep, uptime: { clock.time })
            }
            try check(reads == 1 && clock.sleeps.isEmpty, "permissions/security/nontransient errors fail immediately")
        }
        let variants: [(inout Entry) -> Void] = [
            { $0.path = "other" }, { $0.kind = "directory" }, { $0.size += 1 }, { $0.mode = 0o600 },
            { $0.mtimeSeconds += 1 }, { $0.mtimeNanos += 1 }, { $0.checksum = "different" },
            { $0.attributes = [:] }, { $0.hardlink = "other" }, { $0.flags = UInt32(UF_HIDDEN) }, { $0.attributeBytes += 1 }
        ]
        for change in variants {
            let clock = Clock(); var reads = 0; var mismatch = expected; change(&mismatch.entries[0])
            let error = try failure {
                try PopulationReadiness.verify(expected: expected, read: { reads += 1; return mismatch },
                    sleep: clock.sleep, uptime: { clock.time }, maximumAttempts: 3)
            }
            try check(reads == 3 && clock.sleeps.count == 2, "each manifest field remains strict through bounded mismatch exhaustion")
            try check(error.localizedDescription.contains("guarded"), "exhaustion explains guarded state")
        }
        let clock = Clock(); var reads = 0
        let error = try failure {
            try PopulationReadiness.verify(expected: expected, read: {
                reads += 1
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO), userInfo: [NSLocalizedDescriptionKey: "PRIVATE-CONTENT"])
            }, sleep: clock.sleep, uptime: { clock.time }, maximumAttempts: 3)
        }
        try check(reads == 3 && clock.sleeps.count == 2, "transient I/O exhaustion obeys attempt cap")
        try check(error.localizedDescription.contains("5") && !error.localizedDescription.contains("PRIVATE-CONTENT"), "exhaustion reports numeric error without private contents")
    }
    static func bounds() throws {
        for runtime in [2.95, 3.0, 9.0] {
            let clock = Clock(); var reads = 0
            _ = try failure {
                try PopulationReadiness.verify(expected: expected, read: {
                    reads += 1; clock.time += runtime; throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))
                }, sleep: clock.sleep, uptime: { clock.time })
            }
            try check(reads == 1 && clock.sleeps.isEmpty, "read runtime counts; no sleep when expired or insufficient time for normal spacing")
        }
        let large = Clock(); var validReads = 0
        try PopulationReadiness.verify(expected: expected, read: { validReads += 1; large.time += 30; return expected },
            sleep: large.sleep, uptime: { large.time })
        try check(validReads == 1 && large.sleeps.isEmpty, "large valid first manifest may finish normally")
        let clock = Clock(); var reads = 0
        _ = try failure {
            try PopulationReadiness.verify(expected: expected, read: { reads += 1; clock.time += 0.8; return Manifest(entries: []) },
                sleep: clock.sleep, uptime: { clock.time }, timeout: 1)
        }
        try check(reads == 2 && clock.sleeps.count == 1, "second read runtime exhausts deadline without extra waits")
        let stopped = Clock(); stopped.advanceOnSleep = false; var capped = 0
        _ = try failure {
            try PopulationReadiness.verify(expected: expected, read: { capped += 1; return Manifest(entries: []) },
                sleep: stopped.sleep, uptime: { stopped.time }, maximumAttempts: 4)
        }
        try check(capped == 4 && stopped.sleeps.count == 3, "attempt cap prevents a busy loop even if injected clock does not advance")
        let overrun = Clock(); var overruns = 0
        _ = try failure {
            try PopulationReadiness.verify(expected: expected, read: { overruns += 1; return Manifest(entries: []) },
                sleep: { overrun.sleep($0); overrun.time += 3 }, uptime: { overrun.time })
        }
        try check(overruns == 1 && overrun.sleeps.count == 1, "deadline checked again after scheduler oversleep")
        let zero = Clock(); var zeroReads = 0
        _ = try failure {
            try PopulationReadiness.verify(expected: expected, read: { zeroReads += 1; return Manifest(entries: []) },
                sleep: zero.sleep, uptime: { zero.time }, timeout: 0)
        }
        try check(zeroReads == 1 && zero.sleeps.isEmpty, "zero retry budget still permits initial read")
    }
    static func projectRoot() -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().resolvingSymlinksInPath()
    }
    static func structuredErrno() throws {
        let missing = projectRoot().appendingPathComponent("artifacts/trash-fix/missing-\(UUID().uuidString)")
        let error = try failure { _ = try Snapshot.attributes(missing) } as NSError
        try check(error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT), "snapshot xattr failure must retain structured errno")
    }
    static func activation() throws {
        let root = projectRoot().appendingPathComponent("artifacts/trash-fix/readiness-fixtures-\(UUID().uuidString)")
        try Store.privateDirectory(root)
        for scenario in ["settled", "mismatch", "io-exhaustion", "permission", "source-changed", "original-changed"] {
            let f = try LatestSnapshotScenarios.Fixture(root, scenario)
            let (_, manifest) = try Snapshot.verified(store: f.store, id: f.folder.id, revision: f.initial)
            var j = try f.store.journal(f.folder.id); j.phase = .mounting; j.populationVerified = false
            try f.store.write(j, for: f.folder.id)
            let clock = Clock(); var reads = 0
            var boundary = f.helper.boundary
            boundary.populationRead = { _ in
                reads += 1
                let durable = try f.store.journal(f.folder.id)
                try check(!durable.populationVerified && !f.helper.commands.contains("activate"), "RAM stays guarded throughout strict verification")
                if scenario == "permission" { throw cocoa(.fileReadUnknown, underlying: EACCES) }
                if scenario == "io-exhaustion" || scenario == "settled" && reads < 3 { throw cocoa(.fileReadUnknown, underlying: EIO) }
                return scenario == "mismatch" ? Manifest(entries: []) : manifest
            }
            boundary.sleep = clock.sleep; boundary.uptime = { clock.time }
            let oldRequest = boundary.request
            boundary.request = { socket, command in
                let durable = try f.store.journal(f.folder.id)
                try check(command == "activate" && durable.populationVerified && durable.phase == .mounted,
                          "durable population verification must precede activate")
                return try oldRequest(socket, command)
            }
            let engine = Engine(store: f.store, session: boundary)
            if scenario == "source-changed" { try Data("inert new writer".utf8).write(to: f.selected.appendingPathComponent("new-entry")) }
            if scenario == "original-changed" { try Data("inert changed original".utf8).write(to: URL(fileURLWithPath: j.evacuation!).appendingPathComponent("payload")) }
            let operation = {
                try f.store.locked {
                    try engine.verifyAndActivatePopulation(f.folder, journal: &j, expected: manifest,
                        source: DirectoryHandle.open(f.selected), original: URL(fileURLWithPath: j.evacuation!))
                }
            }
            if scenario == "settled" {
                try operation()
                try check(reads == 3 && f.helper.commands == ["activate"], "eventual exact match activates once")
            } else {
                _ = try failure(operation)
                let durable = try f.store.journal(f.folder.id)
                try check(durable.phase == .recoveryRequired && !durable.populationVerified && durable.lastError != nil,
                          "failed readiness/original check leaves durable recoveryRequired guard")
                try check(f.helper.commands.isEmpty, "failure never activates, thaws, recovers or switches backend")
                if scenario == "permission" { try check(reads == 1 && clock.sleeps.isEmpty, "permission fails without retries") }
            }
            _ = try Snapshot.verified(store: f.store, id: f.folder.id, revision: f.initial)
            try check(try f.exists(f.initial), "initial snapshot retained")
        }
    }
    static func statuses() throws {
        let root = projectRoot().appendingPathComponent("artifacts/trash-fix/status-fixtures-\(UUID().uuidString)")
        try Store.privateDirectory(root)
        let f = try LatestSnapshotScenarios.Fixture(root, "guarded-status")
        var j = try f.store.journal(f.folder.id)
        func status(active: Bool) throws -> FolderStatus {
            var boundary = f.helper.boundary
            boundary.status = { _, id in HelperStatus(id: id, pid: getpid(), mounted: true, used: 0, capacity: 16 << 20, active: active) }
            return try Engine(store: f.store, session: boundary).statuses()[0]
        }
        let ready = try status(active: true)
        try check(ready.isReady && ready.canSave && ready.canResize && ready.canEject && !ready.canMount && !ready.canRecover,
                  "verified active session keeps existing actions")
        try check(ready.statusTitle == "Mounted in RAM" && ready.primaryActionTitle == "Save and Eject", "verified status unchanged")
        for active in [true, false] {
            for phase in [Phase.mounted, .mounting, .recoveryRequired] {
                for verified in [true, false] {
                    j.phase = phase; j.populationVerified = verified; try f.store.write(j, for: f.folder.id)
                    let s = try status(active: active)
                    if active && verified && phase == .mounted { continue }
                    try check(s.mounted && !s.isReady && s.needsAttention && !s.canMount && !s.canSave && !s.canResize,
                              "OS mount alone never implies readiness or enables writes")
                    try check(s.statusTitle.contains("Needs attention") && s.statusTitle.contains("guarded") && s.primaryActionTitle == "Eject",
                              "guarded session visibly needs attention and offers eject")
                    try check(s.canEject == (phase == .mounted || phase == .recoveryRequired), "eject restricted to supported phases")
                }
            }
        }
        var disconnected = ready; disconnected.connected = false
        try check(!disconnected.isReady && !disconnected.canMount && !disconnected.canSave && !disconnected.canResize,
                  "orphan kernel mount cannot be mounted over or written through UI")
        disconnected.mounted = false; disconnected.journal.phase = .recoveryRequired
        try check(disconnected.canRecover && !disconnected.canMount, "unmounted recovery keeps recovery action")
        disconnected.journal.phase = .idle
        try check(disconnected.canMount && disconnected.canResize && !disconnected.canRecover && !disconnected.isReady, "idle disk actions unchanged")
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ready)) as! [String: Any]
        json.removeValue(forKey: "helperActive")
        let legacy = try JSONDecoder().decode(FolderStatus.self, from: JSONSerialization.data(withJSONObject: json))
        try check(legacy.mounted && !legacy.isReady, "legacy status JSON decodes without assuming helper activity")
    }
}
