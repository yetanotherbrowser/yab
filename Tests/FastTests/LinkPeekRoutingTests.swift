import AppKit
import Testing
@testable import Fast

struct LinkPeekRoutingTests {
    private let pinned = URL(string: "https://mail.google.com/mail/u/0/")!

    @MainActor @Test func pinnedLinksToAnotherSitePeek() {
        let link = URL(string: "https://calendar.example/event")!
        #expect(Browser.shouldPeek(link, from: pinned, pinned: true, flags: [], button: 0))
        #expect(!Browser.shouldPeek(link, from: pinned, pinned: false, flags: [], button: 0))
    }

    @MainActor @Test func pinnedLinksWithinTheSiteStayThere() {
        let link = URL(string: "https://accounts.google.com/signin")!
        #expect(!Browser.shouldPeek(link, from: pinned, pinned: true, flags: [], button: 0))
        #expect(!Browser.shouldPeek(link, from: URL(string: "about:blank"), pinned: true, flags: [], button: 0))
    }

    @MainActor @Test func clickModifiersKeepTheirExistingMeaning() {
        let link = URL(string: "https://calendar.example/event")!
        #expect(Browser.shouldPeek(link, from: pinned, pinned: false, flags: .shift, button: 0))
        #expect(!Browser.shouldPeek(link, from: pinned, pinned: true, flags: .command, button: 0))
        #expect(!Browser.shouldPeek(link, from: pinned, pinned: true, flags: [.command, .shift], button: 0))
        #expect(!Browser.shouldPeek(link, from: pinned, pinned: true, flags: [], button: 4))
        #expect(!Browser.shouldPeek(link, from: pinned, pinned: false, flags: .shift, button: 4))
    }

    @MainActor @Test func configuredOptionClickTakesPeekPriorityWithoutRemappingOtherKeys() {
        let link = URL(string: "https://calendar.example/event")!
        // This is the policy called before Option-click's Split fallback.
        #expect(!Browser.shouldPeek(link, from: pinned, pinned: false, flags: .option, button: 0))
        #expect(Browser.shouldPeek(link, from: pinned, pinned: false, flags: .option, button: 0, peekClick: .option))
        #expect(!Browser.shouldPeek(link, from: pinned, pinned: false, flags: .shift, button: 0, peekClick: .option))
        for flags: NSEvent.ModifierFlags in [.command, [.command, .option], [.option, .shift], .control] {
            #expect(!Browser.shouldPeek(link, from: pinned, pinned: true, flags: flags, button: 0, peekClick: .option))
        }
        #expect(!Browser.shouldPeek(link, from: pinned, pinned: false, flags: .option, button: 4, peekClick: .option))
        #expect(Browser.shouldPeek(link, from: pinned, pinned: true, flags: [], button: 0, peekClick: .option))
        #expect(LinkStatus.act(.option) == "in Split View")
        #expect(LinkStatus.act(.option, peekClick: .option) == "in a peek")
        #expect(LinkStatus.act(.shift, peekClick: .option) == nil)
        #expect(LinkStatus.act([.command, .shift], peekClick: .option) == "in a new tab and go to it")
        #expect(LinkCardRules.eligible(flags: .option, selection: false, peekClick: .option))
        #expect(!LinkCardRules.eligible(flags: .shift, selection: false, peekClick: .option))
        #expect(!LinkCardRules.eligible(flags: .option, selection: true, peekClick: .option))
    }

    @Test func peekClickChoicePersistsInItsOwnDefaultsWithoutChangingTheDefault() throws {
        let name = "peek-click-\(UUID().uuidString)"
        let store = try #require(UserDefaults(suiteName: name))
        defer { store.removePersistentDomain(forName: name) }
        #expect(PeekClick.read(in: store) == .shift)
        PeekClick.option.save(in: store)
        #expect(PeekClick.read(in: store) == .option)
        store.set("command", forKey: PeekClick.key)
        #expect(PeekClick.read(in: store) == .shift)
        PeekClick.shift.save(in: store)
        #expect(PeekClick.read(in: store) == .shift)
    }

    /// WebKit gives a navigation action's button as a mask (feedback #79):
    /// 1 left, 2 right, 4 middle, as webkit_probe.swift measured.
    @Test func middleClickIsWebKitsMaskNotAppKitsNumber() {
        #expect(Browser.middleClick(4))
        #expect(Browser.middleClick(4 | 1))
        #expect(!Browser.middleClick(0))
        #expect(!Browser.middleClick(1))
        #expect(!Browser.middleClick(2))
    }
    /// A site opening the link itself (X, a YouTube embed) calls window.open
    /// with no modifiers in the action: the ⌘ held after a click is the request.
    private func action(_ kind: PageAction.Kind, flags: NSEvent.ModifierFlags = []) -> PageAction {
        PageAction(request: URLRequest(url: URL(string: "https://example.com")!), kind: kind, targetIsMainFrame: nil, source: nil,
                   modifierFlags: flags, buttonNumber: 0, shouldPerformDownload: false, userInitiated: true)
    }

    @Test func scriptedWindowFollowsTheCommandHeldAfterAClick() {
        #expect(Browser.modifiedForeground(for: action(.other), isPopup: false, held: [.command], afterClick: true) == false)
        #expect(Browser.modifiedForeground(for: action(.other), isPopup: false, held: [.command, .shift], afterClick: true) == true)
        #expect(Browser.modifiedForeground(for: action(.other), isPopup: false, held: [], afterClick: true) == nil)
        #expect(Browser.modifiedForeground(for: action(.other), isPopup: true, held: [.command], afterClick: true) == nil)
        #expect(Browser.modifiedForeground(for: action(.other), isPopup: false, held: [.command], afterClick: false) == nil)
        #expect(Browser.modifiedForeground(for: action(.linkActivated, flags: [.command]), isPopup: false, held: [], afterClick: false) == false)
    }

    @MainActor @Test func pinnedOAuthAndSignInLinksStayInTabToPreserveSessionStorage() {
        let replit = URL(string: "https://replit.com/login?source=home&goto=%2F%7E")!
        let oauthLinks = [
            URL(string: "https://accounts.google.com/o/oauth2/v2/auth?client_id=123&redirect_uri=https%3A%2F%2Freplit.com%2F__%2Fauth%2Fhandler")!,
            URL(string: "https://github.com/login/oauth/authorize?client_id=abc&redirect_uri=https%3A%2F%2Freplit.com%2Fcallback")!,
            URL(string: "https://replit.firebaseapp.com/__/auth/handler?apiKey=key&authType=signInViaRedirect")!,
            URL(string: "https://idp.example.com/authorize?client_id=abc&response_type=code&redirect_uri=https%3A%2F%2Freplit.com%2Fcb")!,
            URL(string: "https://sso.example.com/idp?SAMLRequest=payload")!
        ]
        for destination in oauthLinks {
            #expect(!Browser.shouldPeek(destination, from: replit, pinned: true, flags: [], button: 0))
            #expect(Browser.shouldPeek(destination, from: replit, pinned: true, flags: .shift, button: 0))
        }
    }
}
