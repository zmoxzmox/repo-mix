import SwiftUI

// MARK: - Shared Pill Metrics

///
/// All composer pills (Workflow, Interview, Auto Edit, Oracle, Context, the
/// auto-edit guidance bubble) need to scale together so the row reads as a
/// coherent unit at every font preset. Centralising the metrics here means
/// individual pills only declare colors / labels — the geometry stays in sync.
private enum AgentPillMetrics {
    /// Default pill height at the Normal preset (matches the macOS toolbar feel
    /// when scaled). Other heights derive from this baseline.
    static let baseHeight: CGFloat = 28

    static func height(for preset: FontScalePreset) -> CGFloat {
        ButtonScale.metric(baseHeight)
        // `ButtonScale.metric` reads the cached preset; the explicit argument
        // keeps the signature self-documenting without re-reading the cache
        // twice.
    }

    static func horizontalPadding(for preset: FontScalePreset) -> CGFloat {
        ButtonScale.metric(10)
    }

    static func cornerRadius(for preset: FontScalePreset) -> CGFloat {
        ButtonScale.pillCornerRadius(16)
    }

    static func iconSize(for preset: FontScalePreset, base: CGFloat = 12) -> CGFloat {
        preset.scaledMetric(base)
    }
}

struct AgentStatusPillsRow: View {
    let agentModeVM: AgentModeViewModel
    @ObservedObject var statusPillsUI: AgentStatusPillsUIStore
    @ObservedObject var oracleViewModel: OracleViewModel
    @ObservedObject var promptManager: PromptViewModel
    let selectionCoordinator: WorkspaceSelectionCoordinator
    @ObservedObject var runtimeVM: AgentRuntimeSidebarViewModel
    let windowID: Int

    private var snapshot: AgentStatusPillsSnapshot {
        statusPillsUI.snapshot
    }

    var body: some View {
        #if DEBUG
            let _ = AgentModePerfDiagnostics.increment("ui.body.statusPillsRow")
        #endif
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                AgentWorkflowPill(
                    statusPillsUI: statusPillsUI,
                    windowID: windowID,
                    selectWorkflow: { agentModeVM.selectWorkflow($0) }
                )

                if let stagedSlashCommand = snapshot.stagedSlashCommand {
                    AgentStagedSlashCommandPill(staged: stagedSlashCommand)
                }

                if let executionLocation = snapshot.executionLocation {
                    AgentExecutionLocationPill(
                        props: executionLocation,
                        loadExistingWorktrees: { try await agentModeVM.availableExecutionWorktrees(for: executionLocation.tabID) },
                        selectLocation: { choice, confirmation in
                            await agentModeVM.selectExecutionLocation(
                                choice,
                                for: executionLocation.tabID,
                                confirmedChange: confirmation
                            )
                        }
                    )
                }
            }

            Spacer(minLength: 0)

            if let guidance = snapshot.autoEditPermissionGuidance {
                AgentAutoEditGuidanceBubble(
                    agentModeVM: agentModeVM,
                    runState: snapshot.runState,
                    guidance: guidance
                )
                .frame(maxWidth: 720)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            Spacer(minLength: 0)

            HStack(spacing: 6) {
                AgentOraclePill(
                    oracleViewModel: oracleViewModel,
                    windowID: windowID,
                    currentTabID: snapshot.currentTabID,
                    activeAgentSessionID: snapshot.activeAgentSessionID,
                    activeRunID: snapshot.activeRunID
                )

                AgentContextPill(
                    promptManager: promptManager,
                    selectionCoordinator: selectionCoordinator,
                    runtimeVM: runtimeVM,
                    currentTabID: snapshot.currentTabID,
                    activeAgentSessionID: snapshot.activeAgentSessionID,
                    worktreeBindingsProvider: { sessionID, tabID in
                        agentModeVM.worktreeBindings(forAgentSessionID: sessionID, tabID: tabID)
                    }
                )
            }
        }
        .animation(.easeInOut(duration: 0.18), value: snapshot.selectedWorkflow?.id)
    }
}

private struct AgentStagedSlashCommandPill: View {
    let staged: AgentStagedSlashCommandProps

    @ObservedObject private var fontScale = FontScaleManager.shared
    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    private var accentColor: Color {
        staged.action == .setObjective ? .green : .secondary
    }

    private var labelText: String {
        staged.appliesSelectedWorkflowContext ? "\(staged.displayText) + Workflow" : staged.displayText
    }

    private var tooltipText: String {
        switch staged.action {
        case .setObjective where staged.appliesSelectedWorkflowContext:
            let workflowName = staged.selectedWorkflowName ?? "selected"
            return "Next send will set a Codex goal and include \(workflowName) workflow context."
        case .setObjective:
            return "Next send will set a Codex goal."
        case .show:
            return "Next send will run /goal as a Codex control command. Selected workflows are not applied to goal control actions."
        case .pause:
            return "Next send will run /goal pause as a Codex control command. Selected workflows are not applied to goal control actions."
        case .resume:
            return "Next send will run /goal resume as a Codex control command. Selected workflows are not applied to goal control actions."
        case .clear:
            return "Next send will run /goal clear as a Codex control command. Selected workflows are not applied to goal control actions."
        }
    }

    var body: some View {
        let cornerRadius = AgentPillMetrics.cornerRadius(for: fontPreset)
        HStack(spacing: 5) {
            Image(systemName: "target")
                .font(fontPreset.swiftUIFont(sizeAtNormal: 11, weight: .semibold))
            Text(labelText)
                .font(fontPreset.swiftUIFont(sizeAtNormal: 12, weight: .medium))
        }
        .foregroundStyle(accentColor)
        .padding(.horizontal, AgentPillMetrics.horizontalPadding(for: fontPreset))
        .frame(height: AgentPillMetrics.height(for: fontPreset))
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(accentColor.opacity(staged.action == .setObjective ? 0.35 : 0.18), lineWidth: staged.action == .setObjective ? 0.8 : 0.5)
        )
        .hoverTooltip(tooltipText, .top)
    }
}

private struct AgentAutoEditGuidanceBubble: View {
    let agentModeVM: AgentModeViewModel
    let runState: AgentSessionRunState
    let guidance: AgentModeViewModel.AutoEditPermissionGuidance

    @ObservedObject private var fontScale = FontScaleManager.shared
    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    private var accentColor: Color {
        switch guidance.provider {
        case .codex:
            .green
        case .claude:
            .orange
        }
    }

    private var messageText: String {
        if runState.isActive {
            return guidance.message + " Applies next turn."
        }
        return guidance.message
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(messageText)
                .font(fontPreset.swiftUIFont(sizeAtNormal: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)

            Button(guidance.actionTitle) {
                agentModeVM.applyAutoEditPermissionGuidanceAction()
            }
            .buttonStyle(.plain)
            .font(fontPreset.swiftUIFont(sizeAtNormal: 12, weight: .medium))
            .foregroundStyle(accentColor)
        }
        .padding(.horizontal, AgentPillMetrics.horizontalPadding(for: fontPreset))
        .frame(height: AgentPillMetrics.height(for: fontPreset))
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: AgentPillMetrics.cornerRadius(for: fontPreset), style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AgentPillMetrics.cornerRadius(for: fontPreset), style: .continuous)
                .stroke(accentColor.opacity(0.18), lineWidth: 0.8)
        )
    }
}

// MARK: - Auto Edit Pill

struct AgentAutoEditPill: View {
    let isOn: Bool
    let onToggle: () -> Void

    @ObservedObject private var fontScale = FontScaleManager.shared
    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    private var tooltipText: String {
        if isOn {
            return "Auto Edit is on: apply_edits writes files immediately after the agent proposes them."
        }
        return "Auto Edit is off: apply_edits requires approval. If sandbox permissions still allow file edits, those changes bypass RepoPrompt review."
    }

    var body: some View {
        let cornerRadius = AgentPillMetrics.cornerRadius(for: fontPreset)
        let dotSize = fontPreset.scaledMetric(CGFloat(7))
        Button(action: onToggle) {
            HStack(spacing: 6) {
                Circle()
                    .fill(isOn ? Color.green : Color.secondary.opacity(0.35))
                    .frame(width: dotSize, height: dotSize)
                Text("Auto Edit")
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 12, weight: .medium))
                    .foregroundStyle(isOn ? Color.green : .secondary)
            }
            .padding(.horizontal, AgentPillMetrics.horizontalPadding(for: fontPreset))
            .frame(height: AgentPillMetrics.height(for: fontPreset))
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(isOn ? Color.green.opacity(0.35) : Color.secondary.opacity(0.15), lineWidth: isOn ? 0.8 : 0.5)
            )
        }
        .buttonStyle(.plain)
        .hoverTooltip(tooltipText, .top)
    }
}

// MARK: - Interview Pill

struct AgentInterviewPill: View {
    let isOn: Bool
    let onToggle: () -> Void

    @ObservedObject private var fontScale = FontScaleManager.shared
    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    var body: some View {
        let cornerRadius = AgentPillMetrics.cornerRadius(for: fontPreset)
        Button(action: onToggle) {
            HStack(spacing: 5) {
                Image(systemName: "questionmark.bubble")
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                    .foregroundStyle(isOn ? Color.accentColor : .secondary)
                Text("Interview")
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 12, weight: .medium))
                    .foregroundStyle(isOn ? Color.accentColor : .secondary)
            }
            .padding(.horizontal, AgentPillMetrics.horizontalPadding(for: fontPreset))
            .frame(height: AgentPillMetrics.height(for: fontPreset))
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(isOn ? Color.accentColor.opacity(0.4) : Color.secondary.opacity(0.15), lineWidth: isOn ? 0.8 : 0.5)
            )
        }
        .buttonStyle(.plain)
        .hoverTooltip(isOn ? "Interview is on: the agent will ask clarifying questions before starting" : "Interview is off: the agent will start working immediately", .top)
    }
}

// MARK: - Execution Location Pill

private struct AgentExecutionLocationPill: View {
    let props: AgentExecutionLocationProps
    let loadExistingWorktrees: () async throws -> [AgentModeViewModel.AgentExecutionWorktreeSelection]
    let selectLocation: (AgentModeViewModel.InitialStartLocation, AgentModeViewModel.ExecutionLocationChangeConfirmation?) async -> AgentModeViewModel.ExecutionLocationChangeResult

    @State private var showPopover = false
    @State private var existingWorktrees: [AgentModeViewModel.AgentExecutionWorktreeSelection] = []
    @State private var isLoadingExistingWorktrees = false
    @State private var optionError: String?
    @State private var pendingConfirmedChoice: AgentModeViewModel.InitialStartLocation?
    @State private var pendingConfirmation: AgentModeViewModel.ExecutionLocationChangeConfirmation?
    @State private var showLocationChangeConfirmation = false
    @ObservedObject private var fontScale = FontScaleManager.shared
    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    private var popoverWidth: CGFloat {
        fontPreset.scaledClamped(300, max: 360)
    }

    private var pillLabelMaxWidth: CGFloat {
        fontPreset.scaledClamped(170, max: 220)
    }

    private var existingWorktreeRowEstimatedHeight: CGFloat {
        fontPreset.scaledClamped(48, min: 42, max: 62)
    }

    private var existingWorktreeRowsMaxHeight: CGFloat {
        fontPreset.scaledClamped(288, min: 220, max: 360)
    }

    private var optionRowWidth: CGFloat {
        popoverWidth - 16
    }

    private var optionRowContentWidth: CGFloat {
        optionRowWidth - 16
    }

    private func existingWorktreeRowsViewportHeight(rowCount: Int) -> CGFloat {
        let visibleRowCount = min(CGFloat(rowCount), 6)
        let interRowSpacing = max(0, visibleRowCount - 1) * 2
        let estimatedHeight = visibleRowCount * existingWorktreeRowEstimatedHeight + interRowSpacing
        return min(existingWorktreeRowsMaxHeight, estimatedHeight)
    }

    private var accentColor: Color {
        if let indicator = props.indicator {
            return indicator.isAvailable ? indicator.color : .orange
        }
        switch props.selection {
        case .local:
            return .secondary
        case .newWorktree:
            return .accentColor
        case let .existingWorktree(selection):
            return selection.colorHex.flatMap(Color.init(hex:)) ?? .accentColor
        }
    }

    private var iconName: String {
        switch props.selection {
        case .local:
            "laptopcomputer"
        case .newWorktree, .existingWorktree:
            "arrow.triangle.branch"
        }
    }

    private var label: String {
        props.indicator?.capsuleText ?? props.selection.label
    }

    private var usesNeutralChrome: Bool {
        guard props.indicator == nil,
              props.isEnabled,
              !props.isOperationInProgress
        else { return false }
        if case .local = props.selection {
            return true
        }
        return false
    }

    var body: some View {
        let cornerRadius = AgentPillMetrics.cornerRadius(for: fontPreset)
        Button {
            showPopover.toggle()
        } label: {
            HStack(spacing: 5) {
                if props.isOperationInProgress {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: iconName)
                        .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                }
                Text(label)
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: pillLabelMaxWidth, alignment: .leading)
                Image(systemName: "chevron.down")
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 9, weight: .semibold))
            }
            .foregroundStyle(accentColor)
            .padding(.horizontal, AgentPillMetrics.horizontalPadding(for: fontPreset))
            .frame(height: AgentPillMetrics.height(for: fontPreset))
            // Stay content-sized for ordinary labels while the text frame still caps and truncates long worktree names.
            .fixedSize(horizontal: true, vertical: false)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(
                        usesNeutralChrome
                            ? Color.secondary.opacity(0.15)
                            : accentColor.opacity(0.35),
                        lineWidth: usesNeutralChrome ? 0.5 : 0.8
                    )
            )
        }
        .buttonStyle(.plain)
        .disabled(!props.isEnabled)
        .hoverTooltip(props.indicator?.tooltipText ?? (props.disabledReason ?? "Choose this thread's execution location"), .top)
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                Text(props.isInitialSelection ? "Start in" : "Execution location")
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.top, 4)

                locationOption(.local, icon: "laptopcomputer")
                locationOption(.newWorktree, icon: "arrow.triangle.branch")

                Divider().padding(.vertical, 2)
                Text("Existing worktrees")
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)

                if isLoadingExistingWorktrees {
                    ProgressView().controlSize(.small).padding(.horizontal, 8).padding(.vertical, 6)
                } else if let optionError {
                    Text(optionError)
                        .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 8)
                } else if existingWorktrees.isEmpty {
                    Text("No other worktrees available")
                        .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                } else {
                    ScrollView(.vertical) {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(existingWorktrees) { selection in
                                existingWorktreeOption(ExistingWorktreePickerRow(selection: selection))
                            }
                        }
                        .frame(width: optionRowWidth, alignment: .leading)
                    }
                    .frame(width: optionRowWidth, height: existingWorktreeRowsViewportHeight(rowCount: existingWorktrees.count))
                    .scrollIndicators(.automatic)
                }

                if props.isInitialSelection {
                    Text("Worktrees are applied when you first send.")
                        .font(fontPreset.swiftUIFont(sizeAtNormal: 10))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 8)
                        .padding(.top, 3)
                }
            }
            .padding(8)
            .frame(width: popoverWidth, alignment: .leading)
            .task(id: "\(props.tabID.uuidString):\(showPopover)") {
                let loadingTabID = props.tabID
                guard showPopover else {
                    existingWorktrees = []
                    optionError = nil
                    isLoadingExistingWorktrees = false
                    return
                }
                existingWorktrees = []
                isLoadingExistingWorktrees = true
                optionError = nil
                do {
                    let loaded = try await loadExistingWorktrees()
                    guard !Task.isCancelled, showPopover, props.tabID == loadingTabID else { return }
                    existingWorktrees = loaded
                } catch {
                    guard !Task.isCancelled, showPopover, props.tabID == loadingTabID else { return }
                    existingWorktrees = []
                    optionError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
                isLoadingExistingWorktrees = false
            }
        }
        .alert("Change execution location?", isPresented: $showLocationChangeConfirmation) {
            Button("Cancel", role: .cancel) {
                pendingConfirmedChoice = nil
                pendingConfirmation = nil
            }
            Button(confirmationButtonTitle, role: .destructive) {
                guard let choice = pendingConfirmedChoice,
                      let confirmation = pendingConfirmation
                else { return }
                pendingConfirmedChoice = nil
                pendingConfirmation = nil
                applySelection(choice, confirmedBy: confirmation)
            }
        } message: {
            Text(confirmationMessage)
        }
    }

    private struct ExistingWorktreePickerRow: Identifiable {
        let selection: AgentModeViewModel.AgentExecutionWorktreeSelection
        let title: String
        let subtitle: String
        let tooltip: String
        let iconName: String
        let isDisabled: Bool

        var id: String {
            selection.presentationID
        }

        init(selection: AgentModeViewModel.AgentExecutionWorktreeSelection) {
            self.selection = selection
            let worktreeName = Self.worktreeName(for: selection)
            let branchOrHead = Self.branchOrHeadLabel(for: selection)
            title = "\(branchOrHead) — \(worktreeName)"

            var subtitleParts = [Self.compactPath(selection.path)]
            if selection.isLocked {
                subtitleParts.append("locked")
            }
            if selection.isPrunable {
                subtitleParts.append("prunable")
            }
            subtitle = subtitleParts.joined(separator: " · ")

            var tooltipParts = [
                "Branch: \(branchOrHead)",
                "Worktree: \(worktreeName)",
                "Path: \(selection.path)"
            ]
            if selection.isLocked {
                tooltipParts.append("Locked: \(selection.lockReason ?? "no reason provided")")
            }
            if selection.isPrunable {
                tooltipParts.append("Prunable: \(selection.prunableReason ?? "Git reports this worktree as prunable")")
            }
            tooltip = tooltipParts.joined(separator: "\n")
            iconName = selection.isPrunable ? "exclamationmark.triangle" : "arrow.triangle.branch"
            isDisabled = selection.isPrunable
        }

        private static func branchOrHeadLabel(for selection: AgentModeViewModel.AgentExecutionWorktreeSelection) -> String {
            if let branch = selection.branch, !branch.isEmpty {
                return branch
            }
            if let head = selection.head, !head.isEmpty {
                return "Detached \(GitShortRef.shortHead(head))"
            }
            return selection.isDetached ? "Detached HEAD" : selection.label
        }

        private static func worktreeName(for selection: AgentModeViewModel.AgentExecutionWorktreeSelection) -> String {
            if let name = selection.name, !name.isEmpty {
                return name
            }
            let pathTail = URL(fileURLWithPath: selection.path).lastPathComponent
            return pathTail.isEmpty ? selection.label : pathTail
        }

        private static func compactPath(_ path: String) -> String {
            let url = URL(fileURLWithPath: path)
            let folder = url.lastPathComponent
            let parent = url.deletingLastPathComponent().lastPathComponent
            guard !folder.isEmpty else { return path }
            guard !parent.isEmpty else { return "…/\(folder)" }
            return "…/\(parent)/\(folder)"
        }
    }

    private func locationOption(_ selection: AgentModeViewModel.InitialStartLocation, icon: String) -> some View {
        let title: String?
        let subtitle: String?
        if case .local = selection {
            title = "Workspace checkout"
            subtitle = "Work locally in the open workspace"
        } else {
            title = nil
            subtitle = nil
        }
        return optionButton(selection: selection, icon: icon, title: title, subtitle: subtitle, isDisabled: false)
    }

    private func existingWorktreeOption(_ row: ExistingWorktreePickerRow) -> some View {
        optionButton(
            selection: .existingWorktree(row.selection),
            icon: row.iconName,
            title: row.title,
            subtitle: row.subtitle,
            tooltip: row.tooltip,
            isDisabled: row.isDisabled
        )
    }

    private func optionButton(
        selection: AgentModeViewModel.InitialStartLocation,
        icon: String,
        title: String? = nil,
        subtitle: String?,
        tooltip: String? = nil,
        isDisabled: Bool
    ) -> some View {
        ExecutionLocationOptionButton(
            selection: selection,
            icon: icon,
            title: title ?? selection.label,
            subtitle: subtitle,
            tooltip: tooltip,
            isSelected: isSelected(selection),
            isDisabled: isDisabled,
            fontPreset: fontPreset,
            rowWidth: optionRowContentWidth,
            applySelection: { selection in
                applySelection(selection)
            }
        )
    }

    private struct ExecutionLocationOptionButton: View {
        let selection: AgentModeViewModel.InitialStartLocation
        let icon: String
        let title: String
        let subtitle: String?
        let tooltip: String?
        let isSelected: Bool
        let isDisabled: Bool
        let fontPreset: FontScalePreset
        let rowWidth: CGFloat
        let applySelection: (AgentModeViewModel.InitialStartLocation) -> Void

        var body: some View {
            Button {
                guard !isDisabled else { return }
                applySelection(selection)
            } label: {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "checkmark")
                        .font(fontPreset.swiftUIFont(sizeAtNormal: 10, weight: .semibold))
                        .opacity(isSelected ? 1 : 0)
                        .frame(width: 12)
                    Image(systemName: icon)
                        .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                        .frame(width: 14)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(fontPreset.swiftUIFont(sizeAtNormal: 12, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .layoutPriority(1)
                        if let subtitle {
                            Text(subtitle)
                                .font(fontPreset.swiftUIFont(sizeAtNormal: 10))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(
                ExecutionLocationOptionRowButtonStyle(
                    isSelected: isSelected,
                    isDisabled: isDisabled,
                    rowWidth: rowWidth
                )
            )
            .hoverTooltip(tooltip, .top)
            .accessibilityHint(isDisabled ? "Unavailable" : (tooltip ?? title))
        }
    }

    private struct ExecutionLocationOptionRowButtonStyle: ButtonStyle {
        let isSelected: Bool
        let isDisabled: Bool
        let rowWidth: CGFloat

        func makeBody(configuration: Configuration) -> some View {
            HoverableButton(configuration: configuration) { isHovered in
                configuration.label
                    .frame(width: rowWidth, alignment: .leading)
                    .foregroundStyle(isDisabled ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(backgroundColor(isHovered: isHovered, isPressed: configuration.isPressed))
                    )
            }
        }

        private func backgroundColor(isHovered: Bool, isPressed: Bool) -> Color {
            if isSelected {
                return Color.accentColor.opacity(isPressed ? 0.28 : (isHovered ? 0.24 : 0.12))
            }
            return isPressed ? Color.accentColor.opacity(0.18) : (isHovered ? Color.accentColor.opacity(0.14) : .clear)
        }
    }

    private func isSelected(_ selection: AgentModeViewModel.InitialStartLocation) -> Bool {
        switch (props.selection, selection) {
        case (.local, .local), (.newWorktree, .newWorktree):
            true
        case let (.existingWorktree(current), .existingWorktree(candidate)):
            current.worktreeID == candidate.worktreeID && current.repositoryID == candidate.repositoryID
        default:
            false
        }
    }

    private var confirmationButtonTitle: String {
        pendingConfirmation == .activeRunStop ? "Stop Run and Change" : "Restart and Change"
    }

    private var confirmationMessage: String {
        switch pendingConfirmation {
        case .activeRunStop:
            "Changing execution location stops the current run and restarts the agent/provider context for this thread. The in-flight request will not be replayed automatically."
        case .startedThreadRestart, nil:
            "Changing execution location restarts the agent/provider context for this thread. This may confuse the model or reduce conversational continuity."
        }
    }

    private func applySelection(
        _ selection: AgentModeViewModel.InitialStartLocation,
        confirmedBy confirmation: AgentModeViewModel.ExecutionLocationChangeConfirmation? = nil
    ) {
        Task {
            switch await selectLocation(selection, confirmation) {
            case .applied, .unchanged:
                showPopover = false
                optionError = nil
            case let .confirmationRequired(requiredConfirmation):
                pendingConfirmedChoice = selection
                pendingConfirmation = requiredConfirmation
                showLocationChangeConfirmation = true
            case let .blocked(message):
                optionError = message
            }
        }
    }
}

// MARK: - Workflow Pill

/// Pill for selecting a workflow template that wraps user input before sending.
/// Collapsed: shows current selection or generic "Workflow" label.
/// Clicking opens a popover with workflow options (two-pane when custom workflows exist).
struct AgentWorkflowPill: View {
    @ObservedObject var statusPillsUI: AgentStatusPillsUIStore
    @ObservedObject var workflowStore: AgentWorkflowStore = .shared
    let windowID: Int
    let selectWorkflow: (AgentWorkflowDefinition?) -> Void
    @State private var showPopover = false
    @State private var showConfigureSheet = false

    @ObservedObject private var fontScale = FontScaleManager.shared
    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    private var selection: AgentWorkflowDefinition? {
        statusPillsUI.snapshot.selectedWorkflow
    }

    var body: some View {
        #if DEBUG
            let _ = AgentModePerfDiagnostics.increment("ui.body.statusPills.workflow")
        #endif
        let cornerRadius = AgentPillMetrics.cornerRadius(for: fontPreset)
        let height = AgentPillMetrics.height(for: fontPreset)
        let horizontalPadding = AgentPillMetrics.horizontalPadding(for: fontPreset)
        // Trailing padding shrinks when the close (×) button is shown so the
        // pill keeps its overall length proportional at every font scale.
        let trailingPaddingForCloseButton = ButtonScale.metric(4)
        let closeButtonSize = ButtonScale.metric(16)
        let closeButtonTrailing = ButtonScale.metric(6)
        HStack(spacing: 0) {
            Button {
                showPopover.toggle()
            } label: {
                HStack(spacing: 4) {
                    if let selected = selection {
                        Image(systemName: selected.iconName)
                            .font(fontPreset.swiftUIFont(sizeAtNormal: 12))
                        Text(selected.displayName)
                            .font(fontPreset.swiftUIFont(sizeAtNormal: 12, weight: .medium))
                    } else {
                        Image(systemName: "bolt.fill")
                            .font(fontPreset.swiftUIFont(sizeAtNormal: 12))
                        Text("Workflow")
                            .font(fontPreset.swiftUIFont(sizeAtNormal: 12, weight: .medium))
                    }
                    Image(systemName: "chevron.down")
                        .font(fontPreset.swiftUIFont(sizeAtNormal: 9, weight: .semibold))
                }
                .foregroundStyle(selection != nil ? AnyShapeStyle(selection!.accentColor) : AnyShapeStyle(.secondary))
                .padding(.leading, horizontalPadding)
                .padding(.trailing, selection != nil ? trailingPaddingForCloseButton : horizontalPadding)
                .frame(height: height)
            }
            .buttonStyle(.plain)

            if selection != nil {
                Button {
                    selectWorkflow(nil)
                } label: {
                    Image(systemName: "xmark")
                        .font(fontPreset.swiftUIFont(sizeAtNormal: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: closeButtonSize, height: closeButtonSize)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.trailing, closeButtonTrailing)
                .hoverTooltip("Clear workflow", .top)
            }
        }
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(
                    selection != nil
                        ? selection!.accentColor.opacity(0.4)
                        : Color.secondary.opacity(0.15),
                    lineWidth: selection != nil ? 1 : 0.5
                )
        )
        .hoverTooltip("Wrap your message with a workflow template", .top)
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            AgentWorkflowsPopoverView(
                statusPillsUI: statusPillsUI,
                workflowStore: workflowStore,
                isPresented: $showPopover,
                showConfigureSheet: $showConfigureSheet,
                selectWorkflow: selectWorkflow
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: .showAgentWorkflowPopover)) { note in
            guard let targetWindowID = note.userInfo?["windowID"] as? Int,
                  targetWindowID == windowID else { return }
            showPopover = true
        }
        .sheet(isPresented: $showConfigureSheet) {
            AgentWorkflowsConfigureSheet(workflowStore: workflowStore)
        }
    }
}

// MARK: - Context Pill

/// Always-visible pill showing context usage wheel + file/token info.
/// Expands upward into a popover with export controls.
struct AgentContextPill: View {
    @ObservedObject var promptManager: PromptViewModel
    let selectionCoordinator: WorkspaceSelectionCoordinator
    @ObservedObject var runtimeVM: AgentRuntimeSidebarViewModel
    let currentTabID: UUID?
    let activeAgentSessionID: UUID?
    let worktreeBindingsProvider: @MainActor (UUID, UUID?) -> [AgentSessionWorktreeBinding]

    @State private var showPopover = false
    @ObservedObject private var fontScale = FontScaleManager.shared
    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    private var estimatedUsedTokens: Int? {
        runtimeVM.snapshot.usedTokens ?? runtimeVM.snapshot.estimatedTranscriptTokens
    }

    private var contextWindowTokens: Int {
        runtimeVM.snapshot.effectiveContextWindowTokens
    }

    private var fileCount: Int {
        AgentContextExportResolver.displayFileCount(
            resolvedModel: nil,
            sourceSelection: currentExportSourceSelection
        )
    }

    private var currentExportSourceSelection: StoredSelection {
        let requestedTabID = currentTabID ?? promptManager.activeComposeTabID
        let activeTabID = selectionCoordinator.activeTabID() ?? promptManager.activeComposeTabID
        let activeSelectionSnapshot = requestedTabID == activeTabID
            ? selectionCoordinator.activeSelectionSnapshot(flushPendingUI: false)
            : nil
        return AgentContextExportSourceBuilder.makeSource(
            AgentContextExportSourceBuildRequest(
                requestedTabID: requestedTabID,
                activeComposeTabID: promptManager.activeComposeTabID,
                activePromptText: promptManager.promptText,
                activeSelectionSnapshot: activeSelectionSnapshot,
                composeTabs: promptManager.currentComposeTabs,
                explicitActiveAgentSessionID: activeAgentSessionID,
                worktreeBindingsProvider: worktreeBindingsProvider
            )
        ).selection
    }

    private var selectionTokens: Int? {
        runtimeVM.snapshot.selectionTokens
    }

    private var fileSummaryText: String {
        "\(fileCount) file\(fileCount == 1 ? "" : "s")"
    }

    private var contextUsageTooltip: String {
        var lines: [String] = []

        if let usedTokens = estimatedUsedTokens,
           contextWindowTokens > 0
        {
            let usedPercent = min(max((Double(usedTokens) / Double(contextWindowTokens)) * 100, 0), 100)
            lines.append("Context used: \(Int(usedPercent.rounded()))%")
            lines.append("\(AgentContextIndicator.formatTokens(usedTokens)) / \(AgentContextIndicator.formatTokens(contextWindowTokens)) tokens")
        } else if let usedTokens = estimatedUsedTokens {
            lines.append("Used tokens: \(AgentContextIndicator.formatTokens(usedTokens))")
        } else {
            lines.append("Context usage unavailable")
        }

        lines.append("Selected: \(fileSummaryText)")
        if let selectionTokens {
            lines.append("Selection: \(AgentContextIndicator.formatTokens(selectionTokens)) tokens")
        }

        return lines.joined(separator: "\n")
    }

    var body: some View {
        #if DEBUG
            let _ = AgentModePerfDiagnostics.increment("ui.body.statusPills.context")
        #endif
        let cornerRadius = AgentPillMetrics.cornerRadius(for: fontPreset)
        Button {
            showPopover.toggle()
        } label: {
            HStack(spacing: 6) {
                Text(fileSummaryText)
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                AgentContextIndicator(
                    contextWindowTokens: contextWindowTokens,
                    usedTokens: estimatedUsedTokens,
                    style: .compact
                )
            }
            .padding(.horizontal, AgentPillMetrics.horizontalPadding(for: fontPreset))
            .frame(height: AgentPillMetrics.height(for: fontPreset))
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.secondary.opacity(0.15), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .hoverTooltip(contextUsageTooltip, .top)
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            contextPopoverContent
        }
    }

    @ViewBuilder
    private var contextPopoverContent: some View {
        // Width grows with the font scale so the export card never feels
        // pinched at Large/Extra Large.
        let popoverWidth = fontPreset.scaledClamped(360, max: 480)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                AgentContextIndicator(
                    contextWindowTokens: contextWindowTokens,
                    usedTokens: estimatedUsedTokens,
                    sourceLabel: runtimeVM.snapshot.usedTokens != nil
                        ? runtimeVM.snapshot.usageSource.label
                        : "Estimated",
                    style: .labeled
                )
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Selected")
                        .font(fontPreset.swiftUIFont(sizeAtNormal: 10))
                        .foregroundStyle(.tertiary)
                    Text("\(fileCount) files")
                        .font(fontPreset.swiftUIFont(sizeAtNormal: 12, weight: .semibold))
                }
            }

            Divider()

            AgentExportCard(
                promptManager: promptManager,
                tokenCounter: promptManager.tokenCountingViewModel,
                selectionCoordinator: selectionCoordinator,
                fileCount: fileCount,
                selectionTokens: selectionTokens,
                currentTabID: currentTabID,
                activeAgentSessionID: activeAgentSessionID,
                worktreeBindingsProvider: worktreeBindingsProvider
            )
        }
        .padding(12)
        .frame(width: popoverWidth)
    }
}

// MARK: - Oracle Pill

enum AgentOraclePillLogic {
    static func hasRenderableMessages(session: ChatSession, liveMessageCount: Int?) -> Bool {
        if let liveMessageCount {
            return liveMessageCount > 0
        }
        return session.hasMessages
    }

    static func eligibleSessions(
        sessions: [ChatSession],
        streamingSessionIDs: Set<UUID>,
        liveMessageCount: (UUID) -> Int?,
        activeAgentSessionID: UUID? = nil,
        activeRunID: UUID? = nil
    ) -> [ChatSession] {
        let renderable = sessions.filter { session in
            hasRenderableMessages(session: session, liveMessageCount: liveMessageCount(session.id))
                || streamingSessionIDs.contains(session.id)
        }
        guard activeAgentSessionID != nil || activeRunID != nil else { return renderable }

        func isUnownedLegacy(_ session: ChatSession) -> Bool {
            session.agentModeSessionID == nil && session.agentModeRunID == nil
        }
        func matchesAgent(_ session: ChatSession) -> Bool {
            guard let activeAgentSessionID else { return true }
            return session.agentModeSessionID == activeAgentSessionID
        }

        if let activeRunID {
            let exactRunMatches = renderable.filter { matchesAgent($0) && $0.agentModeRunID == activeRunID }
            if !exactRunMatches.isEmpty { return exactRunMatches }

            let sameAgentLegacyRunMatches = renderable.filter { matchesAgent($0) && $0.agentModeSessionID != nil && $0.agentModeRunID == nil }
            if !sameAgentLegacyRunMatches.isEmpty { return sameAgentLegacyRunMatches }

            if let activeAgentSessionID,
               renderable.contains(where: { $0.agentModeSessionID == activeAgentSessionID })
            {
                return []
            }
            return renderable.filter(isUnownedLegacy)
        }

        if let activeAgentSessionID {
            let sameAgentMatches = renderable.filter { $0.agentModeSessionID == activeAgentSessionID }
            if !sameAgentMatches.isEmpty { return sameAgentMatches }
        }

        return renderable.filter(isUnownedLegacy)
    }

    static func latestSession(
        in sessions: [ChatSession],
        streamingSessionIDs: Set<UUID>
    ) -> ChatSession? {
        let streaming = sessions.filter { streamingSessionIDs.contains($0.id) }
        if let latestStreaming = streaming.max(by: { $0.savedAt < $1.savedAt }) {
            return latestStreaming
        }
        return sessions.max(by: { $0.savedAt < $1.savedAt })
    }

    static func selectedSessionID(
        currentSelectionID: UUID?,
        in sessions: [ChatSession],
        streamingSessionIDs: Set<UUID>
    ) -> UUID? {
        if let currentSelectionID,
           sessions.contains(where: { $0.id == currentSelectionID })
        {
            return currentSelectionID
        }
        return latestSession(in: sessions, streamingSessionIDs: streamingSessionIDs)?.id
    }

    static func reconciledPresentedSessionID(
        currentSessionID: UUID?,
        isExplicit: Bool,
        sameTabSessions: [ChatSession],
        eligibleSessions: [ChatSession],
        streamingSessionIDs: Set<UUID>
    ) -> UUID? {
        if isExplicit {
            guard let currentSessionID,
                  sameTabSessions.contains(where: { $0.id == currentSessionID })
            else {
                return nil
            }
            return currentSessionID
        }

        if let currentSessionID,
           eligibleSessions.contains(where: { $0.id == currentSessionID })
        {
            return currentSessionID
        }
        return latestSession(in: eligibleSessions, streamingSessionIDs: streamingSessionIDs)?.id
    }

    static func session(matchingChatID raw: String, in sessions: [ChatSession]) -> ChatSession? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return sessions.first { session in
            session.id.uuidString == trimmed || session.shortID == trimmed
        }
    }
}

/// Pill that appears when there are oracle chat sessions for the current tab.
/// More prominent when streaming. Clicking opens a wide popover with chat transcript.
struct AgentOraclePill: View {
    @ObservedObject var oracleViewModel: OracleViewModel
    let windowID: Int
    let currentTabID: UUID?
    let activeAgentSessionID: UUID?
    let activeRunID: UUID?

    private enum PresentedSessionSource {
        case latest
        case explicit
    }

    @State private var showPopover = false
    @State private var autoScrollEnabled = false
    @State private var presentedSessionID: UUID?
    @State private var presentedSessionSource: PresentedSessionSource = .latest
    @ObservedObject private var fontScale = FontScaleManager.shared
    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    private var eligibleTabSessions: [ChatSession] {
        guard let tabID = currentTabID else { return [] }
        return AgentOraclePillLogic.eligibleSessions(
            sessions: oracleViewModel.sessions(forTabID: tabID),
            streamingSessionIDs: oracleViewModel.streamingSessions,
            liveMessageCount: { oracleViewModel.liveMessageCount(for: $0) },
            activeAgentSessionID: activeAgentSessionID,
            activeRunID: activeRunID
        )
    }

    private var latestTabSession: ChatSession? {
        AgentOraclePillLogic.latestSession(
            in: eligibleTabSessions,
            streamingSessionIDs: oracleViewModel.streamingSessions
        )
    }

    private var isStreaming: Bool {
        guard let latestTabSession else { return false }
        return oracleViewModel.streamingSessions.contains(latestTabSession.id)
    }

    private var presentedSession: ChatSession? {
        guard let presentedSessionID,
              let tabID = currentTabID else { return nil }
        return oracleViewModel.sessions(forTabID: tabID).first { $0.id == presentedSessionID }
    }

    private var isPresentedSessionStreaming: Bool {
        guard let presentedSessionID else { return isStreaming }
        return oracleViewModel.streamingSessions.contains(presentedSessionID)
    }

    private var popoverSubtitle: String {
        guard let presentedSession else { return "Latest tab chat" }
        if presentedSession.id == latestTabSession?.id {
            return "Latest tab chat"
        }
        return presentedSession.name
    }

    private var hasAnySessions: Bool {
        latestTabSession != nil
    }

    var body: some View {
        #if DEBUG
            let _ = AgentModePerfDiagnostics.increment("ui.body.statusPills.oracle")
        #endif
        Group {
            if hasAnySessions {
                let cornerRadius = AgentPillMetrics.cornerRadius(for: fontPreset)
                Button {
                    openPopover(chatID: nil)
                } label: {
                    HStack(spacing: 6) {
                        if isStreaming {
                            ProgressView()
                                .controlSize(.mini)
                                .scaleEffect(0.7)
                        } else {
                            Image(systemName: "brain")
                                .font(fontPreset.swiftUIFont(sizeAtNormal: 12))
                                .foregroundStyle(.secondary)
                        }
                        Text("Oracle")
                            .font(fontPreset.swiftUIFont(sizeAtNormal: 12, weight: isStreaming ? .semibold : .medium))
                            .foregroundStyle(isStreaming ? .primary : .secondary)
                    }
                    .padding(.horizontal, AgentPillMetrics.horizontalPadding(for: fontPreset))
                    .frame(height: AgentPillMetrics.height(for: fontPreset))
                    .background(isStreaming ? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(.ultraThinMaterial))
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .stroke(isStreaming ? Color.purple.opacity(0.4) : Color.secondary.opacity(0.15), lineWidth: isStreaming ? 1 : 0.5)
                    )
                    .shadow(color: isStreaming ? Color.purple.opacity(0.15) : .clear, radius: 4, y: 1)
                }
                .buttonStyle(.plain)
                .hoverTooltip(isStreaming ? "Oracle is thinking — click to view the live chat" : "Open the latest Oracle chat for this tab", .top)
                .animation(.easeInOut(duration: 0.2), value: isStreaming)
            } else {
                Color.clear.frame(width: 0, height: 0)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showAgentOraclePopover)) { note in
            guard let targetWindowID = note.userInfo?["windowID"] as? Int,
                  targetWindowID == windowID else { return }

            let requestedTabID: UUID? = {
                if let tabID = note.userInfo?["tabID"] as? UUID { return tabID }
                if let tabIDString = note.userInfo?["tabID"] as? String { return UUID(uuidString: tabIDString) }
                return nil
            }()
            if let requestedTabID, requestedTabID != currentTabID { return }

            let requestedChatID: String? = {
                if let chatID = note.userInfo?["chatID"] as? String { return chatID }
                if let chatID = note.userInfo?["chatID"] as? UUID { return chatID.uuidString }
                return nil
            }()

            openPopover(chatID: requestedChatID)
        }
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            oraclePopoverContent
        }
        .onChange(of: currentTabID) { _, _ in
            reconcilePresentedSession()
        }
        .onChange(of: activeAgentSessionID) { _, _ in
            reconcilePresentedSession()
        }
        .onChange(of: activeRunID) { _, _ in
            reconcilePresentedSession()
        }
    }

    @ViewBuilder
    private var oraclePopoverContent: some View {
        // Popover dimensions scale so chat messages don't feel cramped at
        // Larger/Extra Large. Width gets a tighter cap than height because the
        // popover is anchored to the composer and we don't want it to spill
        // beyond the window edges; the chat transcript area takes the rest.
        let popoverWidth = fontPreset.scaledClamped(800, max: 1040)
        let transcriptMinHeight = fontPreset.scaledClamped(350, max: 460)
        let transcriptIdealHeight = fontPreset.scaledClamped(500, max: 660)
        let transcriptMaxHeight = fontPreset.scaledClamped(600, max: 780)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Oracle")
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 13, weight: .semibold))
                if isPresentedSessionStreaming {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.7)
                }
                Spacer()
                Text(popoverSubtitle)
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            ChatMessagesView(
                viewModel: oracleViewModel,
                autoScrollEnabled: $autoScrollEnabled,
                bottomOcclusion: 0,
                showsScrollControls: true,
                autoScrollOnAppear: true,
                sessionIDOverride: presentedSessionID
            )
            .frame(minHeight: transcriptMinHeight, idealHeight: transcriptIdealHeight, maxHeight: transcriptMaxHeight)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .padding(14)
        .frame(width: popoverWidth)
    }

    private func reconcilePresentedSession() {
        guard showPopover else { return }
        let sameTabSessions = currentTabID.map { oracleViewModel.sessions(forTabID: $0) } ?? []
        let resolvedID = AgentOraclePillLogic.reconciledPresentedSessionID(
            currentSessionID: presentedSessionID,
            isExplicit: presentedSessionSource == .explicit,
            sameTabSessions: sameTabSessions,
            eligibleSessions: eligibleTabSessions,
            streamingSessionIDs: oracleViewModel.streamingSessions
        )
        guard let resolvedID else {
            presentedSessionID = nil
            showPopover = false
            return
        }
        presentedSessionID = resolvedID
    }

    private func openPopover(chatID: String?) {
        guard let tabID = currentTabID else { return }
        let target: ChatSession?
        let source: PresentedSessionSource
        if let chatID {
            target = AgentOraclePillLogic.session(
                matchingChatID: chatID,
                in: oracleViewModel.sessions(forTabID: tabID)
            )
            source = .explicit
            guard target != nil else { return }
        } else {
            target = latestTabSession
            source = .latest
        }
        guard let target else { return }

        presentedSessionID = target.id
        presentedSessionSource = source
        showPopover = true
    }
}
