import RemoteCore
import SwiftUI

/// Full-screen remote display: video, touch input, keyboard, stats and controls.
struct StreamView: View {
    let client: StreamClient
    let hostName: String
    @State private var isStatsVisible = true
    @State private var isKeyboardActive = false
    @State private var pointerMode: PointerController.Mode = .trackpad
    @State private var zoom = ViewZoom.identity
    @State private var pointer: PointerController
    @State private var keyboard: KeyboardController

    init(client: StreamClient, hostName: String) {
        self.client = client
        self.hostName = hostName
        let send: @MainActor (InputEvent) -> Void = { [client] in client.send($0) }
        _pointer = State(initialValue: PointerController(send: send))
        _keyboard = State(initialValue: KeyboardController(modifiers: ModifierState(), send: send))
    }

    var body: some View {
        ZStack {
            VideoView(layer: client.renderer.displayLayer, zoom: zoom)
            InputSurface(controller: pointer, videoSize: client.videoSize, zoom: zoom)
            KeyboardHost(isActive: $isKeyboardActive, keyboard: keyboard)
                .frame(width: 0, height: 0)
        }
        .ignoresSafeArea()
        .ignoresSafeArea(.keyboard)
        .overlay(alignment: .topLeading) {
            StatsOverlay(stats: client.stats, isVisible: $isStatsVisible)
                .padding()
        }
        .overlay(alignment: .topTrailing) {
            controls.padding()
        }
        .overlay(alignment: .bottom) {
            if let status = client.reconnect {
                ReconnectBanner(status: status).padding()
            }
        }
        .background(.black)
        .statusBarHidden()
        .onChange(of: pointerMode) { _, mode in pointer.mode = mode }
        .onAppear { pointer.onZoomChange = { zoom = $0 } }
    }

    private var controls: some View {
        HStack(spacing: 16) {
            Button("Keyboard", systemImage: isKeyboardActive ? "keyboard.chevron.compact.down" : "keyboard") {
                isKeyboardActive.toggle()
            }
            Button(pointerMode == .trackpad ? "Trackpad mode" : "Direct touch mode",
                   systemImage: pointerMode == .trackpad ? "rectangle.and.hand.point.up.left" : "hand.point.up.left") {
                pointerMode = pointerMode == .trackpad ? .direct : .trackpad
            }
            if zoom.isZoomed {
                Button("Reset zoom (\(String(format: "%.1f", Double(zoom.scale)))×)",
                       systemImage: "arrow.down.right.and.arrow.up.left") {
                    pointer.resetZoom()
                }
            }
            Button("Disconnect from \(hostName)", systemImage: "xmark.circle.fill") {
                client.disconnect()
            }
        }
        .labelStyle(.iconOnly)
        .font(.title2)
        .foregroundStyle(.white.opacity(0.8))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.black.opacity(0.4), in: Capsule())
    }
}

/// Shown over the last picture while the client redials the Mac.
private struct ReconnectBanner: View {
    let status: ReconnectStatus

    var body: some View {
        Label("Connection lost. Reconnecting (\(status.attempt) of \(status.total))…", systemImage: "wifi.exclamationmark")
            .font(.callout)
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.black.opacity(0.6), in: Capsule())
            .accessibilityElement(children: .combine)
    }
}
