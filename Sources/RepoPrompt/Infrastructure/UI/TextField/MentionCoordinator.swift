import AppKit
import Combine
import Foundation

@MainActor
final class MentionCoordinator: MentionTextViewDelegate {
    // MARK: – Init & stored refs

    private unowned let textView: MentionTextView
    private let suggestionService: MentionSuggestionService
    private let overlay = MentionOverlayController()
    private var configuration: FileMentionPickerConfiguration
    private let commitHandler: (MentionSuggestion) -> Void
    private let tokenRemovedHandler: (MentionTokenPayload) -> Void

    init(
        textView: MentionTextView,
        suggestionService: MentionSuggestionService,
        configuration: FileMentionPickerConfiguration = .compact,
        commitHandler: @escaping (MentionSuggestion) -> Void,
        tokenRemovedHandler: @escaping (MentionTokenPayload) -> Void
    ) {
        self.textView = textView
        self.suggestionService = suggestionService
        self.configuration = configuration
        self.commitHandler = commitHandler
        self.tokenRemovedHandler = tokenRemovedHandler
        applyConfiguration(configuration)

        // ------------------------------------------------------------------
        // Debounce search queries (80 ms) so the UI remains responsive while
        // the user is typing fast.  The subscription is stored in
        // `cancellables`, so it is cancelled automatically on deinit.
        // ------------------------------------------------------------------
        querySubject
            .debounce(for: .milliseconds(80), scheduler: RunLoop.main)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] q, parent, preserve in
                self?.runQuery(q, parent: parent, preserveIndex: preserve)
            }
            .store(in: &cancellables)
    }

    func updateFileManager(_ manager: WorkspaceFilesViewModel?) {
        suggestionService.updateFileManager(manager)
    }

    func updateConfiguration(_ configuration: FileMentionPickerConfiguration) {
        guard self.configuration != configuration else { return }
        self.configuration = configuration
        applyConfiguration(configuration)
    }

    private func applyConfiguration(_ configuration: FileMentionPickerConfiguration) {
        suggestionService.updateConfiguration(configuration)
        overlay.suggestedWidth = configuration.overlayWidth
        overlay.visibleRowLimit = configuration.visibleRows
    }

    // MARK: – Internal state

    private var parentStack: [MentionSuggestion?] = [nil]
    // Mirrors `parentStack` – keeps the highlighted row for every depth
    private var highlightStack: [Int] = [0]
    private var suggestions: [MentionSuggestion] = []
    private var highlighted: Int = 0

    // Combine-based debounce ------------------------------------------------
    private let querySubject = PassthroughSubject<(String, MentionSuggestion?, Bool), Never>()
    private var cancellables = Set<AnyCancellable>()
    private var pendingReanchorTask: Task<Void, Never>?
    private var reanchorGeneration: UInt64 = 0

    // MARK: – Delegate entry-points (will be wired later)

    func mentionStarted(at caret: NSRect) {
        parentStack = [nil]
        highlightStack = [0]
        highlighted = 0

        // Pre-compute the default suggestion list (empty query at repo root)
        let initialItems = suggestionService.suggestions(for: "", under: nil)
        suggestions = initialItems

        guard !textView.hasMarkedText(), let host = textView.window else {
            overlay.hide()
            return
        }
        // Pass the real items right away so the table never displays the
        // "No results found" placeholder.
        overlay.show(at: caret, owner: host, items: initialItems)
        scheduleOverlayReanchor()
    }

    /// ------------------------------------------------------------------
    /// Overload required by `MentionTextViewDelegate` for protocol conformance
    /// ------------------------------------------------------------------
    func mentionQueryChanged(_ q: String, parent: MentionSuggestion?) {
        mentionQueryChanged(q, parent: parent, preserveIndex: false)
    }

    func mentionQueryChanged(
        _ q: String,
        parent: MentionSuggestion?,
        preserveIndex: Bool = false
    ) {
        // Push every change through the Combine pipeline; the subscriber
        // will receive debounced updates on the main run-loop.
        querySubject.send((q, parent, preserveIndex))
    }

    // ------------------------------------------------------------------
    // MARK: – Private helpers

    /// ------------------------------------------------------------------
    private func runQuery(
        _ q: String,
        parent: MentionSuggestion?,
        preserveIndex: Bool
    ) {
        guard !textView.hasMarkedText() else {
            overlay.hide()
            return
        }
        // Resolve `nil` parent to the current folder context so searches stay
        // properly scoped after the user has drilled into a sub-folder.
        let effectiveParent = parent ?? parentStack.last ?? nil
        let items = suggestionService.suggestions(for: q, under: effectiveParent)
        suggestions = items

        // Decide which row should be highlighted first
        let desired = preserveIndex
            ? (highlightStack.last ?? 0)
            : 0
        // Clamp in case the list shrunk; avoid negative when list is empty
        highlighted = items.isEmpty ? 0 : min(max(desired, 0), items.count - 1)

        // Sync per-level cache
        if !highlightStack.isEmpty {
            highlightStack[highlightStack.count - 1] = highlighted
        }

        overlay.update(items: items, highlighted: highlighted)
        guard textView.window != nil else {
            overlay.hide()
            return
        }
        scheduleOverlayReanchor()
    }

    func mentionNavigate(_ cmd: MentionNavigationCommand) {
        // Ensure stacks are initialized
        if highlightStack.isEmpty {
            highlightStack = [0]
        }
        if parentStack.isEmpty {
            parentStack = [nil]
        }
        switch cmd {
        case .up:
            highlighted = (highlighted - 1 + suggestions.count) % max(suggestions.count, 1)
            overlay.moveHighlight(by: -1)
            if !highlightStack.isEmpty {
                highlightStack[highlightStack.count - 1] = highlighted
            }
        case .down:
            highlighted = (highlighted + 1) % max(suggestions.count, 1)
            overlay.moveHighlight(by: +1)
            if !highlightStack.isEmpty {
                highlightStack[highlightStack.count - 1] = highlighted
            }
        case .left:
            guard parentStack.count > 1 else { return }
            parentStack.removeLast()
            highlightStack.removeLast()
            highlighted = highlightStack.last ?? 0

            overlay.popLevel()
            // Refresh suggestions for the new parent folder but keep index
            mentionQueryChanged("", parent: parentStack.last ?? nil, preserveIndex: true)
        case .right:
            guard highlighted >= 0,
                  highlighted < suggestions.count,
                  suggestions[highlighted].kind == .folder
            else { return }
            parentStack.append(suggestions[highlighted])
            // Store current selection, start child level at 0
            highlightStack.append(0)
            overlay.pushLevel()
            // clear query for new level
            mentionQueryChanged("", parent: parentStack.last ?? nil)
        }
    }

    func mentionAccept() {
        guard highlighted >= 0, highlighted < suggestions.count else { return }
        let sugg = suggestions[highlighted]
        overlay.hide() // Tear down UI first
        textView.insertMentionToken(sugg) // Then mutate text
        commitHandler(sugg)
    }

    func mentionAbort() {
        pendingReanchorTask?.cancel()
        overlay.hide()
    }

    func tokenRemoved(_ payload: MentionTokenPayload) {
        tokenRemovedHandler(payload)
    }

    /// ------------------------------------------------------------------
    /// Ensure no suggestion window survives the lifetime of the coordinator
    /// ------------------------------------------------------------------
    deinit {
        pendingReanchorTask?.cancel()
        // Capture overlay in a local so we don't rebuild self-access after
        // the object is partially de-initialised.
        let overlayRef = self.overlay
        Task { @MainActor in
            overlayRef.hide()
        }
    }

    private func scheduleOverlayReanchor() {
        pendingReanchorTask?.cancel()
        reanchorGeneration &+= 1
        let generation = reanchorGeneration

        pendingReanchorTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            guard !Task.isCancelled else { return }
            guard generation == reanchorGeneration else { return }
            guard !textView.hasMarkedText() else {
                overlay.hide()
                return
            }
            guard textView.window != nil else {
                overlay.hide()
                return
            }
            let selection = textView.clampSelectionToCurrentString()
            let caretRect = textView.firstRect(
                forCharacterRange: selection,
                actualRange: nil
            )
            overlay.repositionRoot(to: caretRect)
        }
    }
}
