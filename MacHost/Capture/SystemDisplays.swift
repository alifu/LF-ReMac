import AppKit
import CoreGraphics
import Foundation
import OSLog

/// Reads the real display list from macOS.
enum SystemDisplays {
    private static let maxDisplayCount: UInt32 = 32

    static func current() -> [DisplayDescriptor] {
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(maxDisplayCount))
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(maxDisplayCount, &ids, &count) == .success else { return [] }
        let mainID = CGMainDisplayID()
        return ids.prefix(Int(count)).compactMap { id in
            guard let uuid = uuidString(for: id) else { return nil }
            return DisplayDescriptor(
                uuid: uuid, name: name(for: id), pixelWidth: CGDisplayPixelsWide(id),
                pixelHeight: CGDisplayPixelsHigh(id), isMain: id == mainID, displayID: id
            )
        }
    }

    private static func uuidString(for id: CGDirectDisplayID) -> String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String?
    }

    private static func name(for id: CGDirectDisplayID) -> String {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        let screen = NSScreen.screens.first { ($0.deviceDescription[key] as? NSNumber)?.uint32Value == id }
        return screen?.localizedName ?? "Display \(id)"
    }
}

/// Calls `onChange` (on the main actor, debounced) after displays are added, removed or reconfigured.
@MainActor
final class DisplayWatcher {
    private static let debounce = Duration.milliseconds(500)

    private let onChange: @MainActor () -> Void
    private var pending: Task<Void, Never>?
    private var isRegistered = false

    init(onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
    }

    func start() {
        guard !isRegistered else { return }
        isRegistered = true
        CGDisplayRegisterReconfigurationCallback(displayWatcherCallback, Unmanaged.passUnretained(self).toOpaque())
    }

    func stop() {
        guard isRegistered else { return }
        isRegistered = false
        CGDisplayRemoveReconfigurationCallback(displayWatcherCallback, Unmanaged.passUnretained(self).toOpaque())
        pending?.cancel()
        pending = nil
    }

    fileprivate func displaysChanged() {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled else { return }
            self?.onChange()
        }
    }

    isolated deinit { stop() }
}

/// Reconfiguration comes in two calls per change; only the "done" one (no begin flag) matters.
private func displayWatcherCallback(_ id: CGDirectDisplayID, _ flags: CGDisplayChangeSummaryFlags, _ info: UnsafeMutableRawPointer?) {
    guard let info, !flags.contains(.beginConfigurationFlag) else { return }
    let watcher = Unmanaged<DisplayWatcher>.fromOpaque(info).takeUnretainedValue()
    DispatchQueue.main.async { watcher.displaysChanged() }
}
