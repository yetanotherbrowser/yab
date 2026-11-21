import Foundation

/// Files a tab opens that are documents rather than pages: a PDF, a Word,
/// Excel, PowerPoint, Pages, Numbers or Keynote file, rich text. Each opens
/// in the system's viewer (QuickLook), which saves and shares it, as a file
/// in Files would; WebKit's own view of them has no way to keep the file.
/// Pictures, video, sound and text stay pages.
nonisolated enum PageDocument {
    /// As the Mac's PDFDesk reads a PDF: what servers really send, not only
    /// application/pdf.
    static let types: Set<String> = [
        "application/pdf", "application/x-pdf", "text/pdf", "text/x-pdf", "application/acrobat", "applications/vnd.pdf", "application/vnd.pdf",
        "application/msword", "application/vnd.ms-excel", "application/vnd.ms-powerpoint",
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        "application/vnd.openxmlformats-officedocument.presentationml.presentation",
        "application/vnd.apple.pages", "application/vnd.apple.numbers", "application/vnd.apple.keynote",
        "application/x-iwork-pages-sffpages", "application/x-iwork-numbers-sffnumbers", "application/x-iwork-keynote-sffkey",
        "application/rtf", "text/rtf",
    ]

    static func opensInViewer(_ mimeType: String?) -> Bool {
        guard let type = mimeType?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased() else { return false }
        return types.contains(type)
    }
}
