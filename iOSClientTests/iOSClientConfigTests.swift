import Foundation
import Testing

struct iOSClientConfigTests {
    @Test func clientAppHasExpectedBundleIdentifier() {
        #expect(Bundle.main.bundleIdentifier == "com.alifu.lfremac.client")
    }

    @Test func clientAppDeclaresBonjourService() {
        let services = Bundle.main.object(forInfoDictionaryKey: "NSBonjourServices") as? [String]
        #expect(services?.contains("_lfremac._tcp") == true)
    }
}
