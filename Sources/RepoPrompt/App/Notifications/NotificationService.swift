import AppKit
import Foundation
import UserNotifications

#if DEBUG
    private var notificationServiceDebugLoggingEnabled = false
    private func notificationServiceDebugLog(_ message: @autoclosure () -> String) {
        guard notificationServiceDebugLoggingEnabled else { return }
        print("[NotificationService] \(message())")
    }
#else
    private func notificationServiceDebugLog(_ message: @autoclosure () -> String) {}
#endif

/// SEARCH-HELPER: Notifications, UserNotifications, Alerts, Chat Complete
/// Service for managing macOS notifications
@MainActor
class NotificationService: NSObject {
    static let shared = NotificationService()

    private var isAuthorized = false
    private lazy var center: UNUserNotificationCenter? = {
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            notificationServiceDebugLog("Skipping UserNotifications outside an app bundle")
            return nil
        }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        return center
    }()

    override private init() {
        super.init()
    }

    /// Request notification authorization on app launch
    func requestAuthorization() async {
        guard let center else {
            isAuthorized = false
            return
        }
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            isAuthorized = granted
            if !granted {
                notificationServiceDebugLog("Notification authorization denied")
            }
        } catch {
            notificationServiceDebugLog("Error requesting notification authorization: \(error)")
            isAuthorized = false
        }
    }

    /// Send a notification when a chat completes
    /// - Parameters:
    ///   - chatName: The name of the completed chat session
    ///   - fallbackToDockBounce: Whether to fall back to dock icon bounce if notifications aren't authorized
    func notifyChatComplete(chatName: String?, fallbackToDockBounce: Bool = true) {
        // Only notify if app is not active
        guard NSApp?.isActive != true else { return }

        if isAuthorized {
            sendChatCompleteNotification(chatName: chatName)
        } else if fallbackToDockBounce {
            // Fallback to dock icon bounce
            NSApp?.requestUserAttention(.informationalRequest)
        }
    }

    /// Send a notification when Context Builder completes and tab is renamed
    /// - Parameters:
    ///   - tabName: The new name of the tab
    ///   - fallbackToDockBounce: Whether to fall back to dock icon bounce if notifications aren't authorized
    func notifyContextBuilderComplete(tabName: String, fallbackToDockBounce: Bool = true) {
        // Only notify if app is not active
        guard NSApp?.isActive != true else { return }

        if isAuthorized {
            notifyContextBuilderCompleted(tabName: tabName)
        } else if fallbackToDockBounce {
            // Fallback to dock icon bounce
            NSApp?.requestUserAttention(.informationalRequest)
        }
    }

    /// Send a notification when an agent turn completes
    /// - Parameters:
    ///   - sessionName: The agent session/tab name
    ///   - previewText: Message text to preview in the notification body
    ///   - route: Optional scoped route to the originating agent session
    ///   - fallbackToDockBounce: Whether to fall back to dock icon bounce if notifications aren't authorized
    func notifyAgentTurnComplete(
        sessionName: String?,
        previewText: String?,
        route: AgentSessionDeepLinkRoute? = nil,
        fallbackToDockBounce: Bool = true
    ) {
        guard NSApp?.isActive != true else { return }

        if isAuthorized {
            sendAgentTurnCompleteNotification(sessionName: sessionName, previewText: previewText, route: route)
        } else if fallbackToDockBounce {
            NSApp?.requestUserAttention(.informationalRequest)
        }
    }

    /// Send a notification when an agent turn is waiting for user input
    /// - Parameters:
    ///   - sessionName: The agent session/tab name
    ///   - promptText: Wait prompt text to preview in the notification body
    ///   - route: Optional scoped route to the originating agent session
    ///   - fallbackToDockBounce: Whether to fall back to dock icon bounce if notifications aren't authorized
    func notifyAgentWaitingForUser(
        sessionName: String?,
        promptText: String?,
        route: AgentSessionDeepLinkRoute? = nil,
        fallbackToDockBounce: Bool = true
    ) {
        guard NSApp?.isActive != true else { return }

        if isAuthorized {
            sendAgentWaitingForUserNotification(sessionName: sessionName, promptText: promptText, route: route)
        } else if fallbackToDockBounce {
            NSApp?.requestUserAttention(.informationalRequest)
        }
    }

    /// Send the actual notification
    private func sendChatCompleteNotification(chatName: String?) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = "Chat Complete"

        // Customize body based on chat name
        if let name = chatName, !name.isEmpty, name != "New Chat" {
            content.body = name
        } else {
            content.body = "Your AI response is ready"
        }

        content.sound = .default

        // Create request with unique identifier
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil // Deliver immediately
        )

        // Add notification request
        center.add(request) { error in
            if let error {
                notificationServiceDebugLog("Error sending notification: \(error)")
            }
        }
    }

    /// Send the actual Context Builder complete notification
    private func notifyContextBuilderCompleted(tabName: String) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = "Context Builder Complete"
        content.body = tabName
        content.sound = .default

        // Create request with unique identifier
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil // Deliver immediately
        )

        // Add notification request
        center.add(request) { error in
            if let error {
                notificationServiceDebugLog("Error sending notification: \(error)")
            }
        }
    }

    private func sendAgentTurnCompleteNotification(sessionName: String?, previewText: String?, route: AgentSessionDeepLinkRoute?) {
        guard let center else { return }
        let content = Self.agentTurnCompleteContent(sessionName: sessionName, previewText: previewText, route: route)

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        center.add(request) { error in
            if let error {
                notificationServiceDebugLog("Error sending notification: \(error)")
            }
        }
    }

    private func sendAgentWaitingForUserNotification(sessionName: String?, promptText: String?, route: AgentSessionDeepLinkRoute?) {
        guard let center else { return }
        let content = Self.agentWaitingForUserContent(sessionName: sessionName, promptText: promptText, route: route)

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        center.add(request) { error in
            if let error {
                notificationServiceDebugLog("Error sending notification: \(error)")
            }
        }
    }

    static func agentTurnCompleteContent(
        sessionName: String?,
        previewText: String?,
        route: AgentSessionDeepLinkRoute?
    ) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = notificationTitle(from: sessionName)
        content.body = notificationBody(primaryText: previewText, fallbackName: sessionName, fallback: "Your agent message is ready")
        content.sound = .default
        if let route {
            content.userInfo = route.notificationUserInfo
        }
        return content
    }

    static func agentWaitingForUserContent(
        sessionName: String?,
        promptText: String?,
        route: AgentSessionDeepLinkRoute?
    ) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = notificationTitle(from: sessionName)
        content.body = notificationBody(primaryText: promptText, fallbackName: sessionName, fallback: "Your agent needs input")
        content.sound = .default
        if let route {
            content.userInfo = route.notificationUserInfo
        }
        return content
    }

    private static func notificationBody(primaryText: String?, fallbackName: String?, fallback: String) -> String {
        if let preview = makePreview(from: primaryText) {
            return preview
        }
        if let name = fallbackName,
           !name.isEmpty,
           name != "New Chat",
           name != "Agent Session"
        {
            return name
        }
        return fallback
    }

    private static func notificationTitle(from sessionName: String?) -> String {
        if let name = sessionName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty
        {
            return name
        }
        return "Agent Session"
    }

    private static func makePreview(from text: String?) -> String? {
        guard let text else { return nil }
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let trimmed = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let maxLines = 3
        let maxChars = 220

        var lines: [String] = []
        for rawLine in trimmed.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            lines.append(line)
            if lines.count >= maxLines {
                break
            }
        }

        guard !lines.isEmpty else { return nil }
        var preview = lines.joined(separator: "\n")
        if preview.count > maxChars {
            let index = preview.index(preview.startIndex, offsetBy: maxChars)
            preview = String(preview[..<index]).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
        }
        return preview
    }

    /// Check current authorization status
    func checkAuthorizationStatus() async -> Bool {
        guard let center else {
            isAuthorized = false
            return false
        }
        let settings = await center.notificationSettings()
        isAuthorized = settings.authorizationStatus == .authorized
        return isAuthorized
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension NotificationService: UNUserNotificationCenterDelegate {
    /// Handle notification when app is in foreground
    /// Note: This is only called when the app is already frontmost
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Don't show notifications when app is in foreground
        // (This method is only called when app is frontmost)
        completionHandler([])
    }

    /// Handle notification tap
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let route = AgentSessionDeepLinkRoute.parse(notificationUserInfo: response.notification.request.content.userInfo)
        Task { @MainActor in
            await AppDeepLinkRouter.shared.route(notificationRoute: route)
        }
        completionHandler()
    }
}
