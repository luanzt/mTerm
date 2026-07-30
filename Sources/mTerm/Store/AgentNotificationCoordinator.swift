import AppKit
@preconcurrency import UserNotifications

enum AgentAttention {
    case claude(ClaudeIntegration.AttentionKind)
    case codex

    var notificationTitle: String {
        switch self {
        case .claude(let kind):
            return kind.notificationTitle
        case .codex:
            return "Codex needs your attention"
        }
    }

    var notificationBody: String {
        switch self {
        case .claude(let kind):
            return kind.notificationBody
        case .codex:
            return "A turn finished or Codex is waiting for your input."
        }
    }
}

/// Owns macOS notification authorization, delivery, and click-through behavior.
/// Agent events arrive on the main actor from the terminal's OSC handler.
@MainActor
final class AgentNotificationCoordinator: NSObject, UNUserNotificationCenterDelegate {
    typealias SessionID = SessionRecord.ID

    var onOpenSession: ((SessionID) -> Void)?

    private let center: UNUserNotificationCenter
    private var authorizationRequestedThisLaunch = false
    private var authorizationDeferredUntilActive = false

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
        super.init()
    }

    /// Must run before notifications can be interacted with.
    func start() {
        center.delegate = self
    }

    /// Ask when the user first starts a supported agent, rather than surprising
    /// them at app launch. If it was started while mTerm is in the background,
    /// defer the system prompt until the app is active again.
    func prepareAuthorization() {
        guard !authorizationRequestedThisLaunch else { return }
        if !NSApp.isActive {
            authorizationDeferredUntilActive = true
            return
        }

        authorizationRequestedThisLaunch = true
        authorizationDeferredUntilActive = false
        let notificationCenter = center
        notificationCenter.getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            notificationCenter.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    func applicationDidBecomeActive() {
        guard authorizationDeferredUntilActive else { return }
        prepareAuthorization()
    }

    /// Deliver only while the application is inactive. The request identifier is
    /// stable per pane: a newer "needs attention" event replaces stale state from
    /// the same terminal instead of stacking duplicate alerts.
    func deliver(
        _ attention: AgentAttention,
        from session: SessionRecord
    ) {
        guard !NSApp.isActive else { return }

        let identifier = Self.identifier(for: session.id)
        let content = UNMutableNotificationContent()
        content.title = attention.notificationTitle
        content.subtitle = session.title
        content.body = attention.notificationBody
        content.sound = .default
        content.threadIdentifier = session.id.uuidString
        content.userInfo = ["sessionID": session.id.uuidString]

        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
        center.add(UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil))
    }

    /// Suppress a notification if the app became active after it was scheduled
    /// but before Notification Center presented it.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler:
            @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([])
    }

    /// Clicking an alert activates mTerm and routes back to its originating pane.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let rawID = response.notification.request.content.userInfo["sessionID"] as? String
        Task { @MainActor [weak self] in
            defer { completionHandler() }
            guard let rawID, let sessionID = UUID(uuidString: rawID) else { return }
            NSApp.activate(ignoringOtherApps: true)
            self?.onOpenSession?(sessionID)
        }
    }

    private static func identifier(for id: SessionID) -> String {
        "com.luanzt.mterm.agent-attention.\(id.uuidString)"
    }
}
