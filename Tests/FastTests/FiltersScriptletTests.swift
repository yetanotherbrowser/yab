import WebKit
import XCTest
@testable import Fast

// Scriptlets (##+js), domain.* entities, !#if blocks and the count of what
// is left out by reason: what Filters reads of the lists beyond WebKit's
// own rules.

final class FiltersScriptletTests: XCTestCase {
    private func scriptlets(_ lines: [String]) -> Filters.Scriptlets {
        Filters.convert([lines.joined(separator: "\n")]).scriptlets
    }

    // MARK: real list lines (one popup-heavy site)

    /// The lines the lists hold for yts.gg (uBlock filters, EasyList), as
    /// they were saved on 2026-11-15.
    private let yts = [
        "2ddl.*,allitebooks.*,bonstreams.net,yts.*,zooqle.*##+js(nowebrtc)",
        "yts.*##+js(aeld, , _0x)",
        "yts.*##+js(aopr, runAdblock)",
        "yts.*##+js(nowoif)",
        "yts.*##+js(nostif, \"admc\")",
        "yts.*##+js(acs, document.createElement, admc)",
        "yts.*##+js(aopw, Adcash)",
        "yts.*##^script:has-text(admc)",
        "*/script/clock.js$script,domain=yts.*",
        "yts.*##.cborz-bordered",
        "yts.*###dontfoid",
    ]

    func testYtsScriptletsAreKept() {
        let rules = Filters.convert([yts.joined(separator: "\n")])
        XCTAssertEqual(rules.scriptlets.calls, [
            ["aeld", "", "_0x"], ["aopr", "runAdblock"], ["nowoif"], ["nostif", "admc"],
            ["acs", "document.createElement", "admc"], ["aopw", "Adcash"],
        ])
        XCTAssertEqual(rules.scriptlets.hosts, ["yts.*": [0, 1, 2, 3, 4, 5]])
        XCTAssertEqual(rules.dropped["scriptlet-unsupported"], 1)
        XCTAssertEqual(rules.dropped["entity-domain"], 1)
        XCTAssertEqual(rules.dropped["html-filtering"], 1)
    }

    func testYtsHidingIsKeptForTheEntity() {
        let rules = Filters.convert([yts.joined(separator: "\n")])
        let filter = "^[a-z-]+://([^/]*\\.)?yts\\.[a-z0-9-]+[/:]"
        XCTAssertEqual(rules.blocks.filter { $0.action == .hide("#dontfoid") }.map(\.filter), [filter])
        XCTAssertEqual(rules.blocks.filter { $0.action == .hide(".cborz-bordered") }.map(\.filter), [filter])
        XCTAssertEqual(Filters.onEntity("yts"), filter)
    }

    func testTableIsExact() {
        let table = Filters.convert([yts.joined(separator: "\n")]).scriptlets.table()
        XCTAssertEqual(table, #"{"v":2,"calls":"aeld\t\t_0x\naopr\trunAdblock\nnowoif\nnostif\tadmc\nacs\tdocument.createElement\tadmc\naopw\tAdcash","hosts":" yts.*=0,1,2,3,4,5 "}"#)
    }

    func testTableSortsKeysAndWritesExceptionsAndOff() throws {
        let made = scriptlets([
            "example.com,~safe.example.com##+js(nowoif)",
            "popups.*##+js(nowoif)",
            "popups.*,example.com##+js(aopw, Adcash)",
            "off.example.com#@#+js()",
        ])
        XCTAssertEqual(made.table(), #"{"v":2,"calls":"nowoif\nnowoif\naopw\tAdcash","hosts":" example.com=0,2 off.example.com=*off popups.*=1,2 safe.example.com=-1 "}"#)
        // And it is JSON the page reads back.
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(made.table().utf8)) as? [String: Any])
        XCTAssertEqual(object["v"] as? Int, 2)
        XCTAssertEqual(object["calls"] as? String, "nowoif\nnowoif\naopw\tAdcash")
        XCTAssertEqual(object["hosts"] as? String, " example.com=0,2 off.example.com=*off popups.*=1,2 safe.example.com=-1 ")
    }

    func testTableQuotesArguments() throws {
        let made = scriptlets([#"a.example##+js(set, "x\"y", 'back\slash')"#])
        XCTAssertEqual(made.calls, [["set", "x\"y", "back\\slash"]])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(made.table().utf8)) as? [String: Any])
        XCTAssertEqual(object["calls"] as? String, "set\tx\"y\tback\\slash")
    }

    /// No control character reaches the text raw, and the calls come back
    /// the way the page cuts them: lines, then tabs.
    func testTableCallsSplitBackIntoTheCalls() throws {
        let rules = Filters.convert([yts.joined(separator: "\n")])
        let table = rules.scriptlets.table()
        XCTAssertFalse(table.unicodeScalars.contains { $0.value < 0x20 })
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(table.utf8)) as? [String: Any])
        let lines = try XCTUnwrap(object["calls"] as? String)
        XCTAssertEqual(lines.split(separator: "\n", omittingEmptySubsequences: false).map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) },
                       rules.scriptlets.calls)
    }

    /// An argument may hold the two line separators older engines can't have in a literal.
    func testTableEscapesLineSeparators() throws {
        let made = Filters.Scriptlets(calls: [["nostif", "x\u{2028}y\u{2029}z"]], hosts: ["a.example": [0]])
        let table = made.table()
        XCTAssertFalse(table.contains("\u{2028}") || table.contains("\u{2029}"))
        XCTAssertTrue(table.contains("x\\u2028y\\u2029z"))
    }

    func testEmpty() {
        XCTAssertTrue(scriptlets(["||ads.example^", "##.ad"]).isEmpty)
        XCTAssertEqual(scriptlets([]).table(), #"{"v":2,"calls":"","hosts":" "}"#)
        XCTAssertFalse(scriptlets(["a.example##+js(nowoif)"]).isEmpty)
        // Only an "all off" for a site, nothing to run anywhere.
        XCTAssertTrue(scriptlets(["a.example#@#+js()"]).isEmpty)
    }

    // MARK: names

    func testAliasesAreCanonical() {
        let lines = [
            "abort-on-property-read", "abort-on-property-write", "abort-current-script", "abort-current-inline-script",
            "acis", "set-constant", "addEventListener-defuser", "prevent-addEventListener", "no-setTimeout-if",
            "setTimeout-defuser", "prevent-setTimeout", "no-window-open-if", "window.open-defuser", "prevent-window-open",
            "aopr.js", "nowoif.js",
        ].enumerated().map { "s\($0.offset).example##+js(\($0.element), x\($0.offset))" }
        let made = scriptlets(lines)
        XCTAssertEqual(made.calls.map { $0[0] }, [
            "aopr", "aopw", "acs", "acs", "acs", "set", "aeld", "aeld", "nostif", "nostif", "nostif",
            "nowoif", "nowoif", "nowoif", "aopr", "nowoif",
        ])
    }

    func testUnsupportedNamesAreCounted() {
        let rules = Filters.convert(["a.example##+js(nowebrtc)\nb.example##+js(trusted-set-constant, x, 1)\nc.example##+js(rmnt, script, ads)"])
        XCTAssertTrue(rules.scriptlets.isEmpty)
        XCTAssertEqual(rules.dropped["scriptlet-unsupported"], 3)
    }

    // MARK: arguments

    func testArguments() {
        XCTAssertEqual(scriptlets([#"a.example##+js(nostif, "admc")"#]).calls, [["nostif", "admc"]])
        XCTAssertEqual(scriptlets(["a.example##+js(nostif, 'a, b')"]).calls, [["nostif", "a, b"]])
        XCTAssertEqual(scriptlets(["a.example##+js(nostif, `t`)"]).calls, [["nostif", "t"]])
        XCTAssertEqual(scriptlets([#"a.example##+js(acs, document.write, a\,b)"#]).calls, [["acs", "document.write", "a,b"]])
        // A regular expression keeps its backslashes.
        XCTAssertEqual(scriptlets([#"a.example##+js(nostif, /\d{2}\.js/)"#]).calls, [["nostif", #"/\d{2}\.js/"#]])
        // An empty argument in the middle stays; spaces around are trimmed.
        XCTAssertEqual(scriptlets(["a.example##+js(  aeld ,  , _0x  )"]).calls, [["aeld", "", "_0x"]])
        // A trailing empty one says nothing.
        XCTAssertEqual(scriptlets(["a.example##+js(nowoif, )"]).calls, [["nowoif"]])
        // An empty pair of quotes is kept as written; set's tokens are plain.
        XCTAssertEqual(scriptlets(["a.example##+js(set, ads, '')"]).calls, [["set", "ads", "''"]])
        XCTAssertEqual(scriptlets([#"a.example##+js(set, ads, "")"#]).calls, [["set", "ads", #""""#]])
        XCTAssertEqual(scriptlets(["a.example##+js(set, document.ads, noopFunc, as, function)"]).calls,
                       [["set", "document.ads", "noopFunc", "as", "function"]])
        // A quote that isn't the whole argument is part of it.
        XCTAssertEqual(scriptlets([#"a.example##+js(set, a"b, 1)"#]).calls, [["set", #"a"b"#, "1"]])
        XCTAssertEqual(scriptlets([#"a.example##+js(set, "a"b, 1)"#]).calls, [["set", #""a"b"#, "1"]])
    }

    func testTheSameCallIsOneCall() {
        let made = scriptlets(["a.example##+js(nowoif)", "b.example##+js(nowoif.js)", "c.example##+js(no-window-open-if)"])
        XCTAssertEqual(made.calls, [["nowoif"]])
        XCTAssertEqual(made.hosts, ["a.example": [0], "b.example": [0], "c.example": [0]])
    }

    // MARK: sites

    func testHostListsAndExclusions() {
        let made = scriptlets(["A.Example,b.example,~sub.a.example,web.popups.*,1337x.unblocked.*##+js(aopr, x)"])
        XCTAssertEqual(made.calls, [["aopr", "x"]])
        XCTAssertEqual(made.hosts, ["a.example": [0], "b.example": [0], "sub.a.example": [-1], "web.popups.*": [0], "1337x.unblocked.*": [0]])
    }

    // uBO: `~safe` spares that site from its own line only, so another
    // line still runs the call there, naming it or a domain above it; a
    // `#@#` still takes it back. The page cancels an index for every key,
    // so the line that spares has its own (ShieldScriptletsTests runs them).
    func testAnExclusionSparesOnlyItsOwnLine() {
        let both = scriptlets(["example.com,~safe.example.com##+js(nowoif)", "safe.example.com##+js(nowoif)"])
        XCTAssertEqual(both.calls, [["nowoif"], ["nowoif"]])
        XCTAssertEqual(both.hosts, ["example.com": [0], "safe.example.com": [1, -1]])
        let above = scriptlets(["example.com,~safe.example.com##+js(nowoif)", "example.com##+js(nowoif)"])
        XCTAssertEqual(above.hosts, ["example.com": [0, 1], "safe.example.com": [-1]])
        let alone = scriptlets(["example.com,~safe.example.com##+js(nowoif)"])
        XCTAssertEqual(alone.calls, [["nowoif"]])
        XCTAssertEqual(alone.hosts, ["example.com": [0], "safe.example.com": [-1]])
        let excepted = scriptlets(["example.com,~safe.example.com##+js(nowoif)", "safe.example.com##+js(nowoif)", "safe.example.com#@#+js(nowoif)"])
        XCTAssertEqual(excepted.hosts["safe.example.com"], [1, -1, -2])
        // Lines that spare the same sites share their call.
        let same = scriptlets(["a.example,~x.a.example##+js(nowoif)", "b.example,~x.a.example##+js(nowoif.js)"])
        XCTAssertEqual(same.calls, [["nowoif"]])
        XCTAssertEqual(same.hosts, ["a.example": [0], "b.example": [0], "x.a.example": [-1]])
    }

    func testBadSitesDropTheLine() {
        let rules = Filters.convert(["ex%ample.com##+js(nowoif)\nb*d.example##+js(nowoif)\n~.example,a.example##+js(nowoif)"])
        XCTAssertTrue(rules.scriptlets.isEmpty)
        XCTAssertEqual(rules.dropped["bad-domain"], 3)
    }

    func testGenericScriptletsAreDropped() {
        let rules = Filters.convert(["##+js(aopr, x)\n~a.example##+js(aopr, y)\n*##+js(nowoif)"])
        XCTAssertTrue(rules.scriptlets.isEmpty)
        XCTAssertEqual(rules.dropped["scriptlet-generic"], 3)
    }

    func testMalformedScriptlets() {
        let rules = Filters.convert(["a.example##+js(aopr, x\nb.example##+js()"])
        XCTAssertTrue(rules.scriptlets.isEmpty)
        XCTAssertEqual(rules.dropped["scriptlet-malformed"], 2)
    }

    // MARK: what the table can't carry

    func testACallWithAControlCharacterIsLeftOut() {
        let rules = Filters.convert([[
            "a.example##+js(nostif, \"two\tparts\")",
            "b.example##+js(aopr, bell\u{07}here)",
            "c.example##+js(aopr, unit\u{1F}separator)",
            "d.example##+js(aopr, fine)",
        ].joined(separator: "\n")])
        XCTAssertEqual(rules.scriptlets.calls, [["aopr", "fine"]])
        XCTAssertEqual(rules.scriptlets.hosts, ["d.example": [0]])
        XCTAssertEqual(rules.dropped["scriptlet-unsafe-arg"], 3)
        XCTAssertFalse(rules.scriptlets.table().contains("two"))
    }

    func testUnsafeCallsAndExceptedCallsAreCountedApart() {
        let rules = Filters.convert(["a.example##+js(aopr, bad\u{07})", "#@#+js(aopr, bad\u{07})", "b.example##+js(nowoif)", "#@#+js(nowoif)"])
        XCTAssertTrue(rules.scriptlets.isEmpty)
        XCTAssertEqual(rules.dropped["scriptlet-unsafe-arg"], 1)
        XCTAssertEqual(rules.dropped["scriptlet-excepted"], 1)
    }

    func testCarriableCalls() {
        XCTAssertTrue(Filters.Scriptlets.carriable([]))
        XCTAssertTrue(Filters.Scriptlets.carriable(["set", "a b", "''", "caf\u{E9} \u{2028}", "\u{7F}"]))
        for control in ["\t", "\n", "\r", "\u{0}", "\u{1F}"] {
            XCTAssertFalse(Filters.Scriptlets.carriable(["aopr", "a" + control]), "U+\(String(control.unicodeScalars.first!.value, radix: 16))")
            XCTAssertFalse(Filters.Scriptlets.carriable([control + "aopr"]))
        }
    }

    func testCarriableHosts() {
        for host in ["example.com", "a-b.example", "popups.*", "xn--bcher-kva.example", "1337x.unblocked.*", "under_score.example", "localhost"] {
            XCTAssertTrue(Filters.Scriptlets.carriable(host: host), host)
        }
        for host in ["", "Example.com", "a b.example", "a=b.example", "a,b.example", "tab\t.example", "new\nline", "caf\u{E9}.example", "a/b", "a:80", "~a.example"] {
            XCTAssertFalse(Filters.Scriptlets.carriable(host: host), host)
        }
    }

    /// The parser only makes keys the table can carry, so a stray one is put in by hand.
    func testASiteTheTableCannotNameLeavesItsLineOut() {
        var rules = Filters.ScriptletRules()
        rules.made = [
            (["ok.example"], [], ["nowoif"]),
            (["Bad.Example", "other.example"], [], ["aopr", "x"]),
            (["fine.example"], ["spare me.example"], ["aopr", "y"]),
            (["popups.*"], ["tab\t.example"], ["aopr", "z"]),
        ]
        rules.excepted = [(["ok.example", "a=b.example"], ["nowoif"]), (["off=.example"], nil)]
        let (table, dropped) = rules.table()
        XCTAssertEqual(table.calls, [["nowoif"]])
        XCTAssertEqual(table.hosts, ["ok.example": [0]])
        XCTAssertEqual(dropped, ["scriptlet-bad-host": 5])
        XCTAssertEqual(table.table(), #"{"v":2,"calls":"nowoif","hosts":" ok.example=0 "}"#)
    }

    func testEveryKeyOfARealTableIsCarriable() {
        let rules = Filters.convert([yts.joined(separator: "\n"), "A.Example,~b.sub.example,web.popups.*,xn--bcher-kva.example,a_b.example##+js(nowoif)"])
        XCTAssertFalse(rules.scriptlets.hosts.isEmpty)
        XCTAssertTrue(rules.scriptlets.hosts.keys.allSatisfy(Filters.Scriptlets.carriable(host:)))
        XCTAssertNil(rules.dropped["scriptlet-bad-host"])
    }

    // MARK: compact

    func testCompactDropsCommentLinesBlankLinesAndIndentation() {
        let library = """
        // header
        (function () {
            // a note
            var a = 1;

        \t\t// tabbed note
        \tif (a) {
                b();   // kept: it ends a code line
            }
          //
        })();
        """
        XCTAssertEqual(Filters.Scriptlets.compact(library), """
        (function () {
        var a = 1;
        if (a) {
        b();   // kept: it ends a code line
        }
        })();
        """)
    }

    func testCompactKeepsSlashesThatAreCode() {
        let library = "var u = '://';\n  var re = /a\\/\\/b/; // end\n  var s = \"// not a comment\";\n    /* block */\n  x = a / b;"
        XCTAssertEqual(Filters.Scriptlets.compact(library), "var u = '://';\nvar re = /a\\/\\/b/; // end\nvar s = \"// not a comment\";\n/* block */\nx = a / b;")
    }

    func testCompactKeepsTheMarkersAndEndsWithoutANewline() {
        let library = "// markers\n  var TABLE = __YAB_TABLE__;\n  var OFF = __YAB_OFF__;\n\n"
        XCTAssertEqual(Filters.Scriptlets.compact(library), "var TABLE = __YAB_TABLE__;\nvar OFF = __YAB_OFF__;")
        XCTAssertEqual(Filters.Scriptlets.compact(""), "")
        XCTAssertEqual(Filters.Scriptlets.compact("// only\n  // comments\n\n"), "")
    }

    func testTheLibraryTakesTheClickGuardInsideAtItsMarker() {
        let scriptlets = "(function () {\n  // run\n  if (top) guardClicks(host);\n  __YAB_GUARD__\n})();\n"
        let clicks = "// the guard\nfunction guardClicks(host) {\n    listen(host);\n}\n"
        XCTAssertEqual(Filters.Scriptlets.library(scriptlets, clickGuard: clicks),
                       "(function () {\nif (top) guardClicks(host);\nfunction guardClicks(host) {\nlisten(host);\n}\n})();")
    }

    func testCompactReadsWindowsLineEndings() {
        XCTAssertEqual(Filters.Scriptlets.compact("// a\r\n  x();\r\n\r\n  y();\r\n"), "x();\ny();")
    }

    func testCompactIsStable() {
        let once = Filters.Scriptlets.compact("  // a\n    f( 1,\n      2 );\n")
        XCTAssertEqual(Filters.Scriptlets.compact(once), once)
    }

    // MARK: exceptions

    func testSiteExceptionSparesThatCall() {
        let made = scriptlets([
            "shop.example#@#+js(set-constant, ads, false)",
            "shop.example,news.example##+js(set, ads, false)",
            "news.example##+js(nowoif)",
        ])
        XCTAssertEqual(made.calls, [["set", "ads", "false"], ["nowoif"]])
        XCTAssertEqual(made.hosts, ["shop.example": [0, -1], "news.example": [0, 1]])
        XCTAssertEqual(Filters.convert(["example##+js(nowoif)"]).dropped["bad-domain"], 1)
    }

    func testExceptionForACallNoneMakesIsLeftOut() {
        let made = scriptlets(["a.example#@#+js(aopr, never)", "a.example##+js(nowoif)"])
        XCTAssertEqual(made.hosts, ["a.example": [0]])
    }

    func testEmptyExceptionTurnsASiteOff() {
        let made = scriptlets(["vr.pornhat.*#@#+js()", "pornhat.*##+js(aopr, document.dispatchEvent)"])
        XCTAssertEqual(made.hosts, ["pornhat.*": [0], "vr.pornhat.*": [Int.min]])
    }

    func testEntityException() {
        let made = scriptlets(["vr.pornhat.*#@#+js(aopr, document.dispatchEvent)", "pornhat.*##+js(aopr, document.dispatchEvent)"])
        XCTAssertEqual(made.hosts, ["pornhat.*": [0], "vr.pornhat.*": [-1]])
    }

    func testExceptionsWithoutSites() {
        // The call off everywhere, every call off everywhere.
        let made = scriptlets(["a.example##+js(nowoif)", "a.example##+js(aopr, x)", "#@#+js(nowoif)"])
        XCTAssertEqual(made.calls, [["aopr", "x"]])
        XCTAssertEqual(made.hosts, ["a.example": [0]])
        XCTAssertTrue(scriptlets(["a.example##+js(nowoif)", "#@#+js()"]).isEmpty)
        // An exception that spares sites says nothing WebKit-like lists can.
        XCTAssertEqual(Filters.convert(["~a.example#@#+js(nowoif)"]).dropped["exception-excluding"], 1)
    }

    func testAdGuardScriptletsAreCounted() {
        let rules = Filters.convert(["popups.example#%#//scriptlet('abort-on-property-read', 'aclib')\npopups.example#%#window.x = 1;"])
        XCTAssertTrue(rules.scriptlets.isEmpty)
        XCTAssertEqual(rules.dropped["adguard-scriptlet"], 1)
        XCTAssertEqual(rules.dropped["adguard-js"], 1)
    }

    // MARK: entity hiding

    func testEntityHiding() {
        let rules = Filters.convert(["popups.*,b.example##.ad"])
        XCTAssertEqual(rules.blocks.map(\.filter), [Filters.onSite("b.example"), Filters.onEntity("popups")])
        // The entity is a site with hiding of its own too, so it is never quiet.
        XCTAssertEqual(rules.hidingSites, ["b.example", "popups.*"])
        // Spared on a site the entity names: gone, as for any site.
        XCTAssertEqual(Filters.convert(["popups.*##.ad", "popups.net#@#.ad"]).blocks.count, 0)
        XCTAssertEqual(Filters.convert(["popups.net##.ad", "popups.*#@#.ad"]).blocks.count, 0)
        XCTAssertEqual(Filters.convert(["web.popups.*##.ad", "popups.*#@#.ad"]).blocks.count, 0)
        XCTAssertEqual(Filters.convert(["popups.*##.ad", "other.net#@#.ad"]).blocks.count, 1)
        // An entity to spare can't be said in unless-domain: a generic rule
        // is kept as it was before entities were read.
        XCTAssertEqual(Filters.convert(["##.ad", "popups.*#@#.ad"]).generic.map(\.unlessDomain), [[]])
        XCTAssertEqual(Filters.convert(["~popups.*##.ad"]).dropped["entity-exclude"], 1)
    }

    // MARK: !#if

    func testPreparserBlocks() {
        let text = """
        !#if env_chromium
        a.example##+js(aopr, chromium)
        ||chromium.example^
        !#else
        a.example##+js(aopr, other)
        !#endif
        !#if !cap_html_filtering
        b.example##+js(aopr, nohtml)
        !#endif
        !#if cap_html_filtering
        b.example##^script:has-text(ads)
        !#endif
        !#if env_safari
        c.example##+js(aopr, safari)
        !#if env_mobile
        c.example##+js(aopr, mobile)
        !#endif
        !#endif
        !#if (env_firefox || env_safari) && !ext_ubol
        d.example##+js(aopr, either)
        !#endif
        !#if env_mobile
        e.example##+js(aopr, unclosed)
        """
        let rules = Filters.convert([text, "f.example##+js(aopr, next)"])
        XCTAssertEqual(rules.scriptlets.calls.map { $0[1] }, ["other", "nohtml", "safari", "either", "next"])
        XCTAssertEqual(rules.blocks.count, 0)
        XCTAssertEqual(rules.dropped["not-this-platform"], 5)
        // On a phone, the mobile blocks too.
        let phone = Filters.convert([text], env: Filters.webKit.union(["env_mobile"]))
        XCTAssertEqual(phone.scriptlets.calls.map { $0[1] }, ["other", "nohtml", "safari", "mobile", "either", "unclosed"])
    }

    func testPreparserOddExpressionsSkipTheBlock() {
        let rules = Filters.convert(["!#if env_safari &&\na.example##+js(nowoif)\n!#endif\n!#if )(\nb.example##+js(nowoif)\n!#endif"])
        XCTAssertTrue(rules.scriptlets.isEmpty)
    }

    // MARK: reasons

    func testDroppedByReason() {
        let rules = Filters.convert([[
            "||a.example^$redirect=noop.js", "/ad[0-9]+/", "||b.example^$csp=script-src 'none'", "example.com##div:has-text(Ad)",
            "||c.example^$badfilter", "||c.example^", "/ads.js$domain=a.com|~b.a.com", "$script", "@@||d.example/x$document",
            "a.com,~b.a.com##.promo", "example.com#?#.x:-abp-has(.ad)", "example.com#$#.x { display: none }", "~x.*##.ad",
        ].joined(separator: "\n")])
        XCTAssertEqual(rules.dropped, [
            "option-redirect": 1, "regex": 1, "option-csp": 1, "procedural": 2, "badfilter": 2, "mixed-domains": 1,
            "everywhere": 1, "document-exception": 1, "mixed-sites": 1, "css-injection": 1, "entity-exclude": 1,
        ])
        XCTAssertEqual(rules.skipped, rules.dropped.values.reduce(0, +))
    }

    // MARK: WebKit

    @MainActor
    func testEntityHidingCompilesBesideEverything() throws {
        let lines = [
            "popups.*###dontfoid", "1337x.unblocked.*##.ad", "web.popups.*,b.example##.promo", "/ads.js$domain=b.com|a.com",
            "~a.com##.promo2", "##.sponsor", "news.com#@#.sponsor", "||ads.example^$important", "@@||bank.example^$document",
            "@@||news.example^$ghide", "popups.*##+js(nowoif)",
        ]
        let lists = try XCTUnwrap(Filters.lists(Filters.convert(lines + [Shield.base]))).lists
        XCTAssertTrue(lists[0].contains(#"popups\\.[a-z0-9-]+[/:]"#))
        for list in lists { try compile(list) }
    }

    /// A page of popups.net (by its address, not the network) under the hiding
    /// rule for popups.*, and one of another site.
    @MainActor
    func testEntityHidingHidesOnItsSites() throws {
        let list = try XCTUnwrap(Filters.lists(Filters.convert(["popups.*###dontfoid"]))).lists
        let compiled = try list.map { try compile($0) }
        XCTAssertEqual(try hidden(at: "https://popups.net/", with: compiled), true)
        XCTAssertEqual(try hidden(at: "https://www.popups.org/movies", with: compiled), true)
        XCTAssertEqual(try hidden(at: "https://notpopups.net/", with: compiled), false)
        XCTAssertEqual(try hidden(at: "https://popups.example.com/", with: compiled), false)
    }

    @MainActor
    private func hidden(at address: String, with lists: [WKContentRuleList]) throws -> Bool? {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        for list in lists { config.userContentController.add(list) }
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 400, height: 400), configuration: config)
        web.loadHTMLString(#"<div id="dontfoid">x</div>"#, baseURL: URL(string: address))
        let done = expectation(description: "styled")
        var out: Bool?
        func poll(_ left: Int) {
            web.evaluateJavaScript("document.readyState === 'complete' && document.getElementById('dontfoid') ? getComputedStyle(document.getElementById('dontfoid')).display : ''") { value, _ in
                let display = value as? String ?? ""
                if !display.isEmpty || left == 0 {
                    out = display.isEmpty ? nil : display == "none"
                    done.fulfill()
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { poll(left - 1) }
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { poll(50) }
        wait(for: [done], timeout: 20)
        return out
    }

    @MainActor
    @discardableResult
    private func compile(_ json: String) throws -> WKContentRuleList {
        let store = try XCTUnwrap(WKContentRuleListStore(url: scratch()))
        var made: WKContentRuleList?
        var failure: Error?
        let done = expectation(description: "compiled")
        store.compileContentRuleList(forIdentifier: "test-\(UUID().uuidString)", encodedContentRuleList: json) { list, error in
            made = list
            failure = error
            done.fulfill()
        }
        wait(for: [done], timeout: 120)
        if let failure { throw failure }
        return try XCTUnwrap(made)
    }

    private var folder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("yab-scriptlet-tests-\(getpid())", isDirectory: true)
    }

    private func scratch() -> URL {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
        super.tearDown()
    }

    // MARK: saved lists

    /// Every .txt in a folder of saved lists (SHIELD_SAVED_LISTS=path), read
    /// the way Shield reads its own: the scriptlets kept, the table's size,
    /// and what is left out most.
    @MainActor
    func testSavedLists() throws {
        guard let path = ProcessInfo.processInfo.environment["SHIELD_SAVED_LISTS"] else { throw XCTSkip("SHIELD_SAVED_LISTS not set") }
        let names = try FileManager.default.contentsOfDirectory(atPath: path).filter { $0.hasSuffix(".txt") }.sorted()
        let texts = try names.map { try String(contentsOfFile: "\(path)/\($0)", encoding: .utf8) }
        let t0 = CFAbsoluteTimeGetCurrent()
        let rules = Filters.convert([Shield.base] + texts)
        let ms = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
        let made = rules.scriptlets
        let yts = Set(made.hosts["yts.*"] ?? []).map { made.calls[$0] }
        for call in [["aeld", "", "_0x"], ["aopr", "runAdblock"], ["nowoif"], ["nostif", "admc"], ["acs", "document.createElement", "admc"], ["aopw", "Adcash"]] {
            XCTAssertTrue(yts.contains(call), "yts.* lacks \(call)")
        }
        XCTAssertTrue(rules.blocks.contains { $0.action == .hide("#dontfoid") && $0.filter == Filters.onEntity("yts") })
        let positive = made.hosts.values.reduce(0) { $0 + $1.filter { $0 >= 0 }.count }
        let byName = Dictionary(grouping: made.calls, by: { $0[0] }).mapValues(\.count).sorted { $0.value > $1.value }
        let top = rules.dropped.sorted { $0.value > $1.value }.prefix(15).map { "\($0.key) \($0.value)" }
        print("saved lists \(names): \(rules.count) rules, \(rules.skipped) left out, converted in \(ms) ms")
        print("scriptlets: \(made.calls.count) calls, \(made.hosts.count) keys (\(made.hosts.keys.filter { $0.hasSuffix(".*") }.count) entities), "
              + "\(positive) host entries, table \(made.table().utf8.count) bytes; by name \(byName)")
        print("dropped, most first: \(top.joined(separator: ", "))")
        let split = try XCTUnwrap(Filters.lists(rules))
        for list in split.lists { try compile(list) }
    }
}
