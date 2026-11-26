import AppKit
import UniformTypeIdentifiers

// The chosen clip's kept text, apart from the one-line index. The little
// marks belong to this drawing alone: neither copy nor paste sees them.
@MainActor
struct ClipText {
    let text: String
    let rich: NSAttributedString
    let formatted: Bool
    let bold: Bool

    init(clip: Clips.Clip, data: [(String, Data)]) {
        var parsed: NSAttributedString?
        for (type, format) in [(NSPasteboard.PasteboardType.rtf, NSAttributedString.DocumentType.rtf),
                               (.html, .html)] {
            guard let bytes = data.first(where: { $0.0 == type.rawValue })?.1 else { continue }
            if let value = try? NSAttributedString(data: bytes, options: [.documentType: format], documentAttributes: nil) {
                parsed = value
                break
            }
        }
        var plain: String?
        for type in ["public.utf8-plain-text", "public.utf16-plain-text", "public.utf16-external-plain-text"] {
            guard let bytes = data.first(where: { $0.0 == type })?.1,
                  let value = String(data: bytes, encoding: type.contains("utf16") ? .utf16 : .utf8) else { continue }
            plain = value
            break
        }
        text = plain ?? parsed?.string ?? clip.text
        let result = NSMutableAttributedString(string: text)
        // HTML's importer may add its own final newline. Keep the plain
        // flavor's outer blank lines, and place the rich runs over its words.
        if let parsed {
            let core = parsed.string.trimmingCharacters(in: .whitespacesAndNewlines)
            let source = (parsed.string as NSString).range(of: core)
            let target = (text as NSString).range(of: core)
            if !core.isEmpty, source.location != NSNotFound, target.location != NSNotFound, source.length == target.length {
                parsed.enumerateAttributes(in: source) { attributes, range, _ in
                    result.addAttributes(attributes, range: NSRange(location: target.location + range.location - source.location,
                                                                     length: range.length))
                }
            } else {
                // Paragraph spacing in an HTML flavor often differs from
                // its plain flavor. Match its runs in order so a bold span
                // still shows bold without replacing the kept blank lines.
                let words = text as NSString
                var cursor = 0
                parsed.enumerateAttributes(in: NSRange(location: 0, length: parsed.length)) { attributes, range, _ in
                    let run = parsed.attributedSubstring(from: range).string.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !run.isEmpty else { return }
                    let found = words.range(of: run, range: NSRange(location: cursor, length: words.length - cursor))
                    guard found.location != NSNotFound else { return }
                    result.addAttributes(attributes, range: found)
                    cursor = NSMaxRange(found)
                }
            }
        }
        rich = result
        formatted = parsed != nil || clip.types.contains("public.rtf") || clip.types.contains("public.html")
        var hasBold = false
        result.enumerateAttribute(.font, in: NSRange(location: 0, length: result.length)) { font, _, _ in
            if let font = font as? NSFont, NSFontManager.shared.traits(of: font).contains(.boldFontMask) { hasBold = true }
        }
        bold = hasBold
    }

    var kind: String { formatted ? (bold ? "Formatted Text, bold" : "Formatted Text") : "Text" }

    var lines: String? {
        let rows = text.components(separatedBy: .newlines)
        // Treat CRLF as one break, as the text system does.
        let count = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: .newlines).count
        guard count > 1 else { return nil }
        let start = rows.first?.trimmingCharacters(in: .whitespaces).isEmpty == true
        let end = rows.last?.trimmingCharacters(in: .whitespaces).isEmpty == true
        let blank = start && end ? "start and end" : start ? "start" : end ? "end" : nil
        return "\(count)" + (blank.map { ", blank at \($0)" } ?? "")
    }

    /// The same fixed-width size throughout, retaining bold and italic.
    /// Leading tabs advance to four columns; only their drawing is expanded.
    func drawing() -> NSAttributedString {
        let shown = String(text.prefix(2000))
        let sample = rich.attributedSubstring(from: NSRange(location: 0, length: shown.utf16.count))
        let out = NSMutableAttributedString(attributedString: sample)
        let all = NSRange(location: 0, length: out.length)
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = 18.75
        paragraph.maximumLineHeight = 18.75
        paragraph.lineBreakMode = .byWordWrapping
        out.setAttributes([.font: NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular),
                           .foregroundColor: Palette.NS.ink, .paragraphStyle: paragraph], range: all)
        sample.enumerateAttributes(in: all) { attributes, range, _ in
            if let font = attributes[.font] as? NSFont {
                let traits = NSFontManager.shared.traits(of: font).intersection([.boldFontMask, .italicFontMask])
                out.addAttribute(.font, value: NSFontManager.shared.convert(NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular),
                                                                           toHaveTrait: traits), range: range)
            }
            for key in [NSAttributedString.Key.underlineStyle, .strikethroughStyle] {
                if let value = attributes[key] { out.addAttribute(key, value: value, range: range) }
            }
        }
        let source = shown as NSString
        var changes: [(NSRange, String)] = []
        source.enumerateSubstrings(in: all, options: [.byLines, .substringNotRequired]) { _, line, _, _ in
            let words = source.substring(with: line)
            let indent = words.prefix { $0 == " " || $0 == "\t" }
            if words.trimmingCharacters(in: .whitespaces).isEmpty, line.location == 0 || NSMaxRange(line) == source.length {
                changes.append((line, "¶"))
                return
            }
            var columns = 0
            for char in indent { columns += char == "\t" ? 4 - columns % 4 : 1 }
            if !indent.isEmpty { changes.append((NSRange(location: line.location, length: indent.utf16.count), String(repeating: "·", count: columns))) }
        }
        // enumerateSubstrings omits the empty line after a final newline.
        if shown == text, text.last?.isNewline == true { changes.append((NSRange(location: source.length, length: 0), "¶")) }
        for (range, marks) in changes.sorted(by: { $0.0.location > $1.0.location }) {
            out.replaceCharacters(in: range, with: NSAttributedString(string: marks, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular),
                .foregroundColor: Palette.NS.faint.withAlphaComponent(0.4), .paragraphStyle: paragraph]))
        }
        return out
    }
}

extension Clips.Clip {
    func lastCopied(now: Date = Date(), calendar: Calendar = .current) -> String {
        let time = last.englishFormatted(date: .omitted, time: .shortened)
        let day: String
        if calendar.isDate(last, inSameDayAs: now) { day = "Today at \(time)" }
        else if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(last, inSameDayAs: yesterday) {
            day = "Yesterday at \(time)"
        } else { day = last.englishFormatted(date: .abbreviated, time: .shortened) }
        return day + (times > 1 ? ", \(times) times" : "")
    }

    var fileKind: String {
        let url = URL(fileURLWithPath: text)
        let values = try? url.resourceValues(forKeys: [.contentTypeKey, .fileSizeKey, .localizedTypeDescriptionKey])
        var parts = [values?.localizedTypeDescription ?? values?.contentType?.localizedDescription ?? "File"]
        if values?.contentType?.conforms(to: .image) == true,
           let image = NSImage(contentsOf: url), let pixels = image.representations.first {
            parts.append("\(pixels.pixelsWide) × \(pixels.pixelsHigh)")
        }
        if let size = values?.fileSize { parts.append(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)) }
        return parts.joined(separator: ", ")
    }

    var folder: String { (URL(fileURLWithPath: text).deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath }
}

/// App icons are looked up once, including a missing application.
@MainActor
final class ClipApps {
    static let shared = ClipApps()
    let folder = NSWorkspace.shared.icon(for: .folder)
    private var icons: [String: NSImage] = [:]
    private var missing: Set<String> = []

    func icon(_ bundle: String?) -> NSImage? {
        guard let bundle, !missing.contains(bundle) else { return nil }
        if let icon = icons[bundle] { return icon }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else {
            missing.insert(bundle)
            return nil
        }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icons[bundle] = icon
        return icon
    }
}
