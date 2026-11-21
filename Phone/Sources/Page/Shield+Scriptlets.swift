import Foundation
import WebKit

/// The lists' scriptlets (##+js), as the Mac has them: one page-world script
/// for every frame of every page that gets the lists, the library
/// (shield-scriptlets.js) with the table of which sites run which. Each
/// frame picks by its own host, so the script never changes with the site;
/// only whether a page has it does, by the same answer as the lists. One
/// script object, made once per table, is shared by every page.
extension Shield {
    nonisolated static let scriptletLibrary: String? = {
        func load(_ name: String) -> String? {
            Bundle.main.url(forResource: name, withExtension: "js").flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        }
        // The click guard (shield-guard.js) goes inside, as on the Mac.
        guard let text = load("shield-scriptlets"), text.contains("__YAB_TABLE__"), let guardText = load("shield-guard") else { return nil }
        return Filters.Scriptlets.library(text, clickGuard: guardText)
    }()

    /// YAB_SHIELD_SCRIPTLETS=0 in the environment, or the launch argument
    /// `-YAB_SHIELD_SCRIPTLETS 0`: no scriptlets anywhere, the lists as
    /// before, so a measure can tell what they cost in the same build.
    nonisolated static func scriptletsAllowed(environment: [String: String] = ProcessInfo.processInfo.environment,
                                             arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
        if environment["YAB_SHIELD_SCRIPTLETS"] == "0" { return false }
        if let at = arguments.firstIndex(of: "-YAB_SHIELD_SCRIPTLETS"), at + 1 < arguments.count { return arguments[at + 1] != "0" }
        return true
    }

    nonisolated static func scriptletsFile(_ build: Int, in folder: URL) -> URL {
        folder.appendingPathComponent("scriptlets-\(build).json")
    }

    /// The page script for a table (Filters.Scriptlets.table), or nil.
    nonisolated static func scriptletSource(_ table: String) -> String? {
        guard !table.isEmpty, let library = scriptletLibrary else { return nil }
        return Filters.Scriptlets.page(library, table: table, off: "null")
    }

    /// A build's table kept beside its lists, or taken away when it has none.
    nonisolated static func keep(_ table: String?, build: Int, in folder: URL) {
        let file = scriptletsFile(build, in: folder)
        if let table { try? Data(table.utf8).write(to: file, options: .atomic) }
        else { try? FileManager.default.removeItem(at: file) }
    }

    /// WebKit takes user scripts off only all at once, so the page's others
    /// go back in their order after this one, which then runs before them
    /// and before the page.
    static func place(_ script: WKUserScript?, replacing old: WKUserScript?, in controller: WKUserContentController) {
        let others = controller.userScripts.filter { $0 !== old }
        controller.removeAllUserScripts()
        if let script { controller.addUserScript(script) }
        for other in others { controller.addUserScript(other) }
    }
}
