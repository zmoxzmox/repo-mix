import Foundation

struct AgentContextExportSource: Equatable {
    let tabID: UUID?
    let promptText: String
    let selection: StoredSelection
    let selectedMetaPromptIDs: [UUID]
    let tabName: String?
    let activeAgentSessionID: UUID?
    let worktreeBindings: [AgentSessionWorktreeBinding]

    var hasWorktreeBindings: Bool {
        activeAgentSessionID != nil && !worktreeBindings.isEmpty
    }

    var exportContextIdentity: AgentContextExportIdentity {
        AgentContextExportIdentity(
            tabID: tabID,
            activeAgentSessionID: activeAgentSessionID,
            worktreeBindingFingerprint: Self.worktreeBindingFingerprint(worktreeBindings)
        )
    }

    static func worktreeBindingFingerprint(_ bindings: [AgentSessionWorktreeBinding]) -> String {
        AgentWorkspaceLookupContextSource.worktreeBindingFingerprint(bindings)
    }
}

struct AgentContextExportIdentity: Equatable {
    let tabID: UUID?
    let activeAgentSessionID: UUID?
    let worktreeBindingFingerprint: String
}

struct AgentContextExportSourceBuildRequest {
    let requestedTabID: UUID?
    let activeComposeTabID: UUID?
    let activePromptText: String
    let activeSelectionSnapshot: WorkspaceSelectionCoordinator.Snapshot?
    let composeTabs: [ComposeTabState]
    let explicitActiveAgentSessionID: UUID?
    let worktreeBindingsProvider: (UUID, UUID?) -> [AgentSessionWorktreeBinding]
}

enum AgentContextExportSourceBuilder {
    static func makeSource(_ request: AgentContextExportSourceBuildRequest) -> AgentContextExportSource {
        let resolvedTabID = request.requestedTabID
            ?? request.activeSelectionSnapshot?.tabID
            ?? request.activeComposeTabID
        let tab = resolvedTabID.flatMap { tabID in
            request.composeTabs.first { $0.id == tabID }
        }
        let activeSnapshotApplies = request.activeSelectionSnapshot?.tabID == resolvedTabID
        let selection = activeSnapshotApplies
            ? request.activeSelectionSnapshot?.selection ?? StoredSelection()
            : tab?.selection ?? StoredSelection()
        let promptText = resolvedTabID == request.activeComposeTabID
            ? request.activePromptText
            : tab?.promptText ?? request.activePromptText
        let sessionID = request.explicitActiveAgentSessionID ?? tab?.activeAgentSessionID
        let bindings = sessionID.map { request.worktreeBindingsProvider($0, resolvedTabID) } ?? []

        return AgentContextExportSource(
            tabID: resolvedTabID,
            promptText: promptText,
            selection: selection,
            selectedMetaPromptIDs: tab?.selectedMetaPromptIDs ?? [],
            tabName: tab?.name,
            activeAgentSessionID: sessionID,
            worktreeBindings: bindings
        )
    }
}

struct AgentContextExportModel: Equatable {
    let source: AgentContextExportSource
    let lookupContext: WorkspaceLookupContext
    let rows: [AgentContextExportRow]
    let missingPaths: [String]
    let invalidPaths: [String]

    var fileCount: Int {
        rows.count
    }
}

struct AgentContextExportRow: Identifiable, Equatable {
    enum Kind: Int, Equatable {
        case codemap = 0
        case slices = 1
        case full = 2

        var iconName: String {
            switch self {
            case .codemap: "square.grid.2x2"
            case .slices: "scissors"
            case .full: "doc.text"
            }
        }

        var badgeText: String? {
            switch self {
            case .codemap: "Codemap"
            case .slices: "Slices"
            case .full: nil
            }
        }
    }

    let id: ResolvedPromptFileEntryID
    let kind: Kind
    let physicalPath: String
    let rootID: UUID
    let relativePath: String
    let displayPath: String
    let displayName: String
    let directoryDisplay: String?
    let lineRanges: [LineRange]?
    let canRemove: Bool
}

extension AgentContextExportRow {
    enum ContentPurpose {
        case preview
        case copy
    }
}

struct AgentContextClipboardRequest {
    let cfg: PromptContextResolved
    let source: AgentContextExportSource
    let store: WorkspaceFileContextStore
    let lookupContext: WorkspaceLookupContext
    let filePathDisplay: FilePathDisplay
    let onlyIncludeRootsWithSelectedFiles: Bool
    let showCodeMapMarkers: Bool
    let codemapSnapshots: [UUID: WorkspaceCodemapSnapshot]
    let metaInstructions: [MetaInstruction]
    let includeDatetimeInUserInstructions: Bool
    let promptSectionsOrder: [PromptSection]
    let disabledPromptSections: Set<PromptSection>
    let duplicateUserInstructionsAtTop: Bool
    let selectedGitDiffProvider: ([String]) async -> String
    let completeGitDiffProvider: () async -> String
}

enum AgentContextExportResolver {
    private struct RowResolutionEntry {
        let entry: ResolvedPromptFileEntry
        let canRemove: Bool
    }

    static let deferredCompleteWorktreeGitDiffMessage = "Complete git diff export is not available for worktree-bound Agent context yet; this export intentionally omits the base-checkout complete diff. Use selected-file diff or MCP workspace_context export for worktree-aware diff details."

    static func selectionFileCount(_ selection: StoredSelection) -> Int {
        var seen = Set<String>()
        for path in selection.selectedPaths {
            seen.insert(normalizedSelectionKey(path))
        }
        for path in selection.autoCodemapPaths {
            seen.insert(normalizedSelectionKey(path))
        }
        for (path, ranges) in selection.slices where !ranges.isEmpty {
            seen.insert(normalizedSelectionKey(path))
        }
        return seen.count
    }

    static func displayFileCount(
        resolvedModel: AgentContextExportModel?,
        sourceSelection: StoredSelection
    ) -> Int {
        if let resolvedModel {
            return resolvedModel.fileCount
        }
        return selectionFileCount(sourceSelection)
    }

    static func lookupContext(
        source: AgentContextExportSource,
        store: WorkspaceFileContextStore
    ) async -> WorkspaceLookupContext {
        await AgentWorkspaceLookupContextResolver.lookupContext(
            source: AgentWorkspaceLookupContextSource(
                activeAgentSessionID: source.activeAgentSessionID,
                worktreeBindings: source.worktreeBindings
            ),
            store: store
        )
    }

    static func resolveModel(
        source: AgentContextExportSource,
        store: WorkspaceFileContextStore,
        filePathDisplay: FilePathDisplay,
        codeMapUsage: CodeMapUsage
    ) async -> AgentContextExportModel {
        let lookupContext = await lookupContext(source: source, store: store)
        let physicalSelection = lookupContext.physicalizeSelection(source.selection)
        let codemapSnapshots = await store.codemapSnapshotDictionary()
        let resolution = await resolveRows(
            selection: physicalSelection,
            store: store,
            rootScope: lookupContext.rootScope,
            profile: .uiAssisted,
            codeMapUsage: codeMapUsage,
            codemapSnapshots: codemapSnapshots
        )
        let roots = await store.rootRefs(scope: lookupContext.rootScope)
        let rows = resolution.rows.map { rowEntry in
            row(
                from: rowEntry.entry,
                roots: roots,
                lookupContext: lookupContext,
                filePathDisplay: filePathDisplay,
                canRemove: rowEntry.canRemove
            )
        }
        .sorted(by: rowSort)
        return AgentContextExportModel(
            source: source,
            lookupContext: lookupContext,
            rows: rows,
            missingPaths: resolution.missingPaths,
            invalidPaths: resolution.invalidPaths
        )
    }

    static func buildClipboardContent(_ request: AgentContextClipboardRequest) async -> String {
        let cfg = request.cfg
        let physicalSelection = request.lookupContext.physicalizeSelection(request.source.selection)
        let accountingService = PromptContextAccountingService()
        let resolution = await accountingService.resolveEntries(
            selection: physicalSelection,
            store: request.store,
            rootScope: request.lookupContext.rootScope,
            profile: .uiAssisted,
            codeMapUsage: cfg.codeMapUsage
        )

        let combinedTreeAndMap: String?
        if cfg.rendersFileTree {
            let rawFileTreeSnapshot = await request.store.makeFileTreeSelectionSnapshot(
                selection: physicalSelection,
                request: WorkspaceFileTreeSnapshotRequest(
                    mode: WorkspaceFileTreeSnapshotMode(fileTreeOption: cfg.effectiveFileTreeMode),
                    filePathDisplay: request.filePathDisplay,
                    onlyIncludeRootsWithSelectedFiles: request.onlyIncludeRootsWithSelectedFiles,
                    includeLegend: true,
                    showCodeMapMarkers: request.showCodeMapMarkers,
                    rootScope: request.lookupContext.rootScope
                ),
                profile: .uiAssisted
            )
            let fileTreeSnapshot = request.lookupContext.bindingProjection?.logicalizeFileTreeSnapshot(rawFileTreeSnapshot) ?? rawFileTreeSnapshot
            let tree = CodeMapExtractor.generateFileTree(using: fileTreeSnapshot)
            combinedTreeAndMap = tree.isEmpty ? nil : tree
        } else {
            combinedTreeAndMap = nil
        }

        let (diffEntries, _) = PromptPackagingService.partitionPromptEntriesForGitDiff(resolution.entries)
        let gitDiff: String?
        switch cfg.gitInclusion {
        case .none:
            gitDiff = nil
        case .selected:
            let selectedPaths = await selectedGitDiffPaths(
                for: physicalSelection,
                store: request.store,
                rootScope: request.lookupContext.rootScope
            )
            gitDiff = diffEntries.isEmpty ? await request.selectedGitDiffProvider(selectedPaths) : nil
        case .complete:
            if request.lookupContext.bindingProjection != nil {
                gitDiff = deferredCompleteWorktreeGitDiffMessage
            } else {
                gitDiff = diffEntries.isEmpty ? await request.completeGitDiffProvider() : nil
            }
        }

        return await PromptPackagingService.generateClipboardContent(
            metaInstructions: request.metaInstructions,
            userInstructions: cfg.includeUserPrompt ? request.source.promptText : "",
            files: resolution.entries,
            fileTreeContent: combinedTreeAndMap,
            gitDiff: gitDiff,
            includeSavedPrompts: !request.metaInstructions.isEmpty,
            includeFiles: cfg.includeFiles,
            includeUserPrompt: cfg.includeUserPrompt,
            filePathDisplay: request.filePathDisplay,
            codemapSnapshots: request.codemapSnapshots,
            includeDatetimeInUserInstructions: request.includeDatetimeInUserInstructions,
            promptSectionsOrder: request.promptSectionsOrder,
            disabledPromptSections: request.disabledPromptSections,
            duplicateUserInstructionsAtTop: request.duplicateUserInstructionsAtTop,
            displayPathResolver: { entry in
                request.lookupContext.bindingProjection?.projectedLogicalDisplayPath(
                    forPhysicalPath: entry.file.standardizedFullPath,
                    display: request.filePathDisplay
                )
            }
        )
    }

    static func loadRowContent(
        for row: AgentContextExportRow,
        store: WorkspaceFileContextStore,
        purpose: AgentContextExportRow.ContentPurpose
    ) async -> String? {
        switch row.kind {
        case .codemap:
            let snapshots = await store.codemapSnapshotDictionary()
            let text = snapshots[row.id.fileID]?.fileAPI?.getFullAPIDescription(displayPath: row.displayPath)
            return text?.isEmpty == false ? text : nil
        case .full:
            return try? await store.readContent(rootID: row.rootID, relativePath: row.relativePath)
        case .slices:
            guard let content = try? await store.readContent(rootID: row.rootID, relativePath: row.relativePath) else {
                return nil
            }
            guard purpose == .copy, let ranges = row.lineRanges, !ranges.isEmpty else {
                return content
            }
            return SliceAssemblyBuilder.build(from: content, ranges: ranges).combinedText
        }
    }

    static func removeRow(_ row: AgentContextExportRow, from selection: StoredSelection, lookupContext: WorkspaceLookupContext) -> StoredSelection {
        let target = StandardizedPath.absolute(row.physicalPath)
        let selectedPaths = selection.selectedPaths.filter { physicalizedKey($0, lookupContext: lookupContext) != target }
        let autoCodemapPaths = selection.autoCodemapPaths.filter { physicalizedKey($0, lookupContext: lookupContext) != target }
        let slices = selection.slices.filter { path, ranges in
            !ranges.isEmpty && physicalizedKey(path, lookupContext: lookupContext) != target
        }
        return StoredSelection(
            selectedPaths: selectedPaths,
            autoCodemapPaths: autoCodemapPaths,
            slices: slices,
            codemapAutoEnabled: selection.codemapAutoEnabled
        )
    }

    static func removeSelectionSnapshot(_ snapshot: StoredSelection, from selection: StoredSelection) -> StoredSelection {
        let selectedSnapshotKeys = Set(snapshot.selectedPaths.map(normalizedSelectionKey))
        let codemapSnapshotKeys = Set(snapshot.autoCodemapPaths.map(normalizedSelectionKey))
        let sliceSnapshotKeys = Set(snapshot.slices.keys.map(normalizedSelectionKey))
        let selectedPaths = selection.selectedPaths.filter { !selectedSnapshotKeys.contains(normalizedSelectionKey($0)) }
        let autoCodemapPaths = selection.autoCodemapPaths.filter { !codemapSnapshotKeys.contains(normalizedSelectionKey($0)) }
        let slices = selection.slices.filter { path, ranges in
            !ranges.isEmpty && !sliceSnapshotKeys.contains(normalizedSelectionKey(path))
        }
        return StoredSelection(
            selectedPaths: selectedPaths,
            autoCodemapPaths: autoCodemapPaths,
            slices: slices,
            codemapAutoEnabled: selection.codemapAutoEnabled
        )
    }

    static func selectedGitDiffPaths(
        for selection: StoredSelection,
        store: WorkspaceFileContextStore,
        rootScope: WorkspaceLookupRootScope
    ) async -> [String] {
        let candidates = gitDiffCandidates(from: selection)
        guard !candidates.isEmpty else { return [] }
        let resolvedFiles = await store.lookupFiles(atPaths: candidates, profile: .mcpSelection, rootScope: rootScope)
        let resolvedMap = resolvedFiles.mapValues { $0.standardizedFullPath }
        return resolveGitDiffPaths(
            candidates: candidates,
            resolvedMap: resolvedMap,
            normalizeUserInput: { ($0 as NSString).expandingTildeInPath.trimmingCharacters(in: .whitespacesAndNewlines) },
            fileExists: { FileManager.default.fileExists(atPath: $0) }
        )
    }

    private static func resolveRows(
        selection: StoredSelection,
        store: WorkspaceFileContextStore,
        rootScope: WorkspaceLookupRootScope,
        profile: PathLocateProfile,
        codeMapUsage: CodeMapUsage,
        codemapSnapshots: [UUID: WorkspaceCodemapSnapshot]
    ) async -> (rows: [RowResolutionEntry], missingPaths: [String], invalidPaths: [String]) {
        var rows: [RowResolutionEntry] = []
        var missingPaths: [String] = []
        var invalidPaths: [String] = []
        var seenIDs = Set<ResolvedPromptFileEntryID>()
        var selectedFileIDs = Set<UUID>()

        let selectedRequests = selection.selectedPaths.map {
            WorkspacePathLookupRequest(userPath: $0, profile: profile, rootScope: rootScope)
        }
        let selectedLookupResults = await store.lookupPaths(selectedRequests)

        for path in selection.selectedPaths {
            let result = await selectedLookupResult(
                for: path,
                batchedResults: selectedLookupResults,
                store: store,
                profile: profile,
                rootScope: rootScope
            )
            guard let result else {
                if await appendDirectoryRows(
                    for: path,
                    store: store,
                    rootScope: rootScope,
                    selectedFileIDs: &selectedFileIDs,
                    rows: &rows,
                    seenIDs: &seenIDs
                ) {
                    continue
                }
                missingPaths.append(path)
                continue
            }

            if let file = result.file {
                selectedFileIDs.insert(file.id)
                let ranges = sliceRanges(for: path, file: file, location: result.location, in: selection.slices)
                let useSelectedCodemap = codeMapUsage == .selected && codemapSnapshots[file.id]?.fileAPI != nil
                let entry = ResolvedPromptFileEntry(
                    file: file,
                    isCodemap: useSelectedCodemap,
                    lineRanges: useSelectedCodemap ? nil : ranges,
                    mode: useSelectedCodemap ? .codemap : ((ranges?.isEmpty == false) ? .sliced : .fullFile),
                    loadedContent: nil,
                    rootFolderPath: result.location.rootPath
                )
                append(entry, canRemove: true, to: &rows, seenIDs: &seenIDs)
            } else if let folder = result.folder {
                let files = await store.files(inRoot: folder.rootID)
                let prefix = folder.standardizedRelativePath
                for file in files where prefix.isEmpty || file.standardizedRelativePath == prefix || file.standardizedRelativePath.hasPrefix(prefix + "/") {
                    selectedFileIDs.insert(file.id)
                    let useSelectedCodemap = codeMapUsage == .selected && codemapSnapshots[file.id]?.fileAPI != nil
                    let entry = ResolvedPromptFileEntry(
                        file: file,
                        isCodemap: useSelectedCodemap,
                        mode: useSelectedCodemap ? .codemap : .fullFile,
                        loadedContent: nil,
                        rootFolderPath: result.location.rootPath
                    )
                    append(entry, canRemove: false, to: &rows, seenIDs: &seenIDs)
                }
            } else {
                invalidPaths.append(path)
            }
        }

        for (path, ranges) in selection.slices where !ranges.isEmpty {
            guard let result = await store.lookupPath(path, profile: profile, rootScope: rootScope) else {
                missingPaths.append(path)
                continue
            }
            guard let file = result.file else {
                invalidPaths.append(path)
                continue
            }
            guard !selectedFileIDs.contains(file.id) else { continue }
            selectedFileIDs.insert(file.id)
            let entry = ResolvedPromptFileEntry(
                file: file,
                lineRanges: ranges,
                mode: .sliced,
                loadedContent: nil,
                rootFolderPath: result.location.rootPath
            )
            append(entry, canRemove: true, to: &rows, seenIDs: &seenIDs)
        }

        let scopedRoots = await store.rootRefs(scope: rootScope)
        let scopedRootIDs = Set(scopedRoots.map(\.id))
        let codemapPaths: [String] = switch codeMapUsage {
        case .none, .selected:
            []
        case .auto:
            Array(selection.autoCodemapPaths)
        case .complete:
            codemapSnapshots.compactMap { fileID, snapshot in
                guard !selectedFileIDs.contains(fileID),
                      scopedRootIDs.contains(snapshot.rootID),
                      snapshot.fileAPI != nil
                else { return nil }
                return snapshot.fullPath
            }
        }

        for path in codemapPaths {
            guard let result = await store.lookupPath(path, profile: profile, rootScope: rootScope) else {
                missingPaths.append(path)
                continue
            }
            guard let file = result.file else {
                invalidPaths.append(path)
                continue
            }
            guard !selectedFileIDs.contains(file.id), codemapSnapshots[file.id]?.fileAPI != nil else { continue }
            let entry = ResolvedPromptFileEntry(
                file: file,
                isCodemap: true,
                mode: .codemap,
                loadedContent: nil,
                rootFolderPath: result.location.rootPath
            )
            append(entry, canRemove: codeMapUsage == .auto, to: &rows, seenIDs: &seenIDs)
        }

        return (rows, Array(Set(missingPaths)).sorted(), Array(Set(invalidPaths)).sorted())
    }

    private static func row(
        from entry: ResolvedPromptFileEntry,
        roots: [WorkspaceRootRef],
        lookupContext: WorkspaceLookupContext,
        filePathDisplay: FilePathDisplay,
        canRemove: Bool
    ) -> AgentContextExportRow {
        let displayPath = displayPath(for: entry, roots: roots, lookupContext: lookupContext, filePathDisplay: filePathDisplay)
        let kind: AgentContextExportRow.Kind = if entry.isCodemap {
            .codemap
        } else if entry.lineRanges?.isEmpty == false {
            .slices
        } else {
            .full
        }
        let displayName = URL(fileURLWithPath: displayPath).lastPathComponent
        let directory = directoryDisplay(for: displayPath, fallbackRootPath: entry.rootFolderPath)
        return AgentContextExportRow(
            id: entry.id,
            kind: kind,
            physicalPath: entry.file.standardizedFullPath,
            rootID: entry.file.rootID,
            relativePath: entry.file.standardizedRelativePath,
            displayPath: displayPath,
            displayName: displayName.isEmpty ? entry.file.name : displayName,
            directoryDisplay: directory,
            lineRanges: entry.lineRanges,
            canRemove: canRemove
        )
    }

    private static func displayPath(
        for entry: ResolvedPromptFileEntry,
        roots: [WorkspaceRootRef],
        lookupContext: WorkspaceLookupContext,
        filePathDisplay: FilePathDisplay
    ) -> String {
        if let projected = lookupContext.bindingProjection?.projectedLogicalDisplayPath(
            forPhysicalPath: entry.file.standardizedFullPath,
            display: filePathDisplay
        ) {
            return projected
        }
        if filePathDisplay == .full {
            return entry.file.standardizedFullPath
        }
        if let root = roots.first(where: { $0.id == entry.file.rootID }) {
            return ClientPathFormatter.displayPath(
                root: root,
                relativePath: entry.file.standardizedRelativePath,
                visibleRoots: roots
            )
        }
        return entry.file.standardizedRelativePath.isEmpty ? entry.file.standardizedFullPath : entry.file.standardizedRelativePath
    }

    private static func directoryDisplay(for displayPath: String, fallbackRootPath: String?) -> String? {
        let directory = (displayPath as NSString).deletingLastPathComponent
        if directory != ".", !directory.isEmpty {
            return directory
        }
        guard let fallbackRootPath else { return nil }
        let rootName = URL(fileURLWithPath: fallbackRootPath).lastPathComponent
        return rootName.isEmpty ? nil : rootName
    }

    private static func rowSort(_ lhs: AgentContextExportRow, _ rhs: AgentContextExportRow) -> Bool {
        if lhs.kind != rhs.kind { return lhs.kind.rawValue < rhs.kind.rawValue }
        if lhs.displayName.localizedStandardCompare(rhs.displayName) != .orderedSame {
            return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
        }
        return lhs.displayPath.localizedStandardCompare(rhs.displayPath) == .orderedAscending
    }

    private static func appendDirectoryRows(
        for path: String,
        store: WorkspaceFileContextStore,
        rootScope: WorkspaceLookupRootScope,
        selectedFileIDs: inout Set<UUID>,
        rows: inout [RowResolutionEntry],
        seenIDs: inout Set<ResolvedPromptFileEntryID>
    ) async -> Bool {
        let roots = await store.rootRefs(scope: rootScope)
        var handled = false
        for root in roots {
            guard let relativePrefix = directoryRelativePrefix(path, in: root) else { continue }
            let absoluteDirectory = ((root.standardizedFullPath as NSString).appendingPathComponent(relativePrefix) as NSString).standardizingPath
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: absoluteDirectory, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            handled = true
            let files = await store.files(inRoot: root.id)
            for file in files where relativePrefix.isEmpty || file.standardizedRelativePath.hasPrefix(relativePrefix + "/") {
                selectedFileIDs.insert(file.id)
                let entry = ResolvedPromptFileEntry(
                    file: file,
                    mode: .fullFile,
                    loadedContent: nil,
                    rootFolderPath: root.standardizedFullPath
                )
                append(entry, canRemove: false, to: &rows, seenIDs: &seenIDs)
            }
        }
        return handled
    }

    private static func directoryRelativePrefix(_ path: String, in root: WorkspaceRootRef) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let expanded = (trimmed as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") {
            let standardized = StandardizedPath.absolute(expanded)
            guard standardized == root.standardizedFullPath || StandardizedPath.isDescendant(standardized, of: root.standardizedFullPath) else { return nil }
            if standardized == root.standardizedFullPath { return "" }
            return StandardizedPath.relative(String(standardized.dropFirst(root.standardizedFullPath.count + 1)))
        }
        return StandardizedPath.relative(expanded)
    }

    private static func selectedLookupResult(
        for path: String,
        batchedResults: [String: WorkspacePathLookupResult],
        store: WorkspaceFileContextStore,
        profile: PathLocateProfile,
        rootScope: WorkspaceLookupRootScope
    ) async -> WorkspacePathLookupResult? {
        if let result = batchedResults[path] { return result }
        return await store.lookupPath(path, profile: profile, rootScope: rootScope)
    }

    private static func sliceRanges(
        for path: String,
        file: WorkspaceFileRecord,
        location: WorkspacePathLocation,
        in slices: [String: [LineRange]]
    ) -> [LineRange]? {
        let candidateKeys = [
            path,
            StandardizedPath.absolute(path),
            file.relativePath,
            file.standardizedRelativePath,
            file.fullPath,
            file.standardizedFullPath,
            location.absolutePath
        ]
        for key in candidateKeys {
            if let ranges = slices[key] { return ranges }
        }
        return nil
    }

    private static func append(
        _ entry: ResolvedPromptFileEntry,
        canRemove: Bool,
        to rows: inout [RowResolutionEntry],
        seenIDs: inout Set<ResolvedPromptFileEntryID>
    ) {
        guard seenIDs.insert(entry.id).inserted else { return }
        rows.append(RowResolutionEntry(entry: entry, canRemove: canRemove))
    }

    private static func physicalizedKey(_ path: String, lookupContext: WorkspaceLookupContext) -> String {
        let translated = lookupContext.translateInputPath(path)
        if translated.hasPrefix("/") {
            return StandardizedPath.absolute(translated)
        }
        return StandardizedPath.relative(translated)
    }

    private static func normalizedSelectionKey(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let expanded = (trimmed as NSString).expandingTildeInPath
        return expanded.hasPrefix("/") ? StandardizedPath.absolute(expanded) : StandardizedPath.relative(expanded)
    }

    private static func gitDiffCandidates(from selection: StoredSelection) -> [String] {
        var candidates = StoredSelectionPathNormalization.standardizedPaths(selection.selectedPaths)
        var seen = Set(candidates)
        for (path, ranges) in StoredSelectionPathNormalization.standardizedSlices(selection.slices) where !ranges.isEmpty {
            guard seen.insert(path).inserted else { continue }
            candidates.append(path)
        }
        return candidates
    }

    private static func resolveGitDiffPaths(
        candidates: [String],
        resolvedMap: [String: String],
        normalizeUserInput: (String) -> String,
        fileExists: (String) -> Bool
    ) -> [String] {
        var seen = Set<String>()
        var results: [String] = []
        results.reserveCapacity(candidates.count)

        for raw in candidates {
            if let resolved = resolvedMap[raw] {
                let std = StandardizedPath.absolute(resolved)
                if seen.insert(std).inserted {
                    results.append(std)
                }
                continue
            }

            let normalized = normalizeUserInput(raw)
            guard normalized.hasPrefix("/") else { continue }
            let std = StandardizedPath.absolute(normalized)
            if fileExists(std), seen.insert(std).inserted {
                results.append(std)
            }
        }

        return results
    }
}
