import Foundation
import JavaScriptCore
import Testing
@testable import Fast

/// The JSON viewer's reading and laying out (json-view.js, run without a
/// page in JavaScriptCore) and what yab says of a JSON page (JSONView.swift).
@MainActor
struct JSONViewTests {
    private func core() throws -> JSValue {
        let context = try #require(JSContext())
        var failure: String?
        context.exceptionHandler = { _, error in failure = error?.toString() }
        let source = PageScript.load("json-view", vars: ["MODE": "tree", "KEEPS": "true", "COLORS": JSONView.colors])
        context.evaluateScript(source)
        #expect(failure == nil, "\(failure ?? "")")
        return try #require(context.objectForKeyedSubscript("__yabJSONCore"))
    }

    private func call(_ core: JSValue, _ name: String, _ args: [Any]) -> JSValue {
        core.objectForKeyedSubscript(name).call(withArguments: args)
    }

    private func eval(_ core: JSValue, _ js: String) -> JSValue {
        core.context.evaluateScript("(function (C) { \(js) })(__yabJSONCore)")
    }

    @Test func scriptHasEveryValueFilledIn() {
        let source = PageScript.load("json-view", vars: ["MODE": "text", "KEEPS": "false", "COLORS": JSONView.colors])
        #expect(!source.contains("__YAB_"))
        #expect(source.contains("var PREF = 'text'"))
        #expect(JSONView.colors.contains("\"key\":[\"#881280\",\"#e36eec\"]"))
    }

    @Test func keysStayInTheirOrder() throws {
        let c = try core()
        let keys = eval(c, "return C.parse('{\"b\":1,\"10\":2,\"2\":3}').root.v.map(function (x) { return x.k; }).join(',')").toString()
        #expect(keys == "b,10,2")
    }

    @Test func numbersStayAsWritten() throws {
        let c = try core()
        let numbers = eval(c, "var r = C.parse('{\"id\":1849384729384729384,\"ratio\":1.50}').root; return r.v[0].v.v + ' ' + r.v[1].v.v").toString()
        #expect(numbers == "1849384729384729384 1.50")
        #expect(eval(c, "return C.plain(C.parse('{\"id\":1849384729384729384}').root.v[0].v)").toString() == "1849384729384729384")
    }

    @Test func aSecondKeyIsKeptAndMarked() throws {
        let c = try core()
        #expect(eval(c, "var r = C.parse('{\"lang\":\"en\",\"lang\":\"ru\"}').root; return r.v.length + ' ' + r.v[0].d + ' ' + r.v[1].d").toString() == "2 false true")
    }

    @Test func brokenJSONSaysWhere() throws {
        let c = try core()
        let broken = "{\n  \"name\": \"yab\",\n  \"version\": \"0.0.21\",\n  \"scripts\": {\n    \"build\": \"swift build\",\n    \"test\": \"swift test\",\n  },\n  \"private\": true\n}"
        c.context.setObject(broken, forKeyedSubscript: "broken" as NSString)
        let said = eval(c, "try { C.parse(broken); return 'read'; } catch (e) { var p = C.place(broken, e.at); return p.line + ':' + p.col + ' ' + e.message; }").toString()
        #expect(said == "7:3 Expected a key in quotes")
        #expect(eval(c, "try { C.parse('{\"a\":1} x'); } catch (e) { return e.message; }").toString() == "Extra text after the JSON")
        #expect(eval(c, "try { C.parse('{\"a\":'); } catch (e) { return e.message; }").toString() == "The text ends too early")
    }

    @Test func securityPrefixesAreCut() throws {
        let c = try core()
        #expect(eval(c, "var p = C.prefix(\")]}'\\n[1]\"); return p.text + '|' + C.parse(\")]}'\\n[1]\", p.from).root.v[0].v").toString() == ")]}'|1")
        #expect(eval(c, "return C.prefix('while(1);{\"a\":1}').text").toString() == "while(1);")
        #expect(eval(c, "return C.prefix('for(;;);[]').text").toString() == "for(;;);")
        #expect(eval(c, "return C.prefix('{\"a\":1}') === null").toBool())
    }

    @Test func textLinesMatchThePrettyJSON() throws {
        let c = try core()
        let same = eval(c, """
        var docs = ['{"a":{"b":[1,2,{}],"c":[]},"d":"x,y","e":"q\\\\"}"}', '[ 1 , [ ] , { "k" : null } ]', '"alone"', '{"k":[{"x":[[]]}]}'];
        for (var d = 0; d < docs.length; d++) {
          var s = docs[d], ix = C.index(s), lines = [];
          for (var i = 0; i < ix.n; i++) lines.push('  '.repeat(ix.depths[i]) + C.compact(s.slice(ix.starts[i], ix.ends[i])));
          if (lines.join('\\n') !== C.pretty(C.parse(s).root)) return 'differs: ' + s + '\\n' + lines.join('\\n');
          if (ix.n !== C.parse(s).lines) return 'count: ' + s;
        }
        return 'same';
        """).toString()
        #expect(same == "same")
    }

    @Test func aStringWithLineBreaksStaysOnItsRow() throws {
        let c = try core()
        let drawn = eval(c, "return C.oneLine(C.parse('{\"body\":\"one\\\\n\\\\ntwo\\\\r\\\\n\\\\tthree\\\\u0001\"}').root.v[0].v.v)").toString()
        #expect(drawn == "one\\n\\ntwo\\r\\n\\tthree\\u0001")
        #expect(eval(c, "return C.oneLine('plain \"quoted\" text')").toString() == "plain \"quoted\" text")
        // Copy Value still takes the string itself.
        #expect(eval(c, "return C.plain(C.parse('\"a\\\\nb\"').root)").toString() == "a\nb")
    }

    @Test func pathsForCopying() throws {
        let c = try core()
        #expect(call(c, "pathText", [["owner", "login"]]).toString() == "owner.login")
        #expect(call(c, "jq", [["owner", "login"]]).toString() == ".owner.login")
        #expect(call(c, "pathText", [["topics", 3]]).toString() == "topics[3]")
        #expect(call(c, "jq", [["a b"]]).toString() == ".[\"a b\"]")
        #expect(call(c, "pathText", [[]]).toString() == "$")
        #expect(call(c, "jq", [[]]).toString() == ".")
    }

    @Test func jqQuotesAKeyWithADollarSign() throws {
        let c = try core()
        // jq reads `.$schema` as a variable and won't run it.
        #expect(call(c, "jq", [["$schema"]]).toString() == ".[\"$schema\"]")
        #expect(call(c, "jq", [["definitions", "user", "$ref"]]).toString() == ".definitions.user[\"$ref\"]")
        #expect(call(c, "jq", [["$"]]).toString() == ".[\"$\"]")
        #expect(call(c, "jq", [["items", 0, "id"]]).toString() == ".items[0].id")
        // Copy Path keeps its own way: `$` is fine in a script's path.
        #expect(call(c, "pathText", [["definitions", "$ref"]]).toString() == "definitions.$ref")
    }

    @Test func quietHintsBesideValues() throws {
        let c = try core()
        let now = 1_791_835_200_000.0 // 2026-10-12T20:00:00Z
        #expect(eval(c, "return C.hint({ t: 's', v: '2026-10-12T18:00:00Z' }, 'pushed_at', \(now))").toString() == "2 hours ago")
        #expect(eval(c, "return C.hint({ t: 'n', v: '1791835200' }, 'exp', \(now))").toString() == "2026-10-12 20:00 UTC")
        #expect(eval(c, "return C.hint({ t: 'n', v: '1791835200' }, 'count', \(now))").toString() == "")
        #expect(eval(c, "return C.swatch({ t: 's', v: '#2f6bff' })").toString() == "#2f6bff")
        #expect(eval(c, "return C.ago(\(now) + 3 * 86400000, \(now))").toString() == "in 3 days")
    }

    @Test func aMillionLinesInAFewSeconds() throws {
        let c = try core()
        let ms = eval(c, """
        var parts = []; for (var i = 0; i < 100000; i++) parts.push('{"id":' + i + ',"name":"n' + i + '","tags":["a","b"]}');
        var s = '[' + parts.join(',') + ']';
        var t = Date.now(); var ix = C.index(s); var took = Date.now() - t;
        return ix.n === C.parse(s).lines ? took : -1;
        """).toInt32()
        #expect(ms >= 0)
        #expect(ms < 3000)
    }

    @Test func bandWordsOnlyWhenSomethingIsOff() throws {
        let fine = try #require(JSONPage(["shown": "tree", "size": 6312]))
        #expect(JSONBandDoor.words(fine, nil).isEmpty)
        let url = try #require(URL(string: "https://api.github.com/repos/vercel/nope"))
        let missing = PageResponse(url: url, status: 404, headers: [], milliseconds: 90)
        #expect(JSONBandDoor.words(fine, missing).map(\.text) == ["404 Not Found"])
        let broken = try #require(JSONPage(["shown": "text", "size": 120, "error": ["line": 7, "col": 3, "message": "Expected a key in quotes"]]))
        #expect(JSONBandDoor.words(broken, nil).map(\.text) == ["Not valid JSON \u{00B7} line 7"])
        let big = try #require(JSONPage(["shown": "text", "size": 84_000_000, "big": true]))
        #expect(JSONBandDoor.words(big, nil).map(\.text) == ["84 MB, opened as text", "Show as Tree"])
        let plain = try #require(JSONPage(["shown": "tree", "size": 20, "plain": true]))
        #expect(JSONBandDoor.words(plain, nil).map(\.text) == ["Sent as text"])
        let text = try #require(JSONPage(["shown": "text", "size": 20]))
        #expect(JSONBandDoor.words(text, nil).map(\.text) == ["Text"])
        let sent = try #require(JSONPage(["shown": "sent", "size": 20, "plain": true]))
        #expect(JSONBandDoor.words(sent, nil).isEmpty)
    }

    @Test func savedUnderTheAddressName() throws {
        #expect(JSONView.fileName(for: URL(string: "https://api.github.com/repos/vercel/next.js")) == "next.js.json")
        #expect(JSONView.fileName(for: URL(string: "https://example.com/data.json")) == "data.json")
        #expect(JSONView.fileName(for: URL(string: "https://example.com/")) == "example.com.json")
    }

    @Test func settingIsFoundAndDescribed() {
        #expect(SettingsItem.all.contains { $0.id == "dev-json" && $0.page == .developers })
        #expect(JSONShow.tree.detail == "Display JSON as a collapsible, searchable tree.")
        #expect(JSONShow.sent.title == "As Sent")
        #expect(Command.jsonText.title == "Show JSON as Text")
    }
}
