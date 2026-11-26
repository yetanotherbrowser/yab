import Foundation
import FoundationModels
import WebKit

/// Apple Intelligence on this iPhone (Foundation Models): answers questions
/// about the page in front from the page's own words, and has ideas for a
/// new chat about it. Its context window is about 4,000 tokens, so a page is
/// cut to its first 3,500 characters, as the Mac's ChatIdeas does.
@MainActor
final class OnDeviceModel: ChatBackend {
    let who = Chat.Answerer.iphone

    var isAvailable: Bool { SystemLanguageModel.default.isAvailable }

    /// A temporary download or disabled setting must not change who owns a page.
    static var isDeviceEligible: Bool {
        if case .unavailable(.deviceNotEligible) = SystemLanguageModel.default.availability { return false }
        return true
    }

    func answer(_ context: AskContext) async throws -> String {
        let session = LanguageModelSession(instructions: """
        You answer questions about the web page a person has open in Yab, a browser on their \(DeviceWord.name). \
        Answer from the page's words in two or three plain sentences, in the language of the question. \
        No headings, lists or markup. If the page doesn't say, say so in one sentence.
        """)
        let earlier = context.history.suffix(6).compactMap { message -> String? in
            switch message.role {
            case .you: "They asked: \(message.plain)"
            case .answer: "You answered: \(message.plain)"
            default: nil
            }
        }.joined(separator: "\n")
        var prompt = ""
        if let page = context.page {
            prompt += "Page: \(page.title) (\(page.address))\n\(String(page.text.prefix(3_500)))\n\n"
        }
        if !earlier.isEmpty { prompt += earlier + "\n\n" }
        prompt += "Question: \(context.question)"
        let reply = try await session.respond(to: prompt)
        return reply.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Three requests about `page` for a new chat, or nil without the model
    /// or when it gives fewer than two plain lines. The Mac's prompt
    /// (ChatIdeas in Sources/Fast/ChatComposer.swift), shortened for the
    /// smaller window.
    func ideas(about page: PageContext) async -> [String]? {
        guard isAvailable else { return nil }
        let session = LanguageModelSession(instructions: "Return only the three lines asked for, in English, nothing else.")
        let prompt = """
        The user has this page open in their browser, where an AI agent can work in tabs for them: read pages, \
        search the web, compare sources, fill forms. Write three requests they might give the agent about this page.
        If the page is one thing, the requests name its subject. If it is a feed or a list of unrelated items, the \
        requests are about what to find or catch up on across the site. Never a request to only open, play or scroll.
        Each under 50 characters, in the imperative. Reply with exactly three lines and nothing else.

        Page: \(page.address)
        \(page.title)
        \(String(page.text.prefix(3_000)))
        """
        guard let reply = try? await session.respond(to: prompt) else { return nil }
        return Ideas.lines(reply.content)
    }
}

/// Ideas over a new chat's field: three requests about the page in front.
enum Ideas {
    /// The ideas in a reply: up to three plain lines, nil for fewer than two
    /// (the Mac's ChatIdeas.lines).
    static func lines(_ reply: String) -> [String]? {
        let lines = reply.split(whereSeparator: \.isNewline)
            .map { plain(String($0)) }
            .filter { line in
                !line.isEmpty && line.count <= 70 && !line.hasSuffix(":")
                    && !["#", "|", "**", "](", "`"].contains { line.contains($0) }
            }
        return lines.count >= 2 ? Array(lines.prefix(3)) : nil
    }

    /// A line without its list mark, its wrapping quotes and a closing stop.
    static func plain(_ line: String) -> String {
        var line = line.trimmingCharacters(in: .whitespaces)
        if let mark = line.range(of: #"^(\d{1,2}[.)]|[-*\u{2022}])\s+"#, options: .regularExpression) {
            line.removeSubrange(mark)
        }
        for (open, close) in [("\"", "\""), ("\u{201C}", "\u{201D}"), ("\u{AB}", "\u{BB}")]
        where line.count > 2 && line.hasPrefix(open) && line.hasSuffix(close)
            && !line.dropFirst().dropLast().contains(where: { String($0) == open || String($0) == close }) {
            line = String(line.dropFirst().dropLast())
        }
        if line.hasSuffix("."), !line.hasSuffix("..") { line.removeLast() }
        return line.trimmingCharacters(in: .whitespaces)
    }
}

/// The words of the page in front, for the model: read from its live web
/// view, else just its title.
@MainActor
enum PageText {
    static func read(_ tab: Tab, pool: WebPool) async -> PageContext {
        var text = tab.title
        if pool.isLive(tab.id) {
            let js = """
            (document.title || '') + '\\n' + (document.body ? document.body.innerText : '').slice(0, 6000)
            """
            if let words = try? await pool.view(for: tab).evaluateJavaScript(js) as? String, !words.isEmpty {
                text = words
            }
        }
        return PageContext(title: tab.title, address: tab.navigationURL?.absoluteString ?? tab.address, text: text)
    }
}
