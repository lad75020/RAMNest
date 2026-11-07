import Foundation
import Darwin

@main struct MountedFlagPolicyTestRunner {
    static func main() {
        var failed = false
        let scenarios: [(String, () throws -> Void)] = [
            ("strict default and raw equality", MountedFlagPolicyScenarios.strictDefaults),
            ("directional two-bit mask, all other bits rejected", MountedFlagPolicyScenarios.directionalMask),
            ("journal backend policy, fields and activation guards", MountedFlagPolicyScenarios.journalPolicy),
            ("strict snapshot capture, verification and restoration copy", MountedFlagPolicyScenarios.snapshots),
            ("readiness EIO and permissions", PopulationReadinessScenarios.failures),
            ("readiness bounds", PopulationReadinessScenarios.bounds)
        ]
        for (name, run) in scenarios {
            do { try run(); print("PASS: \(name)") }
            catch { failed = true; print("FAIL: \(name): \(error.localizedDescription)") }
        }
        if failed { exit(1) }
    }
}
