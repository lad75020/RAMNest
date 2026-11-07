import Foundation
import Darwin
@testable import RAMNestCore

// A separate process lets the socket regression exercise real EOF, SIGPIPE and
// signal interruptions without modifying production API or global app state.
@main struct ControlTestClient {
    static func main() {
        guard CommandLine.arguments.count == 4, let timeout = Int(CommandLine.arguments[3]) else { exit(64) }
        var action = sigaction()
        action.__sigaction_u.__sa_handler = { _ in }
        sigemptyset(&action.sa_mask)
        action.sa_flags = 0 // Do not restart poll/read automatically.
        sigaction(SIGUSR1, &action, nil)
        do {
            let address = CommandLine.arguments[1]
            let result: [String]
            if address.hasPrefix("fd:"), let fd = Int32(address.dropFirst(3)) {
                result = try Control.exchange(fd, CommandLine.arguments[2], timeout: timeout)
            } else {
                result = try Control.request(address, CommandLine.arguments[2], timeout: timeout)
            }
            print("OK", result.joined(separator: "\t"))
        } catch let error as NestError {
            print("CONTROL_ERROR \(error.code) \(error.localizedDescription)")
            exit(1)
        } catch {
            print("UNEXPECTED_ERROR \(error)")
            exit(2)
        }
    }
}
