@testable import RepoPrompt
import XCTest

final class WorkspaceRootSeedPlannerTests: XCTestCase {
    private typealias Support = WorkspaceRootSeedTestSupport

    func testCleanSameTreePlanReusesBaseWithoutVerificationOverlay() throws {
        let prefix = try GitRepositoryRelativeRootPrefix("")
        let snapshot = Support.snapshot(paths: [
            ("A.swift", "100644"),
            ("Sources/B.swift", "100644")
        ])
        let outcome = WorkspaceRootSeedPlanner.materialize(
            snapshot: snapshot,
            targetTreeOID: snapshot.compatibilityKey.treeOID,
            treeDelta: [],
            index: GitIndexManifest(
                rootPrefix: prefix,
                entries: [Support.indexEntry("A.swift"), Support.indexEntry("Sources/B.swift")],
                outputByteCount: 0
            ),
            status: Support.status([]),
            verificationFacts: [:],
            copiedRepositoryRelativePaths: [],
            prefix: prefix
        )
        guard case let .planned(plan) = outcome else {
            return XCTFail("Expected clean plan, got \(outcome)")
        }
        XCTAssertEqual(plan.relativeFilePaths, ["A.swift", "Sources/B.swift"])
        XCTAssertEqual(plan.relativeFolderPaths, ["Sources"])
        XCTAssertTrue(plan.changedRelativeFilePaths.isEmpty)
        XCTAssertTrue(plan.tombstonedBaseRelativeFilePaths.isEmpty)
        XCTAssertEqual(plan.verifiedPathCount, 0)
    }

    func testByteExactUnicodePathsRemainDistinctInDigestAndCollisionsFailClosed() throws {
        let composed = "Caf\u{00E9}.swift"
        let decomposed = "Cafe\u{0301}.swift"
        XCTAssertEqual(composed, decomposed)
        XCTAssertNotEqual(Array(composed.utf8), Array(decomposed.utf8))

        let composedSnapshot = Support.snapshot(paths: [(composed, "100644")])
        let decomposedSnapshot = Support.snapshot(paths: [(decomposed, "100644")])
        XCTAssertNotEqual(composedSnapshot.identity.sha256, decomposedSnapshot.identity.sha256)
        XCTAssertEqual(Array(composedSnapshot.inventory.entries[0].relativePath.utf8), Array(composed.utf8))
        XCTAssertEqual(Array(decomposedSnapshot.inventory.entries[0].relativePath.utf8), Array(decomposed.utf8))

        let collisionSnapshot = Support.snapshot(paths: [
            (composed, "100644"),
            (decomposed, "100644")
        ])
        let prefix = try GitRepositoryRelativeRootPrefix("")
        let outcome = WorkspaceRootSeedPlanner.materialize(
            snapshot: collisionSnapshot,
            targetTreeOID: collisionSnapshot.compatibilityKey.treeOID,
            treeDelta: [],
            index: GitIndexManifest(
                rootPrefix: prefix,
                entries: [Support.indexEntry(composed), Support.indexEntry(decomposed)],
                outputByteCount: 0
            ),
            status: Support.status([]),
            verificationFacts: [:],
            copiedRepositoryRelativePaths: [],
            prefix: prefix
        )
        XCTAssertEqual(outcome, .fallback(.compatibilityMismatch))
    }

    func testServingOutcomeCarriesExactFinalAuthorityEvidenceWithoutChangingPlan() async throws {
        let prefix = try GitRepositoryRelativeRootPrefix("")
        let reusable = Support.snapshot(paths: [("A.swift", "100644")], prefix: prefix)
        let shadow = WorkspaceRootSeedPlanner.materialize(
            snapshot: reusable,
            targetTreeOID: reusable.compatibilityKey.treeOID,
            treeDelta: [],
            index: GitIndexManifest(
                rootPrefix: prefix,
                entries: [Support.indexEntry("A.swift")],
                outputByteCount: 0
            ),
            status: Support.status([]),
            verificationFacts: [:],
            copiedRepositoryRelativePaths: [],
            prefix: prefix
        )
        guard case let .planned(plan) = shadow else {
            return XCTFail("Expected a shadow plan")
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceRootSeedPlannerTests-\(UUID().uuidString)", isDirectory: true)
        let gitDirectory = root.appendingPathComponent(".git", isDirectory: true)
        try FileManager.default.createDirectory(at: gitDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = GitRepositoryLayout(
            workTreeRoot: root,
            dotGitPath: gitDirectory,
            gitDir: gitDirectory,
            commonDir: gitDirectory,
            isWorktree: false
        )
        let repositoryKey = GitWorkspaceAuthorityRepositoryKey(layout: layout)
        let authoritySnapshot = GitWorkspaceAuthoritySnapshot(
            repositoryKey: repositoryKey,
            repositoryNamespace: reusable.compatibilityKey.repositoryNamespace,
            objectFormat: reusable.compatibilityKey.objectFormat,
            headCommitOID: Support.oid("b"),
            treeOID: reusable.compatibilityKey.treeOID,
            repositoryRelativeRootPrefix: prefix,
            repositoryBindingEpoch: "repository",
            worktreeBindingEpoch: "worktree",
            layoutGeneration: "layout",
            indexGeneration: "index",
            checkoutConfigurationGeneration: "checkout",
            metadataGeneration: "metadata",
            policyIdentity: reusable.compatibilityKey.policyIdentity
        )
        let monitor = GitWorkspaceMetadataMonitor()
        let token = try await monitor.retain(repositoryKey: repositoryKey, paths: [gitDirectory]) { _ in }
        let lease = GitWorkspaceAuthorityLease(
            scopeKey: GitWorkspaceAuthorityScopeKey(
                repositoryKey: repositoryKey,
                repositoryRelativeRootPrefix: prefix
            ),
            authorityGeneration: 1,
            invalidationGeneration: 0,
            acceptedMetadataWatermark: 0,
            snapshot: authoritySnapshot
        )
        let fence = GitWorkspacePendingInitializationAuthorityFence(
            snapshot: authoritySnapshot,
            lease: lease,
            metadataObservationToken: token,
            acceptedMetadataWatermark: 0,
            targetLayout: layout,
            repositoryRelativeRootPrefix: prefix,
            additionalAuthorityPaths: [],
            revalidationUsed: false
        )
        let serving = WorkspaceRootSeedServingPlanningOutcome.planned(
            plan: plan,
            authorityFence: fence
        )
        guard case let .planned(servingPlan, finalFence) = serving else {
            return XCTFail("Expected a serving plan")
        }
        XCTAssertEqual(servingPlan, plan)
        XCTAssertEqual(finalFence.snapshot, authoritySnapshot)
        XCTAssertEqual(finalFence.lease, lease)
        XCTAssertEqual(finalFence.acceptedMetadataWatermark, 0)
        await monitor.release(token)
    }

    func testMaterializerAppliesCommittedIndexAndPorcelainOverlays() throws {
        let snapshot = Support.snapshot(paths: [
            ("Copy.swift", "100644"),
            ("Delete.swift", "100644"),
            ("Mode.sh", "100644"),
            ("Old.swift", "100644"),
            ("Sources/Ångström.swift", "100644")
        ])
        let targetTree = Support.oid("f")
        let delta: [GitTreeDeltaRecord] = [
            delta(.copied(score: 100), source: "Copy.swift", destination: "Copy2.swift"),
            delta(.deleted, destination: "Delete.swift", newMode: nil, newOID: nil),
            delta(.modified, destination: "Mode.sh", newMode: "100755"),
            delta(.renamed(score: 100), source: "Old.swift", destination: "Renamed.swift"),
            delta(.added, destination: "Committed.swift")
        ]
        let manifest = try GitIndexManifest(
            rootPrefix: GitRepositoryRelativeRootPrefix(""),
            entries: [
                Support.indexEntry("Committed.swift"),
                Support.indexEntry("Copy.swift"),
                Support.indexEntry("Copy2.swift"),
                Support.indexEntry("Mode.sh", mode: "100755"),
                Support.indexEntry("Renamed.swift"),
                Support.indexEntry("Sources/Ångström.swift")
            ],
            outputByteCount: 0
        )
        let status = Support.status([
            Support.pathRecord(
                kind: .renamedOrCopied(originalPath: "Copy2.swift", score: "R100"),
                path: "DirtyRename.swift",
                indexStatus: ".",
                workTreeStatus: "R"
            ),
            Support.pathRecord(kind: .ordinary, path: "Mode.sh", workTreeStatus: "M", workTreeMode: "100755"),
            Support.pathRecord(kind: .ordinary, path: "Sources/Ångström.swift", workTreeStatus: "D"),
            Support.pathRecord(kind: .untracked, path: "Untracked 文件.swift", indexStatus: nil, workTreeStatus: nil),
            Support.pathRecord(kind: .ignored, path: "Ignored.tmp", indexStatus: nil, workTreeStatus: nil)
        ])
        let facts = [
            "Committed.swift": Support.fact("Committed.swift"),
            "Copy2.swift": Support.fact("Copy2.swift"),
            "Delete.swift": Support.fact("Delete.swift", kind: .missing),
            "DirtyRename.swift": Support.fact("DirtyRename.swift"),
            "Mode.sh": Support.fact("Mode.sh", kind: .regularFile(isExecutable: true)),
            "Renamed.swift": Support.fact("Renamed.swift"),
            "Sources/Ångström.swift": Support.fact("Sources/Ångström.swift", kind: .missing),
            "Untracked 文件.swift": Support.fact("Untracked 文件.swift"),
            "Ignored.tmp": Support.fact("Ignored.tmp", ignored: true)
        ]

        let outcome = try WorkspaceRootSeedPlanner.materialize(
            snapshot: snapshot,
            targetTreeOID: targetTree,
            treeDelta: delta,
            index: manifest,
            status: status,
            verificationFacts: facts,
            copiedRepositoryRelativePaths: [],
            prefix: GitRepositoryRelativeRootPrefix("")
        )
        guard case let .planned(plan) = outcome else {
            return XCTFail("Expected a plan, got \(outcome)")
        }
        XCTAssertEqual(plan.relativeFilePaths, [
            "Committed.swift", "Copy.swift", "DirtyRename.swift", "Mode.sh",
            "Renamed.swift", "Untracked 文件.swift"
        ])
        XCTAssertEqual(plan.relativeFolderPaths, [])
        XCTAssertTrue(plan.tombstonedBaseRelativeFilePaths.isSuperset(of: [
            "Delete.swift", "Old.swift", "Sources/Ångström.swift"
        ]))
        XCTAssertEqual(plan.targetTreeOID, targetTree)
    }

    func testCleanSameTreePlanPreservesIgnoredCommittedProjection() throws {
        let prefix = try GitRepositoryRelativeRootPrefix("")
        let snapshot = Support.snapshot(
            paths: [
                ("Sources/Visible.swift", "100644"),
                ("Generated/Ignored.swift", "100644")
            ],
            policyIgnoredPaths: ["Generated/Ignored.swift"]
        )
        let outcome = WorkspaceRootSeedPlanner.materialize(
            snapshot: snapshot,
            targetTreeOID: snapshot.compatibilityKey.treeOID,
            treeDelta: [],
            index: GitIndexManifest(
                rootPrefix: prefix,
                entries: [
                    Support.indexEntry("Sources/Visible.swift"),
                    Support.indexEntry("Generated/Ignored.swift")
                ],
                outputByteCount: 0
            ),
            status: Support.status([]),
            verificationFacts: [
                "Generated": Support.fact(
                    "Generated",
                    kind: .directory,
                    includedInOrdinaryCrawl: true
                ),
                "Generated/Ignored.swift": Support.fact("Generated/Ignored.swift", ignored: true)
            ],
            copiedRepositoryRelativePaths: [],
            prefix: prefix
        )
        guard case let .planned(plan) = outcome else {
            return XCTFail("Expected policy-projected plan, got \(outcome)")
        }
        XCTAssertEqual(plan.relativeFilePaths, ["Sources/Visible.swift"])
        XCTAssertEqual(plan.relativeFolderPaths, ["Generated", "Sources"])
        XCTAssertEqual(plan.policyIgnoredTrackedRelativeFilePaths, ["Generated/Ignored.swift"])
        XCTAssertEqual(plan.baseRelativeFilePaths, ["Sources/Visible.swift"])
        XCTAssertTrue(plan.overlayRelativeFilePaths.isEmpty)
        XCTAssertTrue(plan.tombstonedBaseRelativeFilePaths.isEmpty)
        XCTAssertTrue(plan.relativeFilePaths.isDisjoint(with: plan.policyIgnoredTrackedRelativeFilePaths))
    }

    func testChangedTreePlanKeepsIgnoredTrackedAbsentAndVisibleUntrackedOverlayOnly() throws {
        let prefix = try GitRepositoryRelativeRootPrefix("")
        let snapshot = Support.snapshot(
            paths: [
                ("Keep.swift", "100644"),
                ("Old.swift", "100644"),
                ("Ignored/Tracked.swift", "100644")
            ],
            policyIgnoredPaths: ["Ignored/Tracked.swift"]
        )
        let outcome = WorkspaceRootSeedPlanner.materialize(
            snapshot: snapshot,
            targetTreeOID: Support.oid("f"),
            treeDelta: [
                delta(.deleted, destination: "Old.swift", newMode: nil, newOID: nil),
                delta(.added, destination: "Ignored/New.swift")
            ],
            index: GitIndexManifest(
                rootPrefix: prefix,
                entries: [
                    Support.indexEntry("Keep.swift"),
                    Support.indexEntry("Ignored/Tracked.swift"),
                    Support.indexEntry("Ignored/New.swift")
                ],
                outputByteCount: 0
            ),
            status: Support.status([
                Support.pathRecord(kind: .ordinary, path: "Keep.swift", workTreeStatus: "M"),
                Support.pathRecord(
                    kind: .untracked,
                    path: "Overlay/Visible.swift",
                    indexStatus: nil,
                    workTreeStatus: nil
                ),
                Support.pathRecord(
                    kind: .ignored,
                    path: "Ignored/Untracked.swift",
                    indexStatus: nil,
                    workTreeStatus: nil
                )
            ]),
            verificationFacts: [
                "Keep.swift": Support.fact("Keep.swift"),
                "Old.swift": Support.fact("Old.swift", kind: .missing),
                "Ignored": Support.fact(
                    "Ignored",
                    kind: .directory,
                    ignored: true,
                    includedInOrdinaryCrawl: false
                ),
                "Ignored/Tracked.swift": Support.fact("Ignored/Tracked.swift", ignored: true),
                "Ignored/New.swift": Support.fact("Ignored/New.swift", ignored: true),
                "Overlay/Visible.swift": Support.fact("Overlay/Visible.swift"),
                "Ignored/Untracked.swift": Support.fact("Ignored/Untracked.swift", ignored: true)
            ],
            copiedRepositoryRelativePaths: [],
            prefix: prefix
        )
        guard case let .planned(plan) = outcome else {
            return XCTFail("Expected changed policy-projected plan, got \(outcome)")
        }
        let ordinaryFiles: Set = ["Keep.swift", "Overlay/Visible.swift"]
        let ordinaryFolders: Set = ["Overlay"]
        XCTAssertEqual(plan.relativeFilePaths, ordinaryFiles)
        XCTAssertEqual(plan.relativeFolderPaths, ordinaryFolders)
        XCTAssertEqual(plan.policyIgnoredTrackedRelativeFilePaths, [
            "Ignored/New.swift", "Ignored/Tracked.swift"
        ])
        XCTAssertEqual(plan.overlayRelativeFilePaths, ordinaryFiles)
        XCTAssertEqual(plan.tombstonedBaseRelativeFilePaths, ["Old.swift"])
        XCTAssertFalse(plan.relativeFilePaths.contains("Ignored/Untracked.swift"))
        XCTAssertEqual(plan.baseRelativeFilePaths, ["Keep.swift", "Old.swift"])
        XCTAssertTrue(plan.relativeFilePaths.isDisjoint(with: plan.policyIgnoredTrackedRelativeFilePaths))
        XCTAssertTrue(snapshot.inventory.entries.contains {
            $0.relativePath == "Keep.swift" && $0.objectID == Support.oid("1")
        })
    }

    func testCleanSameTreePlanOmitsTrackedSymlinksAndPreservesAncestors() throws {
        let prefix = try GitRepositoryRelativeRootPrefix("")
        let snapshot = Support.snapshot(paths: [
            ("A.swift", "100644"),
            ("Links/Current", "120000")
        ])
        let manifest = GitIndexManifest(
            rootPrefix: prefix,
            entries: [
                Support.indexEntry("A.swift"),
                Support.indexEntry("Links/Current", mode: "120000")
            ],
            outputByteCount: 0
        )
        let clean = WorkspaceRootSeedPlanner.materialize(
            snapshot: snapshot,
            targetTreeOID: snapshot.compatibilityKey.treeOID,
            treeDelta: [],
            index: manifest,
            status: Support.status([]),
            verificationFacts: [
                "Links": Support.fact(
                    "Links",
                    kind: .directory,
                    includedInOrdinaryCrawl: true
                )
            ],
            copiedRepositoryRelativePaths: [],
            prefix: prefix
        )
        guard case let .planned(plan) = clean else {
            return XCTFail("Expected unchanged symlink topology to plan, got \(clean)")
        }
        XCTAssertEqual(plan.relativeFilePaths, ["A.swift"])
        XCTAssertEqual(plan.relativeFolderPaths, ["Links"])
        XCTAssertFalse(plan.relativeFilePaths.contains("Links/Current"))

        let dirty = WorkspaceRootSeedPlanner.materialize(
            snapshot: snapshot,
            targetTreeOID: snapshot.compatibilityKey.treeOID,
            treeDelta: [],
            index: manifest,
            status: Support.status([
                Support.pathRecord(
                    kind: .ordinary,
                    path: "Links/Current",
                    workTreeStatus: "T",
                    indexMode: "120000",
                    workTreeMode: "100644"
                )
            ]),
            verificationFacts: [
                "Links": Support.fact(
                    "Links",
                    kind: .directory,
                    includedInOrdinaryCrawl: true
                ),
                "Links/Current": Support.fact("Links/Current", kind: .symbolicLink)
            ],
            copiedRepositoryRelativePaths: [],
            prefix: prefix
        )
        XCTAssertEqual(dirty, .fallback(.symlinkOrSpecialTopology))
    }

    func testTypedFallbackMatrixRejectsConflictsSparseSpecialTopologyAndCaps() throws {
        let prefix = try GitRepositoryRelativeRootPrefix("")
        let snapshot = Support.snapshot(paths: [("A.swift", "100644")])
        let targetTree = Support.oid("f")
        let emptyStatus = Support.status([])

        let conflict = WorkspaceRootSeedPlanner.materialize(
            snapshot: snapshot,
            targetTreeOID: targetTree,
            treeDelta: [],
            index: GitIndexManifest(
                rootPrefix: prefix,
                entries: [Support.indexEntry("A.swift", stage: 2)],
                outputByteCount: 0
            ),
            status: emptyStatus,
            verificationFacts: [:],
            copiedRepositoryRelativePaths: [],
            prefix: prefix
        )
        XCTAssertEqual(conflict, .fallback(.conflictOrUnmergedIndex))

        let sparse = WorkspaceRootSeedPlanner.materialize(
            snapshot: snapshot,
            targetTreeOID: targetTree,
            treeDelta: [],
            index: GitIndexManifest(
                rootPrefix: prefix,
                entries: [Support.indexEntry("A.swift", skipWorktree: true)],
                outputByteCount: 0
            ),
            status: emptyStatus,
            verificationFacts: [:],
            copiedRepositoryRelativePaths: [],
            prefix: prefix
        )
        XCTAssertEqual(sparse, .fallback(.sparseCheckout))

        let sparseEnabled = WorkspaceRootSeedPlanner.materialize(
            snapshot: snapshot,
            targetTreeOID: targetTree,
            treeDelta: [],
            index: GitIndexManifest(
                rootPrefix: prefix,
                entries: [Support.indexEntry("A.swift")],
                outputByteCount: 0,
                sparseCheckoutEnabled: true
            ),
            status: emptyStatus,
            verificationFacts: [:],
            copiedRepositoryRelativePaths: [],
            prefix: prefix
        )
        XCTAssertEqual(sparseEnabled, .fallback(.sparseCheckout))

        let specialStatus = Support.status([
            Support.pathRecord(kind: .ordinary, path: "A.swift", workTreeStatus: "M")
        ])
        let special = WorkspaceRootSeedPlanner.materialize(
            snapshot: snapshot,
            targetTreeOID: targetTree,
            treeDelta: [],
            index: GitIndexManifest(
                rootPrefix: prefix,
                entries: [Support.indexEntry("A.swift")],
                outputByteCount: 0
            ),
            status: specialStatus,
            verificationFacts: ["A.swift": Support.fact("A.swift", kind: .symbolicLink)],
            copiedRepositoryRelativePaths: [],
            prefix: prefix
        )
        XCTAssertEqual(special, .fallback(.symlinkOrSpecialTopology))

        let additions = (0 ..< 32).map { index in
            delta(.added, destination: "Added\(index).swift")
        }
        let addedEntries = (0 ..< 32).map { Support.indexEntry("Added\($0).swift") }
        let addedFacts = Dictionary(uniqueKeysWithValues: (0 ..< 32).map {
            ("Added\($0).swift", Support.fact("Added\($0).swift"))
        })
        let capped = WorkspaceRootSeedPlanner.materialize(
            snapshot: snapshot,
            targetTreeOID: targetTree,
            treeDelta: additions,
            index: GitIndexManifest(rootPrefix: prefix, entries: addedEntries, outputByteCount: 0),
            status: emptyStatus,
            verificationFacts: addedFacts,
            copiedRepositoryRelativePaths: [],
            prefix: prefix
        )
        XCTAssertEqual(capped, .fallback(.overlayThresholdExceeded))
    }

    func testAssumeUnchangedDeletedAndTypeChangedEntriesFailClosed() throws {
        let prefix = try GitRepositoryRelativeRootPrefix("")
        let snapshot = Support.snapshot(paths: [("Deleted.swift", "100644"), ("Type.swift", "100644")])

        for (path, fact) in [
            ("Deleted.swift", Support.fact("Deleted.swift", kind: .missing)),
            ("Type.swift", Support.fact("Type.swift", kind: .directory))
        ] {
            let outcome = WorkspaceRootSeedPlanner.materialize(
                snapshot: snapshot,
                targetTreeOID: snapshot.compatibilityKey.treeOID,
                treeDelta: [],
                index: GitIndexManifest(
                    rootPrefix: prefix,
                    entries: [Support.indexEntry(path, assumeUnchanged: true)],
                    outputByteCount: 0
                ),
                status: Support.status([]),
                verificationFacts: [path: fact],
                copiedRepositoryRelativePaths: [],
                prefix: prefix
            )
            XCTAssertEqual(outcome, .fallback(.assumeUnchangedIndexEntry), path)
        }
    }

    func testVerificationRejectsNestedRepositoryMetadataInDirectDirectory() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceRootSeedNestedRepo", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = root.appendingPathComponent("Nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("gitdir: /tmp/linked-worktree\n".utf8)
            .write(to: nested.appendingPathComponent(".git"))
        let service = try await FileSystemService(
            path: root.path,
            respectRepoIgnore: false,
            respectCursorignore: false
        )

        do {
            _ = try await service.workspaceRootSeedVerificationFacts(
                relativePaths: ["Nested"],
                affectedDirectories: [],
                limits: .production
            )
            XCTFail("Expected nested repository fallback proof")
        } catch let error as WorkspaceRootSeedVerificationError {
            XCTAssertEqual(error, .unsupportedTopology)
        }
    }

    func testPrefixIgnoreAndExecutableVerificationStayRootLocal() throws {
        let prefix = try GitRepositoryRelativeRootPrefix("Subdir")
        let snapshot = Support.snapshot(
            paths: [("bin/tool", "100755"), ("Keep.swift", "100644")],
            prefix: prefix
        )
        let status = Support.status([
            Support.pathRecord(
                kind: .ordinary,
                path: "Subdir/bin/tool",
                workTreeStatus: "M",
                indexMode: "100755",
                workTreeMode: "100755"
            ),
            Support.pathRecord(
                kind: .untracked,
                path: "Subdir/新規.swift",
                indexStatus: nil,
                workTreeStatus: nil
            ),
            Support.pathRecord(
                kind: .untracked,
                path: "Subdir/Generated.tmp",
                indexStatus: nil,
                workTreeStatus: nil
            )
        ])
        let outcome = WorkspaceRootSeedPlanner.materialize(
            snapshot: snapshot,
            targetTreeOID: Support.oid("f"),
            treeDelta: [],
            index: GitIndexManifest(
                rootPrefix: prefix,
                entries: [
                    Support.indexEntry("Subdir/Keep.swift"),
                    Support.indexEntry("Subdir/bin/tool", mode: "100755")
                ],
                outputByteCount: 0
            ),
            status: status,
            verificationFacts: [
                "bin/tool": Support.fact("bin/tool", kind: .regularFile(isExecutable: true)),
                "新規.swift": Support.fact("新規.swift"),
                "Generated.tmp": Support.fact("Generated.tmp", ignored: true)
            ],
            copiedRepositoryRelativePaths: [],
            prefix: prefix
        )
        guard case let .planned(plan) = outcome else {
            return XCTFail("Expected prefix plan, got \(outcome)")
        }
        XCTAssertEqual(plan.relativeFilePaths, ["Keep.swift", "bin/tool", "新規.swift"])
        XCTAssertEqual(plan.relativeFolderPaths, ["bin"])

        let changedIgnore = Support.compatibilityKey(
            treeOID: Support.oid("f"),
            prefix: prefix,
            committedIgnoreDigest: "changed"
        )
        XCTAssertFalse(snapshot.compatibilityKey.isDeltaCompatible(with: changedIgnore))
    }

    private func delta(
        _ status: GitTreeDeltaStatus,
        source: String? = nil,
        destination: String,
        newMode: String? = "100644",
        newOID: GitObjectID? = Support.oid("f")
    ) -> GitTreeDeltaRecord {
        GitTreeDeltaRecord(
            oldMode: source == nil && status == .added ? nil : "100644",
            newMode: newMode,
            oldObjectID: source == nil && status == .added ? nil : Support.oid("1"),
            newObjectID: newOID,
            status: status,
            sourceRepositoryRelativePath: source,
            repositoryRelativePath: destination
        )
    }
}
