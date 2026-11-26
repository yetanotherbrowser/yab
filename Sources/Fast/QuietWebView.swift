import AppKit
import WebKit

/// A web view that keeps quiet about keys its page didn't use. WebKit sends
/// such a key back up the responder chain, the same event, a second time,
/// where nothing takes it and macOS plays its "can't do that" sound.
/// Editors that put the text in themselves (X's reply box, anything built on
/// Draft.js) leave WebKit thinking their keys unused, so typing into them
/// beeped; so does a game in an extension's popup that moves on its own
/// keydown without preventDefault (Stacker's arrows). Safari keeps those
/// quiet, and so does this view. The app's own shortcuts never get this far:
/// its key monitor takes them before the page sees the key.
class QuietWebView: WKWebView {
    /// The last keys handed to the page. More than one: a key held down
    /// repeats faster than WebKit answers, so the next press is handed
    /// before the one before it comes back (a game's arrows).
    private var handed: [NSEvent] = []
    /// How many came back unused and were kept quiet, for the bench.
    static var quieted = 0

    /// Arrows, Home, End and the page keys carry function flags, so AppKit
    /// offers them as key equivalents first, and WebKit takes them for the
    /// page there, never in `keyDown`. One the page leaves unused (a player
    /// that seeks on its own keydown without preventDefault, a page with
    /// nowhere to scroll) comes back to `keyDown` all the same, so it is
    /// marked as handed here too. Only a key WebKit took: one it passes on
    /// still reaches `keyDown` for the first time. ⌘ and ⌃ are left to beep
    /// as anywhere else when nothing has them.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let taken = super.performKeyEquivalent(with: event)
        if taken, event.type == .keyDown, window?.firstResponder === self,
           event.modifierFlags.isDisjoint(with: [.command, .control]) {
            hand(event)
        }
        return taken
    }

    override func keyDown(with event: NSEvent) {
        if let index = handed.firstIndex(where: { Self.same($0, event) }) {
            handed.remove(at: index)
            Self.quieted += 1
            return
        }
        hand(event)
        super.keyDown(with: event)
    }

    private func hand(_ event: NSEvent) {
        handed.append(event)
        if handed.count > 16 { handed.removeFirst() }
    }

    /// The same key press: the event WebKit sends back is the one it was
    /// given, and no two presses share a timestamp.
    static func same(_ one: NSEvent, _ other: NSEvent) -> Bool {
        one === other || (one.timestamp == other.timestamp && one.keyCode == other.keyCode && one.type == other.type)
    }
}
