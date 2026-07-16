import Darwin
import Dispatch
import Foundation

/// One cancellation-independent owner for a direct child's destructive reap.
/// Callers may wait repeatedly, but only the callback-based observation invokes
/// `waitpid` through `ProcessTermination.observeChildStatus`.
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
            // Keep publication idempotently closed to PID signaling even if a
            // future result path reaches finish without the callback boundary.
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
    private static let outcomePublicationQueue = DispatchQueue(
        label: "com.repoprompt.child-process-exit-observer.outcome-publication",
        qos: .userInitiated,
        attributes: .concurrent
    )

    init(
        pid: pid_t,
        beforePublishingOutcome: @escaping @Sendable (Outcome) -> Void = { _ in }
    ) {
        self.pid = pid
        let state = State()
        self.state = state

        ProcessTermination.observeChildStatus(pid: pid) { result in
            state.markRootReaped()
            let outcome: Outcome = switch result {
            case let .success(status): .exited(status)
            case let .failure(error): .failed(error)
            }
            // Publication hooks may deliberately block for diagnostics. Keep
            // them off the serial reaper registry so unrelated children can
            // continue closing their ownership windows and publishing exits.
            Self.outcomePublicationQueue.async {
                beforePublishingOutcome(outcome)
                state.finish(with: outcome)
            }
        }
    }

    func wait(timeout: TimeInterval? = nil) async -> Outcome? {
        await state.wait(timeout: timeout)
    }

    /// Signals only while this observer still owns an unreaped root PID. The
    /// callback closes this lock-protected window immediately after waitpid,
    /// before diagnostic outcome publication can block or change executors.
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
