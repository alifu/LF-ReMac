import SwiftUI

@main
struct MacHostApp: App {
    @State private var session = HostSession()

    var body: some Scene {
        MenuBarExtra("LF-ReMac", systemImage: "display") {
            HostMenuView(session: session)
        }
        Window("Pair a New iPhone", id: HostWindows.pairingID) {
            PairingWindow(session: session)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        Window("Paired iPhones", id: HostWindows.pairedDevicesID) {
            PairedDevicesWindow(session: session)
        }
    }
}
