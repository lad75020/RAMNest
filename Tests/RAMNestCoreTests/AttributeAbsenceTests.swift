import Foundation
import Darwin
@testable import RAMNestCore
#if !RAMNEST_ATTRIBUTE_ABSENCE_STANDALONE
import Testing
extension RAMNestTestSuite {
    struct AttributeAbsenceTests {
        @Test func `Explicit absence`() throws { try AttributeAbsenceScenarios.absence() }
        @Test func `Errors stay fatal`() throws { try AttributeAbsenceScenarios.errors() }
        @Test func `Missing expected attributes fail`() throws { try AttributeAbsenceScenarios.mismatch() }
        @Test func `Readiness diagnostic`() throws { try AttributeAbsenceScenarios.diagnostic() }
    }
}
#endif

enum AttributeAbsenceScenarios {
    static let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("artifacts/eio-fix/inert")
    static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw NestError("TEST: " + message) }
    }
    static func failure(_ body: () throws -> Void) throws -> NSError {
        do { try body() } catch { return error as NSError }
        throw NestError("TEST: expected fatal error")
    }
    static func absence() throws {
        for code in [ENOATTR, ENOTSUP] {
            var calls = 0
            let result = try Snapshot.attributes(path, list: { buffer, size in
                calls += 1
                try! check(buffer == nil && size == 0, "first list only")
                errno = code; return -1
            })
            try check(result.isEmpty && calls == 1, "explicit absence is empty after one list")
        }
        try check(try Snapshot.attributes(path, list: { _, _ in 0 }).isEmpty, "standard zero remains empty")
    }
    static func errors() throws {
        for code in [EIO, EACCES, EPERM, ENOENT] {
            let error = try failure { _ = try Snapshot.attributes(path, list: { _, _ in errno = code; return -1 }) }
            try check(error.domain == NSPOSIXErrorDomain && error.code == Int(code), "first-list errors retain errno")
        }
        for code in [ENOATTR, ENOTSUP, EIO, EACCES, EPERM, ENOENT] {
            var calls = 0
            let error = try failure {
                _ = try Snapshot.attributes(path, list: { _, _ in
                    calls += 1
                    if calls == 1 { return 8 }
                    errno = code; return -1
                })
            }
            try check(calls == 2 && error.domain == NSPOSIXErrorDomain && error.code == Int(code), "second-list errors must stay fatal")
        }
        for changed in [0, 7] {
            var calls = 0
            _ = try failure { _ = try Snapshot.attributes(path, list: { _, _ in calls += 1; return calls == 1 ? 8 : changed }) }
            try check(calls == 2, "positive-count race stays fatal")
        }
    }
    static func mismatch() throws {
        let absent = try Snapshot.attributes(path, list: { _, _ in errno = ENOATTR; return -1 })
        let entry = Entry(path: "inert", kind: "file", size: 4, mode: 0o600, mtimeSeconds: 1,
            mtimeNanos: 2, checksum: "fixture-hash", attributes: ["user.fixture": "fixture-digest"],
            hardlink: nil, flags: 0, attributeBytes: 12)
        let expected = Manifest(entries: [entry])
        var actual = expected; actual.entries[0].attributes = absent
        var calls = 0
        let error = try failure {
            try PopulationReadiness.verify(expected: expected, read: { calls += 1; return actual },
                sleep: { _ in }, uptime: { 0 }, maximumAttempts: 2)
        }
        try check(calls == 2 && error.localizedDescription.contains("full manifest mismatch"), "expected nonempty attrs must fail exact verification")
    }
    static func diagnostic() throws {
        let source = try failure { _ = try Snapshot.attributes(path, list: { _, _ in errno = EIO; return -1 }) }
        try check(source.userInfo[NSFilePathErrorKey] as? String == path.path, "structured failing path")
        let error = try failure {
            try PopulationReadiness.verify(expected: Manifest(entries: []), read: { throw source },
                sleep: { _ in }, uptime: { 0 }, maximumAttempts: 2)
        }
        try check(error.localizedDescription.contains("listxattr") && error.localizedDescription.contains(path.path)
            && error.localizedDescription.contains("code 5"), "bounded diagnostic identifies operation/path/errno")
        let privateError = NSError(domain: NSPOSIXErrorDomain, code: Int(EIO),
            userInfo: [NSLocalizedDescriptionKey: "PRIVATE-CONTENT-OR-XATTR-VALUE"])
        let safe = try failure {
            try PopulationReadiness.verify(expected: Manifest(entries: []), read: { throw privateError },
                sleep: { _ in }, uptime: { 0 }, maximumAttempts: 1)
        }
        try check(!safe.localizedDescription.contains("PRIVATE-CONTENT"), "arbitrary error text is never included")
    }
}
