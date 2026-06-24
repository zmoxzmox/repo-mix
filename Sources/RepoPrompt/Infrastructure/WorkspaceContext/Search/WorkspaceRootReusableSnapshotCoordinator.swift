import Foundation

actor WorkspaceRootReusableSnapshotCoordinator {
    enum CurrentnessValidation: Equatable {
        case current
        case stale(ObservationFailureCause)
    }

    typealias CurrentnessValidator = @Sendable () async -> CurrentnessValidation
    typealias CatalogEvidenceProvider = @Sendable (WorkspaceRootByteExactPathSet) async -> WorkspaceRootCatalogProjectionEvidence?

    enum ObservationFailureStage: String, Equatable {
        case loadedRootValidation = "loaded_root_validation"
        case initialCurrentness = "initial_currentness"
        case discoveryObservation = "discovery_observation"
        case discoveryAuthorityCapture = "discovery_authority_capture"
        case replacementObservation = "replacement_observation"
        case collection
        case capturedAuthority = "captured_authority"
        case treeInventory = "tree_inventory"
        case catalogClassification = "catalog_classification"
        case admissionPreparation = "admission_preparation"
        case preparedAdmissionCurrentness = "prepared_admission_currentness"
        case admissionCommit = "admission_commit"
        case committedAdmissionCurrentness = "committed_admission_currentness"
        case finalLoadedRootCurrentness = "final_loaded_root_currentness"
    }

    enum ObservationFailureCause: Equatable {
        case cancelled
        case staleCurrentness
        case loadedRootOwnerStale
        case loadedRootCatalogStale
        case loadedRootWatcherStale
        case boundedGitFailure(GitWorktreeInitializationFailureReason)
        case admissionRejected
        case unexpectedFailure

        var code: String {
            switch self {
            case .cancelled: "cancelled"
            case .staleCurrentness: "stale_currentness"
            case .loadedRootOwnerStale: "loaded_root_owner_stale"
            case .loadedRootCatalogStale: "loaded_root_catalog_stale"
            case .loadedRootWatcherStale: "loaded_root_watcher_stale"
            case .boundedGitFailure(.timeout): "git_timeout"
            case .boundedGitFailure(.gitError): "git_error"
            case .boundedGitFailure(.malformedOutput): "git_malformed_output"
            case .boundedGitFailure(.cappedOutput): "git_capped_output"
            case .boundedGitFailure(.recordLimitExceeded): "git_record_limit_exceeded"
            case .boundedGitFailure(.pathLimitExceeded): "git_path_limit_exceeded"
            case .boundedGitFailure(.invalidRootPrefix): "git_invalid_root_prefix"
            case .boundedGitFailure(.cancelled): "git_cancelled"
            case .admissionRejected: "admission_rejected"
            case .unexpectedFailure: "unexpected_failure"
            }
        }
    }

    struct ObservationFailure: Equatable {
        let stage: ObservationFailureStage
        let cause: ObservationFailureCause
    }

    enum ObservationResult: Equatable {
        case admitted(WorkspaceRootReusableSnapshotIdentity)
        case nonGit
        case unsupportedRoot
        case authorityUnavailable(
            stage: ObservationFailureStage,
            reason: GitWorkspaceAuthorityUnavailableReason
        )
        case catalogMismatch
        case failed(ObservationFailure)
    }

    static let shared = WorkspaceRootReusableSnapshotCoordinator()

    private let gitService: GitService
    private let authority: GitWorkspaceStateAuthority
    #if DEBUG
        private var preparedAdmissionHandlerForTesting: (@Sendable () async -> Void)?
    #endif

    init(
        gitService: GitService = GitService(),
        authority: GitWorkspaceStateAuthority = .shared
    ) {
        self.gitService = gitService
        self.authority = authority
    }

    func observeAuthoritativeFullLoad(
        rootURL: URL,
        authoritativeRelativeFilePaths: some Sequence<String>,
        catalogPolicyIdentity: WorkspaceRootCatalogPolicyIdentity = .canonicalDefaults,
        catalogEvidenceProvider: CatalogEvidenceProvider? = nil,
        currentnessValidator: @escaping CurrentnessValidator = { .current }
    ) async -> ObservationResult {
        guard let authoritativeExactPaths = WorkspaceRootByteExactPathSet(authoritativeRelativeFilePaths) else {
            return .catalogMismatch
        }
        if let failure = await Self.currentnessFailure(
            stage: .initialCurrentness,
            validator: currentnessValidator
        ) {
            return failure
        }
        guard let layout = Self.gitLayoutContaining(rootURL) else { return .nonGit }
        guard let prefix = try? Self.rootPrefix(rootURL: rootURL, layout: layout) else {
            return .unsupportedRoot
        }

        var discoveryObservation: GitWorkspaceMetadataMonitor.RetainToken?
        var replacementObservation: GitWorkspaceMetadataMonitor.RetainToken?
        var activeStage = ObservationFailureStage.discoveryObservation
        do {
            // The base observation stays live until replacement coverage has been
            // installed. A policy-path change during either collection advances
            // the shared watermark and prevents conditional admission.
            let discoveryToken = try await authority.retainMetadataObservation(for: layout)
            discoveryObservation = discoveryToken
            if let failure = await Self.currentnessFailure(
                stage: .discoveryObservation,
                validator: currentnessValidator
            ) {
                await authority.releaseMetadataObservation(discoveryToken)
                return failure
            }
            activeStage = .discoveryAuthorityCapture
            let discovery = try await gitService.workspaceAuthoritySnapshot(in: layout, prefix: prefix)
            if let failure = await Self.currentnessFailure(
                stage: .discoveryAuthorityCapture,
                validator: currentnessValidator
            ) {
                await authority.releaseMetadataObservation(discoveryToken)
                return failure
            }
            let discoveredExternalPaths = Self.canonicalPathSet(
                discovery.metadata.resolvedExternalAuthorityPaths
            )

            activeStage = .replacementObservation
            let observation = try await authority.retainMetadataObservation(
                for: layout,
                additionalAuthorityPaths: discovery.metadata.resolvedExternalAuthorityPaths
            )
            replacementObservation = observation
            if let failure = await Self.currentnessFailure(
                stage: .replacementObservation,
                validator: currentnessValidator
            ) {
                await authority.releaseMetadataObservation(observation)
                await authority.releaseMetadataObservation(discoveryToken)
                return failure
            }
            await authority.releaseMetadataObservation(discoveryToken)
            discoveryObservation = nil
            if let failure = await Self.currentnessFailure(
                stage: .collection,
                validator: currentnessValidator
            ) {
                await authority.releaseMetadataObservation(observation)
                return failure
            }

            let scope = GitWorkspaceAuthorityScopeKey(
                repositoryKey: GitWorkspaceAuthorityRepositoryKey(layout: layout),
                repositoryRelativeRootPrefix: prefix
            )
            let captureToken: GitWorkspaceAuthorityCaptureToken
            activeStage = .collection
            switch await authority.beginCollection(scopeKey: scope) {
            case let .success(token):
                captureToken = token
            case let .failure(reason):
                await authority.releaseMetadataObservation(observation)
                return .authorityUnavailable(stage: .collection, reason: reason)
            }
            if let failure = await Self.currentnessFailure(
                stage: .collection,
                validator: currentnessValidator
            ) {
                await authority.releaseMetadataObservation(observation)
                return failure
            }

            activeStage = .capturedAuthority
            let captured = try await gitService.workspaceAuthoritySnapshot(in: layout, prefix: prefix)
            if let failure = await Self.currentnessFailure(
                stage: .capturedAuthority,
                validator: currentnessValidator
            ) {
                await authority.releaseMetadataObservation(observation)
                return failure
            }
            guard Self.canonicalPathSet(captured.metadata.resolvedExternalAuthorityPaths) == discoveredExternalPaths else {
                await authority.releaseMetadataObservation(observation)
                return .authorityUnavailable(
                    stage: .capturedAuthority,
                    reason: .invalidatedDuringCollection
                )
            }
            let observationIsCurrent = await authority.metadataObservationIsCurrent(
                observation,
                for: layout,
                additionalAuthorityPaths: captured.metadata.resolvedExternalAuthorityPaths,
                expectedAcceptedWatermark: captureToken.acceptedMetadataWatermark
            )
            guard observationIsCurrent else {
                await authority.releaseMetadataObservation(observation)
                return .authorityUnavailable(
                    stage: .capturedAuthority,
                    reason: .invalidatedDuringCollection
                )
            }
            if let failure = await Self.currentnessFailure(
                stage: .capturedAuthority,
                validator: currentnessValidator
            ) {
                await authority.releaseMetadataObservation(observation)
                return failure
            }
            activeStage = .treeInventory
            let tree = try await gitService.listTree(
                captured.snapshot.treeOID,
                in: layout,
                prefix: prefix
            )
            if let failure = await Self.currentnessFailure(
                stage: .treeInventory,
                validator: currentnessValidator
            ) {
                await authority.releaseMetadataObservation(observation)
                return failure
            }

            guard let committedRegularRelativePaths = Self.committedRegularRelativePaths(in: tree) else {
                await authority.releaseMetadataObservation(observation)
                return .catalogMismatch
            }
            let missingCommittedRegularPaths = committedRegularRelativePaths
                .subtracting(authoritativeExactPaths)
            guard let emptyExactPaths = WorkspaceRootByteExactPathSet([String]()) else {
                await authority.releaseMetadataObservation(observation)
                return .catalogMismatch
            }
            var policyIgnoredCommittedRegularPaths = emptyExactPaths
            if !missingCommittedRegularPaths.isEmpty {
                activeStage = .catalogClassification
                if let failure = await Self.currentnessFailure(
                    stage: .catalogClassification,
                    validator: currentnessValidator
                ) {
                    await authority.releaseMetadataObservation(observation)
                    return failure
                }
                guard let catalogEvidenceProvider else {
                    await authority.releaseMetadataObservation(observation)
                    return .catalogMismatch
                }
                guard let evidence = await catalogEvidenceProvider(missingCommittedRegularPaths) else {
                    await authority.releaseMetadataObservation(observation)
                    return .failed(.init(stage: .catalogClassification, cause: .loadedRootCatalogStale))
                }
                guard evidence.policyIdentity == catalogPolicyIdentity else {
                    await authority.releaseMetadataObservation(observation)
                    return .failed(.init(stage: .catalogClassification, cause: .loadedRootCatalogStale))
                }
                guard Set(evidence.dispositionsByRelativePath.keys) == missingCommittedRegularPaths.keys,
                      evidence.dispositionsByRelativePath.values.allSatisfy({ $0 == .policyIgnoredRegularFile })
                else {
                    await authority.releaseMetadataObservation(observation)
                    return .catalogMismatch
                }
                policyIgnoredCommittedRegularPaths = missingCommittedRegularPaths
                if let failure = await Self.currentnessFailure(
                    stage: .catalogClassification,
                    validator: currentnessValidator
                ) {
                    await authority.releaseMetadataObservation(observation)
                    return failure
                }
            }

            let validatedCatalogProjection = WorkspaceRootValidatedCatalogProjection(
                discoverableRelativeFilePaths: authoritativeExactPaths,
                policyIgnoredCommittedRegularRelativePaths: policyIgnoredCommittedRegularPaths,
                policyIdentity: catalogPolicyIdentity
            )
            let lease: GitWorkspaceAuthorityLease
            switch await authority.install(captured.snapshot, capturedUsing: captureToken) {
            case let .success(installed):
                lease = installed
            case let .failure(reason):
                await authority.releaseMetadataObservation(observation)
                return .authorityUnavailable(stage: .treeInventory, reason: reason)
            }
            if let failure = await Self.currentnessFailure(
                stage: .admissionPreparation,
                validator: currentnessValidator
            ) {
                await authority.releaseMetadataObservation(observation)
                return failure
            }
            guard let snapshot = WorkspaceRootReusableSnapshot.make(
                authority: captured.snapshot,
                tree: tree,
                catalogProjection: validatedCatalogProjection
            ) else {
                await authority.releaseMetadataObservation(observation)
                return .catalogMismatch
            }
            activeStage = .admissionPreparation
            let preparedAdmission = await authority.prepareReusableSnapshotAdmission(
                snapshot,
                capturedUsing: lease,
                observationToken: observation
            )
            replacementObservation = nil
            if Task.isCancelled {
                if let preparedAdmission {
                    await authority.cancelPreparedReusableSnapshotAdmission(preparedAdmission)
                }
                return .failed(.init(stage: .admissionPreparation, cause: .cancelled))
            }
            guard let prepared = preparedAdmission else {
                return .failed(.init(stage: .admissionPreparation, cause: .admissionRejected))
            }
            #if DEBUG
                if let preparedAdmissionHandlerForTesting {
                    await preparedAdmissionHandlerForTesting()
                }
            #endif
            if let failure = await Self.currentnessFailure(
                stage: .preparedAdmissionCurrentness,
                validator: currentnessValidator
            ) {
                await authority.cancelPreparedReusableSnapshotAdmission(prepared)
                return failure
            }
            guard await authority.preparedReusableSnapshotAdmissionIsCurrent(prepared) else {
                await authority.cancelPreparedReusableSnapshotAdmission(prepared)
                return .authorityUnavailable(
                    stage: .preparedAdmissionCurrentness,
                    reason: .invalidatedDuringCollection
                )
            }
            if let failure = await Self.currentnessFailure(
                stage: .preparedAdmissionCurrentness,
                validator: currentnessValidator
            ) {
                await authority.cancelPreparedReusableSnapshotAdmission(prepared)
                return failure
            }
            activeStage = .admissionCommit
            let committedAdmission = await authority.admitPreparedReusableSnapshot(prepared)
            if Task.isCancelled {
                if let committedAdmission {
                    await authority.revokeReusableSnapshotAdmission(committedAdmission)
                }
                return .failed(.init(stage: .admissionCommit, cause: .cancelled))
            }
            guard let receipt = committedAdmission else {
                return .failed(.init(stage: .admissionCommit, cause: .admissionRejected))
            }
            if let failure = await Self.currentnessFailure(
                stage: .committedAdmissionCurrentness,
                validator: currentnessValidator
            ) {
                await authority.revokeReusableSnapshotAdmission(receipt)
                return failure
            }
            guard await authority.reusableSnapshotAdmissionIsCurrent(receipt) else {
                await authority.revokeReusableSnapshotAdmission(receipt)
                return .authorityUnavailable(
                    stage: .committedAdmissionCurrentness,
                    reason: .invalidatedDuringCollection
                )
            }
            if let failure = await Self.currentnessFailure(
                stage: .committedAdmissionCurrentness,
                validator: currentnessValidator
            ) {
                await authority.revokeReusableSnapshotAdmission(receipt)
                return failure
            }
            return .admitted(receipt.snapshotIdentity)
        } catch {
            if let discoveryObservation {
                await authority.releaseMetadataObservation(discoveryObservation)
            }
            if let replacementObservation {
                await authority.releaseMetadataObservation(replacementObservation)
            }
            let cause: ObservationFailureCause = if Task.isCancelled || error is CancellationError {
                .cancelled
            } else if let gitError = error as? GitWorktreeInitializationError {
                .boundedGitFailure(gitError.reason)
            } else {
                .unexpectedFailure
            }
            return .failed(.init(stage: activeStage, cause: cause))
        }
    }

    #if DEBUG
        func setPreparedAdmissionHandlerForTesting(
            _ handler: (@Sendable () async -> Void)?
        ) {
            preparedAdmissionHandlerForTesting = handler
        }
    #endif

    private nonisolated static func committedRegularRelativePaths(
        in tree: GitTreeInventorySnapshot
    ) -> WorkspaceRootByteExactPathSet? {
        WorkspaceRootByteExactPathSet(tree.entries.compactMap { entry in
            guard entry.kind == .blob,
                  entry.mode == "100644" || entry.mode == "100755",
                  let relativePath = WorkspaceRootByteExactPathKey.rootRelativePath(
                      repositoryRelativePath: entry.repositoryRelativePath,
                      prefix: tree.rootPrefix
                  ),
                  !relativePath.isEmpty
            else { return nil }
            return relativePath
        })
    }

    private nonisolated static func canonicalPathSet(_ paths: [URL]) -> Set<String> {
        Set(paths.map { $0.resolvingSymlinksInPath().standardizedFileURL.path })
    }

    private nonisolated static func currentnessFailure(
        stage: ObservationFailureStage,
        validator: CurrentnessValidator
    ) async -> ObservationResult? {
        guard !Task.isCancelled else {
            return .failed(.init(stage: stage, cause: .cancelled))
        }
        let validation = await validator()
        guard !Task.isCancelled else {
            return .failed(.init(stage: stage, cause: .cancelled))
        }
        switch validation {
        case .current:
            return nil
        case let .stale(cause):
            return .failed(.init(stage: stage, cause: cause))
        }
    }

    private nonisolated static func gitLayoutContaining(_ rootURL: URL) -> GitRepositoryLayout? {
        var candidate = rootURL.standardizedFileURL
        while true {
            if let layout = GitRepositoryLayoutResolver.resolve(atWorkTreeRoot: candidate) {
                return layout
            }
            let parent = candidate.deletingLastPathComponent().standardizedFileURL
            guard parent.path != candidate.path else { return nil }
            candidate = parent
        }
    }

    private nonisolated static func rootPrefix(
        rootURL: URL,
        layout: GitRepositoryLayout
    ) throws -> GitRepositoryRelativeRootPrefix {
        let rootPath = rootURL.standardizedFileURL.path
        let worktreePath = layout.workTreeRoot.standardizedFileURL.path
        let rootBytes = Array(rootPath.utf8)
        let worktreeBytes = Array(worktreePath.utf8)
        if rootBytes == worktreeBytes {
            return try GitRepositoryRelativeRootPrefix("")
        }
        let requiredPrefix = worktreeBytes + [UInt8(ascii: "/")]
        guard rootBytes.starts(with: requiredPrefix), rootBytes.count > requiredPrefix.count else {
            throw GitWorktreeInitializationError.invalidRootPrefix
        }
        return try GitRepositoryRelativeRootPrefix(
            String(decoding: rootBytes.dropFirst(requiredPrefix.count), as: UTF8.self)
        )
    }
}
