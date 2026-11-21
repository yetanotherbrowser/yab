import Testing
import WebKit
@testable import Fast

@MainActor
struct ContextLinkScriptTests {
    @Test func svgLinksAreReadLikeHTMLLinks() async throws {
        let web = WKWebView(frame: .zero)
        web.loadHTMLString("""
        <a data-probe href="https://html.test/">html</a>
        <svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink">
          <a data-probe href="https://svg.test/"><text>svg</text></a>
          <a data-probe xlink:href="https://xlink.test/"><text>xlink</text></a>
          <a data-probe href="relative"><text>relative</text></a>
          <a data-probe><text>none</text></a>
        </svg>
        <span data-probe>not a link</span>
        """, baseURL: URL(string: "https://page.test/dir/"))
        for _ in 0..<100 {
            if try await web.evaluateJavaScript("document.readyState === 'complete' && !!document.querySelector('span')") as? Bool == true { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let got = try await web.evaluateJavaScript("""
        Array.from(document.querySelectorAll('[data-probe]')).map(\(ImageRelay.linkOf))
        """) as? [String]
        #expect(got == ["https://html.test/", "https://svg.test/", "https://xlink.test/",
                        "https://page.test/dir/relative", "", ""])
    }
}
