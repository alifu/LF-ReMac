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
        Toggle("Keep Mac Awake While Hosting", isOn: Binding(
            get: { session.keepsMacAwake },
            set: { session.setKeepsMacAwake($0) }
        ))
        Toggle("Allow Tailscale Connections", isOn: Binding(
            get: { session.allowsTailscale },
            set: { session.setAllowsTailscale($0) }
        ))
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
            if let name = session.connectedDeviceName {
                "Streaming to \(name)"
            } else {
                "Streaming to iPhone"
            }
        case .failed(let message):
            "Error: \(message)"
        }
    }
}
