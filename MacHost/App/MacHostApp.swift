import SwiftUI

@main
struct MacHostApp: App {
    @State private var session = Self.makeSession()

    var body: some Scene {
        MenuBarExtra {
            HostMenuView(session: session)
        } label: {
            MenuBarLabel()
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

    private static func makeSession() -> HostSession {
        #if DEBUG
        if ScreenshotMode.isOn { return ScreenshotMode.makeSession() }
        #endif
        return HostSession()
    }
}

/// The menu bar icon. In Debug builds with `-screenshots` it also opens the demo windows at launch (the label is
/// built at launch, unlike the menu), so UI automation need not drive the menu bar.
private struct MenuBarLabel: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Label("LF-ReMac", systemImage: "display")
            #if DEBUG
            .task {
                guard ScreenshotMode.isOn else { return }
                ScreenshotMode.openDemoWindows(openWindow)
            }
            #endif
    }
}
