import AppKit

@MainActor
enum AccessibilityAnnouncer {
    static func announce(
        _ message: String,
        priority: NSAccessibilityPriorityLevel = .high
    ) {
        NSAccessibility.post(
            element: NSApplication.shared,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: priority.rawValue,
            ]
        )
    }
}
