import Foundation
import Testing
@testable import Fast

/// What one pass of the cookie step costs on the main thread, a host's two
/// jars agreeing as they nearly always do: hashes made and time taken, the
/// way main read them (every cookie hashed in the plan and again in the
/// book) against now. Printed for the measurements; only counts are checked.
struct CookieStepHarnessTests {
    private func jar(_ count: Int) -> [String: ChromiumDRMCookie] {
        Dictionary(uniqueKeysWithValues: (0..<count).map { n in
            let made = ChromiumDRMCookie(HTTPCookie(properties: [.name: "c\(n)", .value: String(repeating: "v", count: 40) + "\(n)",
                .domain: ".harness.test", .path: "/", .expires: Date(timeIntervalSince1970: 2_000_000_000)])!)
            return (made.key, made)
        })
    }

    @Test func aQuietPassHashesNothing() {
        let cookies = 300, passes = 20
        let both = jar(cookies)
        var book = ChromiumCookieBook()
        let scope = book.scope(host: "harness.test", seen: [])
        book.record(scope, webKit: both, chromium: both)
        let made = book.printsMade
        var saves = 0
        let began = Date()
        for _ in 0..<passes {
            _ = ChromiumDRMCookieMerge.plan(webKit: both, chromium: both, previous: book.slice(scope))
            if book.record(scope, webKit: both, chromium: both) { saves += 1 }
        }
        let now = Date().timeIntervalSince(began) / Double(passes)
        let oldBegan = Date()
        for _ in 0..<passes {
            for _ in 0..<2 {
                _ = ChromiumSwitchCookieLedger.fingerprint(both)
                _ = ChromiumSwitchCookieLedger.fingerprint(both)
            }
        }
        let old = Date().timeIntervalSince(oldBegan) / Double(passes)
        print(String(format: "cookie step harness: %d cookies, a pass hashed %d before (%.2f ms), %d now (%.2f ms), saves %d of %d passes",
                     cookies, cookies * 4, old * 1000, book.printsMade - made, now * 1000, saves, passes))
        #expect(book.printsMade == made && saves == 0)
    }
}
