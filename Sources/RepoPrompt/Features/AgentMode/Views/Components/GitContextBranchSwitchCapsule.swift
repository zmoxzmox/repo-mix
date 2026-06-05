import SwiftUI

struct AgentWorkspaceBranchSwitchActions {
    let loadOptions: (AgentWorkspaceRootRow) async throws -> GitBranchSwitchOptions
    let preflight: (AgentWorkspaceRootRow, String) async throws -> GitBranchSwitchPreflight
    let switchBranch: (AgentWorkspaceRootRow, GitBranchSwitchPreflight) async throws -> GitBranchSwitchResult
    let isAgentRunActive: () -> Bool

    static let unavailable = AgentWorkspaceBranchSwitchActions(
        loadOptions: { _ in
            throw GitBranchSwitchError.unavailable("Branch switching is unavailable in this context.")
        },
        preflight: { _, _ in
            throw GitBranchSwitchError.unavailable("Branch switching is unavailable in this context.")
        },
        switchBranch: { _, _ in
            throw GitBranchSwitchError.unavailable("Branch switching is unavailable in this context.")
        },
        isAgentRunActive: { false }
    )
}

struct GitContextBranchSwitchCapsule: View {
    let row: AgentWorkspaceRootRow
    let context: GitWorktreeContextSummary
    let actions: AgentWorkspaceBranchSwitchActions

    @State private var showPopover = false
    @State private var options: GitBranchSwitchOptions?
    @State private var isLoading = false
    @State private var isSwitching = false
    @State private var optionErrorMessage: String?
    @State private var actionErrorMessage: String?
    @State private var pendingPreflight: GitBranchSwitchPreflight?
    @State private var showSwitchConfirmation = false
    @State private var branchSortOrder: VCSBranchSortOrder = .recent
    @State private var loadGeneration = 0
    @State private var uiTask: Task<Void, Never>?
    @State private var switchTask: Task<Void, Never>?
    @ObservedObject private var fontScale = FontScaleManager.shared
    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    private var capsuleLabelText: String {
        context.branchDisplayText ?? "unknown branch"
    }

    private var branchRowEstimatedHeight: CGFloat {
        fontPreset.scaledClamped(28, min: 24, max: 36)
    }

    private var branchListMaxHeight: CGFloat {
        fontPreset.scaledClamped(224, min: 168, max: 300)
    }

    private var capsuleLabelMaxWidth: CGFloat {
        fontPreset.scaledClamped(88, min: 56, max: 128)
    }

    private func branchListViewportHeight(for branches: [VCSBranch]) -> CGFloat {
        let visibleRowCount = min(CGFloat(branches.count), 8)
        let interRowSpacing = max(0, visibleRowCount - 1) * 2
        let estimatedHeight = visibleRowCount * branchRowEstimatedHeight + interRowSpacing
        return min(branchListMaxHeight, estimatedHeight)
    }

    var body: some View {
        Button {
            showPopover.toggle()
        } label: {
            HStack(spacing: fontPreset.scaledClamped(3, max: 4)) {
                Image(systemName: "point.topleft.down.curvedto.point.bottomright.up")
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 7, weight: .semibold))
                Text(capsuleLabelText)
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 8, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: capsuleLabelMaxWidth, alignment: .leading)
                Image(systemName: "chevron.down")
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 6, weight: .semibold))
            }
            .foregroundColor(.secondary)
            .padding(.horizontal, fontPreset.scaledClamped(4, max: 6))
            .padding(.vertical, fontPreset.scaledClamped(1, max: 2))
            .background(Capsule().fill(Color.secondary.opacity(0.10)))
            .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.35), lineWidth: 0.75))
        }
        .buttonStyle(.plain)
        .disabled(isSwitching)
        .hoverTooltip(context.tooltipText + "\nClick to switch local branches in this checkout.", .top)
        .accessibilityLabel(context.accessibilityText)
        .popover(isPresented: $showPopover, arrowEdge: .trailing) {
            popoverContent
                .task(id: "\(row.id.uuidString):\(showPopover)") {
                    guard showPopover else {
                        options = nil
                        optionErrorMessage = nil
                        actionErrorMessage = nil
                        isLoading = false
                        return
                    }
                    branchSortOrder = .recent
                    await reloadOptions()
                }
        }
        .alert("Switch Git branch?", isPresented: $showSwitchConfirmation) {
            Button("Cancel", role: .cancel) {
                pendingPreflight = nil
            }
            Button("Switch Branch") {
                guard let pendingPreflight else { return }
                self.pendingPreflight = nil
                startSwitchTask(pendingPreflight)
            }
        } message: {
            Text(confirmationMessage)
        }
        .onDisappear {
            uiTask?.cancel()
            uiTask = nil
            switchTask?.cancel()
            switchTask = nil
        }
    }

    private var popoverContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(row.name)
                .font(fontPreset.swiftUIFont(sizeAtNormal: 12, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            Text(context.tooltipText)
                .font(fontPreset.swiftUIFont(sizeAtNormal: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Switches this checkout in place. It does not create or select another worktree.")
                .font(fontPreset.swiftUIFont(sizeAtNormal: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            if isLoading {
                ProgressView().controlSize(.small)
            }

            if let actionErrorMessage {
                Text(actionErrorMessage)
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if isLoading {
                EmptyView()
            } else if let optionErrorMessage {
                VStack(alignment: .leading, spacing: 6) {
                    Text(optionErrorMessage)
                        .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Reload branches") {
                        startUITask { await reloadOptions() }
                    }
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                }
            } else if let options {
                branchList(options)
            } else {
                Text("Open the menu to load local branches.")
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(width: fontPreset.scaledClamped(300, min: 280, max: 380), alignment: .leading)
    }

    private func branchList(_ options: GitBranchSwitchOptions) -> some View {
        let branches = sortedBranches(options.branches)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("Local branches")
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Picker("Sort branches", selection: $branchSortOrder) {
                    ForEach(VCSBranchSortOrder.allCases) { order in
                        Text(order.displayName).tag(order)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .controlSize(.mini)
                .frame(width: fontPreset.scaledClamped(110, min: 104, max: 132))
            }
            if branches.isEmpty {
                Text("No local branches found.")
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                    .foregroundStyle(.secondary)
            } else {
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(branches) { branch in
                            BranchSwitchBranchRow(
                                branch: branch,
                                isSwitching: isSwitching,
                                fontPreset: fontPreset,
                                selectBranch: { selected in
                                    startUITask { await selectBranch(selected) }
                                }
                            )
                        }
                    }
                }
                .frame(height: branchListViewportHeight(for: branches))
                .scrollIndicators(.automatic)
            }
        }
    }

    private func sortedBranches(_ branches: [VCSBranch]) -> [VCSBranch] {
        branches.sortedForDisplay(by: branchSortOrder)
    }

    private struct BranchSwitchBranchRow: View {
        let branch: VCSBranch
        let isSwitching: Bool
        let fontPreset: FontScalePreset
        let selectBranch: (VCSBranch) -> Void

        @State private var isHovered = false

        var body: some View {
            Button {
                selectBranch(branch)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: branch.isCurrent ? "checkmark.circle.fill" : "circle")
                        .font(fontPreset.swiftUIFont(sizeAtNormal: 10))
                        .foregroundStyle(branch.isCurrent ? Color.accentColor : Color.secondary)
                        .frame(width: 14)
                    Text(branch.name)
                        .font(fontPreset.swiftUIFont(sizeAtNormal: 11, weight: branch.isCurrent ? .semibold : .regular))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                    if isSwitching {
                        ProgressView().controlSize(.small)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(backgroundColor)
                )
            }
            .buttonStyle(.plain)
            .disabled(isSwitching || branch.isCurrent)
            .onHover { hovered in
                isHovered = hovered
            }
            .help(branch.isCurrent ? "Already on \(branch.name)" : "Switch this checkout to \(branch.name)")
        }

        private var backgroundColor: Color {
            if branch.isCurrent {
                return Color.accentColor.opacity(isHovered ? 0.16 : 0.10)
            }
            return isHovered ? Color.secondary.opacity(0.12) : .clear
        }
    }

    private var confirmationMessage: String {
        guard let pendingPreflight else { return "" }
        return GitBranchSwitchConfirmationText.message(
            preflight: pendingPreflight,
            activeRun: actions.isAgentRunActive()
        )
    }

    private func reloadOptions() async {
        loadGeneration &+= 1
        let generation = loadGeneration
        isLoading = true
        optionErrorMessage = nil
        defer {
            if loadGeneration == generation {
                isLoading = false
            }
        }
        do {
            let loaded = try await actions.loadOptions(row)
            guard !Task.isCancelled else { return }
            guard showPopover else {
                options = nil
                optionErrorMessage = nil
                return
            }
            options = loaded
        } catch {
            guard !Task.isCancelled else { return }
            guard showPopover else {
                options = nil
                optionErrorMessage = nil
                return
            }
            options = nil
            optionErrorMessage = displayMessage(for: error)
        }
    }

    private func selectBranch(_ branch: VCSBranch) async {
        guard !branch.isCurrent else { return }
        isSwitching = true
        actionErrorMessage = nil
        defer {
            if !Task.isCancelled {
                isSwitching = false
            }
        }
        do {
            let preflight = try await actions.preflight(row, branch.name)
            guard !Task.isCancelled else { return }
            guard !preflight.isCurrentBranch else {
                actionErrorMessage = "Already on \(branch.name)."
                await reloadOptions()
                return
            }
            if actions.isAgentRunActive() || !preflight.warnings.isEmpty {
                pendingPreflight = preflight
                showSwitchConfirmation = true
            } else {
                startSwitchTask(preflight)
            }
        } catch {
            guard !Task.isCancelled else { return }
            await reloadOptions()
            actionErrorMessage = displayMessage(for: error)
        }
    }

    private func performSwitch(_ preflight: GitBranchSwitchPreflight) async {
        guard !Task.isCancelled else { return }
        isSwitching = true
        actionErrorMessage = nil
        defer {
            if !Task.isCancelled {
                isSwitching = false
            }
        }
        do {
            guard !Task.isCancelled else { return }
            _ = try await actions.switchBranch(row, preflight)
            guard !Task.isCancelled else { return }
            await reloadOptions()
            guard !Task.isCancelled else { return }
            showPopover = false
        } catch {
            guard !Task.isCancelled else { return }
            await reloadOptions()
            actionErrorMessage = displayMessage(for: error)
        }
    }

    private func startUITask(_ operation: @escaping () async -> Void) {
        uiTask?.cancel()
        uiTask = Task {
            await operation()
        }
    }

    private func startSwitchTask(_ preflight: GitBranchSwitchPreflight) {
        guard switchTask == nil else { return }
        uiTask?.cancel()
        uiTask = nil
        switchTask = Task {
            await performSwitch(preflight)
            switchTask = nil
        }
    }

    private func displayMessage(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

private enum GitBranchSwitchConfirmationText {
    static func message(preflight: GitBranchSwitchPreflight, activeRun: Bool) -> String {
        var parts: [String] = []
        if activeRun {
            parts.append("An Agent run is active. Files may change underneath the running agent. The run will continue, and the in-flight request will not be replayed or rewritten.")
        }
        if preflight.warnings.contains(.uncommittedChanges) {
            parts.append("This checkout has uncommitted changes. Git may refuse the switch if those files would be overwritten.")
        }
        if preflight.warnings.contains(.detachedHead) {
            parts.append("This checkout is currently detached. Switching will move it onto the selected local branch.")
        }
        if preflight.warnings.contains(.mergeInProgress) {
            parts.append("A merge appears to be in progress. Git may refuse the switch until it is resolved or aborted.")
        }
        parts.append("Target branch: \(preflight.targetBranch)")
        return parts.joined(separator: "\n\n")
    }
}
