import Foundation
import Testing
@testable import RAMNestCore

extension RAMNestTestSuite {
    struct NativeHelperAuthorityTests {
        private func receipt(_ selected: NativeHelperCompiledAuthority) -> [String: Any] {
            ["engine": selected.engine, "helperSHA256": selected.sha256,
             "configuration": selected.configuration == "Debug" ? "Debug" : "RelWithDebInfo"]
        }

        @Test func `Production byte authority comes from the generated source compiled into Core`() throws {
            let selected = NativeHelperCompiledAuthority.current
            #expect(selected.engine == NativeHelperBuildIdentity.engine)
            #expect(selected.sha256 == NativeHelperBuildIdentity.sha256)
            #expect(selected.configuration == NativeHelperBuildIdentity.configuration)
            #expect(selected.engine == NativeTmpfsControl.protocolVersion)
            #expect(selected.sha256.count == 64)
            #expect(["Debug", "Release"].contains(selected.configuration))
            try selected.require(pinnedDigest: selected.sha256, receipt: receipt(selected))
            let encoded = try JSONEncoder().encode(selected)
            #expect(try JSONDecoder().decode(NativeHelperCompiledAuthority.self, from: encoded) == selected)
        }

        @Test func `A valid selected seal cannot authorize restored attacker bytes and matching forged provenance`() throws {
            // Pure decision seam for the review's race: paths presented a valid
            // selected bundle during validation, but the captured descriptor and
            // later mutable receipt both contain the attacker's self-signed image.
            // Signature success is deliberately insufficient byte authority.
            let selected = NativeHelperCompiledAuthority.current
            let captured = Snapshot.digest(Data("self-signed attacker helper image".utf8))
            #expect(captured != selected.sha256)
            var mutableReceipt = receipt(selected)
            mutableReceipt["helperSHA256"] = captured
            var administratorInvocations = 0
            do {
                try selected.require(pinnedDigest: captured, receipt: mutableReceipt)
                administratorInvocations += 1
                Issue.record("Mutable helper/provenance pair replaced compiled authority")
            } catch {
                #expect(error.localizedDescription.contains("compiled into this running RAMNest"))
            }
            #expect(administratorInvocations == 0)
            // Conversely, a pinned selected image plus a later forged receipt is
            // incoherent too; there is no fallback to whichever path validated.
            #expect(throws: (any Error).self) { try selected.require(pinnedDigest: selected.sha256, receipt: mutableReceipt) }
        }

        @Test func `Missing malformed stale or other configuration authority fails closed`() throws {
            let selected = NativeHelperCompiledAuthority.current
            #expect(throws: (any Error).self) { try selected.require(pinnedDigest: selected.sha256, receipt: nil) }
            for key in ["engine", "helperSHA256", "configuration"] {
                var bad = receipt(selected); bad[key] = NSNull()
                #expect(throws: (any Error).self) { try selected.require(pinnedDigest: selected.sha256, receipt: bad) }
                bad = receipt(selected); bad.removeValue(forKey: key)
                #expect(throws: (any Error).self) { try selected.require(pinnedDigest: selected.sha256, receipt: bad) }
            }
            var other = receipt(selected)
            other["configuration"] = selected.configuration == "Debug" ? "RelWithDebInfo" : "Debug"
            #expect(throws: (any Error).self) { try selected.require(pinnedDigest: selected.sha256, receipt: other) }
            for missing in ["", "not-a-digest"] {
                let absent = NativeHelperCompiledAuthority(engine: selected.engine, sha256: missing, configuration: selected.configuration)
                #expect(throws: (any Error).self) { try absent.require(pinnedDigest: missing, receipt: receipt(absent)) }
            }
        }
    }
}
