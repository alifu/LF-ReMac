import SwiftUI

/// Full-screen remote display with a disconnect button and a stats overlay.
struct StreamView: View {
    let client: StreamClient
    let hostName: String
    @State private var isStatsVisible = true

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VideoView(layer: client.renderer.displayLayer)
                .ignoresSafeArea()
            Button("Disconnect", systemImage: "xmark.circle.fill") {
                client.disconnect()
            }
            .labelStyle(.iconOnly)
            .font(.title)
            .foregroundStyle(.white.opacity(0.7))
            .padding()
            .accessibilityLabel("Disconnect from \(hostName)")
        }
        .overlay(alignment: .topLeading) {
            StatsOverlay(stats: client.stats, isVisible: $isStatsVisible)
                .padding()
        }
        .background(.black)
        .statusBarHidden()
    }
}
