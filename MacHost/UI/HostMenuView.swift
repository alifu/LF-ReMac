import SwiftUI

struct HostMenuView: View {
    var body: some View {
        Text("Host idle")
        Divider()
        Button("Quit LF-ReMac") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
