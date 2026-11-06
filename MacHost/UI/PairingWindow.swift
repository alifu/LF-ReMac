import AppKit
import RemoteCore
import SwiftUI

/// Shows the pairing QR code and code text while a new iPhone pairs.
struct PairingWindow: View {
    let session: HostSession
    @Environment(\.dismissWindow) private var dismissWindow

    private static let width: CGFloat = 360

    var body: some View {
        content
            .padding(20)
            .frame(width: Self.width)
            .onAppear { NSApp.activate() }
            .onDisappear {
                if case .open = session.pairingState { session.cancelPairing() }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch session.pairingState {
        case .idle:
            idleView
        case .open(let invitation, let expiresAt):
            openView(invitation: invitation, expiresAt: expiresAt)
        case .paired(let deviceName):
            pairedView(deviceName: deviceName)
        case .failed(let message):
            failedView(message: message)
        }
    }

    private var idleView: some View {
        VStack(spacing: 16) {
            Text("Pair a New iPhone")
                .font(.headline)
            Button("Start pairing") { session.startPairing() }
                .keyboardShortcut(.defaultAction)
                .disabled(!session.isHosting)
            if !session.isHosting {
                Text("Start hosting from the menu bar first.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func openView(invitation: PairingInvitation, expiresAt: Date) -> some View {
        VStack(spacing: 12) {
            if let qrImage = QRCodeImage.make(from: invitation.urlString) {
                Image(nsImage: qrImage)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 240, height: 240)
                    .accessibilityLabel("Pairing QR code")
            }
            Text(invitation.secret.displayCode)
                .font(.system(.title3, design: .monospaced))
            VStack(spacing: 2) {
                Text("This Mac's security code")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(invitation.hostFingerprint.verificationCode)
                    .font(.system(.callout, design: .monospaced))
                Text("Your iPhone shows this code before pairing. Only continue if they match.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("On your iPhone open LF-ReMac and tap Pair, then scan this code or type the code.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text("Expires in \(PairingCountdown.text(until: expiresAt, now: context.date))")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if let notice = session.pairingNotice {
                Text(notice)
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("Cancel", role: .cancel) { closeWindow() }
                .keyboardShortcut(.cancelAction)
        }
    }

    private func pairedView(deviceName: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.green)
            Text("\(deviceName) is now paired.")
                .font(.headline)
                .multilineTextAlignment(.center)
            Button("Done", action: closeWindow)
                .keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: .infinity)
    }

    private func failedView(message: String) -> some View {
        VStack(spacing: 16) {
            Text(message)
                .multilineTextAlignment(.center)
            Button("Try Again") { session.startPairing() }
                .keyboardShortcut(.defaultAction)
                .disabled(!session.isHosting)
        }
        .frame(maxWidth: .infinity)
    }

    private func closeWindow() {
        session.cancelPairing()
        dismissWindow(id: HostWindows.pairingID)
    }
}
