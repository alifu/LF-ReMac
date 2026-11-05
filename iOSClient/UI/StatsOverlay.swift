import SwiftUI

/// Small translucent readout of stream statistics. Tapping the readout hides it; tapping the collapsed
/// label shows it again.
struct StatsOverlay: View {
    let stats: StreamStats
    @Binding var isVisible: Bool

    var body: some View {
        Button {
            isVisible.toggle()
        } label: {
            Text(isVisible ? stats.summary : "Stats")
                .font(.caption.monospaced())
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isVisible ? stats.accessibilitySummary : "Show statistics")
    }
}
