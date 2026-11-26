import XCTest
@testable import Fast

/// What leaves the Mac for the site, field by field, as docs/privacy.md says:
/// the day's count holds the two IDs and the update channel alone, the kept
/// boosts their Store ids alone, the update check its build, macOS, the running
/// slice, the channel and whether it is the day's first, plus a failure once,
/// the hang counts their buckets.
@MainActor
final class ActivityRequestTests: XCTestCase {
    private let site = URL(string: "https://yetanotherbrowser.com/")!
    private let id = "6f1c0d2e-3b4a-4c5d-8e6f-7a8b9c0d1e2f"

    private func body(_ request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
    }

    func testTheDaysCountIsTheTwoIDsAndTheChannelAlone() throws {
        let person = "0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d"
        let request = Activity.dayRequest(site: site, id: id, person: person, nightly: false)
        XCTAssertEqual(request.url?.absoluteString, "https://yetanotherbrowser.com/api/activity")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(try body(request).keys.sorted(), ["channel", "id", "person"])
        XCTAssertEqual(try body(request)["id"] as? String, id)
        XCTAssertEqual(try body(request)["person"] as? String, person)
        XCTAssertEqual(try body(request)["channel"] as? String, "stable")
        let nightly = Activity.dayRequest(site: site, id: id, person: person, nightly: true)
        XCTAssertEqual(try body(nightly)["channel"] as? String, "nightly")
        XCTAssertTrue(SyncShapes.syncs(Activity.personKey))
        XCTAssertFalse(SyncShapes.syncs("activity.installation"))
        XCTAssertFalse(request.httpShouldHandleCookies)
        XCTAssertNil(request.url?.query)
    }

    func testKeptBoostsGoWithoutTheID() throws {
        let request = Activity.keptRequest(site: site, ids: ["hn-readable", "youtube-no-shorts"])
        XCTAssertEqual(request.url?.absoluteString, "https://yetanotherbrowser.com/api/kept")
        XCTAssertEqual(try body(request).keys.sorted(), ["kept"])
        XCTAssertEqual(try body(request)["kept"] as? [String], ["hn-readable", "youtube-no-shorts"])
        let raw = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        XCTAssertFalse(raw.contains(id))
        XCTAssertFalse(request.httpShouldHandleCookies)
        XCTAssertNil(request.url?.query)
        XCTAssertEqual(Set((request.allHTTPHeaderFields ?? [:]).keys), ["Content-Type", "Cache-Control"])
    }

    func testEachBoostAtMostOnceInThirtyDays() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let day: TimeInterval = 24 * 60 * 60
        let sent: [String: Double] = [
            "fresh": now.timeIntervalSince1970 - 2 * day,
            "due": now.timeIntervalSince1970 - 30 * day,
        ]
        XCTAssertEqual(Activity.keptDue(["fresh", "due", "new", "new"], sent: sent, now: now), ["due", "new"])
        XCTAssertEqual(Activity.keptDue([], sent: sent, now: now), [])
        XCTAssertEqual(Activity.keptDue((0..<300).map { "b\($0)" }, sent: [:], now: now).count, 100)

        let after = Activity.keptSent(["due", "new"], into: sent.merging(["gone": now.timeIntervalSince1970 - 90 * day]) { $1 },
                                      at: now)
        XCTAssertEqual(after, ["fresh": sent["fresh"]!, "due": now.timeIntervalSince1970, "new": now.timeIntervalSince1970])
        XCTAssertEqual(Activity.keptDue(["fresh", "due", "new"], sent: after, now: now.addingTimeInterval(day)), [])
    }

    /// The hang counts' body (FieldHangs) and the update check (Updater)
    /// beside the others, so README's list is held in one place.
    func testHangCountsAndTheUpdateCheckHoldNoID() throws {
        let hangs = FieldHangs.body([FieldHangs.Bucket(from: 250, to: 500, count: 2)], version: "0.0.9", build: 7, system: "26.0")
        XCTAssertEqual(hangs.keys.sorted(), ["buckets", "build", "os", "version"])
        let check = URLComponents(url: Updater.checkURL(feed: site.appendingPathComponent("appcast.json"), build: 7,
                                                        system: "26.0", failure: "download"),
                                  resolvingAgainstBaseURL: false)
        XCTAssertEqual(check?.queryItems?.map(\.name), ["b", "os", "fail"])
    }

    // MARK: docs/privacy.md

    /// One row of "What Yab sends" in docs/privacy.md, found by its first cell.
    private func privacyRow(_ request: String) throws -> String {
        let page = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/privacy.md")
        let text = try String(contentsOf: page, encoding: .utf8)
        return try XCTUnwrap(text.split(separator: "\n").first { $0.hasPrefix("| \(request)") }.map(String.init),
                             "docs/privacy.md has no row for \(request)")
    }

    /// The page says each request "holds what is listed here and nothing
    /// more". Every query item the update check sends with all of today's
    /// options on is named in its row, as `name` or `name=value`, so a new item
    /// fails here until the page says it. A new option needs a line here too.
    func testPrivacyPageNamesEveryItemOfTheUpdateCheck() throws {
        let row = try privacyRow("Update check")
        let check = Updater.checkURL(feed: site.appendingPathComponent("appcast.json"), build: 7, system: "26.0",
                                     failure: "download", again: true, nightly: true, arch: "arm64")
        let names = try XCTUnwrap(URLComponents(url: check, resolvingAgainstBaseURL: false)?.queryItems).map(\.name)
        XCTAssertEqual(Set(names), ["b", "os", "arch", "fail", "again", "channel"])
        for name in names {
            XCTAssertTrue(row.contains("`\(name)`") || row.contains("`\(name)="),
                          "docs/privacy.md, Update check, doesn't name `\(name)`")
        }
    }

    /// The same for the day's count: every key of the Mac's body is in the
    /// row's first `{…}`, the Mac's, not in the iPhone's sentence after it.
    func testPrivacyPageNamesEveryKeyOfTheDaysCount() throws {
        let row = try privacyRow("Daily count")
        let open = try XCTUnwrap(row.range(of: "`{"), "docs/privacy.md, Daily count, has no `{…}` body")
        let close = try XCTUnwrap(row.range(of: "}`", range: open.upperBound..<row.endIndex))
        let mac = row[open.upperBound..<close.lowerBound]
        let request = Activity.dayRequest(site: site, id: id, person: "0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d", nightly: true)
        for key in try body(request).keys {
            XCTAssertTrue(mac.contains("\"\(key)\""), "docs/privacy.md, Daily count, doesn't name \"\(key)\" in the Mac's body")
        }
    }
}
