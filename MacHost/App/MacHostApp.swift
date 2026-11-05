import SwiftUI

@main
struct MacHostApp: App {
    @State private var session = HostSession()

    var body: some Scene {
        MenuBarExtra("LF-ReMac", systemImage: "display") {
            HostMenuView(session: session)
        }
    }
}
