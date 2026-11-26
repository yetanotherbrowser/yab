import AppKit
import Testing
@testable import Fast

struct AppIconsTests {
    /// App Icon asks for every icon's picture in each pass of its row. A
    /// new charm each time was drawn again, at full size on the main
    /// thread, as the row turned.
    @MainActor @Test func theCharmsPictureIsKeptUntilTheCharmChanges() {
        let settings = Store.settings
        let was = settings.string(forKey: "invite.charm.left")
        defer { settings.set(was, forKey: "invite.charm.left") }
        settings.set("mint", forKey: "invite.charm.left")
        let mint = AppIconStyle.picture(.charm, dark: false)
        #expect(AppIconStyle.picture(.charm, dark: false) === mint)
        settings.set("rose", forKey: "invite.charm.left")
        let rose = AppIconStyle.picture(.charm, dark: false)
        #expect(rose !== mint)
        #expect(AppIconStyle.picture(.charm, dark: false) === rose)
    }
}
