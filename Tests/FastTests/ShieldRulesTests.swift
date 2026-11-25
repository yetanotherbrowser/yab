import Testing
@testable import Fast

@Suite struct ShieldRulesTests {
    @Test func everyShapeFiltersWritesIsReadBack() {
        func pattern(_ line: String) -> ShieldRules.Pattern? {
            guard let rule = Filters.network(line)?.first?.0 else { return nil }
            return ShieldRules.pattern(rule.filter)
        }
        #expect(pattern("||ads.example.com^") == .init(text: "ads.example.com\u{01}", flags: 1))
        #expect(pattern("||ads.example.com/banner") == .init(text: "ads.example.com/banner", flags: 1))
        #expect(pattern("|https://exact.test/x") == .init(text: "https://exact.test/x", flags: 2))
        #expect(pattern("/banners/*.gif") == .init(text: "/banners/*.gif", flags: 0))
        #expect(pattern("/adv^") == .init(text: "/adv\u{02}", flags: 0))
        #expect(pattern("/adv^ok") == .init(text: "/adv^ok", flags: 0))
        #expect(pattern(".swf|") == .init(text: ".swf", flags: 4))
        #expect(pattern("||a.test^x^|") == .init(text: "a.test\u{01}x\u{03}", flags: 1))
        #expect(ShieldRules.pattern(".*") == .init(text: "", flags: 0))
        #expect(ShieldRules.pattern("(a|b)") == nil)
    }

    @Test func aHidingRuleIsReadBackToItsSite() {
        #expect(ShieldRules.site(Filters.onSite("shop.example.org")) == "shop.example.org")
        #expect(ShieldRules.site(".*") == nil)
    }

    // The helper looks a hiding rule up by its site's name: an entity has
    // none, so it is left out and counted rather than kept under a pattern.
    @Test func anEntitysHidingRuleIsLeftOut() {
        #expect(ShieldRules.site(Filters.onEntity("popups")) == nil)
        let made = ShieldRules.text(Filters.convert(["popups.*###dontfoid\nexample.org##.banner\n"]))
        let lines = made.text.split(separator: "\n").map(String.init)
        #expect(lines.contains("H\texample.org\t.banner"))
        #expect(!lines.contains { $0.hasPrefix("H\tpopups") })
        #expect(made.left == 1)
    }

    @Test func theFileKeepsEveryKindOfRule() {
        let rules = Filters.convert(["||ads.example.com^$script,third-party\n@@||good.example.com^\nexample.org##.banner\n##.ad-slot\n~spare.com##.sometimes\n@@||nohide.test^$generichide\n"])
        let made = ShieldRules.text(rules)
        #expect(made.left == 0)
        let lines = made.text.split(separator: "\n").map(String.init)
        #expect(lines.first == "YABSHIELD1")
        #expect(lines.contains("N\tblock\t1\t33\t\tads.example.com\u{01}"))
        #expect(lines.contains { $0.hasPrefix("N\tallow\t") && $0.hasSuffix("good.example.com\u{01}") })
        #expect(lines.contains("H\texample.org\t.banner"))
        #expect(lines.contains("G\t.ad-slot"))
        #expect(lines.contains("S\tspare.com\t.sometimes"))
        #expect(lines.contains { $0.hasPrefix("U\t") && $0.contains("nohide.test") })
    }
}
