import Darwin
import Foundation

/// One cancellation-independent owner for a direct child's destructive reap.
/// Callers may wait repeatedly, but only the detached observation task invokes
/// `waitpid` through `ProcessTermination.reapChildStatus`.
final class ChildProcessExitObserver: @unchecked Sendable {
    enum Outcome: Equatable {
        case exited(ProcessExitStatus)
        case failed(ProcessTerminationError)
    }

    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var rootReaped = false
        private var outcome: Outcome?
        private var waiters: [UUID: CheckedContinuation<Outcome?, Never>] = [:]

        func markRootReaped() {
            lock.lock()
            rootReaped = true
            lock.unlock()
        }

        func finish(with outcome: Outcome) {
            lock.lock()
            guard self.outcome == nil else {
                lock.unlock()
                return
            }
            self.outcome = outcome
            // An ownership failure also closes PID signaling. Another reaper may
            // already have consumed the child, so a PID fallback is no longer safe.
            rootReaped = true
            let continuations = waiters.values
            waiters.removeAll()
            lock.unlock()

            for continuation in continuations {
                continuation.resume(returning: outcome)
            }
        }

        func wait(timeout: TimeInterval?) async -> Outcome? {
            let waiterID = UUID()
            return await withCheckedContinuation { continuation in
                lock.lock()
                if let outcome {
                    lock.unlock()
                    continuation.resume(returning: outcome)
                    return
                }
                waiters[waiterID] = continuation
                lock.unlock()

                guard let timeout else { return }
                let timeoutNanoseconds = UInt64(max(timeout, 0) * 1_000_000_000)
                Task.detached { [weak self] in
                    if timeoutNanoseconds > 0 {
                        try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                    }
                    self?.expireWaiter(waiterID)
                }
            }
        }

        func withRootSignalingWindow<T>(_ operation: () -> T) -> T? {
            lock.lock()
            defer { lock.unlock() }
            guard !rootReaped, outcome == nil else { return nil }
            return operation()
        }

        private func expireWaiter(_ waiterID: UUID) {
            lock.lock()
            let continuation = waiters.removeValue(forKey: waiterID)
            lock.unlock()
            continuation?.resume(returning: nil)
        }
    }

    let pid: pid_t
    private let state: State

    init(pid: pid_t) {
        self.pid = pid
        let state = State()
        self.state = state

        Task.detached {
            let outcome: Outcome
            do {
                let status = try await ProcessTermination.reapChildStatus(
                    pid: pid,
                    onReaped: { state.markRootReaped() }
                )
                outcome = .exited(status)
            } catch let error as ProcessTerminationError {
                outcome = .failed(error)
            } catch {
                outcome = .failed(.waitFailed(error.localizedDescription))
            }
            state.finish(with: outcome)
        }
    }

    func wait(timeout: TimeInterval? = nil) async -> Outcome? {
        await state.wait(timeout: timeout)
    }

    /// Signals only while this observer still owns an unreaped root PID. Holding
    /// the same lock used by `onReaped` closes the lifecycle signaling window at
    /// the sole-reaper boundary rather than after actor scheduling.
    func signalRootProcessFamilyIfUnreaped(
        processGroupID: pid_t?,
        signal: Int32,
        logger: (String) -> Void = { _ in }
    ) -> Bool? {
        state.withRootSignalingWindow {
            ProcessTermination.signalProcessGroupOrPID(
                pid: pid,
                processGroupID: processGroupID,
                signal: signal,
                logger: logger
            )
        }
    }
}
