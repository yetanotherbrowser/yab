import Foundation
import Testing
import WebKit
@testable import Fast

// Tabs ask WebKit for Global Privacy Control (Web.globalPrivacyControl).
// WebKit has the setting from macOS 27; before that there is nothing to read.
@MainActor
struct GlobalPrivacyControlTests {
    private func sends(_ config: WKWebViewConfiguration) -> Bool? {
        let preferences: WKWebpagePreferences = config.defaultWebpagePreferences
        let selector = NSSelectorFromString("globalPrivacyControlEnabled")
        guard preferences.responds(to: selector) else { return nil }
        typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(preferences.method(for: selector), to: Getter.self)(preferences, selector)
    }

    @Test func everyTabSendsGlobalPrivacyControl() {
        guard sends(WKWebViewConfiguration()) != nil else { return }
        #expect(sends(WKWebViewConfiguration()) == false, "WebKit's own default, off")
        #expect(sends(Web.configuration()) == true)
        #expect(sends(Web.configuration(shy: true)) == true)
        #expect(sends(Web.configuration(store: .nonPersistent(), extensions: false)) == true)
    }
}
