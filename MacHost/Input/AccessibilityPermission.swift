import ApplicationServices

/// macOS only lets an app post mouse and keyboard events after the user grants Accessibility access.
enum AccessibilityPermission {
    // Same value as kAXTrustedCheckOptionPrompt; the C global is not usable under Swift 6 concurrency checking.
    private static let promptOptionKey = "AXTrustedCheckOptionPrompt"

    static var isGranted: Bool {
        AXIsProcessTrusted()
    }

    /// Shows the system prompt (once) that leads to System Settings > Privacy & Security > Accessibility.
    @discardableResult
    static func requestPrompt() -> Bool {
        AXIsProcessTrustedWithOptions([promptOptionKey: true] as CFDictionary)
    }
}
