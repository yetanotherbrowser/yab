import Foundation
import Testing
@testable import Fast

/// A file Yab can't read is refused before the page is given it: the page
/// got a File it couldn't open while upload said it was done.
@MainActor
struct AgentUploadUnreadableTests {
    @Test func unreadableFileIsRefused() throws {
        let folder = URL(fileURLWithPath: "/tmp").appendingPathComponent("yab-unreadable-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("contacts.csv")
        try Data("email\na@example.com\n".utf8).write(to: file)
        let path = file.resolvingSymlinksInPath().path

        #expect(AgentFiles.unreadable(path) == nil)

        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path) }
        let refused = try #require(AgentFiles.unreadable(path))
        #expect(refused.hasPrefix("contacts.csv can't be read"))
        #expect(refused.contains("Don't say it was uploaded"))

        // A named pipe would hold the read open until something writes to it.
        let pipe = folder.appendingPathComponent("feed.csv").path
        #expect(mkfifo(pipe, 0o644) == 0)
        let piped = try #require(AgentFiles.unreadable(pipe))
        #expect(piped.hasPrefix("feed.csv isn't a file Yab can upload"))

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(AgentFiles.privacyFolder(home + "/Documents/a/b.csv") == "your Documents folder")
        #expect(AgentFiles.privacyFolder(home + "/Desktop/b.csv") == "your Desktop folder")
        #expect(AgentFiles.privacyFolder(home + "/Library/Mobile Documents/com~apple~CloudDocs/b.csv") == "iCloud Drive")
        #expect(AgentFiles.privacyFolder("/Volumes/Disk/b.csv") == "that volume")
        #expect(AgentFiles.privacyFolder(home + "/Pictures/b.png") == "that folder")
    }
}
