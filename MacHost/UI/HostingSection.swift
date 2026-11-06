import SwiftUI

/// Start/stop hosting and show the connection status.
struct HostingSection: View {
    let session: HostSession

    var body: some View {
        Text(statusText)
        Button(session.isHosting ? "Stop Hosting" : "Start Hosting") {
            Task {
                if session.isHosting {
                    await session.stop()
                } else {
                    session.start()
                }
            }
        }
        Divider()
        Toggle("Allow Remote Control", isOn: Binding(
            get: { session.isRemoteControlEnabled },
            set: { session.setRemoteControl(enabled: $0) }
        ))
        if session.isRemoteControlEnabled && !AccessibilityPermission.isGranted {
            Button("Grant Accessibility Access…") {
                AccessibilityPermission.requestPrompt()
            }
        }
    }

    private var statusText: String {
        switch session.state {
        case .stopped:
            "Not hosting"
        case .listening(let port):
            "Waiting for iPhone (port \(port))"
        case .streaming:
            "Streaming to iPhone"
        case .failed(let message):
            "Error: \(message)"
        }
    }
}
