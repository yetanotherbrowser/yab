import AppKit
import SQLite3
import os

// Files between an agent and your Mac, and the few things it may read off
// it with your yes.
//
// Up: `upload` gives a page files from the Mac, after a yes at the page's
// foot that names them. The page's own file picker is answered with them,
// so it works wherever a person would press Attach; a page that never opens
// one is given them straight into its file field. Never from the hidden
// corners of home (keys, keychains, other browsers' and yab's own folders),
// never more than 100 MB a file, and a task kept to the browser can only
// give back what it downloaded itself.
//
// Down: what an agent downloads, and a page it prints, lands in a folder of
// its task's, ~/Downloads/yab/<task>/, through the downloads you see.
//
// And codes: the latest one-time code in Messages, when you turned that on
// and say yes, for a task with full access.

@MainActor
final class AgentFiles {
    static let shared = AgentFiles()

    struct Got {
        let session: String
        var path: String
        var done = false
        var failed: String?
    }

    /// Downloads an agent is owed, by session, in the order they began.
    private(set) var got: [String: [Got]] = [:]
    /// Tabs of yours where an agent has just asked for a download: the next
    /// one from there is its.
    var expecting: [UUID: (session: String, until: Date)] = [:]
    private var mine: [ObjectIdentifier: (session: String, index: Int)] = [:]

    // MARK: - the task's folder

    /// ~/Downloads/yab/<task>/, made when first needed.
    func folder(for id: String) -> URL {
        let agents = Agents.shared
        let root = agents.session(agents.root(of: id))
        let said = root?.title ?? root?.prompt ?? "Task"
        let words = said.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).prefix(6).joined(separator: " ")
        let name = (words.isEmpty ? "Task" : String(words.prefix(48))) + " " + String(id.suffix(4))
        let base = (agents.browser?.prefs.downloads ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0])
        let url = base.appendingPathComponent("yab").appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - down

    /// Where a download goes, if it is an agent's: one from its own tab,
    /// or from a tab of yours it just asked one of.
    func claim(_ download: any PageDownload) -> (URL, String)? {
        guard let web = download.page, let tab = Agents.shared.browser?.tabs.first(where: { $0.builtPage === web }) else { return nil }
        var session: String?
        if let wait = expecting[tab.id], wait.until > Date() {
            session = wait.session
            expecting[tab.id] = nil
        } else if tab.bench, let agent = tab.agent, agent != Agents.script {
            session = agent
        }
        guard let session else { return nil }
        return (folder(for: session), session)
    }

    func began(_ download: any PageDownload, at url: URL, for session: String) {
        got[session, default: []].append(Got(session: session, path: url.path))
        mine[ObjectIdentifier(download)] = (session, got[session]!.count - 1)
    }

    func ended(_ download: any PageDownload, error: String? = nil) {
        guard let (session, index) = mine.removeValue(forKey: ObjectIdentifier(download)), got[session]?.indices.contains(index) == true else { return }
        got[session]![index].done = true
        got[session]![index].failed = error
        // The name WebKit settled on, if it changed it.
        if error == nil, let file = download.progress.fileURL { got[session]![index].path = file.path }
    }

    // MARK: - up

    /// Why a file can't go up, or nil when it can.
    /// A task kept to the browser may give a page what it downloaded
    /// itself, and a file its own words name by path: `yab "upload
    /// ~/Desktop/icon.png as the app icon"`, or one attached in the chat
    /// (feedback #141, where the icon the caller made was refused and the
    /// agent asked the person to pick it).
    func refuse(_ url: URL, session: String, full: Bool, told: [String] = []) -> String? {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { return "no file at \(url.path)" }
        guard !isDir.boolValue else { return "\(url.lastPathComponent) is a folder: zip it first, or give its files" }
        if !full, !AgentFiles.named(url, in: told) {
            let own = folder(for: session).resolvingSymlinksInPath().path
            guard path.hasPrefix(own + "/") else {
                return "this task is kept to the browser: it can upload what it downloaded itself (into \(own)) and files its task names by path, and \(url.path) is neither. Call computer_access saying which file you need to upload, then upload again"
            }
        }
        // Nothing hidden in home, no keys, no keychains, no browser's own
        // folders, yab's included.
        if path.hasPrefix(home + "/") {
            let inside = path.dropFirst(home.count + 1).split(separator: "/")
            if inside.contains(where: { $0.hasPrefix(".") }) { return "\(url.lastPathComponent) is in a hidden folder, which Yab never uploads" }
        }
        let barred = ["/Library/Keychains", "/Library/Application Support/Google", "/Library/Application Support/Arc",
                      "/Library/Application Support/Firefox", "/Library/Safari", "/Library/Cookies", "/Library/Messages",
                      "/Library/Mail", "/Library/Application Support/\(Store.name)", "/Library/Application Support/\(Store.oldName)",
                      "/Library/Application Support/BraveSoftware", "/Library/Application Support/Microsoft Edge",
                      "/Library/Application Support/Dia", "/Library/Application Support/Chromium"]
        // A file mail brought, kept where Files lists it, may go up like
        // any other the person has: the card still asks first.
        let mails = Store.folder.appendingPathComponent("mail").resolvingSymlinksInPath().path + "/"
        let mailFile = path.hasPrefix(mails) && path.contains(".noindex/files/")
        if !mailFile, barred.contains(where: { path.hasPrefix(home + $0) }) || path.hasPrefix("/private/etc") || path.hasPrefix("/etc/") {
            return "\(url.lastPathComponent) is somewhere Yab never uploads from"
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
        guard size <= 100 << 20 else { return "\(url.lastPathComponent) is over 100 MB" }
        return nil
    }

    /// Why Yab can't read the file's bytes, or nil when it can. macOS lets
    /// an app without Files and Folders access see a file in Documents,
    /// Desktop or Downloads (its name, its size) but not read it: the page
    /// was given a File it couldn't open, NotReadableError, while upload
    /// said it was done (#1090, a CSV in ~/Documents). Only a regular file
    /// is opened: a named pipe's open would wait for a writer forever.
    nonisolated static func unreadable(_ path: String) -> String? {
        let name = (path as NSString).lastPathComponent
        var info = stat()
        guard stat(path, &info) == 0 else { return "\(name) can't be read (\(String(cString: strerror(errno)))). Don't say it was uploaded" }
        guard info.st_mode & S_IFMT == S_IFREG else { return "\(name) isn't a file Yab can upload (a pipe, a device or a socket)" }
        let fd = open(path, O_RDONLY | O_NONBLOCK)
        var failure = fd < 0 ? errno : 0
        if fd >= 0 {
            var byte: UInt8 = 0
            if read(fd, &byte, 1) < 0 { failure = errno }
            close(fd)
        }
        switch failure {
        case 0: return nil
        case EPERM:
            return "macOS doesn't let Yab read \(name) in \(privacyFolder(path)): the user can turn on Yab under System Settings › Privacy & Security › Files and Folders, then upload again. Don't say it was uploaded"
        default:
            return "\(name) can't be read (\(String(cString: strerror(failure)))). Don't say it was uploaded"
        }
    }

    /// The folder macOS asks about, as Files and Folders names it.
    nonisolated static func privacyFolder(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let folders = ["Documents": "your Documents folder", "Desktop": "your Desktop folder", "Downloads": "your Downloads folder",
                       "Library/Mobile Documents": "iCloud Drive"]
        for (inside, said) in folders where path.hasPrefix(home + "/" + inside + "/") { return said }
        return path.hasPrefix("/Volumes/") ? "that volume" : "that folder"
    }

    /// Whether these words name the file by its path, as given, as the
    /// disk has it (/tmp is /private/tmp), or from ~.
    static func named(_ url: URL, in told: [String]) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let given = url.standardizedFileURL.path
        let real = url.standardizedFileURL.resolvingSymlinksInPath().path
        var forms: Set<String> = [given, real]
        for form in [given, real] {
            if form.hasPrefix("/private/") { forms.insert(String(form.dropFirst("/private".count))) }
            if form.hasPrefix(home + "/") { forms.insert("~" + form.dropFirst(home.count)) }
        }
        return told.contains { words in forms.contains { words.contains($0) } }
    }

    static func size(_ urls: [URL]) -> String {
        let bytes = urls.reduce(0) { $0 + ((try? FileManager.default.attributesOfItem(atPath: $1.path)[.size] as? Int) ?? 0) }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    /// File fields wherever a page keeps them: in shadow roots (a web
    /// component's upload button) and its own site's frames too, which
    /// querySelector alone never reaches.
    static let deep = """
    const deepFiles = root => {
      const out = [];
      const visit = node => {
        if (!node) return;
        if (node.matches && node.matches('input[type=file]')) out.push(node);
        if (node.shadowRoot) visit(node.shadowRoot);
        if (node.tagName === 'IFRAME') { let d = null; try { d = node.contentDocument; } catch (e) {} if (d) visit(d.documentElement); }
        for (const c of node.children || []) visit(c);
      };
      visit(root);
      return out;
    };
    // The field a ref means: itself, a label's, inside it, or beside it in
    // what holds it (a drop zone's hidden input sits next to its button),
    // nearest first.
    const fieldFor = el => {
      if (!el) return null;
      if (el.matches('input[type=file]')) return el;
      if (el.tagName === 'LABEL' && el.control && el.control.type === 'file') return el.control;
      const label = el.closest && el.closest('label');
      if (label && label.control && label.control.type === 'file') return label.control;
      // Never the whole page's: a drop zone of its own isn't the field of
      // another section.
      let node = el;
      for (let up = 0; node && up < 5 && !node.matches('body,html'); up++) {
        const found = deepFiles(node);
        if (found.length) return found[0];
        if (node.matches('form,section,article,main,[role=dialog],dialog')) break;
        node = node.parentNode instanceof ShadowRoot ? node.parentNode.host : node.parentElement;
      }
      return null;
    };
    """

    /// Straight into the page's file field, for a page that never opens its
    /// picker: the one ref names, near it, or the page's last; with no field
    /// at all, dropped on what ref names, as a drag from Finder would.
    static let intoField = deep + """
    const S = globalThis.__yab;
    let el = ref && S ? S.refs.get(ref) : null;
    if (el && !el.isConnected) el = null;
    const list = () => {
      const dt = new DataTransfer();
      for (const f of files) {
        const bytes = Uint8Array.from(atob(f.data), c => c.charCodeAt(0));
        dt.items.add(new File([bytes], f.name, { type: f.type || 'application/octet-stream', lastModified: Date.now() }));
      }
      return dt;
    };
    let input = fieldFor(el);
    if (!input && !el) input = deepFiles(document.documentElement).pop();
    if (input) {
      input.files = list().files;
      input.dispatchEvent(new Event('input', { bubbles: true, composed: true }));
      input.dispatchEvent(new Event('change', { bubbles: true, composed: true }));
      return { done: 'field', count: input.files.length };
    }
    if (!el) return { error: 'no file field on this page: give upload the ref of what attaches a file (a button, a drop zone)' };
    // A drop zone: the drag a person makes from Finder, onto it.
    el.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' });
    const r = el.getBoundingClientRect();
    const at = { clientX: r.left + r.width / 2, clientY: r.top + r.height / 2, bubbles: true, cancelable: true, composed: true };
    const dt = list();
    let taken = false;
    for (const type of ['dragenter', 'dragover', 'drop']) {
      let ev;
      try { ev = new DragEvent(type, Object.assign({ dataTransfer: dt }, at)); } catch (e) { ev = null; }
      if (!ev || !ev.dataTransfer) { ev = new Event(type, at); Object.defineProperty(ev, 'dataTransfer', { value: dt }); }
      el.dispatchEvent(ev);
      if (type !== 'dragenter' && ev.defaultPrevented) taken = true;
    }
    if (!taken) return { error: 'no file field at that ref, and it took no drop: give upload the ref of the button or drop zone that attaches a file' };
    return { done: 'drop', count: files.length };
    """

    /// The file field ref means (itself, a label's, inside or beside it), or
    /// with no ref the page's last: the element itself, for Chromium's
    /// DOM.setFileInputFiles to fill by path. Null when there is none.
    static let field = deep + """
    const S = globalThis.__yab;
    const el = ref && S ? S.refs.get(ref) : null;
    if (ref && (!el || !el.isConnected)) throw new Error('stale ref ' + ref + ', take a new snapshot');
    return fieldFor(el) || (el ? null : deepFiles(document.documentElement).pop() || null);
    """

    /// The ref's own file field (or one beside it), clicked in script,
    /// which opens the picker yab answers; or where to click with the
    /// mouse, for a button that opens one itself.
    static let opener = deep + """
    const S = globalThis.__yab;
    const el = S && S.refs.get(ref);
    if (!el || !el.isConnected) return { error: 'stale ref ' + ref + ', take a new snapshot' };
    const own = el.matches('input[type=file]') ? el : (el.tagName === 'LABEL' && el.control && el.control.type === 'file' ? el.control : null);
    if (own) { own.click(); return { done: 'script' }; }
    el.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' });
    const r = el.getBoundingClientRect();
    return { x: r.left + r.width / 2, y: r.top + r.height / 2 };
    """

    // MARK: - signing in

    /// A yes to sign in, kept for the steps of one sign-in: a name page,
    /// then a password page.
    var signIns: [String: (user: String, at: Date)] = [:]

    static let submit = """
    const shown = e => e && e.offsetParent !== null && e.getBoundingClientRect().width > 0;
    const pass = [...document.querySelectorAll('input[type=password]')].find(shown);
    const field = pass || [...document.querySelectorAll('input[type=email],input[autocomplete=username],input[autocomplete=email],input[name*=user i],input[name*=email i],input[name*=login i],input[id*=user i],input[id*=email i],input[type=text]')].find(shown);
    if (!field) return { error: 'no sign-in field on this page' };
    if (phase === 'focus') { field.focus(); return { done: 'focused', password: !!pass }; }
    const form = field.closest('form');
    const words = /^(sign ?in|log ?in|next|continue|submit|verify)\\b/i;
    const buttons = [...(form || document).querySelectorAll('button,input[type=submit],[role=button]')].filter(shown);
    const button = buttons.find(b => b.type === 'submit' && (b.innerText || b.value || '').trim()) || buttons.find(b => words.test((b.innerText || b.value || b.getAttribute('aria-label') || '').trim()));
    if (button) { button.click(); return { done: 'clicked', password: !!pass }; }
    if (form && form.requestSubmit) { form.requestSubmit(); return { done: 'submitted', password: !!pass }; }
    field.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }));
    return { done: 'entered', password: !!pass };
    """

    /// The saved names for a site, no secrets read.
    static func users(for host: String) -> [Vault.Entry] {
        let domain = Vault.registrable(host)
        return Vault.entries()
            .filter { $0.host == host || Vault.registrable($0.host) == domain }
            .sorted { ($0.host == host ? 0 : 1, -($0.used?.timeIntervalSince1970 ?? 0)) < ($1.host == host ? 0 : 1, -($1.used?.timeIntervalSince1970 ?? 0)) }
    }

    // MARK: - a code from Messages

    enum Trouble: Error {
        case access
        var said: String { "Yab can't read Messages: it needs Full Disk Access (System Settings › Privacy & Security › Full Disk Access). Granting it has macOS quit and reopen Yab: the page the person is on comes back as one of their tabs, so find it again with tabs before carrying on" }
    }

    /// Codes in messages that came in the last few minutes, newest first:
    /// who from, how long ago, the code, and the line it was in.
    nonisolated static func codes(minutes: Double) -> Result<[String], AgentFiles.Trouble> {
        texts(minutes: minutes).map { texts in texts.compactMap { line($0.text, at: $0.at, from: $0.from) } }
    }

    /// Texts that came in the last few minutes, newest first.
    nonisolated static func texts(minutes: Double) -> Result<[(text: String, at: Date, from: String)], AgentFiles.Trouble> {
        // A test world's phone: texts an eval put there (agent-sms-fake).
        if let fake = fakeTexts.withLock({ $0 }) {
            let since = Date().addingTimeInterval(-minutes * 60)
            return .success(fake.filter { $0.at > since }.sorted { $0.at > $1.at })
        }
        let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Messages/chat.db").path
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return .failure(.access)
        }
        defer { sqlite3_close(db) }
        let since = (Date().timeIntervalSinceReferenceDate - minutes * 60) * 1_000_000_000
        let sql = "SELECT m.text, m.date, h.id FROM message m LEFT JOIN handle h ON m.handle_id = h.ROWID WHERE m.is_from_me = 0 AND m.date > ? ORDER BY m.date DESC LIMIT 30"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return .failure(.access)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, since)
        var out: [(text: String, at: Date, from: String)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let raw = sqlite3_column_text(statement, 0) else { continue }
            let text = String(cString: raw)
            let when = Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 1) / 1_000_000_000)
            let from = sqlite3_column_text(statement, 2).map { String(cString: $0) } ?? "?"
            out.append((text, when, from))
        }
        return .success(out)
    }

    /// A text with a code in it as the agent reads it: the code, who from,
    /// how long ago, and the text.
    nonisolated private static func line(_ text: String, at when: Date, from: String) -> String? {
        let pattern = try? NSRegularExpression(pattern: #"(?<![\d-])(\d{4,8}|\d{3}[- ]\d{3})(?![\d-])"#)
        guard let pattern, let match = pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        let ago = max(0, Int(Date().timeIntervalSince(when) / 60))
        return "\(text[range]) · from \(from), \(ago == 0 ? "just now" : "\(ago) min ago") · \(text.prefix(140))"
    }

    /// A test run's texts, in place of Messages; nil everywhere else.
    nonisolated static let fakeTexts = OSAllocatedUnfairLock<[(text: String, at: Date, from: String)]?>(initialState: nil)
}
