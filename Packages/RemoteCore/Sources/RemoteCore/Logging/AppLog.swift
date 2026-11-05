import Foundation
import os

/// Creates `Logger`s that share the app's bundle ID as their subsystem.
/// Never log keys, pairing codes or screen content.
public enum AppLog {
    static let fallbackSubsystem = "com.alifu.lfremac"

    public static func logger(category: String, bundle: Bundle = .main) -> Logger {
        Logger(subsystem: subsystem(for: bundle), category: category)
    }

    static func subsystem(for bundle: Bundle) -> String {
        bundle.bundleIdentifier ?? fallbackSubsystem
    }
}
