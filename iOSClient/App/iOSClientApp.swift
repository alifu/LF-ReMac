import SwiftUI

@main
struct iOSClientApp: App {
    @State private var credentials = Self.makeCredentials()

    var body: some Scene {
        WindowGroup {
            ConnectionView(credentials: credentials)
        }
    }

    private static func makeCredentials() -> PhoneCredentials {
        #if DEBUG
        if ScreenshotMode.isOn { return ScreenshotMode.credentials() }
        #endif
        return PhoneCredentials.live()
    }
}
