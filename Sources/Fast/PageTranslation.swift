import Foundation
import NaturalLanguage
import SwiftUI
import Translation

/// Only this tiny view is invalidated when a translation starts or changes state.
struct PageTranslationHost: View {
    @ObservedObject var translation: PageTranslation

    var body: some View {
        Color.clear.translationTask(translation.configuration) { session in
            await translation.run(session)
        }
    }
}

/// Translates the text of one page with the system's on-device language models.
/// The page adapter lives in yab's isolated content world, never in the site's JS world.
@MainActor
final class PageTranslation: ObservableObject {
    enum Phase: Equatable {
        case original, preparing, translating, translated, failed(String)
    }

    @Published private(set) var phases: [Tab.ID: Phase] = [:]
    @Published var configuration: TranslationSession.Configuration?

    /// A model dependency for deterministic DOM/lifecycle checks. Ordinary
    /// instances use the observed Apple TranslationSession host above.
    typealias Translator = @MainActor ([[String: String]], Locale.Language, Locale.Language) async throws -> [[String: String]]
    private let translator: Translator?
    init(translator: Translator? = nil) { self.translator = translator }

    @MainActor private final class Document {
        let id = UUID()
        let token: String
        let tab: Tab
        let web: any PageHandle
        let url: URL?
        let source: Locale.Language
        let target: Locale.Language
        var watch: Task<Void, Never>?
        init(token: String, tab: Tab, web: any PageHandle, source: Locale.Language, target: Locale.Language) {
            self.token = token; self.tab = tab; self.web = web; self.url = web.url
            self.source = source; self.target = target
        }
        deinit { watch?.cancel() }
    }

    private struct Pending {
        let id: UUID
        let tab: Tab
        let web: any PageHandle
        let url: URL?
        let items: [Item]
        let contexts: [PageTranslationContext]
        let document: Document
        let initial: Bool
    }

    private struct Item {
        let id: String
        let text: String
    }

    private var pending: Pending?
    private var documents: [Tab.ID: Document] = [:]
    private var preparing: [Tab.ID: UUID] = [:]
    private var queued: [Pending] = []
    private var controlledWork: Task<Void, Never>?
    /// Told when a page asked for couldn't be translated, and why.
    var failed: ((Tab, String) -> Void)?
    /// The language each page is going to or is in, where Translate To
    /// picked one other than the Mac's first.
    private var targets: [Tab.ID: Locale.Language] = [:]

    var targetName: String {
        let code = Self.targetCode
        return Locale(identifier: "en").localizedString(forLanguageCode: code) ?? code
    }

    /// The language this page is in now, or would go to.
    func targetName(for tab: Tab) -> String {
        targets[tab.id].map(Self.name) ?? targetName
    }

    func phase(for tab: Tab) -> Phase { phases[tab.id] ?? .original }

    /// The page's rows in its right-click menu: Translate Page to the Mac's
    /// first language (Stop Translating while it goes, Show Original Page
    /// once translated), and Translate To.
    func menuItems(for tab: Tab) -> [NSMenuItem] {
        guard let item = menuItem(for: tab) else { return [] }
        return [item, toItem(for: tab)]
    }

    func menuItem(for tab: Tab) -> NSMenuItem? {
        guard let scheme = tab.address?.scheme, ["http", "https"].contains(scheme) else { return nil }
        let phase = phase(for: tab)
        let title: String
        switch phase {
        case .translated: title = "Show Original Page"
        case .preparing, .translating: title = "Stop Translating"
        case .original, .failed: title = "Translate Page to \(targetName)"
        }
        let item = PageMenuItem(title) { [weak self, weak tab] in
            guard let tab else { return }; self?.toggle(tab)
        }
        item.identifier = NSUserInterfaceItemIdentifier("YabTranslatePage")
        return item
    }

    /// View › Translate Page, by the title App Shortcuts knows it by while
    /// the page is as it came (Hotkeys' title variants keep one key on all
    /// three).
    func barTitle(for tab: Tab?) -> String {
        switch tab.map(phase(for:)) ?? .original {
        case .translated: "Show Original Page"
        case .preparing, .translating: "Stop Translating"
        case .original, .failed, nil: "Translate Page"
        }
    }

    static let barTitles = ["Translate Page", "Show Original Page", "Stop Translating"]

    func canTranslate(_ tab: Tab?) -> Bool {
        guard let scheme = tab?.address?.scheme?.lowercased() else { return false }
        return ["http", "https"].contains(scheme)
    }

    /// Translate To: the page in a language other than the Mac's first.
    /// The Mac's own languages and the ones picked lately are the list,
    /// and every other one macOS translates into waits under More
    /// Languages, by name; the one the page is in now is ticked.
    func toItem(for tab: Tab) -> NSMenuItem {
        let phase = phase(for: tab)
        let item = NSMenuItem(title: "Translate To", action: nil, keyEquivalent: "")
        item.identifier = NSUserInterfaceItemIdentifier("YabTranslateTo")
        item.isEnabled = phase != .preparing && phase != .translating
        item.submenu = FreshMenu("Translate To") { [weak self, weak tab] in
            guard let self, let tab else { return [] }
            return self.languageItems(for: tab)
        }
        Self.learnLanguages()
        return item
    }

    private func languageItems(for tab: Tab) -> [NSMenuItem] {
        let now = phase(for: tab) == .translated ? targets[tab.id] ?? Locale.Language(identifier: Self.targetIdentifier) : nil
        let choices = Self.choices(supported: Self.languages ?? [], preferred: Locale.preferredLanguages + Self.recent)
        func row(_ choice: Choice) -> NSMenuItem {
            let item = PageMenuItem(choice.name) { [weak self, weak tab] in
                guard let tab else { return }; self?.translate(tab, to: choice.language)
            }
            if let now, Self.same(now, choice.language) { item.state = .on }
            return item
        }
        var items = choices.mine.map(row)
        guard !choices.others.isEmpty else { return items }
        if !items.isEmpty { items.append(.separator()) }
        let more = NSMenuItem(title: "More Languages", action: nil, keyEquivalent: "")
        more.identifier = NSUserInterfaceItemIdentifier("YabTranslateMore")
        let rest = NSMenu(title: "More Languages")
        rest.autoenablesItems = false
        rest.items = choices.others.map(row)
        more.submenu = rest
        // The page is in one of these now: said on the way in, too.
        if let now, choices.others.contains(where: { Self.same(now, $0.language) }) { more.state = .on }
        items.append(more)
        return items
    }

    /// Languages picked under Translate To lately, the last first: they
    /// stay in its list beside the Mac's own.
    static let recentKey = "translate.recent"
    static var recent: [String] { Store.settings.stringArray(forKey: recentKey) ?? [] }

    static func remembering(_ language: Locale.Language, in list: [String], keep: Int = 3) -> [String] {
        let id = language.minimalIdentifier
        return Array(([id] + list.filter { !same(Locale.Language(identifier: $0), language) }).prefix(keep))
    }

    /// Translate Page, Stop Translating while it goes, Show Original Page
    /// once it is done.
    func toggle(_ tab: Tab) {
        switch phase(for: tab) {
        case .translated: restore(tab)
        case .preparing, .translating: stop(tab)
        case .original, .failed: Task { await start(tab) }
        }
    }

    /// A long page can take a while: stopped, what was done is put back.
    func stop(_ tab: Tab) {
        restore(tab)
    }

    /// The page in this language, from its own words: one already in
    /// another language is put back first. Asked for the one it is in, it
    /// stays as it is.
    func translate(_ tab: Tab, to language: Locale.Language) {
        // The Mac's own languages are in the list anyway.
        if !Locale.preferredLanguages.contains(where: { Self.same(Locale.Language(identifier: $0), language) }) {
            Store.settings.set(Self.remembering(language, in: Self.recent), forKey: Self.recentKey)
        }
        switch phase(for: tab) {
        case .preparing, .translating: break
        case .translated where Self.same(targets[tab.id] ?? Locale.Language(identifier: Self.targetIdentifier), language): break
        case .original, .failed, .translated: Task { await start(tab, to: language) }
        }
    }

    /// Where a page's words go when Reading Mode comes or goes.
    struct Held { let language: Locale.Language? }

    /// Reading Mode shows a copy of the article over the page (Reader.swift).
    /// A translated page is put back before the reader comes or goes, so
    /// the copy is taken from the page's own words and the page is left as
    /// it came, and `again` translates what is on screen after.
    func holdForReader(_ tab: Tab) -> Held? {
        switch phase(for: tab) {
        case .original, .failed: return nil
        case .preparing, .translating, .translated:
            let held = Held(language: targets[tab.id])
            stop(tab)
            return held
        }
    }

    func again(_ tab: Tab, _ held: Held, after delay: Duration = .zero) {
        Task { [weak self, weak tab] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard let self, let tab, self.phase(for: tab) == .original else { return }
            await self.start(tab, to: held.language)
        }
    }

    struct Choice: Equatable {
        let language: Locale.Language
        let name: String
    }

    /// The rows of Translate To: each of the Mac's languages that macOS
    /// translates into, in the Mac's order and as the Mac has it (English
    /// as in Britain for en-GB), then every other one by name. One row a
    /// language: English as in India or Spanish as in Mexico go with
    /// English and Spanish, while Chinese, written two ways, is two rows.
    /// With nothing heard from macOS yet, the Mac's own languages alone.
    static func choices(supported: [Locale.Language], preferred: [String], in locale: Locale = Locale(identifier: "en")) -> (mine: [Choice], others: [Choice]) {
        var heads: [String: Locale.Language] = [:]
        var order: [String] = []
        for language in supported {
            let key = key(language)
            if let head = heads[key] {
                // The plain one, fr rather than fr-CA, stands for the rest.
                if head.region != nil, language.region == nil { heads[key] = language }
            } else {
                heads[key] = language
                order.append(key)
            }
        }
        let codes = order.compactMap { heads[$0]?.languageCode?.identifier }
        func choice(_ language: Locale.Language) -> Choice {
            let code = language.languageCode?.identifier ?? language.minimalIdentifier
            let script = Locale.Language(identifier: language.maximalIdentifier).script?.identifier
            let id = codes.filter { $0 == code }.count > 1 ? script.map { "\(code)-\($0)" } ?? code : code
            return Choice(language: language, name: locale.localizedString(forIdentifier: id) ?? id)
        }
        var mine: [Choice] = [], taken = Set<String>()
        for identifier in preferred {
            let wanted = Locale.Language(identifier: identifier)
            let key = key(wanted)
            guard !taken.contains(key) else { continue }
            if supported.isEmpty {
                taken.insert(key)
                mine.append(choice(wanted))
            } else if let head = heads[key] {
                taken.insert(key)
                mine.append(choice(supported.first { $0.maximalIdentifier == wanted.maximalIdentifier } ?? head))
            }
        }
        let others = order.filter { !taken.contains($0) }.compactMap { heads[$0].map(choice) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return (mine, others)
    }

    /// A language and the way it is written: en and en-GB are one, zh and
    /// zh-TW two.
    private static func key(_ language: Locale.Language) -> String {
        let full = Locale.Language(identifier: language.maximalIdentifier)
        return [full.languageCode?.identifier, full.script?.identifier].compactMap { $0 }.joined(separator: "-")
    }

    private static func same(_ one: Locale.Language, _ other: Locale.Language) -> Bool {
        key(one) == key(other)
    }

    private static func name(_ language: Locale.Language) -> String {
        let code = language.languageCode?.identifier ?? language.minimalIdentifier
        return Locale(identifier: "en").localizedString(forLanguageCode: code) ?? code
    }

    /// What macOS translates into, asked once, when a page's menu first
    /// opens rather than at launch; Translate To lists it as it opens.
    private static var languages: [Locale.Language]?
    private static var asked = false

    private static func learnLanguages() {
        guard !asked else { return }
        asked = true
        Task { languages = await LanguageAvailability().supportedLanguages }
    }

    func navigationCommitted(_ tab: Tab) {
        clear(tab)
        advance()
    }

    func forget(_ tab: Tab) {
        clear(tab)
        advance()
    }

    private func clear(_ tab: Tab) {
        preparing.removeValue(forKey: tab.id)
        queued.removeAll { $0.tab === tab }
        if pending?.tab === tab {
            controlledWork?.cancel(); controlledWork = nil
            pending = nil; configuration = nil
        }
        if let document = documents.removeValue(forKey: tab.id) {
            document.watch?.cancel()
            Self.disconnect(document.web, token: document.token)
        }
        if phases[tab.id] != nil { phases.removeValue(forKey: tab.id) }
        targets.removeValue(forKey: tab.id)
    }

    private func fail(_ reason: String, on tab: Tab, in web: (any PageHandle)? = nil, token: String? = nil, notice: String? = nil) {
        clear(tab)
        if let web, let token { Self.disconnect(web, token: token) }
        phases[tab.id] = .failed(reason)
        failed?(tab, notice ?? reason)
    }

    private func start(_ tab: Tab, to chosen: Locale.Language? = nil) async {
        guard let web = tab.builtPage, let url = web.url,
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            fail("This page can't be translated", on: tab)
            return
        }
        clear(tab)
        let attempt = UUID()
        preparing[tab.id] = attempt
        phases[tab.id] = .preparing
        targets.removeValue(forKey: tab.id)
        let read = await evaluate(Self.collectScript, in: web)
        // Stopped, or the page went, while it was read.
        guard preparing[tab.id] == attempt, phase(for: tab) == .preparing else {
            if let token = (read as? [String: Any])?["token"] as? String { Self.disconnect(web, token: token) }
            return
        }
        guard let data = read as? [String: Any],
              let token = data["token"] as? String,
              let raw = data["items"] as? [[String: String]] else {
            fail("Couldn't read this page", on: tab, in: web)
            return
        }
        let items = raw.compactMap { item -> Item? in
            guard let id = item["id"], let text = item["text"] else { return nil }
            return Item(id: id, text: text)
        }
        let contexts = (data["groups"] as? [[String: Any]] ?? []).compactMap { group -> PageTranslationContext? in
            guard let id = group["id"] as? String, let rawParts = group["parts"] as? [[String: String]] else { return nil }
            let parts = rawParts.compactMap { part -> PageTranslationContext.Part? in
                guard let id = part["id"], let text = part["text"] else { return nil }
                return .init(id: id, text: text, anchored: part["anchor"] != "false")
            }
            return .init(id: id, parts: parts)
        }
        guard !items.isEmpty else {
            fail("No text to translate on this page", on: tab, in: web, token: token)
            return
        }
        let sample = String(items.prefix(80).map(\.text).joined(separator: " ").prefix(8_000))
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sample)
        let hint = (data["language"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let detected = recognizer.dominantLanguage?.rawValue
        guard hint != nil || detected != nil else {
            fail("Couldn't identify the page language", on: tab, in: web, token: token)
            return
        }
        let target = chosen ?? Locale.Language(identifier: Self.targetIdentifier)
        let targetCode = target.languageCode?.identifier ?? Self.targetCode
        // A declared page language is usually more reliable than detection from
        // repeated menus, numbers, or a short sample. If it is the system
        // language or unsupported, try the actual text instead.
        var candidates: [String] = []
        for code in [hint, detected].compactMap({ $0 }) where !candidates.contains(code) {
            candidates.append(code)
        }
        var source: Locale.Language?
        var alreadyTarget = false
        for code in candidates {
            if Locale(identifier: code).language.languageCode?.identifier == targetCode {
                alreadyTarget = true
                continue
            }
            let language = Locale.Language(identifier: code)
            if translator != nil {
                source = language
                break
            }
            if await LanguageAvailability().status(from: language, to: target) != .unsupported {
                source = language
                break
            }
        }
        guard preparing[tab.id] == attempt, phase(for: tab) == .preparing else {
            Self.disconnect(web, token: token)
            return
        }
        guard let source else {
            if alreadyTarget {
                fail("This page is already in \(Self.name(target))", on: tab, in: web, token: token)
                return
            }
            fail("Translation isn't available for this language", on: tab, in: web, token: token)
            return
        }
        guard tab.builtPage === web, web.url == url else {
            Self.disconnect(web, token: token)
            clear(tab)
            return
        }
        if let previous = pending, previous.initial {
            clear(previous.tab)
        }
        preparing.removeValue(forKey: tab.id)
        let document = Document(token: token, tab: tab, web: web, source: source, target: target)
        documents[tab.id] = document
        queued.insert(Pending(id: UUID(), tab: tab, web: web, url: url, items: items, contexts: contexts,
                              document: document, initial: true), at: 0)
        phases[tab.id] = .translating
        if chosen != nil { targets[tab.id] = target }
        watch(document)
        advance()
    }

    private func advance() {
        guard pending == nil else { return }
        while !queued.isEmpty {
            let next = queued.removeFirst()
            guard current(next.document) else { continue }
            pending = next
            if let translator {
                controlledWork = Task { [weak self] in await self?.run(next, using: translator) }
            } else {
                configure(next.document)
            }
            return
        }
    }

    private func configure(_ document: Document) {
        let source = document.source, target = document.target
        // The SwiftUI task asks to download the language pair when needed.
        if configuration?.source == source && configuration?.target == target {
            configuration?.invalidate()
        } else {
            configuration = .init(source: source, target: target)
        }
    }

    private func current(_ document: Document) -> Bool {
        documents[document.tab.id]?.id == document.id && document.tab.builtPage === document.web && document.web.url == document.url
    }

    private func current(_ request: Pending) -> Bool {
        pending?.id == request.id && current(request.document)
    }

    /// One suspended event read per translated document. next() resolves
    /// from MutationObserver, or with null on disconnect; no timer scans.
    /// No TranslationSession is retained while the page is idle.
    private func watch(_ document: Document) {
        let web = document.web, token = document.token
        document.watch = Task { [weak self, weak document] in
            while !Task.isCancelled {
                let value = await withTaskCancellationHandler {
                    try? await web.evaluate(.function(
                        "const adapter = window.__yabPageTranslation; return adapter?.token === token ? await adapter.next() : null;",
                        arguments: ["token": token]), in: .yab, frame: nil, gesture: false)
                } onCancel: {
                    Task { @MainActor in Self.disconnect(web, token: token) }
                }
                guard !Task.isCancelled, let self, let document, self.current(document),
                      let data = value as? [String: Any], data["token"] as? String == document.token else { return }
                let items = (data["items"] as? [[String: String]] ?? []).compactMap { row -> Item? in
                    guard let id = row["id"], let text = row["text"] else { return nil }
                    return Item(id: id, text: text)
                }
                guard !items.isEmpty else { continue }
                // Incremental fragments need no regrouping of already translated siblings.
                self.queued.append(Pending(id: UUID(), tab: document.tab, web: document.web,
                                           url: document.url, items: items, contexts: [], document: document, initial: false))
                self.advance()
            }
        }
    }

    private func finish(_ request: Pending) {
        guard current(request) else { return }
        pending = nil
        controlledWork = nil
        phases[request.tab.id] = .translated
        advance()
    }

    private func run(_ request: Pending, using translate: Translator) async {
        do {
            for slice in stride(from: 0, to: request.items.count, by: 40) {
                guard current(request) else { return }
                let chunk = request.items[slice..<min(slice + 40, request.items.count)]
                let translated = try await translate(chunk.map { ["id": $0.id, "text": $0.text] }, request.document.source, request.document.target)
                guard current(request) else { return }
                await apply(translated, for: request)
            }
            finish(request)
        } catch {
            guard current(request) else { return }
            fail(error.localizedDescription, on: request.tab, notice: "Couldn\u{2019}t translate this page")
            advance()
        }
    }

    func run(_ session: TranslationSession) async {
        guard let request = pending else { return }
        do {
            var remaining = request.items
            if #available(macOS 26.4, *) {
                for context in request.contexts {
                    try Task.checkCancellation()
                    guard current(request) else { return }
                    // Batch responses can omit attributedTargetText; the direct
                    // attributed overload preserves the node alignment we need.
                    let answer = try await session.translate(context.source)
                    guard current(request) else { return }
                    if let translated = context.aligned(answer) {
                        await apply(translated, for: request)
                        let covered = Set(context.parts.map(\.id))
                        remaining.removeAll { covered.contains($0.id) }
                    }
                }
            }
            for slice in stride(from: 0, to: remaining.count, by: 40) {
                try Task.checkCancellation()
                guard current(request) else { return }
                let chunk = Array(remaining[slice..<min(slice + 40, remaining.count)])
                let batch = chunk.map { TranslationSession.Request(sourceText: $0.text, clientIdentifier: $0.id) }
                var translated: [[String: String]] = []
                for try await answer in session.translate(batch: batch) {
                    if let id = answer.clientIdentifier {
                        translated.append(["id": id, "text": answer.targetText])
                    }
                }
                guard current(request) else { return }
                await apply(translated, for: request)
            }
            finish(request)
        } catch {
            guard current(request) else { return }
            fail(error.localizedDescription, on: request.tab, notice: "Couldn\u{2019}t translate this page")
            advance()
        }
    }

    private func apply(_ translated: [[String: String]], for request: Pending) async {
        guard current(request) else { return }
        _ = try? await request.web.evaluate(.function(
            "if (window.__yabPageTranslation?.token === token) window.__yabPageTranslation.apply(batch);",
            arguments: ["token": request.document.token, "batch": translated]),
            in: .yab, frame: nil, gesture: false)
    }

    private func restore(_ tab: Tab) {
        clear(tab)
        advance()
    }

    private static func disconnect(_ web: any PageHandle, token: String) {
        web.evaluate(.function("if (window.__yabPageTranslation?.token === token) window.__yabPageTranslation.restore();",
                               arguments: ["token": token]), in: .yab, frame: nil, gesture: false, done: nil)
    }

    private func evaluate(_ script: String, in web: any PageHandle) async -> Any? {
        await withCheckedContinuation { continuation in
            web.runInYab(script) { result in continuation.resume(returning: result) }
        }
    }

    private static var targetCode: String {
        Locale(identifier: targetIdentifier).language.languageCode?.identifier ?? "en"
    }

    private static var targetIdentifier: String {
        Locale.preferredLanguages.first ?? Locale.current.identifier
    }

    static let collectScript = #"""
    (() => {
      if (window.__yabPageTranslation) window.__yabPageTranslation.restore();
      const token = Date.now().toString(36) + '-' + Math.random().toString(36).slice(2);
      const originals = new Map(), known = new WeakMap();
      const items = [], blocks = new Map();
      let output = items, nextID = 0, live = true, waiting = null, scheduled = false;
      const batches = [], dirty = new Set();
      const groupSelector = 'p,h1,h2,h3,h4,h5,h6,li,dt,dd,figcaption,caption,td,th,button,label';
      const skip = 'script,style,noscript,code,pre,svg,canvas,textarea,input,[contenteditable],[translate="no"],[hidden],[aria-hidden="true"]';
      // Preserve Reading Mode's existing root and deferred article paragraphs.
      const reader = window.__yabReader && window.__yabReader.on() ? document.getElementById('yab-reader') : null;
      const root = reader || document.body;
      const seen = element => reader
        ? !!element.closest('.yab-later') || !element.checkVisibility || element.checkVisibility()
        : !element.checkVisibility || element.checkVisibility({ visibilityProperty: true });
      function eligible(owner, attribute) {
        const element = owner.nodeType === Node.TEXT_NODE ? owner.parentElement : owner;
        if (attribute === 'value' && !owner.matches('input[type="button"],input[type="submit"],input[type="reset"]')) return false;
        return owner.isConnected && root.contains(owner) && element && seen(element) &&
          !(attribute ? element.closest('[translate="no"],[hidden],[aria-hidden="true"]') : element.closest(skip));
      }
      function keep(owner, attribute, source, read, write, spaced, includeBlank = false) {
        if (!source || (!source.trim() && !includeBlank)) return;
        let keys = known.get(owner);
        if (!keys) known.set(owner, keys = new Map());
        const oldID = keys.get(attribute), old = originals.get(oldID);
        // Observer also hears our own writes. A translated value, or an
        // unchanged request already in flight, is never translated again.
        if (old && (source === old.translated || (source === old.source && old.pending))) return;
        if (oldID) originals.delete(oldID);
        const id = String(++nextID);
        keys.set(attribute, id);
        originals.set(id, { owner, attribute, source, read, write, spaced, translated: null, pending: true });
        if (source.trim()) output.push({ id, text: source.trim() });
        return id;
      }
      function scan(scope, initial = false) {
        if (!scope.isConnected || !(scope === root || root.contains(scope))) return;
        function text(node) {
          const parent = node.parentElement;
          if (!parent || !eligible(node, '')) return;
          const block = parent.closest(groupSelector);
          const id = keep(node, '', node.textContent, () => node.isConnected ? node.textContent : null,
            value => { node.textContent = value; }, true, !!block);
          if (initial && id && block) {
            if (!blocks.has(block)) blocks.set(block, []);
            blocks.get(block).push({ id, text: node.textContent, anchor: parent === block ? 'false' : 'true' });
          }
        }
        if (scope.nodeType === Node.TEXT_NODE) text(scope);
        else {
          const walker = document.createTreeWalker(scope, NodeFilter.SHOW_TEXT);
          while (walker.nextNode()) text(walker.currentNode);
        }
        if (scope.nodeType !== Node.ELEMENT_NODE) return;
        const selector = 'input[placeholder],textarea[placeholder],input[type="button"],input[type="submit"],input[type="reset"]';
        for (const element of [...(scope.matches(selector) ? [scope] : []), ...scope.querySelectorAll(selector)]) {
          const attribute = element.hasAttribute('placeholder') ? 'placeholder' : 'value';
          if (!eligible(element, attribute)) continue;
          keep(element, attribute, element.getAttribute(attribute), () => element.isConnected ? element.getAttribute(attribute) : null,
            value => { element.setAttribute(attribute, value); }, false);
        }
      }
      scan(root, true);
      const groups = [];
      for (const [block, parts] of blocks) {
        if (parts.filter(part => part.text.trim()).length < 2 || parts.map(part => part.text).join('').length > 4000) continue;
        if (block.querySelector(skip + ',br,' + groupSelector)) continue;
        if ([...block.querySelectorAll('*')].some(element => {
          const style = getComputedStyle(element);
          return !['inline', 'contents'].includes(style.display) || (!reader && style.visibility !== 'visible');
        })) continue;
        const id = 'group-' + groups.length;
        for (const part of parts) originals.get(part.id).group = id;
        groups.push({ id, parts });
      }
      blocks.clear();
      function flush() {
        scheduled = false;
        if (!live) return;
        output = [];
        const roots = [...dirty]; dirty.clear();
        for (const scope of roots) {
          if (roots.some(other => other !== scope && other.contains(scope))) continue;
          scan(scope);
        }
        if (!output.length) return;
        const batch = { token, items: output };
        if (waiting) { const answer = waiting; waiting = null; answer(batch); }
        else batches.push(batch);
      }
      function prune(scope) {
        if (scope.isConnected) return;
        const keys = known.get(scope);
        if (keys) { for (const id of keys.values()) originals.delete(id); keys.clear(); }
        for (const child of scope.childNodes) prune(child);
      }
      const observer = new MutationObserver(records => {
        for (const record of records) {
          if (record.type === 'childList') {
            for (const node of record.addedNodes) dirty.add(node);
            for (const node of record.removedNodes) prune(node);
          } else dirty.add(record.target);
        }
        if (dirty.size && !scheduled) { scheduled = true; queueMicrotask(flush); }
      });
      observer.observe(root, { subtree: true, childList: true, characterData: true, attributes: true,
        attributeFilter: ['hidden', 'aria-hidden', 'style', 'class', 'open', 'translate', 'contenteditable', 'placeholder', 'value'] });
      function restore() {
        live = false;
        observer.disconnect();
        window.removeEventListener('pagehide', restore);
        dirty.clear(); batches.length = 0;
        if (waiting) { const answer = waiting; waiting = null; answer(null); }
        for (const entry of originals.values()) {
          if (entry.translated !== null && entry.read() === entry.translated) entry.write(entry.source);
        }
        originals.clear();
      }
      window.addEventListener('pagehide', restore, { once: true });
      window.__yabPageTranslation = {
        token,
        next() {
          if (!live) return Promise.resolve(null);
          if (batches.length) return Promise.resolve(batches.shift());
          return new Promise(resolve => { waiting = resolve; });
        },
        apply(batch) {
          if (!live) return;
          const changed = new Set(batch.filter(({ id }) => {
            const entry = originals.get(String(id));
            return !entry || entry.read() !== entry.source;
          }).map(({ id, group }) => group || originals.get(String(id))?.group));
          for (const { id, text, exact, group } of batch) {
            const entry = originals.get(String(id));
            if (!entry) continue;
            entry.pending = false;
            if (entry.read() !== entry.source || (group && changed.has(group)) || !eligible(entry.owner, entry.attribute)) continue;
            const leading = entry.spaced && !exact ? entry.source.match(/^\s*/)[0] : '';
            const trailing = entry.spaced && !exact ? entry.source.match(/\s*$/)[0] : '';
            entry.translated = leading + text + trailing;
            entry.write(entry.translated);
          }
        },
        restore
      };
      return { token, language: document.documentElement.lang || '', items, groups };
    })()
    """#
}

/// View › Translate Page: the page's own Translate Page, Stop Translating
/// while it goes and Show Original Page once done, on the menu bar so App
/// Shortcuts and Settings › Shortcuts can give it a key.
struct TranslatePageMenu: View {
    let browser: Browser
    @ObservedObject var translation: PageTranslation

    var body: some View {
        let tab = browser.active
        Button(translation.barTitle(for: tab)) { _ = browser.toggleTranslation() }
            .shortcut(.translatePage)
            .disabled(!translation.canTranslate(tab))
    }
}

extension Browser {
    /// Translate Page's key and menu item, on the page in front.
    func toggleTranslation() -> Bool {
        guard let tab = active, pageTranslation.canTranslate(tab) else { return false }
        pageTranslation.toggle(tab)
        return true
    }
}
