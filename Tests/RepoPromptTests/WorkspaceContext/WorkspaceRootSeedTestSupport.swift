import Foundation
@testable import RepoPrompt

enum WorkspaceRootSeedTestSupport {
    static func oid(_ scalar: Character = "1") -> GitObjectID {
        try! GitObjectID(objectFormat: .sha1, lowercaseHex: String(repeating: scalar, count: 40))
    }

    static func compatibilityKey(
        treeOID: GitObjectID = oid(),
        prefix: GitRepositoryRelativeRootPrefix = try! GitRepositoryRelativeRootPrefix(""),
        committedIgnoreDigest: String = "ignore"
    ) -> WorkspaceRootSeedCompatibilityKey {
        let root = URL(fileURLWithPath: "/tmp/workspace-root-seed-tests")
        let git = root.appendingPathComponent(".git", isDirectory: true)
        let layout = GitRepositoryLayout(
            workTreeRoot: root,
            dotGitPath: git,
            gitDir: git,
            commonDir: git,
            isWorktree: false
        )
        let policy = GitWorkspacePolicyIdentity(
            mandatoryIgnorePolicyIdentity: "git-ignore-policy-v1",
            committedIgnoreControlDigest: committedIgnoreDigest,
            configuredIgnoreAuthorityDigest: "configured-ignore",
            attributePolicyDigest: "attributes",
            sparsePolicyDigest: "sparse-disabled",
            searchABI: .current,
            resolvedExcludesFileIdentity: nil,
            resolvedAttributesFileIdentity: nil,
            prefixControlIdentities: []
        )
        let authority = GitWorkspaceAuthoritySnapshot(
            repositoryKey: GitWorkspaceAuthorityRepositoryKey(layout: layout),
            repositoryNamespace: try! GitBlobRepositoryNamespace(rawValue: String(repeating: "a", count: 64)),
            objectFormat: .sha1,
            headCommitOID: oid("b"),
            treeOID: treeOID,
            repositoryRelativeRootPrefix: prefix,
            repositoryBindingEpoch: "repository",
            worktreeBindingEpoch: "worktree",
            layoutGeneration: "layout",
            indexGeneration: "index",
            checkoutConfigurationGeneration: "checkout",
            metadataGeneration: "metadata",
            policyIdentity: policy
        )
        return WorkspaceRootSeedCompatibilityKey(authority: authority)
    }

    static func snapshot(
        paths: [(String, String)],
        treeOID: GitObjectID = oid(),
        prefix: GitRepositoryRelativeRootPrefix = try! GitRepositoryRelativeRootPrefix(""),
        policyIgnoredPaths: Set<String> = [],
        catalogPolicyIdentity: WorkspaceRootCatalogPolicyIdentity = .canonicalDefaults
    ) -> WorkspaceRootReusableSnapshot {
        let entries = paths.enumerated().map { ordinal, value in
            RootNeutralTreeInventoryEntry(
                ordinal: ordinal,
                parentOrdinal: nil,
                relativePath: value.0,
                mode: value.1,
                kind: .blob,
                objectID: oid(Character(String((ordinal % 8) + 1))),
                provenance: .committedTree,
                catalogProjection: policyIgnoredPaths.contains(value.0)
                    ? .policyIgnoredRegularFile
                    : nil
            )
        }
        return WorkspaceRootReusableSnapshot(
            compatibilityKey: compatibilityKey(treeOID: treeOID, prefix: prefix),
            inventory: RootNeutralTreeInventory(entries: entries),
            catalogPolicyIdentity: catalogPolicyIdentity
        )
    }

    static func indexEntry(
        _ path: String,
        mode: String = "100644",
        stage: Int = 0,
        assumeUnchanged: Bool = false,
        skipWorktree: Bool = false
    ) -> GitIndexManifestEntry {
        GitIndexManifestEntry(
            mode: mode,
            objectID: oid("c"),
            stage: stage,
            repositoryRelativePath: path,
            assumeUnchanged: assumeUnchanged,
            skipWorktree: skipWorktree
        )
    }

    static func status(
        _ records: [GitPorcelainV2PathRecord]
    ) -> GitStatusPorcelainV2Snapshot {
        GitStatusPorcelainV2Snapshot(
            branch: nil,
            headID: nil,
            upstream: nil,
            ahead: nil,
            behind: nil,
            staged: [],
            modified: [],
            untracked: records.compactMap { $0.kind == .untracked ? $0.path : nil },
            pathRecords: records
        )
    }

    static func pathRecord(
        kind: GitPorcelainV2RecordKind,
        path: String,
        indexStatus: Character? = ".",
        workTreeStatus: Character? = ".",
        indexMode: String? = "100644",
        workTreeMode: String? = "100644",
        submoduleState: String? = "N..."
    ) -> GitPorcelainV2PathRecord {
        GitPorcelainV2PathRecord(
            kind: kind,
            path: path,
            indexStatus: indexStatus,
            workTreeStatus: workTreeStatus,
            submoduleState: submoduleState,
            headMode: "100644",
            indexMode: indexMode,
            workTreeMode: workTreeMode,
            headOID: oid("d").lowercaseHex,
            indexOID: oid("e").lowercaseHex,
            conflictStage1Mode: nil,
            conflictStage2Mode: nil,
            conflictStage3Mode: nil,
            conflictStage1OID: nil,
            conflictStage2OID: nil,
            conflictStage3OID: nil
        )
    }

    static func fact(
        _ path: String,
        kind: WorkspaceRootSeedVerifiedPathKind = .regularFile(isExecutable: false),
        ignored: Bool = false,
        includedInOrdinaryCrawl: Bool? = nil
    ) -> WorkspaceRootSeedVerificationFact {
        WorkspaceRootSeedVerificationFact(
            relativePath: path,
            kind: kind,
            isIgnored: ignored,
            isIncludedInOrdinaryCrawl: includedInOrdinaryCrawl
        )
    }
}
