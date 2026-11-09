import Foundation
import Darwin
import Testing
@testable import RAMNestCore
extension RAMNestTestSuite {
    struct PopulationReadinessTests {
        @Test func `Transient reads require exact manifest`() throws { try PopulationReadinessScenarios.transientReads() }
        @Test func `Exhaustion permissions and every metadata field`() throws { try PopulationReadinessScenarios.failures() }
        @Test func `Monotonic bounds`() throws { try PopulationReadinessScenarios.bounds() }
        @Test func `Snapshot preserves errno`() throws { try PopulationReadinessScenarios.structuredErrno() }
    }
}
enum PopulationReadinessScenarios {
    static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw NestError("TEST: " + message) }
    }
    static func failure(_ body: () throws -> Void) throws -> Error {
        do { try body() } catch { return error }; throw NestError("Expected rejection")
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
        try check(handleReads == 2 && staleHandle.sleeps.count == 1, "Transient directory-handle EBADF settles before activation")
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
}
