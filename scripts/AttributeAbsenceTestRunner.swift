import Foundation
import Darwin

@main struct AttributeAbsenceTestRunner {
    static func main() {
        var failed = false
        let scenarios: [(String, () throws -> Void)] = [
            ("explicit absence", AttributeAbsenceScenarios.absence),
            ("first errors and second-list races remain fatal", AttributeAbsenceScenarios.errors),
            ("missing expected attributes mismatch", AttributeAbsenceScenarios.mismatch),
            ("operation/path readiness diagnostic", AttributeAbsenceScenarios.diagnostic)
        ]
        for (name, run) in scenarios {
            do { try run(); print("PASS: \(name)") }
            catch { failed = true; print("FAIL: \(name): \(error.localizedDescription)") }
        }
        if failed { exit(1) }
    }
}
