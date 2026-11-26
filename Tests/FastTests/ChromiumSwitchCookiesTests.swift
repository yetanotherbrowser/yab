import Foundation
import Testing
@testable import Fast

struct ChromiumSwitchCookiesTests {
    private func cookie(_ value: String) -> ChromiumDRMCookie {
        ChromiumDRMCookie(HTTPCookie(properties: [.name: "session", .value: value, .domain: "switch.test", .path: "/",
            .discard: "TRUE", .sameSitePolicy: "lax"])!)
    }

    @Test func restartRetainsBothDirectionsOfSignOut() throws {
        let saved = cookie("synthetic-account")
        let map = [saved.key: saved]
        let ledger = ChromiumSwitchCookieLedger(webKit: ChromiumSwitchCookieLedger.fingerprint(map),
                                                chromium: ChromiumSwitchCookieLedger.fingerprint(map))
        let restarted = try JSONDecoder().decode(ChromiumSwitchCookieLedger.self, from: JSONEncoder().encode(ledger))
        let webKitSignOut = ChromiumDRMCookieMerge.plan(webKit: [:], chromium: map, previous: restarted)
        #expect(webKitSignOut.toWebKit.isEmpty)
        #expect(webKitSignOut.toChromium.count == 1 && webKitSignOut.toChromium[0].cookie == nil)
        let chromiumSignOut = ChromiumDRMCookieMerge.plan(webKit: map, chromium: [:], previous: restarted)
        #expect(chromiumSignOut.toChromium.isEmpty)
        #expect(chromiumSignOut.toWebKit.count == 1 && chromiumSignOut.toWebKit[0].cookie == nil)
    }

    @Test func restartCopiesEditsAndKeepsTheExistingConflictPolicy() {
        let saved = cookie("before"), edited = cookie("after"), remote = cookie("concurrent")
        let hashes = ChromiumSwitchCookieLedger.fingerprint([saved.key: saved])
        let ledger = ChromiumSwitchCookieLedger(webKit: hashes, chromium: hashes)
        let plan = ChromiumDRMCookieMerge.plan(webKit: [saved.key: edited], chromium: [saved.key: remote], previous: ledger)
        #expect(plan.toWebKit.isEmpty)
        #expect(plan.toChromium.count == 1 && plan.toChromium[0].cookie == edited)
        let remoteOnly = ChromiumDRMCookieMerge.plan(webKit: [saved.key: saved], chromium: [saved.key: edited], previous: ledger)
        #expect(remoteOnly.toChromium.isEmpty)
        #expect(remoteOnly.toWebKit.count == 1 && remoteOnly.toWebKit[0].cookie == edited)
    }

    private func cookie(_ name: String, _ value: String = "one", domain: String, path: String = "/", session: Bool = false) -> ChromiumDRMCookie {
        var properties: [HTTPCookiePropertyKey: Any] = [.name: name, .value: value, .domain: domain, .path: path, .sameSitePolicy: "lax"]
        if session { properties[.discard] = "TRUE" } else { properties[.expires] = Date(timeIntervalSince1970: 2_000_000_000) }
        return ChromiumDRMCookie(HTTPCookie(properties: properties)!)
    }

    @Test func aRefusedCookieIsNeitherRetriedNorTakenForASignOut() {
        let refused = cookie("big", domain: "switch.test")
        var book = ChromiumCookieBook()
        let scope = book.scope(host: "switch.test", seen: [])
        book.record(scope, webKit: [refused.key: refused], chromium: [:])
        let plan = ChromiumDRMCookieMerge.plan(webKit: [refused.key: refused], chromium: [:], previous: book.slice(scope))
        #expect(plan.toChromium.isEmpty && plan.toWebKit.isEmpty)
        // Edited in WebKit it is a new cookie, and Chromium is asked again.
        let edited = cookie("big", "two", domain: "switch.test")
        let again = ChromiumDRMCookieMerge.plan(webKit: [refused.key: edited], chromium: [:], previous: book.slice(scope))
        #expect(again.toChromium.count == 1 && again.toChromium[0].cookie == edited)
    }

    @Test func aHostsSliceLeavesEveryOtherHostAlone() {
        let mine = cookie("a", domain: ".switch.test"), other = cookie("b", domain: "other.test"), deep = cookie("c", domain: "app.switch.test", path: "/deep")
        var book = ChromiumCookieBook()
        let all = [mine.key: mine, deep.key: deep]
        book.record(book.scope(host: "app.switch.test", seen: ["/deep"]), webKit: all, chromium: all)
        book.record(book.scope(host: "other.test", seen: []), webKit: [other.key: other], chromium: [other.key: other])
        // What was seen on a path is looked for on that path again.
        let scope = book.scope(host: "app.switch.test", seen: [])
        #expect(scope.paths == ["/", "/deep"])
        #expect(scope.urls.map(\.absoluteString) == ["https://app.switch.test/", "https://app.switch.test/deep"])
        let slice = book.slice(scope)
        #expect(Set(slice.webKit.keys) == [mine.key, deep.key])
        // The other host isn't read, so it isn't a sign-out.
        #expect(ChromiumDRMCookieMerge.plan(webKit: all, chromium: all, previous: slice).toWebKit.isEmpty)
        #expect(book.ledger.webKit[other.key] != nil)
        // A sign-out on one host stays a sign-out, the rest of the book as it was.
        let plan = ChromiumDRMCookieMerge.plan(webKit: [deep.key: deep], chromium: all, previous: slice)
        #expect(plan.toChromium.count == 1 && plan.toChromium[0].key == mine.key && plan.toChromium[0].cookie == nil)
        book.record(scope, webKit: [deep.key: deep], chromium: [deep.key: deep])
        #expect(book.ledger.webKit[mine.key] == nil && book.ledger.webKit[other.key] != nil)
    }

    @Test func aCookieOnAnotherPathIsNotReadSoNotDeleted() {
        let scope = ChromiumCookieScope(host: "switch.test", paths: ["/app"])
        #expect(scope.covers(cookie("a", domain: "switch.test", path: "/app").key))
        #expect(scope.covers(cookie("a", domain: "switch.test", path: "/").key))
        #expect(!scope.covers(cookie("a", domain: "switch.test", path: "/apple").key))
        #expect(!scope.covers(cookie("a", domain: "switch.test", path: "/other").key))
        #expect(!scope.covers(cookie("a", domain: "a.switch.test").key))
        #expect(scope.covers(cookie("a", domain: ".switch.test").key))
    }

    private func row(_ cookie: ChromiumDRMCookie) -> ChromiumCookieImportRow {
        ChromiumCookieImportRow(cookie: cookie, fingerprint: ChromiumSwitchCookieLedger.fingerprint(cookie), payload: cookie.chromium)
    }

    @Test func aNewHelpersLostSessionCookiesGoBackAndStayKnown() throws {
        // A new helper has lasting cookies only. WebKit's session copies go back
        // at once and the ledger is kept, so a sign-out after it is one.
        let session = cookie("sid", domain: "switch.test", session: true), lasting = cookie("keep", domain: "switch.test")
        let both = [session.key: session, lasting.key: lasting]
        var book = ChromiumCookieBook()
        let scope = book.scope(host: "switch.test", seen: [])
        book.record(scope, webKit: both, chromium: both)
        #expect(book.ledger.session == [session.key])
        let relaunched = ChromiumCookieBook(ledger: try JSONDecoder().decode(ChromiumSwitchCookieLedger.self, from: JSONEncoder().encode(book.ledger)))
        let lost = relaunched.lostWithHelper([row(session), row(lasting)])
        #expect(lost.back.map(\.cookie) == [session] && lost.forget.isEmpty)
        // Put back, then Chromium signs out on a hop nobody read yet: a deletion, never a copy back.
        let plan = ChromiumDRMCookieMerge.plan(webKit: both, chromium: [lasting.key: lasting], previous: relaunched.slice(scope))
        #expect(plan.toChromium.isEmpty)
        #expect(plan.toWebKit.count == 1 && plan.toWebKit[0].key == session.key && plan.toWebKit[0].cookie == nil)
    }

    @Test func aSessionCookieWebKitChangedOrTheJarsDisagreedOnIsNotPutBackAsItWas() {
        let agreed = cookie("sid", "one", domain: "switch.test", session: true), mine = cookie("own", "chromium", domain: "switch.test", session: true)
        var book = ChromiumCookieBook()
        let scope = book.scope(host: "switch.test", seen: [])
        let theirs = cookie("own", "webkit", domain: "switch.test", session: true)
        book.record(scope, webKit: [agreed.key: agreed, theirs.key: theirs], chromium: [agreed.key: agreed, mine.key: mine])
        // WebKit signed out of `sid` while Chromium was off: nothing to put back, and it stays known.
        let lost = book.lostWithHelper([row(theirs)])
        #expect(lost.back.isEmpty)
        // `own` held different values: Chromium's is gone, so both sides are forgotten.
        #expect(lost.forget == [mine.key])
        book.forget(lost.forget)
        #expect(book.ledger.webKit[mine.key] == nil && book.ledger.webKit[agreed.key] != nil)
    }

    @Test func aFarDateAndChromiumsCapAreOneCookie() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var far = cookie("a", domain: "switch.test"), capped = far
        far.expires = now.timeIntervalSince1970 + 800 * 86_400
        capped.expires = now.timeIntervalSince1970 + 400 * 86_400
        #expect(ChromiumDRMCookie.same(far, capped, now: now))
        var soon = capped
        soon.expires = now.timeIntervalSince1970 + 86_400
        #expect(!ChromiumDRMCookie.same(far, soon, now: now))
    }

    @Test func anImportRowMarksRefusedAndSessionCookies() {
        let session = cookie("sid", domain: "switch.test", session: true), lasting = cookie("keep", domain: "switch.test"), refused = cookie("big", domain: "switch.test")
        var book = ChromiumCookieBook()
        for (made, accepted) in [(session, true), (lasting, true), (refused, false)] {
            book.note(ChromiumCookieImportRow(cookie: made, fingerprint: "h", payload: .null), accepted: accepted)
        }
        book.finishImport()
        #expect(book.ledger.imported == true && book.ledger.session == [session.key])
        #expect(book.ledger.webKit[refused.key] != nil && book.ledger.chromium[refused.key] == nil)
    }

    @Test func aLedgerFromBeforeTheImportStillReads() throws {
        let old = try JSONDecoder().decode(ChromiumSwitchCookieLedger.self, from: Data(#"{"webKit":{"a":"b"},"chromium":{}}"#.utf8))
        #expect(old.imported == nil && old.webKit == ["a": "b"])
    }

    @Test func savedLedgerContainsNoCookieValuesAndIsPrivate() throws {
        let saved = cookie("synthetic-secret-not-for-ledger")
        let hashes = ChromiumSwitchCookieLedger.fingerprint([saved.key: saved])
        let ledger = ChromiumSwitchCookieLedger(webKit: hashes, chromium: hashes)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let file = folder.appendingPathComponent("cookie-ledger.json")
        defer { try? FileManager.default.removeItem(at: folder) }
        try ledger.save(to: file)
        let bytes = try Data(contentsOf: file)
        #expect(!String(decoding: bytes, as: UTF8.self).contains(saved.value))
        #expect(try JSONDecoder().decode(ChromiumSwitchCookieLedger.self, from: bytes) == ledger)
        #expect((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func aValueChangedOnBothSidesFollowsTheEngineThatUsedTheHostLast() {
        func cookie(_ value: String) -> ChromiumDRMCookie {
            ChromiumDRMCookie(HTTPCookie(properties: [.name: "token", .value: value, .domain: "a.test", .path: "/"])!)
        }
        let old = cookie("1"), seen = ChromiumSwitchCookieLedger.fingerprint(["k": old])
        let ledger = ChromiumSwitchCookieLedger(webKit: seen, chromium: seen)
        let both = (webKit: ["k": cookie("2")], chromium: ["k": cookie("3")])
        let chromiumLast = ChromiumDRMCookieMerge.plan(webKit: both.webKit, chromium: both.chromium, previous: ledger, usedLast: .chromium)
        #expect(chromiumLast.toWebKit.first?.cookie?.value == "3" && chromiumLast.toChromium.isEmpty)
        let webKitLast = ChromiumDRMCookieMerge.plan(webKit: both.webKit, chromium: both.chromium, previous: ledger, usedLast: .webKit)
        #expect(webKitLast.toChromium.first?.cookie?.value == "2" && webKitLast.toWebKit.isEmpty)
        // One side changed: it goes across whoever was last.
        let one = ChromiumDRMCookieMerge.plan(webKit: ["k": old], chromium: ["k": cookie("3")], previous: ledger, usedLast: .webKit)
        #expect(one.toWebKit.first?.cookie?.value == "3" && one.toChromium.isEmpty)
        // Nothing known yet: the WebKit sign-in, as ever.
        let first = ChromiumDRMCookieMerge.plan(webKit: both.webKit, chromium: both.chromium,
                                                previous: ChromiumSwitchCookieLedger(webKit: [:], chromium: [:]), usedLast: .chromium)
        #expect(first.toChromium.first?.cookie?.value == "2" && first.toWebKit.isEmpty)
    }

    // A session the site renews on every check (next-auth does): same value, new expiry.
    private func token(_ value: String, renewed: Double = 0) -> ChromiumDRMCookie {
        ChromiumDRMCookie(HTTPCookie(properties: [.name: "session-token", .value: value, .domain: "chat.test", .path: "/",
            .expires: Date(timeIntervalSince1970: 2_000_000_000 + renewed)])!)
    }

    private func agreed(_ cookie: ChromiumDRMCookie) -> ChromiumSwitchCookieLedger {
        let seen = ChromiumSwitchCookieLedger.fingerprint([cookie.key: cookie])
        return ChromiumSwitchCookieLedger(webKit: seen, chromium: seen)
    }

    @Test func aSignOutBeatsTheOtherEnginesRenewalOfThatSession() {
        let old = token("account-a"), renewed = token("account-a", renewed: 60)
        for usedLast in [PageEngineKind.webKit, .chromium, nil] {
            // Chromium signed out while the site, open in WebKit too, renewed it there.
            let plan = ChromiumDRMCookieMerge.plan(webKit: [old.key: renewed], chromium: [:], previous: agreed(old), usedLast: usedLast)
            #expect(plan.toChromium.isEmpty)
            #expect(plan.toWebKit.count == 1 && plan.toWebKit[0].cookie == nil)
            // And the other way round.
            let other = ChromiumDRMCookieMerge.plan(webKit: [:], chromium: [old.key: renewed], previous: agreed(old), usedLast: usedLast)
            #expect(other.toWebKit.isEmpty)
            #expect(other.toChromium.count == 1 && other.toChromium[0].cookie == nil)
        }
    }

    @Test func anotherAccountBeatsARenewalOfTheEndedOne() {
        let old = token("account-a"), renewed = token("account-a", renewed: 60), next = token("account-b")
        for usedLast in [PageEngineKind.webKit, .chromium, nil] {
            let plan = ChromiumDRMCookieMerge.plan(webKit: [old.key: renewed], chromium: [old.key: next], previous: agreed(old), usedLast: usedLast)
            #expect(plan.toChromium.isEmpty)
            #expect(plan.toWebKit.count == 1 && plan.toWebKit[0].cookie == next)
        }
    }

    @Test func aSignOutOfTheOldAccountLeavesANewSignInAlone() {
        let old = token("account-a"), next = token("account-b")
        // Signed out of A in Chromium while WebKit signed in to B.
        let plan = ChromiumDRMCookieMerge.plan(webKit: [old.key: next], chromium: [:], previous: agreed(old), usedLast: .chromium)
        #expect(plan.toWebKit.isEmpty)
        #expect(plan.toChromium.count == 1 && plan.toChromium[0].cookie == next)
    }

    @Test func aDeletionTheBridgeNeverSawIsStillADeletionAfterARelaunch() throws {
        // The last run ended with both jars signed in to A; Chromium signed out on
        // a hop the bridge hadn't read yet. The ledger is read back as written.
        let old = token("account-a")
        var book = ChromiumCookieBook()
        let scope = book.scope(host: "chat.test", seen: [])
        book.record(scope, webKit: [old.key: old], chromium: [old.key: old])
        let relaunched = ChromiumCookieBook(ledger: try JSONDecoder().decode(ChromiumSwitchCookieLedger.self, from: JSONEncoder().encode(book.ledger)))
        let plan = ChromiumDRMCookieMerge.plan(webKit: [old.key: old], chromium: [:], previous: relaunched.slice(scope))
        #expect(plan.toChromium.isEmpty)
        #expect(plan.toWebKit.count == 1 && plan.toWebKit[0].cookie == nil)
    }

    @Test func aLedgerOfWholePrintsReadsAsBefore() {
        // Before November 2026 a print was the whole cookie's hash alone.
        let old = token("account-a")
        let whole = ChromiumSwitchCookieLedger.whole(ChromiumSwitchCookieLedger.fingerprint(old))!
        #expect(!whole.contains(":") && whole.count == 64)
        #expect(ChromiumSwitchCookieLedger.value(whole) == nil)
        let ledger = ChromiumSwitchCookieLedger(webKit: [old.key: whole], chromium: [old.key: whole])
        // Unchanged on both sides is no change; one side's edit goes over.
        #expect(ChromiumDRMCookieMerge.plan(webKit: [old.key: token("account-b")], chromium: [old.key: old], previous: ledger).toChromium.count == 1)
        let other = ChromiumDRMCookieMerge.plan(webKit: [old.key: old], chromium: [old.key: token("account-c")], previous: ledger)
        #expect(other.toChromium.isEmpty && other.toWebKit.count == 1)
    }

    @Test func aPrintHoldsNoValue() {
        let secret = token("synthetic-secret-not-for-ledger")
        let print = ChromiumSwitchCookieLedger.fingerprint(secret)
        #expect(!print.contains(secret.value))
        #expect(ChromiumSwitchCookieLedger.value(print)?.count == 16)
        #expect(ChromiumSwitchCookieLedger.value(print) == ChromiumSwitchCookieLedger.value(ChromiumSwitchCookieLedger.fingerprint(token("synthetic-secret-not-for-ledger", renewed: 5))))
    }

    @Test func aHostChromiumStillOwesClearingTakesNothingFromIt() {
        // Clear Data emptied WebKit; Chromium's clear failed and is owed. Its
        // script cookie must not come back, though nothing knew of it yet.
        let account = cookie("account", "old", domain: "switch.test", session: true), gone = token("account-a")
        let plan = ChromiumDRMCookieMerge.plan(webKit: [:], chromium: [account.key: account, gone.key: gone],
                                               previous: ChromiumSwitchCookieLedger(webKit: [:], chromium: [:])).owingClearing()
        #expect(plan.toWebKit.isEmpty)
        // A deletion still goes: what Chromium dropped, WebKit drops.
        let deletion = ChromiumDRMCookieMerge.plan(webKit: [gone.key: gone], chromium: [:], previous: agreed(gone)).owingClearing()
        #expect(deletion.toWebKit.count == 1 && deletion.toWebKit[0].cookie == nil)
    }

    // The step reads a host open on both engines every few seconds; most
    // passes find both jars as they were.
    private func jar(_ count: Int, value: String = "v") -> [String: ChromiumDRMCookie] {
        Dictionary(uniqueKeysWithValues: (0..<count).map { n in
            let made = cookie("c\(n)", value + "\(n)", domain: ".switch.test")
            return (made.key, made)
        })
    }

    @Test func aHostReadAgainUnchangedIsNeitherHashedNorSavedAgain() {
        var book = ChromiumCookieBook()
        let scope = book.scope(host: "switch.test", seen: [])
        let both = jar(40)
        let changed1 = book.record(scope, webKit: both, chromium: both)
        #expect(changed1)
        let made = book.printsMade
        let ledger = book.ledger
        for _ in 0..<5 {
            let changed = book.record(scope, webKit: both, chromium: both)
            #expect(!changed)
        }
        #expect(book.printsMade == made && book.ledger == ledger)
        // One cookie rotated in Chromium: that one is hashed, and it is a change.
        var rotated = both
        let key = cookie("c7", "v7", domain: ".switch.test").key
        rotated[key]?.value = "rotated"
        let changed2 = book.record(scope, webKit: both, chromium: rotated)
        #expect(changed2)
        #expect(book.printsMade == made + 1)
        #expect(book.ledger.chromium[key] != ledger.chromium[key] && book.ledger.webKit == ledger.webKit)
        // A deletion is a change too, and what the book holds matches a book made afresh.
        rotated[key] = nil
        let changed3 = book.record(scope, webKit: both, chromium: rotated)
        #expect(changed3)
        var fresh = ChromiumCookieBook()
        fresh.record(scope, webKit: both, chromium: rotated)
        #expect(book.ledger == fresh.ledger)
    }

    @Test func aSessionCookieEndingIsAChange() {
        var book = ChromiumCookieBook()
        let scope = book.scope(host: "switch.test", seen: [])
        let session = cookie("sid", domain: "switch.test", session: true)
        let changed4 = book.record(scope, webKit: [session.key: session], chromium: [session.key: session])
        #expect(changed4)
        #expect(book.ledger.session == [session.key])
        let changed5 = book.record(scope, webKit: [session.key: session], chromium: [:])
        #expect(changed5)
        #expect(book.ledger.session == nil)
    }

    @Test func aPlanHashesOnlyTheKeysTheJarsDisagreeOn() {
        let both = jar(40)
        var other = both
        let key = cookie("c3", "v3", domain: ".switch.test").key
        other[key]?.value = "edited"
        let previous = ChromiumSwitchCookieLedger(webKit: ChromiumSwitchCookieLedger.fingerprint(both),
                                                  chromium: ChromiumSwitchCookieLedger.fingerprint(both))
        var hashed: [String] = []
        let plan = ChromiumDRMCookieMerge.plan(webKit: both, chromium: other, previous: previous, fingerprint: {
            hashed.append($0.key)
            return ChromiumSwitchCookieLedger.fingerprint($0)
        })
        #expect(hashed == [key, key])
        #expect(plan.toWebKit.count == 1 && plan.toWebKit[0].cookie?.value == "edited" && plan.toChromium.isEmpty)
        hashed = []
        _ = ChromiumDRMCookieMerge.plan(webKit: both, chromium: both, previous: previous, fingerprint: {
            hashed.append($0.key)
            return ChromiumSwitchCookieLedger.fingerprint($0)
        })
        #expect(hashed.isEmpty)
    }

    @Test func theStepKeepsPaceOnlyWhileSomeoneIsLooking() {
        typealias Step = ChromiumDRMCookies
        // A host open on both engines keeps the 3 seconds whatever else holds:
        // a longer wait is a longer window for both jars to change at once,
        // which the merge then settles by who used the host last, not by
        // which change came last.
        for active in [true, false] {
            for shown in [true, false] {
                for saving in [true, false] {
                    #expect(Step.stepEvery(shared: true, active: active, shown: shown, saving: saving) == 3)
                }
            }
        }
        // Only Chromium's hosts: quick while someone looks, slower otherwise,
        // slower still while saving power, never stopped.
        #expect(Step.stepEvery(shared: false, active: true, shown: true, saving: false) == 3)
        #expect(Step.stepEvery(shared: false, active: false, shown: true, saving: false) == 30)
        #expect(Step.stepEvery(shared: false, active: true, shown: false, saving: false) == 30)
        #expect(Step.stepEvery(shared: false, active: true, shown: true, saving: true) == 60)
        #expect(Step.stepEvery(shared: false, active: false, shown: false, saving: true) == 60)
    }

    @Test func aLedgerSaveThatFailedIsOwedUntilOneLands() {
        var saves = ChromiumLedgerSaves()
        #expect(!saves.owed)
        saves.edited()
        // The write failed (a full disk): still owed, so the next read saves again.
        #expect(saves.owed)
        let older = saves.edits
        saves.edited()
        // A save of the ledger as it was before the last edit landed: the last edit is still owed.
        saves.wrote(older)
        #expect(saves.owed)
        saves.wrote(saves.edits)
        #expect(!saves.owed)
        // Nothing new: nothing is written again.
        #expect(!saves.owed)
    }

    @Test func aHostAboutToOpenOnTheOtherEngineCountsAsShared() {
        typealias Step = ChromiumDRMCookies
        #expect(!Step.shares(chromium: ["a.test"], webKit: ["b.test"], adding: []))
        #expect(Step.shares(chromium: ["a.test"], webKit: ["a.test"], adding: []))
        // A WebKit tab's first request to a host Chromium has open: its page has no address yet.
        #expect(Step.shares(chromium: ["a.test"], webKit: [], adding: [("a.test", .webKit)]))
        #expect(Step.shares(chromium: [], webKit: ["a.test"], adding: [("a.test", .chromium)]))
        #expect(!Step.shares(chromium: ["a.test"], webKit: [], adding: [("a.test", .chromium)]))
        // Several on their way: any one of them shared is enough.
        #expect(Step.shares(chromium: ["a.test"], webKit: [], adding: [("b.test", .webKit), ("a.test", .webKit)]))
        // Both engines' first requests to one new host, neither page there yet.
        #expect(Step.shares(chromium: [], webKit: [], adding: [("n.test", .webKit), ("n.test", .chromium)]))
        #expect(!Step.shares(chromium: [], webKit: [], adding: [("n.test", .webKit), ("m.test", .chromium)]))
    }

    @MainActor @Test func ledgerSavesLandInTheOrderTheyStartAndTheLastIsTheNewest() async throws {
        final class Box: @unchecked Sendable {
            var ledger = ChromiumSwitchCookieLedger(webKit: ["a": "1"], chromium: [:])
            var written: [Int] = []
            var started = false
        }
        let box = Box()
        let writer = ChromiumLedgerWriter(ledger: { box.ledger }) { ledger in
            await MainActor.run { box.started = true }
            // The first save is the slow one: if saves overlapped, it would land last.
            if ledger.webKit.count == 1 { try await Task.sleep(for: .milliseconds(300)) }
            await MainActor.run { box.written.append(ledger.webKit.count) }
        }
        writer.edited()
        let first = Task { @MainActor in try await writer.save() }
        while !box.started { await Task.yield() }
        box.ledger.webKit["b"] = "2"
        writer.edited()
        try await writer.save()
        try await first.value
        #expect(box.written.last == 2)
        #expect(!writer.owed)
    }

    @MainActor @Test func aFailedLedgerSaveIsOwed() async {
        struct Full: Error {}
        let writer = ChromiumLedgerWriter(ledger: { ChromiumSwitchCookieLedger(webKit: [:], chromium: [:]) }) { _ in throw Full() }
        writer.edited()
        await #expect(throws: Full.self) { try await writer.save() }
        #expect(writer.owed)
    }

    @MainActor @Test func aSaveWhoseBridgeIsGoneWritesNothing() async throws {
        var writes = 0
        let writer = ChromiumLedgerWriter(ledger: { nil }) { _ in writes += 1 }
        writer.edited()
        try await writer.save()
        #expect(writes == 0)
    }

    @MainActor @Test func aFailedSaveIsTriedAgainOnlyAfterARest() async {
        struct Full: Error {}
        var now = Date(timeIntervalSince1970: 1000)
        let writer = ChromiumLedgerWriter(ledger: { ChromiumSwitchCookieLedger(webKit: [:], chromium: [:]) }, clock: { now }) { _ in throw Full() }
        writer.edited()
        #expect(writer.due)
        await #expect(throws: Full.self) { try await writer.save() }
        // A full disk: not every read of a host writes the whole ledger again.
        #expect(writer.owed && !writer.due)
        now = now.addingTimeInterval(ChromiumLedgerWriter.rest)
        #expect(writer.due)
    }

    @Test func chromiumsOwnHostsGetTheirTurnAsOftenAsTheStepAllows() {
        typealias Step = ChromiumDRMCookies
        // At the quick pace, every fifth pass, 15 seconds, as on main.
        #expect((1...10).filter { Step.roundDue(pass: $0, wait: 3) } == [5, 10])
        // At a slower pace every pass takes them: 30 or 60 seconds, not five times that.
        #expect((1...3).allSatisfy { Step.roundDue(pass: $0, wait: 30) })
        #expect((1...3).allSatisfy { Step.roundDue(pass: $0, wait: 60) })
    }

    @MainActor @Test func aLedgerAlreadyWrittenIsNotWrittenAgain() async throws {
        final class Count: @unchecked Sendable { var writes = 0 }
        let count = Count()
        let writer = ChromiumLedgerWriter(ledger: { ChromiumSwitchCookieLedger(webKit: [:], chromium: [:]) }) { _ in
            await MainActor.run { count.writes += 1 }
        }
        writer.edited()
        try await writer.save()
        // A read that changed nothing, its save asked for while the last one was in flight.
        try await writer.save()
        #expect(count.writes == 1)
    }
}
