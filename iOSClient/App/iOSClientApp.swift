import SwiftUI

@main
struct iOSClientApp: App {
    @State private var credentials = PhoneCredentials.live()

    var body: some Scene {
        WindowGroup {
            ConnectionView(credentials: credentials)
        }
    }
}
