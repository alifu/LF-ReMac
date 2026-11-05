import SwiftUI

struct ConnectionView: View {
    var body: some View {
        ContentUnavailableView(
            "No Mac Connected",
            systemImage: "display",
            description: Text("Start LF-ReMac Host on your Mac.")
        )
    }
}

#Preview {
    ConnectionView()
}
