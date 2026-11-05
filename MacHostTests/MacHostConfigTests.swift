import Foundation
import Testing

struct MacHostConfigTests {
    @Test func hostAppHasExpectedBundleIdentifier() {
        #expect(Bundle.main.bundleIdentifier == "com.alifu.lfremac.host")
    }

    @Test func hostAppRunsAsMenuBarAgent() {
        let isAgent = Bundle.main.object(forInfoDictionaryKey: "LSUIElement") as? Bool
        #expect(isAgent == true)
    }
}
