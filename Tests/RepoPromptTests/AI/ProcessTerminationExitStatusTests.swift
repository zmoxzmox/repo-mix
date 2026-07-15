import Darwin
import Foundation
@testable import RepoPromptApp
import XCTest

/// Detailed exit-status decoding and real-child reaping through the shared
/// ProcessTermination authority: exited-vs-signaled semantics must survive
/// alongside the historical normalized `128 + signal` mapping.
final class ProcessTerminationExitStatusTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        try super.tearDownWithError()
    }

    func testDecodeWaitStatusPreservesExitSignalAndFallbackSemantics() {
        // Raw waitpid statuses: exit code lives in the high byte, an uncaught
        // signal in the low 7 bits, and 0x7F marks a stopped child.
        let exitZero = ProcessTermination.decodeWaitStatus(0)
        XCTAssertEqual(exitZero, .exited(code: 0))
        XCTAssertEqual(exitZero.normalizedExitCode, 0)
        XCTAssertEqual(exitZero.terminationStatus, 0)
        XCTAssertEqual(exitZero.terminationReason, .exit)

        let exitThree = ProcessTermination.decodeWaitStatus(3 << 8)
        XCTAssertEqual(exitThree, .exited(code: 3))
        XCTAssertEqual(exitThree.normalizedExitCode, 3)
        XCTAssertEqual(exitThree.terminationStatus, 3)

        let sigterm = ProcessTermination.decodeWaitStatus(SIGTERM)
        XCTAssertEqual(sigterm, .uncaughtSignal(signal: SIGTERM))
        XCTAssertEqual(sigterm.normalizedExitCode, 128 + SIGTERM)
        XCTAssertEqual(sigterm.terminationStatus, SIGTERM)
        XCTAssertEqual(sigterm.terminationReason, .uncaughtSignal)

        // Stopped/other statuses fall back to the raw value, matching the
        // historical normalized behavior.
        let stopped = ProcessTermination.decodeWaitStatus(0x7F)
        XCTAssertEqual(stopped, .exited(code: 0x7F))
        XCTAssertEqual(stopped.normalizedExitCode, 0x7F)
    }

    func testBlockingReapChildStatusPreservesExitAndSignalSemantics() async throws {
        let exiting = try ProcessLauncher.spawn(
            command: "/bin/sh",
            arguments: ["-c", "exit 7"],
            environment: [:],
            workingDirectory: nil
        )
        exiting.stdin?.closeFile()
        let target = GitProcessLifecycleTarget(
            processIdentifier: exiting.pid,
            processGroupID: exiting.processGroupID
        )
        let exitStatus = try await ProcessTermination.reapChildStatus(
            pid: exiting.pid,
            onReaped: { target.markTerminated() }
        )
        XCTAssertEqual(exitStatus, .exited(code: 7))
        XCTAssertFalse(target.isRunning)

        let signaled = try ProcessLauncher.spawn(
            command: "/bin/sh",
            arguments: ["-c", "kill -KILL $$"],
            environment: [:],
            workingDirectory: nil
        )
        signaled.stdin?.closeFile()
        let signalStatus = try await ProcessTermination.reapChildStatus(pid: signaled.pid)
        XCTAssertEqual(signalStatus, .uncaughtSignal(signal: SIGKILL))
    }

    func testBlockingReapChildStatusTreatsECHILDAsOwnershipError() async throws {
        let spawned = try ProcessLauncher.spawn(
            command: "/bin/sh",
            arguments: ["-c", "exit 0"],
            environment: [:],
            workingDirectory: nil
        )
        spawned.stdin?.closeFile()
        let firstStatus = try await ProcessTermination.reapChildStatus(pid: spawned.pid)
        XCTAssertEqual(firstStatus, .exited(code: 0))

        do {
            _ = try await ProcessTermination.reapChildStatus(pid: spawned.pid)
            XCTFail("A second sole-reaper wait must not fabricate a successful exit")
        } catch let error as ProcessTerminationError {
            guard case let .childOwnershipLost(pid) = error else {
                return XCTFail("Expected childOwnershipLost, got \(error)")
            }
            XCTAssertEqual(pid, spawned.pid)
        } catch {
            XCTFail("Expected ProcessTerminationError, got \(error)")
        }
    }

    func testChildProcessExitObserverSharesOneDetailedReap() async throws {
        let spawned = try ProcessLauncher.spawn(
            command: "/bin/sh",
            arguments: ["-c", "exit 19"],
            environment: [:],
            workingDirectory: nil
        )
        spawned.stdin?.closeFile()
        let observer = ChildProcessExitObserver(pid: spawned.pid)

        let first = await observer.wait(timeout: 5)
        let second = await observer.wait(timeout: 0)
        XCTAssertEqual(first, .exited(.exited(code: 19)))
        XCTAssertEqual(second, first)

        do {
            _ = try await ProcessTermination.reapChildStatus(pid: spawned.pid)
            XCTFail("The observer must remain the root child's only destructive reaper")
        } catch let error as ProcessTerminationError {
            XCTAssertEqual(error, .childOwnershipLost(pid: spawned.pid))
        }
    }

    func testObservedTerminationEscalatesBeforeGroupOnlyCleanup() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProcessTerminationExitStatusTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        let childPIDURL = directory.appendingPathComponent("child.pid")
        let script = """
        import os
        import signal
        import time

        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        child = os.fork()
        if child == 0:
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            while True:
                time.sleep(1)
        with open(\(String(reflecting: childPIDURL.path)), "w", encoding="utf-8") as handle:
            handle.write(str(child))
            handle.flush()
            os.fsync(handle.fileno())
        while True:
            time.sleep(1)
        """
        let spawned = try ProcessLauncher.spawn(
            command: "/usr/bin/python3",
            arguments: ["-c", script],
            environment: [:],
            workingDirectory: directory.path
        )
        let observer = ChildProcessExitObserver(pid: spawned.pid)
        let cleanup = ObservedProcessFixtureCleanup(
            observer: observer,
            processGroupID: spawned.processGroupID
        )
        addTeardownBlock {
            await cleanup.run()
        }
        spawned.stdin?.closeFile()
        guard let childPID = await waitForPID(at: childPIDURL) else {
            return XCTFail("Timed out waiting for the descendant PID fixture")
        }

        await cleanup.run()

        let terminationOutcome = await observer.wait(timeout: 0)
        XCTAssertEqual(
            terminationOutcome,
            .exited(.uncaughtSignal(signal: SIGKILL))
        )
        let descendantIsAbsent = await waitUntilProcessIsAbsent(childPID)
        XCTAssertTrue(descendantIsAbsent, "SIGTERM-resistant descendant remained after group cleanup")

        do {
            _ = try await ProcessTermination.reapChildStatus(pid: spawned.pid)
            XCTFail("Observer-aware teardown must not perform or permit a second root reap")
        } catch let error as ProcessTerminationError {
            XCTAssertEqual(error, .childOwnershipLost(pid: spawned.pid))
        }
    }

    func testWaitForTerminationStatusReportsRealChildExitAndSignal() async throws {
        let exiting = try ProcessLauncher.spawn(
            command: "/bin/sh",
            arguments: ["-c", "exit 3"],
            environment: [:],
            workingDirectory: nil
        )
        exiting.stdin?.closeFile()
        let exitOutcome = try await ProcessTermination.waitForTerminationStatus(
            pid: exiting.pid,
            processGroupID: exiting.processGroupID,
            timeout: 5
        )
        XCTAssertFalse(exitOutcome.timedOut)
        XCTAssertEqual(exitOutcome.status, .exited(code: 3))

        let signaled = try ProcessLauncher.spawn(
            command: "/bin/sh",
            arguments: ["-c", "kill -KILL $$"],
            environment: [:],
            workingDirectory: nil
        )
        signaled.stdin?.closeFile()
        let signalOutcome = try await ProcessTermination.waitForTerminationStatus(
            pid: signaled.pid,
            processGroupID: signaled.processGroupID,
            timeout: 5
        )
        XCTAssertFalse(signalOutcome.timedOut)
        XCTAssertEqual(signalOutcome.status, .uncaughtSignal(signal: SIGKILL))
        XCTAssertEqual(signalOutcome.status.normalizedExitCode, 128 + SIGKILL)
    }

    private func waitForPID(at url: URL, timeout: TimeInterval = 2) async -> pid_t? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let text = try? String(contentsOf: url, encoding: .utf8),
               let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
            {
                return pid
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return nil
    }

    private func waitUntilProcessIsAbsent(_ pid: pid_t, timeout: TimeInterval = 2) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if kill(pid, 0) == -1, errno == ESRCH {
                return true
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return kill(pid, 0) == -1 && errno == ESRCH
    }
}

private actor ObservedProcessFixtureCleanup {
    private let observer: ChildProcessExitObserver
    private let processGroupID: pid_t?
    private var didRun = false

    init(observer: ChildProcessExitObserver, processGroupID: pid_t?) {
        self.observer = observer
        self.processGroupID = processGroupID
    }

    func run() async {
        guard !didRun else { return }
        didRun = true
        await ProcessTermination.terminateObservedProcessFamily(
            observer: observer,
            processGroupID: processGroupID,
            sigtermGrace: 0.05,
            sigkillGrace: 0.5
        )
    }
}
