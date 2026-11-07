import Foundation
import Darwin

@main struct PopulationReadinessTestRunner {
    static func main() {
        var failed = false
        let scenarios: [(String, () throws -> Void)] = [
            ("transient exact verification", PopulationReadinessScenarios.transientReads),
            ("exhaustion and permissions", PopulationReadinessScenarios.failures),
            ("monotonic deadline and attempt bounds", PopulationReadinessScenarios.bounds),
            ("structured snapshot errno", PopulationReadinessScenarios.structuredErrno),
            ("durable activation and original guards", PopulationReadinessScenarios.activation),
            ("session readiness status and actions", PopulationReadinessScenarios.statuses)
        ]
        for (name, run) in scenarios {
            do { try run(); print("PASS: \(name)") }
            catch { failed = true; print("FAIL: \(name): \(error.localizedDescription)") }
        }
        if failed { exit(1) }
    }
}
