import AppKit
import SwiftUI

/// Menu items that open the pairing and paired-devices windows.
struct PairingMenuSection: View {
    let session: HostSession
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Pair New iPhone…") {
            session.startPairing()
            NSApp.activate()
            openWindow(id: HostWindows.pairingID)
        }
        .disabled(!session.isHosting)
        Button("Paired iPhones…") {
            NSApp.activate()
            openWindow(id: HostWindows.pairedDevicesID)
        }
    }
}
