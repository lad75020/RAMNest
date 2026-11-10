import Foundation

/// Step-based progress and cooperative cancellation for mount and eject.
///
/// Cancellation is honoured only at checkpoints the engine marks as safe:
/// points where a thrown error already rolls the journal back to idle without
/// recovery (the same path as a declined administrator prompt). Once the engine
/// passes its point of no return, `cancellable` becomes false and `cancel()`
/// has no effect on the running transaction.
public final class OperationProgress: @unchecked Sendable {
    public struct State: Sendable, Equatable {
        public var message: String
        public var completed: Int
        public var total: Int
        public var cancellable: Bool
        public var cancelRequested: Bool
        public var fraction: Double { total > 0 ? min(1, Double(completed) / Double(total)) : 0 }
    }

    private let lock = NSLock()
    private var state: State
    private var started = 0
    private let onChange: @Sendable (State) -> Void

    public init(_ message: String, total: Int = 1, onChange: @escaping @Sendable (State) -> Void = { _ in }) {
        state = State(message: message, completed: 0, total: max(1, total), cancellable: true, cancelRequested: false)
        self.onChange = onChange
    }

    public var current: State { lock.lock(); defer { lock.unlock() }; return state }

    /// Requests cancellation. Returns false when the operation can no longer stop safely.
    @discardableResult public func cancel() -> Bool {
        let snapshot: State
        lock.lock()
        guard state.cancellable, !state.cancelRequested else { let ok = state.cancelRequested; lock.unlock(); return ok }
        state.cancelRequested = true; snapshot = state
        lock.unlock()
        onChange(snapshot)
        return true
    }

    /// Throws if cancellation was requested and this checkpoint is still safe.
    func checkpoint() throws {
        lock.lock(); let stop = state.cancellable && state.cancelRequested; lock.unlock()
        if stop { throw Self.cancelledError }
    }

    /// Starts the next step. A cancellable step first honours a pending cancel.
    /// Place a cancellable step only where a thrown error rolls back cleanly.
    public func step(_ message: String, cancellable: Bool) throws {
        if cancellable { try checkpoint() }
        update { s in
            s.completed = min(started, s.total - 1); started += 1
            s.message = message
            // Point of no return is one-way within an operation. A request that
            // arrives after it is dropped; the operation finishes normally.
            s.cancellable = s.cancellable && cancellable
            if !s.cancellable { s.cancelRequested = false }
        }
    }

    public func finish() { update { $0.completed = $0.total; $0.cancellable = false } }

    private func update(_ change: (inout State) -> Void) {
        lock.lock(); change(&state); let snapshot = state; lock.unlock()
        onChange(snapshot)
    }

    public static let cancelledError = NestError("Cancelled. Your folder wasn't changed.", code: NestError.Code.cancelled)
    public static func isCancellation(_ error: Error) -> Bool { (error as? NestError)?.code == NestError.Code.cancelled }
}
