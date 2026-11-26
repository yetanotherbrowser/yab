import AppKit
import Foundation

// Gemini on this Mac: whether Google's Antigravity CLI (`agy`) is here,
// whether it is signed in to the person's Google account in Yab's profile
// (GeminiSupport.profile), and the models it lists. The person signs in
// themselves, in a Yab tab, with Google's own sign-in; Yab never sees a
// token. A model list alone never proves the keychain login is usable.

/// `agy models` as picker rows.
enum GeminiModels {
    /// What `--effort` takes.
    // The installed CLI's Gemini catalog and init checks accept these
    // levels. Extra high and Max reject the current Flash models.
    nonisolated static let efforts = ["low", "medium", "high"]

    /// How much a Gemini model reads at once: every one `agy` lists takes 1M.
    nonisolated static let context = 1_048_576

    nonisolated static func rows(_ output: String) -> [AgentModel] {
        GeminiSupport.models(output).map { row in
            model(row.id, name: row.name.isEmpty ? GeminiSupport.title(row.id) : row.name)
        }
    }

    /// A row with its line under the name and its context, which `agy`
    /// doesn't say: "Gemini 3.8 Flash (High)" thinks longest.
    nonisolated static func model(_ id: String, name: String) -> AgentModel {
        AgentModel(cli: "gemini", model: id, name: name, about: about(name), efforts: efforts, context: context)
    }

    nonisolated static func about(_ name: String) -> String {
        let lower = name.lowercased()
        let last = lower.split(whereSeparator: { " -()".contains($0) }).last.map(String.init)
        if last == "high" { return "Thinks longest, for hard tasks." }
        if last == "medium" { return "Balanced, for most work." }
        if last == "low" { return "The fastest, for short text." }
        if lower.contains("pro") { return "For long, hard tasks." }
        if lower.contains("flash") { return "Fast and capable, for most work." }
        return ""
    }
}

@MainActor
final class GeminiAccount: ObservableObject {
    static let shared = GeminiAccount()

    /// The CLI found on this Mac, nil when there is none.
    @Published private(set) var binary: String?
    /// Whether it answered in Yab's profile when last asked; nil before.
    @Published private(set) var signedIn: Bool?
    @Published private(set) var models: [AgentModel] = []
    /// Who the CLI said it is signed in as, kept between launches: reading
    /// it again means starting the CLI, which takes seconds.
    @Published private(set) var identity: GeminiIdentity? = Store.testing ? nil
        : Store.settings.data(forKey: "gemini.identity").flatMap { try? JSONDecoder().decode(GeminiIdentity.self, from: $0) } {
        didSet {
            guard !Store.testing, identity != oldValue else { return }
            Store.settings.set(identity.flatMap { try? JSONEncoder().encode($0) }, forKey: "gemini.identity")
        }
    }
    @Published private(set) var quota: PlanQuota?
    @Published private(set) var notice: String?
    var choice: GeminiChoice?
    private var login: GeminiLogin?
    private var checkedLogin = false

    @Published private(set) var awaitingCode = false
    /// The sign-in's tab is open: until then Connect says it is opening,
    /// not that a tab is asking.
    @Published private(set) var pageOpen = false
    @Published private(set) var submittingCode = false
    @Published private(set) var codeError: String?

    func showSignIn() {
        guard waiting == .signingIn else { return }
        // The CLI gone without a page: a fresh one, rather than a button
        // that does nothing (#1829).
        if codeError != nil || login == nil || login?.closed == true || login?.finished == true || login?.authorizationURL == nil { signIn(); return }
        if let login, !login.opened, login.authorizationURL != nil {
            login.openPage(in: Links.browser ?? BrowserWindows.shared.newWindow(), choice: choice ?? .another)
        }
        login?.show()
    }

    /// The code pasted into Connect's field, to the CLI waiting for it.
    /// False when nothing waits or the text isn't a whole Google code.
    @discardableResult
    func submitCode(_ code: String) -> Bool {
        guard waiting == .signingIn, let login, login.awaitingCode else { return false }
        return login.submitCode(code)
    }

    private func updateCodeState(_ signer: GeminiLogin) {
        guard login === signer else { return }
        awaitingCode = signer.awaitingCode
        if pageOpen != signer.opened { pageOpen = signer.opened }
        submittingCode = signer.submittedCode && signer.codeError == nil && !signer.finished
        codeError = signer.codeError
    }
    /// Waiting for an install in Terminal, or Google's sign-in in a tab.
    @Published private(set) var waiting: Waiting?
    /// Why the last sign-in or install stopped, until the next.
    @Published private(set) var trouble: String?

    enum Waiting: Equatable { case installing, signingIn }

    private var lookedAt: Date?
    private var attempt = 0

    @Published var enabled: Bool = Store.settings.object(forKey: "gemini.enabled") as? Bool ?? true {
        didSet { Store.settings.set(enabled, forKey: "gemini.enabled") }
    }

    /// Here and signed in: its models can be picked and its chats run.
    var ready: Bool { enabled && signedIn == true && (binary ?? Shell.cached?.gemini) != nil }

    /// Ready, or connected and not yet found signed out on this launch:
    /// keeps Auto and `Agents.preferred` on Gemini across restarts instead
    /// of falling back to Claude before `look()` has checked the CLI.
    var available: Bool {
        if ready { return true }
        guard enabled, signedIn == nil, AgentSetup.connected("gemini") else { return false }
        return binary != nil || (AgentLaunch.here("gemini") ?? true)
    }

    private convenience init() { self.init(binary: Shell.cached?.gemini) }

    init(binary: String?) {
        signedIn = nil // A saved model catalog is not a verified login on this launch.
        let kept = Store.settings.array(forKey: "gemini.models") as? [[String]] ?? []
        models = kept.compactMap { pair in
            guard pair.count == 2 else { return nil }
            return GeminiModels.model(pair[0], name: pair[1])
        }
        self.binary = binary
    }

    /// Asks the CLI once a minute at most, or now when `fresh`.
    /// `within`: seconds `agy models` may take (25 at most).
    func look(fresh: Bool = false, within: TimeInterval = 25, permit: ProviderLaunchPermit? = nil,
              find: (Bool) async -> Shell.Found = { await Shell.find(fresh: $0) }, profile: URL = GeminiSupport.profile,
              confirmed: ((Bool) -> Void)? = nil) async {
        var usable = false
        defer { confirmed?(usable) }
        guard let permit = permit ?? ProviderConsent.shared.permit("gemini") ?? ProviderConsent.shared.connectionPermit("gemini"), permit.valid else { return }
        let mine = attempt
        if !fresh, let lookedAt, lookedAt.timeIntervalSinceNow > -60 { return }
        lookedAt = Date()
        let found = await find(fresh)
        guard permit.valid, attempt == mine else { return }
        binary = found.gemini
        guard let binary else { return keep(signedIn: nil) }
        let config = GeminiRunner.Configuration(binary: binary, profile: profile, workspace: profile.appendingPathComponent("look"),
                                                model: nil, conversation: nil, command: "", mcpArgs: nil,
                                                brief: Agents.instructions(textOnly: true, full: false, remembering: false), environment: found.env)
        let prepared: (env: [String: String], cwd: URL)
        do { prepared = try config.prepare() }
        catch { lastSaid = error.localizedDescription; keep(signedIn: false); return }
        let deadline = Date().addingTimeInterval(min(25, max(1, within)))
        let ran = await Shell.timed(binary, ["models"], env: prepared.env, limit: max(1, deadline.timeIntervalSinceNow),
                                   in: prepared.cwd, permit: permit, captureErrors: true)
        guard permit.valid, attempt == mine else { return }
        guard !ran.late else {
            lastSaid = "No answer from Antigravity CLI within \(Int(min(25, max(1, within)))) seconds."
            keep(signedIn: false); return
        }
        if ran.code != 0 {
            lastSaid = (ran.output + "\n" + ran.diagnostic).split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                .last { !$0.isEmpty && !$0.hasPrefix("Fetching") && !$0.contains("@") }.map { String($0.prefix(200)) }
        } else { lastSaid = nil }
        let listed = GeminiModels.rows(ran.output)
        if ran.code == 0, !listed.isEmpty {
            models = listed
            Store.settings.set(listed.map { [$0.model, $0.name] }, forKey: "gemini.models")
        }
        guard ran.code == 0, deadline.timeIntervalSinceNow > 0 else { keep(signedIn: false); return }
        // /usage refreshes quota from Google's backend without a model turn.
        // Unlike `models`, this must be able to use the keychain credential.
        // A login it can't use makes it start a sign-in of its own: it
        // opens Google through Yab's launcher and waits a minute for a code
        // on its stdin, which nobody can give it. That page is the answer,
        // signed out: the check ends there (SignInAsked), at once.
        let asked = SignInAsked()
        defer { asked.end() }
        var env = prepared.env
        env["YAB_GEMINI_PAGE"] = asked.page?.path
        let auth = await Shell.timed(binary, ["-p", "/usage", "--output-format", "json"], env: env,
                                     limit: max(1, deadline.timeIntervalSinceNow), in: prepared.cwd,
                                     started: { asked.watch($0) }, permit: permit, captureErrors: true)
        guard permit.valid, attempt == mine else { return }
        if asked.asked {
            lastSaid = "Antigravity isn't signed in."
            keep(signedIn: false)
            return
        }
        let checked = Self.authenticated(auth)
        usable = checked
        if !checked {
            lastSaid = auth.late ? "Antigravity did not finish checking its Google sign-in."
                : (auth.diagnostic + "\n" + auth.output).split(separator: "\n").map(String.init)
                    .last { !$0.isEmpty && !$0.contains("@") }.map { String($0.prefix(300)) }
                ?? "Antigravity could not verify its Google sign-in."
            let said = (auth.output + "\n" + auth.diagnostic).lowercased()
            if waiting == .signingIn, said.contains("canceled") || said.contains("cancelled") { cancel() }
        }
        if checked {
            quota = GeminiQuota.read(auth.output)
            if let quota { PlanAccounts.shared.heard(gemini: quota) }
        }
        keep(signedIn: checked)
    }

    /// Read only: the CLI prints its own public identity in its TUI header.
    /// /usage (including JSON) carries quotas, never an email or plan.
    func identify(permit: ProviderLaunchPermit? = nil, profile: URL = GeminiSupport.profile, duringSignIn: Bool = false) async {
        guard (!Store.testing || duringSignIn), (signedIn == true || duringSignIn), (waiting == nil || duringSignIn),
              let permit = permit ?? ProviderConsent.shared.permit("gemini") ?? ProviderConsent.shared.connectionPermit("gemini"),
              permit.valid, let binary else { return }
        let mine = attempt
        let inspector = GeminiLogin()
        defer { inspector.stop() }
        do { try inspector.start(binary: binary, profile: profile,
                                 base: ProcessInfo.processInfo.environment, switching: false, permit: permit) }
        catch { return }
        let deadline = Date().addingTimeInterval(15)
        var seen: Date?
        while Date() < deadline, permit.valid, attempt == mine {
            if inspector.identity != nil {
                if seen == nil { seen = Date() }
                // The plan's line comes a few frames after the email's.
                if inspector.identity?.plan != nil || (seen?.timeIntervalSinceNow ?? 0) < -4 { break }
            }
            if inspector.finished { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard permit.valid, attempt == mine, let heard = inspector.identity else { return }
        // A header cut off before its plan keeps the plan heard before.
        identity = heard.plan == nil && heard.email.caseInsensitiveCompare(identity?.email ?? "") == .orderedSame
            ? GeminiIdentity(email: heard.email, plan: identity?.plan) : heard
    }

    /// Never accept a timeout, empty success, or a printed auth/keychain error.
    nonisolated static func authenticated(_ ran: Shell.Ran) -> Bool {
        let text = (ran.output + "\n" + ran.diagnostic).lowercased()
        if ran.output.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") {
            return !ran.late && ran.code == 0 && GeminiQuota.read(ran.output) != nil
                && !["keychain", "canceled", "cancelled"].contains(where: ran.diagnostic.lowercased().contains)
        }
        return !ran.late && ran.code == 0 && !ran.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !["error", "sign in", "sign-in", "not signed", "authentication required", "keychain", "canceled", "cancelled"].contains(where: text.contains)
    }

    private func keep(signedIn: Bool?) {
        // A passive refresh during Switch Account must not accept the old
        // shared login, or finish before its new public identity is read.
        if signedIn == true, let login, waiting == .signingIn, choice?.source != .mac {
            checkedLogin = login.opened || login.authenticated
            return
        }
        self.signedIn = signedIn
        Store.settings.set(signedIn, forKey: "gemini.signedIn")
        if signedIn == true {
            trouble = nil
            if waiting == .signingIn { waiting = nil }
        }
    }

    /// The person's selected Google account, in its Yab space or a private
    /// tab. The CLI owns OAuth and the shared keyring entry throughout.
    func signIn(permit: ProviderLaunchPermit? = nil, in browser: Browser? = nil,
                profile: URL = GeminiSupport.profile) {
        guard let permit = permit ?? ProviderConsent.shared.connectionPermit("gemini") ?? ProviderConsent.shared.permit("gemini"), permit.valid else { return }
        enabled = true
        guard let binary else { return install(permit: permit) }
        let selected = choice ?? .another
        // A failed /usage check does not prove the shared CLI login is
        // absent. An explicit Google account choice must also replace an
        // existing TUI header when readiness was false or unknown.
        let replacing = selected.source != .mac
        attempt += 1
        let mine = attempt
        login?.stop()
        let signer = GeminiLogin()
        login = signer
        checkedLogin = false
        awaitingCode = false; submittingCode = false; codeError = nil; pageOpen = false
        signer.changed = { [weak self, weak signer] in
            guard let signer else { return }
            self?.updateCodeState(signer)
        }
        // Keep the fresh readiness check's reason if OAuth never opens.
        // A later successful /usage clears it in look().
        trouble = nil
        notice = nil
        waiting = .signingIn
        let deadline = Date().addingTimeInterval(Self.waitLimit)
        waitingUntil = deadline
        // Connect inspects readiness immediately after this method returns.
        // Clear the old shared login before the asynchronous switch starts.
        keep(signedIn: false)
        Task {
            defer { signer.stop(); if attempt == mine { login = nil; waiting = nil; awaitingCode = false; submittingCode = false } }
            guard permit.valid, attempt == mine else { return }
            if selected.source == .mac {
                await look(fresh: true, within: max(1, deadline.timeIntervalSinceNow), permit: permit, profile: profile)
                return
            }
            identity = nil
            keep(signedIn: false)
            do { try signer.start(binary: binary, profile: profile,
                                  base: ProcessInfo.processInfo.environment, switching: replacing, signingIn: true, permit: permit) }
            catch { trouble = error.localizedDescription; return }
            var checkedAt = Date.distantPast
            var restarted = false
            while Date() < deadline, permit.valid, attempt == mine {
                if !signer.opened, signer.authorizationURL != nil {
                    signer.openPage(in: browser ?? Links.browser ?? BrowserWindows.shared.newWindow(), choice: selected)
                }
                if let failure = signer.failure { trouble = failure; return }
                if signer.usesACP {
                    if signer.authenticated {
                        // Only the authenticate response completes OAuth. A
                        // usable old keyring or an open page is not completion.
                        var verified = false
                        await look(fresh: true, within: max(1, deadline.timeIntervalSinceNow), permit: permit, profile: profile,
                                   confirmed: { verified = $0 })
                        guard permit.valid, attempt == mine else { return }
                        guard verified else {
                            trouble = "Antigravity couldn't verify Google's sign-in. Try again."
                            return
                        }
                        await identify(permit: permit, profile: profile, duringSignIn: true)
                        guard permit.valid, attempt == mine else { return }
                        guard identity != nil else {
                            trouble = "Antigravity couldn't confirm the signed-in Google account. Try again."
                            return
                        }
                        waiting = nil
                        keep(signedIn: true)
                        if let picked = selected.email, let actual = identity?.email,
                           picked.lowercased() != actual.lowercased() {
                            notice = "You picked \(picked); Google signed in \(actual)."
                        }
                        if let settings = SettingsWindow.shared.window, settings.isVisible { settings.makeKeyAndOrderFront(nil) }
                        NSApp.activate()
                        return
                    }
                    if signer.closed { cancel(); return }
                    try? await Task.sleep(for: .milliseconds(100))
                    continue
                }
                signer.completeCodePage()
                if signer.codeError != nil {
                    // Keep the actionable error on the connect card. Show Sign-In
                    // starts a fresh CLI challenge, never reuses the rejected code.
                    submittingCode = false
                    try? await Task.sleep(for: .milliseconds(250))
                    continue
                }
                let closed = signer.closed
                // An existing global login isn't a completed switch. Wait
                // for the CLI to open OAuth before accepting /usage again.
                if signer.opened, closed || Date().timeIntervalSince(checkedAt) >= 3 {
                    checkedAt = Date()
                    await look(fresh: true, within: max(1, deadline.timeIntervalSinceNow), permit: permit, profile: profile)
                    guard permit.valid, attempt == mine else { return }
                    guard Date() < deadline else { break }
                    if checkedLogin {
                        let identityDeadline = min(deadline, Date().addingTimeInterval(3))
                        while signer.identity == nil, Date() < identityDeadline, permit.valid, attempt == mine {
                            try? await Task.sleep(for: .milliseconds(100))
                        }
                        guard permit.valid, attempt == mine else { return }
                        // Opening a browser is not proof OAuth finished. A
                        // shared keyring may already answer /usage elsewhere.
                        guard let confirmed = signer.identity else {
                            if closed { cancel(); return }
                            try? await Task.sleep(for: .milliseconds(250))
                            continue
                        }
                        identity = confirmed
                        waiting = nil
                        keep(signedIn: true)
                        // Never label the login with the requested address.
                        if let picked = selected.email, let actual = identity?.email,
                           picked.lowercased() != actual.lowercased() {
                            notice = "You picked \(picked); Google signed in \(actual)."
                        }
                        if let settings = SettingsWindow.shared.window, settings.isVisible { settings.makeKeyAndOrderFront(nil) }
                        NSApp.activate()
                        // The sign-in's header can end before the plan's
                        // line; read it again once this login has stopped.
                        if identity?.plan == nil { Task { await self.identify(permit: permit) } }
                        return
                    }
                }
                // A callback page can close itself after Allow. Verify
                // the CLI before treating that close as a cancellation.
                if closed { cancel(); return }
                if signer.finished {
                    if signer.loggedOut, !restarted {
                        restarted = true
                        signer.stop()
                        do { try signer.start(binary: binary, profile: profile,
                                              base: ProcessInfo.processInfo.environment, switching: false, signingIn: true, permit: permit) }
                        catch { trouble = error.localizedDescription; return }
                    } else { trouble = "Antigravity closed its sign-in. Press Sign In to try again."; return }
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
            guard permit.valid, attempt == mine else { return }
            trouble = Self.gaveUp(.signingIn, said: lastSaid, limit: Self.waitLimit)
        }
    }

    /// Google's installer, pasted into Terminal by the person: it changes
    /// their shell's PATH, so Yab doesn't run it itself.
    func install(permit: ProviderLaunchPermit? = nil) {
        guard permit?.valid ?? true else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(AgentSetupModel.install("gemini"), forType: .string)
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"),
                                           configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
        trouble = nil
        waiting = .installing
        poll(permit: permit) { $0.binary != nil }
    }

    /// A test run's stand-in state, for pictures (bench `gemini`): the
    /// CLI's path, signed in or not, and `agy models` output.
    func pretend(binary: String?, signedIn: Bool?, models output: String, waiting: Waiting? = nil,
                 identity: GeminiIdentity? = nil, quota: PlanQuota? = nil) {
        guard Store.testing else { return }
        self.binary = binary
        self.signedIn = signedIn
        self.waiting = waiting
        self.identity = identity
        self.quota = quota
        if let quota { PlanAccounts.shared.heard(gemini: quota) }
        models = GeminiModels.rows(output)
        lookedAt = Date.distantFuture
    }

    func cancel() {
        attempt += 1
        login?.stop()
        login = nil
        awaitingCode = false; submittingCode = false; codeError = nil
        if waiting == .signingIn {
            keep(signedIn: false)
            trouble = "Gemini sign-in was canceled. Press Sign In to try again."
        }
        waiting = nil
    }

    /// How long a sign-in or an install is waited for, by the clock, however
    /// slow each look is (#373: "keeps loading with no response" on a Mac
    /// with 366 tabs): five minutes, YAB_SIGNIN_LIMIT seconds in a test world.
    nonisolated static var waitLimit: TimeInterval {
        if Store.testing, let given = ProcessInfo.processInfo.environment["YAB_SIGNIN_LIMIT"].flatMap(Double.init) { return given }
        return 300
    }

    /// Why the wait ended without a sign-in, in words the person can act on:
    /// what Antigravity last said, and that Sign In tries again.
    nonisolated static func gaveUp(_ what: Waiting, said: String?, limit: TimeInterval) -> String {
        let minutes = max(1, Int((limit / 60).rounded()))
        let when = limit < 60 ? "\(Int(limit)) seconds" : minutes == 1 ? "a minute" : "\(minutes) minutes"
        let last = said.map { " Antigravity said: \u{201C}\($0)\u{201D}" } ?? ""
        switch what {
        case .installing:
            return "Antigravity CLI wasn't found within \(when).\(last) Install it in Terminal, then press Set Up again."
        case .signingIn:
            return "Gemini wasn't signed in within \(when).\(last) Press Sign In to try again."
        }
    }

    /// The last thing the CLI said when it could not verify sign-in: one
    /// line, no addresses, for `gaveUp`.
    private(set) var lastSaid: String?
    /// When the wait under way gives up (`poll`); a new Sign In moves it.
    private(set) var waitingUntil: Date?

    /// Every three seconds until `done`, for `waitLimit` by the clock; then
    /// the wait ends with why (`trouble`), never a ring turning on.
    private func poll(permit: ProviderLaunchPermit? = nil, _ done: @escaping (GeminiAccount) -> Bool) {
        let original = permit
        attempt += 1
        let mine = attempt
        let what = waiting ?? .signingIn
        let limit = Self.waitLimit
        let deadline = Date().addingTimeInterval(limit)
        waitingUntil = deadline
        Task { [weak self] in
            while Date() < deadline {
                try? await Task.sleep(for: .seconds(min(3, max(0.5, limit / 10))))
                guard let self, self.attempt == mine, self.waiting != nil else { return }
                if let original {
                    guard original.valid else { self.waiting = nil; return }
                    await self.look(fresh: true, within: max(1, deadline.timeIntervalSinceNow), permit: original)
                    guard self.attempt == mine else { return }
                    guard original.valid else { self.waiting = nil; return }
                } else if what == .installing {
                    let found = await Shell.find(fresh: true)
                    guard self.attempt == mine else { return }
                    self.binary = found.gemini
                } else { return }
                if done(self) { self.waiting = nil; return }
            }
            guard let self, self.attempt == mine, self.waiting != nil else { return }
            guard original?.valid ?? true else { self.waiting = nil; return }
            self.trouble = Self.gaveUp(what, said: self.lastSaid, limit: limit)
            self.waiting = nil
        }
    }

    /// The Terminal script: the CLI in Yab's profile, with nothing of the
    /// person's own Google setup (API keys, ADC, endpoints) passed in.
    nonisolated static func signInScript(binary: String, profile: URL = GeminiSupport.profile) -> String {
        let env = AgentCopies.environment(for: binary, base: GeminiSupport.environment(ProcessInfo.processInfo.environment, profile: profile))
        let keychains = URL(fileURLWithPath: ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory())
            .appendingPathComponent("Library/Keychains").resolvingSymlinksInPath().path
        func quoted(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let exports = ["HOME", "ANTIGRAVITY_GEMINI_DIR", "ANTIGRAVITY_APP_DATA_DIR", "AGY_CLI_DISABLE_AUTO_UPDATE", "PATH"]
            .compactMap { key in env[key].map { "export \(key)=\(quoted($0))" } }
        return """
        #!/bin/zsh
        # Yab: sign in to Gemini with your Google account, in Yab's own profile.
        unset GEMINI_API_KEY GOOGLE_API_KEY AGY_ADC_AUTH GOOGLE_GEMINI_BASE_URL GOOGLE_CLOUD_PROJECT
        \(exports.joined(separator: "\n"))
        if [[ ! -L "$HOME/Library/Keychains" ]] || [[ "$(readlink "$HOME/Library/Keychains")" != \(quoted(keychains)) ]]; then
          echo "Yab couldn't use this Mac's login keychain folder. Open Sign In again in Yab."
          exit 1
        fi
        mkdir -p "$ANTIGRAVITY_GEMINI_DIR" && cd "$ANTIGRAVITY_GEMINI_DIR"
        clear
        echo "Sign in to Gemini with your Google account in the browser that opens."
        echo "When Gemini's prompt shows, you're signed in: type /exit, then close this window."
        echo
        exec \(quoted(binary))

        """
    }
}

/// A readiness check's agy run that started a sign-in of its own: it handed
/// Yab's launcher a page (GeminiSupport.launcherScript writes it to
/// $YAB_GEMINI_PAGE). The run is ended the moment the page is written, from
/// the folder's write event, so a check never waits on a sign-in nobody
/// sees; the page itself is never opened (#2038).
final class SignInAsked: @unchecked Sendable {
    let page: URL?
    private let folder: URL?
    private let lock = NSLock()
    private var source: DispatchSourceFileSystemObject?

    init() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("yab-gemini-check-" + UUID().uuidString)
        let made = (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                            attributes: [.posixPermissions: 0o700])) != nil
        self.folder = made ? folder : nil
        page = made ? folder.appendingPathComponent("page") : nil
    }

    var asked: Bool { page.map { FileManager.default.fileExists(atPath: $0.path) } ?? false }

    func watch(_ process: Process) {
        guard let folder else { return }
        let descriptor = open(folder.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: .write, queue: .global())
        source.setEventHandler { [weak self] in self?.stopIfAsked(process) }
        source.setCancelHandler { close(descriptor) }
        lock.lock(); self.source = source; lock.unlock()
        source.resume()
        // Written before the watch began.
        stopIfAsked(process)
    }

    private func stopIfAsked(_ process: Process) {
        guard asked, process.isRunning else { return }
        Shell.end(process, grace: 1)
    }

    func end() {
        lock.lock(); source?.cancel(); source = nil; lock.unlock()
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }
}
