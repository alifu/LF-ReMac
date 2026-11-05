import SwiftUI

@main
struct MacHostApp: App {
    var body: some Scene {
        MenuBarExtra("LF-ReMac", systemImage: "display") {
            HostMenuView()
        }
    }
}
