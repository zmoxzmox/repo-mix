@testable import RepoPrompt
import XCTest

@MainActor
final class AgentGitBranchSwitchRelevanceTests: XCTestCase {
    func testProviderNoteIsOmittedWhenBoundSessionSwitchesLogicalBaseRootOnly() {
        let binding = makeBinding(
            logicalRootPath: "/repo/base",
            worktreeRootPath: "/repo/.worktrees/feature"
        )

        let relevant = AgentModeViewModel.branchSwitchIsProviderContextRelevant(
            worktreeBindings: [binding],
            switchedCheckoutCandidatePaths: ["/repo/base"],
            isPrimaryRoot: true,
            didUpdateMatchingWorktreeBinding: false
        )

        XCTAssertFalse(relevant)
    }

    func testProviderNoteIsAppendedWhenBoundSessionSwitchesExecutionWorktree() {
        let binding = makeBinding(
            logicalRootPath: "/repo/base",
            worktreeRootPath: "/repo/.worktrees/feature"
        )

        let relevant = AgentModeViewModel.branchSwitchIsProviderContextRelevant(
            worktreeBindings: [binding],
            switchedCheckoutCandidatePaths: ["/repo/.worktrees/feature"],
            isPrimaryRoot: false,
            didUpdateMatchingWorktreeBinding: true
        )

        XCTAssertTrue(relevant)
    }

    func testUnboundSessionOnlyTreatsPrimaryVisibleRootAsRelevant() {
        XCTAssertTrue(AgentModeViewModel.branchSwitchIsProviderContextRelevant(
            worktreeBindings: [],
            switchedCheckoutCandidatePaths: ["/repo/base"],
            isPrimaryRoot: true,
            didUpdateMatchingWorktreeBinding: false
        ))
        XCTAssertFalse(AgentModeViewModel.branchSwitchIsProviderContextRelevant(
            worktreeBindings: [],
            switchedCheckoutCandidatePaths: ["/repo/.worktrees/other"],
            isPrimaryRoot: false,
            didUpdateMatchingWorktreeBinding: false
        ))
    }

    func testBoundSessionTreatsUnboundPrimaryRootAsRelevantContext() {
        let binding = makeBinding(
            logicalRootPath: "/repo/base",
            worktreeRootPath: "/repo/.worktrees/feature"
        )

        let relevant = AgentModeViewModel.branchSwitchIsProviderContextRelevant(
            worktreeBindings: [binding],
            switchedCheckoutCandidatePaths: ["/other-visible-root"],
            isPrimaryRoot: true,
            didUpdateMatchingWorktreeBinding: false
        )

        XCTAssertTrue(relevant)
    }

    private func makeBinding(logicalRootPath: String, worktreeRootPath: String) -> AgentSessionWorktreeBinding {
        AgentSessionWorktreeBinding(
            id: "binding",
            repositoryID: "repo-id",
            repoKey: "repo",
            logicalRootPath: logicalRootPath,
            logicalRootName: "base",
            worktreeID: "worktree-id",
            worktreeRootPath: worktreeRootPath,
            worktreeName: "feature",
            branch: "feature/old",
            head: "old-head",
            visualLabel: "feature",
            visualColorHex: nil,
            boundAt: Date(timeIntervalSinceReferenceDate: 0),
            source: "test"
        )
    }
}
