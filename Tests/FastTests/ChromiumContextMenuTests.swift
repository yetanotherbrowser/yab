import AppKit
import Testing
import YabCoreClient
@testable import Fast

@MainActor
struct ChromiumContextMenuTests {
    @Test func systemTextInsertionUsesTheNativeClientAndCannotWakeAnUnbuiltPage() throws {
        _ = NSApplication.shared
        let tab = Tab(shy: true)
        defer { tab.close() }
        let page = ChromiumPage(tab: tab)
        defer { page.retire(call: false, pictureInPicture: false) }
        let responder: NSResponder = page
        responder.insertText(NSAttributedString(string: "fixture-only"))
        let ticket = try #require(page.inputMethodTicket)
        #expect(ticket.result == .refused)
        #expect(page.remoteID == nil)
        #expect(!page.hasMarkedText())
    }

    private func context(_ fields: [String: JSONValue]) throws -> ChromiumMenuContext {
        var p: [String: JSONValue] = ["request": .string("r1"), "x": .number(40), "y": .number(60),
                                      "devToolsFrontend": .bool(true)] // The rows these tests name; Inspect has its own.
        p.merge(fields) { $1 }
        return try #require(ChromiumMenuContext(p))
    }
    private func ids(_ rows: [ChromiumMenuRow?]) -> [String] { rows.map { $0?.id ?? ($0 == nil ? "-" : $0!.title) } }
    private func rows(_ c: ChromiumMenuContext, back: Bool = false, askable: Bool = true) -> [ChromiumMenuRow?] {
        ChromiumMenuRow.rows(for: c, searchName: "Kagi", canGoBack: back, canGoForward: false, askable: askable)
    }

    @Test func pagesOfferInspectAndDevToolsItselfDoesNot() throws {
        let page = rows(try context(["devToolsFrontend": .bool(false)]))
        #expect(page.last??.id == "WKMenuItemIdentifierInspectElement")
        #expect(!ids(rows(try context([:]))).contains("WKMenuItemIdentifierInspectElement"))
    }

    @Test func linkRowsMatchWebKitIdentifiersAndCopyTheUnfilteredAddress() throws {
        let c = try context(["link": .string("https://example.org/a"), "unfilteredLink": .string("https://example.org/a#raw")])
        let menu = rows(c)
        #expect(ids(menu) == ["WKMenuItemIdentifierOpenLinkInNewWindow", "YabOpenLinkInSplitView", "YabOpenLinkInPrivateWindow",
                              "WKMenuItemIdentifierOpenLink", "WKMenuItemIdentifierDownloadLinkedFile", "WKMenuItemIdentifierCopyLink",
                              "WKMenuItemIdentifierShareMenu"])
        #expect(menu[5]?.action == .copy("https://example.org/a#raw"))
        #expect(menu[0]?.action == .openTab(URL(string: "https://example.org/a")!))
        // What ⌥-click on the link does, as Arc's menu had it (feedback #1900).
        #expect(menu[1]?.title == "Open in Split View")
        #expect(menu[1]?.action == .openSplit(URL(string: "https://example.org/a")!))
        #expect(menu[2]?.title == "Open Link in Private Window")
        #expect(menu[2]?.action == .openPrivate(URL(string: "https://example.org/a")!))
    }

    @Test func privateTabsOfferNoPrivateWindowRow() throws {
        let c = try context(["link": .string("https://example.org/a")])
        let menu = ChromiumMenuRow.rows(for: c, searchName: "Kagi", canGoBack: false, canGoForward: false, askable: false, privateLink: false)
        #expect(!ids(menu).contains("YabOpenLinkInPrivateWindow"))
    }

    @Test func mailtoLinkCopiesTheAddressAndOpensNoTab() throws {
        let menu = rows(try context(["link": .string("mailto:ada%40example.org?subject=hi")]))
        #expect(ids(menu) == ["WKMenuItemIdentifierCopyLink", "YabCopyEmailAddress"])
        #expect(menu[1]?.action == .copy("ada@example.org"))
    }

    @Test func scriptLinksAreNotOffered() throws {
        let menu = rows(try context(["link": .string("javascript:alert(1)")]))
        #expect(ids(menu) == ["WKMenuItemIdentifierGoBack", "WKMenuItemIdentifierGoForward", "WKMenuItemIdentifierReload"])
    }

    @Test func imageRowsGoThroughYabsImageActions() throws {
        let image = URL(string: "https://cdn.example/p.png")!
        let c = try context(["source": .string(image.absoluteString), "media": .number(1), "hasImage": .bool(true)])
        let menu = rows(c)
        #expect(ids(menu) == ["WKMenuItemIdentifierOpenImageInNewWindow", "WKMenuItemIdentifierDownloadImage",
                              "WKMenuItemIdentifierCopyImage", "YabCaptureImage", "YabCopyImageAddress", "YabAskAboutImage"])
        #expect(menu.compactMap { $0?.action } == [.image(.open, image), .image(.download, image), .image(.copy, image),
                                                   .image(.capture, image), .image(.address, image), .image(.ask, image)])
        #expect(!ids(rows(c, askable: false)).contains("YabAskAboutImage"))
    }

    /// Row 1611: a picture behind a referrer check came back 403 from a fresh
    /// download of its address. Chrome's own Save Image As fetches it as its
    /// frame does, so Download Image runs that whenever Chrome offers it.
    @Test func downloadImageRunsChromesSaveImageAsWhenOffered() throws {
        let image = URL(string: "https://images.example/full.jpg")!
        let fields: [String: JSONValue] = ["source": .string(image.absoluteString), "media": .number(1), "hasImage": .bool(true),
                                           "link": .string("https://example.org/page")]
        let offered = rows(try context(fields.merging(["chrome": .array([.number(50120)])]) { $1 }))
        let row = try #require(offered.first { $0?.id == "WKMenuItemIdentifierDownloadImage" } ?? nil)
        #expect(row.title == "Download Image")
        #expect(row.action == .chrome(50120)) // chrome_command_ids.h IDC_CONTENT_CONTEXT_SAVEIMAGEAS
        // Download Linked File stays its own row, for the link's address.
        #expect(offered.first { $0?.id == "WKMenuItemIdentifierDownloadLinkedFile" }??.action == .download(URL(string: "https://example.org/page")!))
        // Not offered (a Chrome policy turned it off): Yab's own download.
        let plain = rows(try context(fields))
        #expect(plain.first { $0?.id == "WKMenuItemIdentifierDownloadImage" }??.action == .image(.download, image))
    }

    @Test func aWebPageOffersCaptureAndHideAsWebKitsDoes() throws {
        let plain = ChromiumMenuRow.rows(for: try context(["devToolsFrontend": .bool(false)]), searchName: "Kagi", canGoBack: false,
                                         canGoForward: false, askable: true, website: true)
        #expect(ids(plain).suffix(3) == ["YabCapturePage", "YabHideElement", "WKMenuItemIdentifierInspectElement"])
        let link = ChromiumMenuRow.rows(for: try context(["devToolsFrontend": .bool(false), "link": .string("https://example.org/")]),
                                        searchName: "Kagi", canGoBack: false, canGoForward: false, askable: true, website: true)
        #expect(!ids(link).contains("YabCapturePage") && ids(link).contains("YabHideElement"))
        let frontend = ChromiumMenuRow.rows(for: try context([:]), searchName: "Kagi", canGoBack: false, canGoForward: false,
                                            askable: true, website: true)
        #expect(!ids(frontend).contains("YabHideElement"))
    }

    @Test func aVideoSavesThroughYabsOwnRoute() throws {
        let blob = URL(string: "blob:https://site.test/1")!
        let menu = rows(try context(["source": .string(blob.absoluteString), "media": .number(2)]))
        let actions = menu.compactMap { $0?.action }
        #expect(actions.contains(ChromiumMenuRow.Action.saveMedia(blob)))
    }

    /// Register 2582: a video's own rows Chrome's menu has (Loop, Show all
    /// controls, Picture in picture) were dropped, so a YouTube video's second
    /// right-click had no Picture in Picture. They come back in WebKit's words,
    /// order and pictures, each run by Chrome on the video pressed.
    @Test func aVideoOffersChromesPlayerRowsInWebKitsWords() throws {
        let blob = URL(string: "blob:https://www.youtube.com/1")!
        let media: [JSONValue] = [
            .object(["command": .number(50140), "enabled": .bool(true), "checked": .bool(false)]),
            .object(["command": .number(50141), "enabled": .bool(true), "checked": .bool(false)]),
            .object(["command": .number(50137), "enabled": .bool(true), "checked": .bool(false)])]
        let menu = rows(try context(["source": .string(blob.absoluteString), "media": .number(2), "mediaRows": .array(media)]))
        #expect(Array(ids(menu).prefix(4)) == ["WKMenuItemIdentifierShowHideMediaControls", "Loop", "WKMenuItemIdentifierToggleEnhancedFullScreen", "-"])
        #expect(menu.prefix(3).map { $0?.title } == ["Show Controls", "Loop", "Enter Picture in Picture"])
        #expect(menu.prefix(3).map { $0?.action } == [.chrome(50141), .chrome(50140), .chrome(50137)])
        #expect(menu.prefix(3).map { $0?.symbol } == ["eye", "arrow.2.squarepath", "pip.enter"])
        #expect(menu[1]?.checked == false)
        // The video's own address rows stay, after them.
        #expect(ids(menu).contains("WKMenuItemIdentifierOpenMediaInNewWindow") && ids(menu).contains("YabDownloadMedia"))

        // Out in Picture in Picture, looping, controls shown: each says so, as WebKit's.
        let on: [JSONValue] = [50140, 50141, 50137].map {
            .object(["command": .number(Double($0)), "enabled": .bool(true), "checked": .bool(true)])
        }
        let held = rows(try context(["source": .string(blob.absoluteString), "media": .number(2), "mediaRows": .array(on)]))
        #expect(held.prefix(3).map { $0?.title } == ["Hide Controls", "Loop", "Exit Picture in Picture"])
        #expect(held[1]?.checked == true)
        #expect(held.prefix(3).map { $0?.symbol } == ["eye.slash", "arrow.2.squarepath", "pip.exit"])

        // Chrome's row disabled (a video that can't go out): shown, not runnable.
        let off: [JSONValue] = [.object(["command": .number(50137), "enabled": .bool(false), "checked": .bool(false)])]
        let barred = rows(try context(["source": .string(blob.absoluteString), "media": .number(2), "mediaRows": .array(off)]))
        #expect(barred.first??.title == "Enter Picture in Picture" && barred.first??.enabled == false)
    }

    @Test func aSoundHasNoPictureInPictureAndAStreamStillHasItsPlayerRows() throws {
        let media: [JSONValue] = [50140, 50141, 50137].map {
            .object(["command": .number(Double($0)), "enabled": .bool(true), "checked": .bool(false)])
        }
        let sound = rows(try context(["source": .string("https://site.test/a.mp3"), "media": .number(3), "mediaRows": .array(media)]))
        #expect(!ids(sound).contains("WKMenuItemIdentifierToggleEnhancedFullScreen"))
        #expect(ids(sound).prefix(2) == ["WKMenuItemIdentifierShowHideMediaControls", "Loop"])
        // A camera's or a call's video (srcObject) has no address, and still its player rows.
        let stream = rows(try context(["media": .number(2), "mediaRows": .array(media)]))
        #expect(ids(stream).prefix(3) == ["WKMenuItemIdentifierShowHideMediaControls", "Loop", "WKMenuItemIdentifierToggleEnhancedFullScreen"])
    }

    /// Chrome's frame rows, in Chrome's words and places among the video's
    /// own: Save Video Frame As… before Download Video, Copy Video Frame before
    /// Copy Video Address (RenderViewContextMenu::AppendVideoItems).
    @Test func aVideoOffersChromesFrameRowsInChromesPlaces() throws {
        let blob = URL(string: "blob:https://www.youtube.com/1")!
        let media: [JSONValue] = [50130, 50133].map {
            .object(["command": .number(Double($0)), "enabled": .bool(true), "checked": .bool(false)])
        }
        let menu = rows(try context(["source": .string(blob.absoluteString), "media": .number(2), "mediaRows": .array(media)]))
        #expect(Array(ids(menu).prefix(5)) == ["WKMenuItemIdentifierOpenMediaInNewWindow", "Save Video Frame As\u{2026}", "YabDownloadMedia",
                                               "Copy Video Frame", "WKMenuItemIdentifierCopyMediaLink"])
        #expect(menu[1]?.action == .chrome(50130) && menu[3]?.action == .chrome(50133))
        let sound = rows(try context(["source": .string("https://site.test/a.mp3"), "media": .number(3)]))
        #expect(!ids(sound).contains("Copy Video Frame"))
    }

    @Test func linkedImageHasBothSections() throws {
        let c = try context(["link": .string("https://example.org/"), "source": .string("https://cdn.example/p.png"),
                             "media": .number(1), "hasImage": .bool(true)])
        let menu = ids(rows(c))
        // The link's seven rows, Open in Split View and Open Link in Private Window among them, then the image's.
        #expect(menu.firstIndex(of: "-") == 7)
        #expect(menu.contains("WKMenuItemIdentifierCopyLink") && menu.contains("WKMenuItemIdentifierCopyImage"))
    }

    @Test func selectionLooksUpSearchesAndCopiesThroughChrome() throws {
        let c = try context(["selection": .string("  example.com  "), "chrome": .array([.number(50150)])])
        let menu = rows(c)
        #expect(ids(menu) == ["WKMenuItemIdentifierLookUp", "YabGoToSelectedURL", "WKMenuItemIdentifierSearchWeb", "-",
                              "YabMoreCommands", "-", "WKMenuItemIdentifierCopy"])
        #expect(menu[2]?.title == "Search with Kagi")
        #expect(menu[2]?.action == .search("example.com"))
        #expect(menu[4]?.action == .selectionCommand(nil))
        let long = rows(try context(["selection": .string(String(repeating: "word ", count: 20))]))
        #expect(long[0]?.title.count ?? 0 < 45)
    }

    @Test func editableFieldOffersSuggestionsAndOnlyOfferedEditCommands() throws {
        let c = try context(["editable": .bool(true), "misspelled": .string("teh"),
                             "suggestions": .array([.string("the"), .string("tech")]),
                             "chrome": .array([.number(50152)])])
        let menu = rows(c)
        #expect(menu.prefix(2).map { $0?.action } == [.replace("the"), .replace("tech")])
        #expect(menu[2] == nil)
        #expect(menu.suffix(4).map { $0?.enabled } == [false, false, true, false])
        #expect(menu.suffix(4).map { $0?.title } == ["Cut", "Copy", "Paste", "Select All"])
        #expect(menu[menu.count - 2]?.action == .chrome(50152))
        #expect(menu.last??.action == .chrome(50156))
    }

    @Test func spellingRowsAreChromesAndOnlyWhenOffered() throws {
        let c = try context(["editable": .bool(true), "misspelled": .string("teh"), "suggestions": .array([.string("the")]),
                             "spelling": .array([.object(["command": .number(41110), "checked": .bool(false)]),
                                                 .object(["command": .number(41107), "checked": .bool(true)])])])
        let menu = rows(c)
        #expect(menu[1]?.title == "Add to Dictionary" && menu[1]?.action == .chrome(41110))
        let spelling = menu.last ?? nil
        #expect(spelling?.title == "Spelling and Grammar" && spelling?.action == nil)
        #expect(spelling?.rows.first??.checked == true && spelling?.rows.first??.action == .chrome(41107))
    }

    @Test func blankPageHasHistoryRowsAndExtensionRowsLast() throws {
        let c = try context(["extensions": .array([
            .object(["command": .number(49001), "label": .string("Translate with Ext"), "enabled": .bool(true), "rows": .array([])]),
            .object(["command": .number(49002), "label": .string("Ext"), "enabled": .bool(true), "rows": .array([
                .object(["command": .number(49003), "label": .string("Inner"), "enabled": .bool(true), "checked": .bool(true), "rows": .array([])])])])])])
        let menu = rows(c, back: true)
        #expect(ids(menu).prefix(4) == ["WKMenuItemIdentifierGoBack", "WKMenuItemIdentifierGoForward", "WKMenuItemIdentifierReload", "-"])
        #expect(menu[0]?.enabled == true && menu[1]?.enabled == false)
        #expect(menu[4]?.action == .chrome(49001))
        #expect(menu[5]?.action == nil && menu[5]?.rows.first??.action == .chrome(49003))
        #expect(menu[5]?.rows.first??.checked == true)
    }

    @Test func malformedEventIsRefused() {
        #expect(ChromiumMenuContext(["x": .number(1)]) == nil)
        #expect(ChromiumMenuContext(["request": .string("")]) == nil)
    }
}
