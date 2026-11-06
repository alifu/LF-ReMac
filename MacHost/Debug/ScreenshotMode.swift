#if DEBUG
import Foundation
import AppKit
import RemoteCore
import SwiftUI

/// Debug-only dummy data for README screenshots (`-screenshots` launch argument). Uses an in-memory
/// store and never starts the server, the capture or the Keychain; absent from Release builds.
enum ScreenshotMode {
    static let isOn = CommandLine.arguments.contains("-screenshots")

    static let invitationPort: UInt16 = 51820

    /// Folder for window snapshots: `-screenshot-dir <path>`.
    static var snapshotDirectory: URL? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "-screenshot-dir"), arguments.indices.contains(index + 1) else { return nil }
        return URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
    }

    @MainActor
    static func makeSession() -> HostSession {
        let store = InMemoryKeyStore()
        let paired = PairedDeviceStore(keyStore: store, key: HostEnvironment.pairedDevicesKey)
        for device in devices { try? paired.add(device) }
        var environment = HostEnvironment.live
        environment = HostEnvironment(
            loadIdentity: environment.loadIdentity, keyStore: store, displayName: { "Mac mini" },
            invitationHost: { "mac-mini.local" }, serviceType: nil, port: environment.port, clock: environment.clock,
            limits: environment.limits)
        let session = HostSession(environment: environment)
        session.applyDemoState(connected: devices[0], invitation: invitation)
        return session
    }

    static let devices: [PairedDevice] = [
        device("Alex's iPhone", seed: 0x21, day: 1_758_000_000),
        device("Family iPad mini", seed: 0x63, day: 1_755_000_000),
    ]

    private static func device(_ name: String, seed: UInt8, day: TimeInterval) -> PairedDevice {
        let fingerprint = try! DeviceFingerprint(bytes: Data((0..<32).map { seed &+ UInt8($0) &* 11 }))
        return PairedDevice(name: name, fingerprint: fingerprint, pairedAt: Date(timeIntervalSince1970: day))
    }

    static var invitation: PairingInvitation {
        let hostKey = try! DeviceFingerprint(bytes: Data((0..<32).map { 0x5A &+ UInt8($0) &* 5 }))
        let secret = try! PairingSecret(bytes: Data([0x13, 0x77, 0xA2, 0x09, 0xC4, 0x5E, 0x81, 0x3B, 0xD0, 0x6F]))
        return try! PairingInvitation(host: "mac-mini.local", port: invitationPort, hostFingerprint: hostKey, secret: secret)
    }
}

/// Draws each demo window into a PNG from inside the app. Unlike a screen capture this ignores whatever
/// else is on the desktop and whichever display the window is on.
@MainActor
enum WindowSnapshots {
    private static let files = ["Pair a New iPhone": "mac-pairing.png", "Paired iPhones": "mac-paired-devices.png"]

    static func save(to directory: URL) {
        let logger = AppLog.logger(category: "screenshots")
        logger.notice("Saving window snapshots to \(directory.path, privacy: .public); windows: \(NSApp.windows.map(\.title), privacy: .public)")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            logger.error("Cannot create \(directory.path, privacy: .public): \(String(describing: error), privacy: .public)")
        }
        for window in NSApp.windows {
            guard let name = files[window.title], let frameView = window.contentView?.superview,
                  let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { continue }
            frameView.cacheDisplay(in: frameView.bounds, to: rep)
            do {
                try rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent(name))
            } catch {
                logger.error("Cannot write \(name, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
    }
}

extension ScreenshotMode {
    /// Opens the pairing and paired-devices windows, then (with `-screenshot-dir`) saves them as PNGs.
    @MainActor
    static func openDemoWindows(_ openWindow: OpenWindowAction) {
        openWindow(id: HostWindows.pairingID)
        openWindow(id: HostWindows.pairedDevicesID)
        guard let directory = snapshotDirectory else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))  // let the QR code and lists render
            WindowSnapshots.save(to: directory)
        }
    }
}
#endif
