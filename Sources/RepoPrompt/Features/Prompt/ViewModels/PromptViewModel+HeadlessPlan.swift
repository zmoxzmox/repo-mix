import Foundation

// MARK: - Headless Mode

/// Which system prompt flavor to use for headless generation
enum HeadlessMode {
    case plan // Uses architect/planning system prompt
    case chat // Uses chat system prompt
    case review // Uses review system prompt with git diff
}

// MARK: - Headless Context Snapshot

/// A frozen snapshot of tab state for headless generation.
/// Used when running plan/chat via AIQueriesService without activating the tab.
struct HeadlessContextSnapshot {
    /// The compose tab this snapshot came from
    let tabID: UUID

    /// Effective prompt text for the request
    let promptText: String

    /// Frozen selection from ComposeTabState.selection
    let selection: StoredSelection
}

// MARK: - Headless AIMessage Builders

extension PromptViewModel {
    /// Builds an AIMessage for a headless request from a frozen snapshot.
    /// Does NOT read from live tab state - uses only the snapshot data.
    ///
    /// Headless specifics:
    /// - File tree: auto mode
    /// - Codemaps: auto mode
    /// - Git diff: included only for review
    /// - Warning: NOT included
    /// - System prompt depends on mode (plan uses architect, chat uses default chat, review uses stored review prompt)
    @MainActor
    func buildHeadlessAIMessage(
        from snapshot: HeadlessContextSnapshot,
        model: AIModel,
        mode: HeadlessMode = .plan,
        gitScopeOverride: GitInclusion? = nil,
        gitBaseOverride: String? = nil
    ) async -> AIMessage {
        // 1. Resolve file entries from the frozen snapshot selection through the headless store.
        let store = workspaceFileContextStore
        let accountingService = PromptContextAccountingService()
        let resolution = await accountingService.resolveEntries(
            selection: snapshot.selection,
            store: store,
            rootScope: .allLoaded,
            profile: .uiAssisted,
            codeMapUsage: .auto // Plan always uses auto
        )
        let codemapSnapshots = await store.codemapSnapshotDictionary()
        let (diffEntries, codeEntries) = PromptPackagingService.partitionPromptEntriesForGitDiff(resolution.entries)

        // 2. Generate file contents
        let fileBlocks = PromptPackagingService.generateFileContents(
            codeEntries,
            filePathDisplay: filePathDisplayOption,
            codemapSnapshots: codemapSnapshots
        )

        // 3. Build file tree (auto mode for plan) from the headless store snapshot.
        let fileTreeSnapshot = await store.makeFileTreeSelectionSnapshot(
            selection: snapshot.selection,
            request: WorkspaceFileTreeSnapshotRequest(
                mode: .auto,
                filePathDisplay: filePathDisplayOption,
                onlyIncludeRootsWithSelectedFiles: onlyIncludeRootsWithSelectedFiles,
                includeLegend: true,
                showCodeMapMarkers: true,
                rootScope: .allLoaded
            ),
            profile: .uiAssisted
        )
        let fileTree = CodeMapExtractor.generateFileTree(using: fileTreeSnapshot)

        // 4. System prompt based on mode
        let systemPrompt: String = {
            switch mode {
            case .plan:
                let custom = customPlanningPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
                return custom.isEmpty ? architectPrompt.content : custom
            case .chat:
                return getChatPrompt()
            case .review:
                let reviewPromptID = ChatPreset.BuiltIn.review.storedPromptIds?.first
                if let reviewPromptID,
                   let stored = storedPrompts.first(where: { $0.id == reviewPromptID })
                {
                    var prompt = stored.content
                    prompt += "\n\nYou may include one chat-name tag on its own line near the top: <chatName=\\\"Unique name describing user request\\\"/>"
                    prompt += "\n\nProvide your response in clean, well-formatted Markdown. Use proper headings, lists, code blocks, and other Markdown elements to make your response easy to read and understand. Do not emit machine-readable edit blocks."
                    return prompt
                }
                return getChatPrompt()
            }
        }()

        // 5. Single-user conversation
        let conversation = [ConversationEntry(role: .user, content: snapshot.promptText)]

        let gitDiff: String? = await PromptPackagingService.resolveGitDiff(
            fromDiffEntries: diffEntries
        ) {
            guard mode == .review else { return nil }
            let effectiveScope = gitScopeOverride ?? .selected
            switch effectiveScope {
            case .none:
                return nil
            case .selected:
                let selectedPaths = await resolvedSelectedGitDiffPaths(for: snapshot.selection)
                return await gitViewModel.getDiffForAbsolutePaths(selectedPaths, vs: gitBaseOverride, forceRefreshStatus: true)
            case .complete:
                return await gitViewModel.getDiffUsing(inclusionMode: .all, vs: gitBaseOverride, forceRefreshStatus: true)
            }
        }

        // 6. Assemble AIMessage (no warning, no meta prompts)
        return PromptPackagingService.buildAIMessage(
            systemPrompt: systemPrompt,
            metaInstructions: [],
            fileTree: fileTree,
            fileContents: fileBlocks,
            gitDiff: gitDiff,
            conversation: conversation,
            temperature: setModelTemperature ? modelTemperature : nil,
            promptSectionsOrder: promptSectionsOrder,
            disabledPromptSections: disabledPromptSections,
            duplicateUserInstructionsAtTop: duplicateUserInstructionsAtTop
        )
    }

    @MainActor
    func resolvedSelectedGitDiffPaths(
        for selection: StoredSelection,
        rootScope: WorkspaceLookupRootScope = .allLoaded
    ) async -> [String] {
        let candidates = MCPServerViewModel.gitDiffCandidates(from: selection)
        guard !candidates.isEmpty else { return [] }

        let store = workspaceFileContextStore
        let requests = candidates.map {
            WorkspacePathLookupRequest(userPath: $0, profile: .uiAssisted, rootScope: rootScope)
        }
        let resolved = await store.lookupPaths(requests)

        var seen = Set<String>()
        var selectedPaths: [String] = []

        func append(_ fullPath: String) {
            let standardized = StandardizedPath.absolute(fullPath)
            guard seen.insert(standardized).inserted else { return }
            selectedPaths.append(standardized)
        }

        for candidate in candidates {
            guard let result = resolved[candidate] else { continue }
            if let file = result.file {
                append(file.standardizedFullPath)
                continue
            }

            guard let folder = result.folder else { continue }
            let prefix = folder.standardizedRelativePath
            let files = await store.files(inRoot: folder.rootID)
            for file in files {
                let isInFolder = prefix.isEmpty
                    || file.standardizedRelativePath == prefix
                    || file.standardizedRelativePath.hasPrefix(prefix + "/")
                guard isInFolder else { continue }
                append(file.standardizedFullPath)
            }
        }

        return selectedPaths
    }
}
