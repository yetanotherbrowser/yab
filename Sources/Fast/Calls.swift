import AppKit
import AVFoundation
import Combine
import SwiftUI

// Calls: a tab with the camera or the microphone on, Meet, Zoom in the
// browser, Teams, a Slack huddle, anything that asked for them.
//
// A call is the one page that costs something to lose: ⌘W on it asks
// twice, as ⌘Q does, quitting says so, and it never sleeps, is never
// tidied, and no update is written in over it. Going to another tab, or
// another space, the call comes along in the floating window (Floater, as
// a call: its people, the microphone, the camera, Leave), its tab staying
// live in its own space (feedback #1878); a call over closes its tab once
// you have looked away from it. See PLAN-calls.md.

extension Tab {
    /// The camera or the microphone is the page's: a call, as far as yab
    /// can tell, whatever the site.
    var onCall: Bool { camera != .none || microphone != .none }

    /// The microphone and the camera as the call has them: WebKit's, and
    /// muted too when the page's own switch is off (`pageMic`).
    ///
    /// Where the page's switch is read, it has the last word: Meet lets go of
    /// the camera when it is turned off, and WebKit then says there is no
    /// camera at all, but there is one, off, to be turned on again.
    var mic: PageMediaState {
        if let off = pageMic, onCall { return off || microphone == .muted ? .muted : .active }
        return microphone == .none ? .none : (microphone == .muted ? .muted : .active)
    }
    var cam: PageMediaState {
        if let off = pageCamera, onCall { return off || camera == .muted ? .muted : .active }
        return camera == .none ? .none : (camera == .muted ? .muted : .active)
    }

    /// On a call and heard: the microphone on, not muted, here or there.
    var heard: Bool { mic == .active }
}

/// What yab keeps about calls between one change and the next.
@MainActor
final class Calls: ObservableObject {
    /// Tabs on a call right now.
    @Published private(set) var live: Set<Tab.ID> = []

    /// A call's tab asked to close once: which tabs, and when. A second ask
    /// soon after, for the same tabs, closes them.
    var armed: (tabs: Set<Tab.ID>, at: CFTimeInterval)?

    /// Calls that ended, by tab, and when their tab was last on screen:
    /// it closes a minute after you stop looking at it.
    var over: [Tab.ID: Date] = [:]
    var sweeping: Timer?

    var any: Bool { !live.isEmpty }

    func set(_ id: Tab.ID, live on: Bool) {
        if on { live.insert(id) } else { live.remove(id) }
    }

    /// How long a second ⌘W has to count.
    static let again: CFTimeInterval = 2
    /// How long a call over stays after you look away.
    static let linger: TimeInterval = 60
}

extension Browser {
    /// Every tab there is, the spaces not on screen included.
    var everyTab: [Tab] { tabs + parkedTabs }

    /// The call a key or a button in the menu means: the one floating, the
    /// one on screen, else the one most recently looked at.
    var call: Tab? {
        let all = everyTab.filter(\.onCall)
        if let id = floating, let tab = all.first(where: { $0.id == id }) { return tab }
        if let active, active.onCall { return active }
        return all.max { $0.touched < $1.touched }
    }

    // MARK: - the camera and the microphone changed

    /// The page took, muted or let go of the camera or the microphone.
    func captureChanged(_ tab: Tab) {
        // The menu's Mute Call reads the microphone, muted or not.
        calls.objectWillChange.send()
        // A huddle's own window (Slack's, opened beside its tab) holds the
        // switches while the call is its opener's: they are said there.
        if !tab.onCall, tab.pageMic != nil || tab.pageCamera != nil,
           let opener = self.tab(id: tab.opener), opener.onCall,
           opener.address?.host() == tab.address?.host() {
            opener.pageMic = tab.pageMic
            opener.pageCamera = tab.pageCamera
        }
        let was = calls.live.contains(tab.id)
        let now = tab.onCall
        guard was != now else { return }
        calls.set(tab.id, live: now)
        // A call is never the band's; one over may be again.
        player.restage()
        if now {
            calls.over[tab.id] = nil
            tab.callStarted = tab.address
            // Its huddle window may have said its switches before the call
            // began here (Slack's opens first): taken from it now.
            if tab.pageMic == nil, tab.pageCamera == nil,
               let window = everyTab.first(where: { $0.opener == tab.id && !$0.onCall
                   && ($0.pageMic != nil || $0.pageCamera != nil) && $0.address?.host() == tab.address?.host() }) {
                tab.pageMic = window.pageMic
                tab.pageCamera = window.pageCamera
            }
            WrappedLedger.shared.add(.calls)
        } else {
            // The page's switches go with its call.
            tab.pageMic = nil
            tab.pageCamera = nil
            callEnded(tab)
        }
    }

    /// A call's page let go of both: the call is over. Out in the window,
    /// it folds back into its tab; the tab itself goes once you have looked
    /// away from it for a minute (a call left by closing the window never
    /// shows its tab again), unless it is pinned or not a meeting's page.
    private func callEnded(_ tab: Tab) {
        if floating == tab.id { land() }
        // One that came along with an agent goes home once you look away;
        // a call's own tab is home already.
        sendHome(tab)
        guard tab.pin == nil, CallLink.isCall(tab.address) || CallLink.isCall(tab.callStarted) else { return }
        calls.over[tab.id] = Date()
        sweepCalls()
    }

    /// Every ten seconds while a call's tab is waiting to go.
    private func sweepCalls() {
        guard calls.sweeping == nil else { return }
        calls.sweeping = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sweepEndedCalls() }
        }
    }

    func sweepEndedCalls(now: Date = Date()) {
        for (id, seen) in calls.over {
            guard let tab = everyTab.first(where: { $0.id == id }), !tab.onCall, tab.pin == nil else {
                calls.over[id] = nil
                continue
            }
            // On screen, it may be rejoined: the minute starts over.
            if onScreen(id) {
                calls.over[id] = now
                continue
            }
            guard now.timeIntervalSince(seen) >= Calls.linger else { continue }
            calls.over[id] = nil
            // Parked in the space it was left talking in, it closes there.
            if tabs.contains(where: { $0.id == id }) { close(tab) } else { closeElsewhere(tab) }
        }
        if calls.over.isEmpty {
            calls.sweeping?.invalidate()
            calls.sweeping = nil
        }
    }

    // MARK: - closing a call by hand

    /// ⌘W, a tab's cross, Close from a menu. A call among them asks first:
    /// the notice says what a second one does, and a second one within two
    /// seconds does it. Anything else closes at once, as ever. With no tab
    /// in front, an empty window closes, whether normal or private.
    func shut(_ group: [Tab], byKey: Bool = false) {
        if group.isEmpty, activeID == nil {
            if closesWindowOnCloseTab {
                BrowserWindows.shared.window(for: self)?.performClose(nil)
            } else {
                askNew()
            }
            return
        }
        // Mail's own page is the space itself, never closed by hand in it:
        // ⌘W there does nothing, the cross on a tab of it closes that tab.
        let group = inMail ? group.filter { !MailPage.isMail($0.pending ?? $0.address) } : group
        guard !group.isEmpty else { return }
        let calling = Set(group.filter(\.onCall).map(\.id))
        // A page holding something typed asks first (LeavePage.swift).
        guard !calling.isEmpty else { return closeAsking(group) }
        let now = CACurrentMediaTime()
        if let armed = calls.armed, armed.tabs == calling, now - armed.at < Calls.again {
            calls.armed = nil
            return closeAsking(group)
        }
        calls.armed = (calling, now)
        let caps = byKey ? (Keymap.shared.keys(.closeTab)?.caps ?? []) : []
        toaster.pop(calling.count > 1 ? "Again to leave the calls" : "Again to leave the call",
                    mark: "phone.down", keys: caps, stay: Calls.again)
    }

    func shut(_ tab: Tab) { shut([tab]) }

    // MARK: - the microphone

    /// Mute Call, from the menu, its key or the floating window: the
    /// call's microphone off, or on again.
    func toggleCallMic() {
        guard let tab = call, tab.microphone != .none else { return }
        tab.muteMicrophone(tab.heard)
    }

    func toggleCallCamera() {
        guard let tab = call, tab.cam != .none else { return }
        tab.turnCamera(tab.cam == .muted)
    }

    // MARK: - the call in the floating window

    /// Away from a call's tab: the call comes along, in the floating
    /// window, laid out by CallStage, its tab where it is, in this row or
    /// parked in the space you left. A video already out goes home to its
    /// tab first; another call already out stays, one call at a time.
    func liftCall(_ tab: Tab) {
        // The call's own window is out (Meet's, on Chromium): it comes along
        // as it is.
        guard tab.onCall, !tab.isBlank, !tab.asleep, !tab.documentPiP.showing, let web = tab.builtPage else { return }
        if floater.showing, !floater.homing {
            if floater.kind == .call { return }
            land()
        }
        CallStage.run("on", on: web) { [weak self] _ in
            guard let self else { return }
            // Gone back to it meanwhile, closed, or the call over: nothing
            // to lift, and the stage comes off again.
            guard self.everyTab.contains(where: { $0 === tab }), tab.onCall, self.activeID != tab.id,
                  !self.floater.showing || self.floater.homing
            else {
                if self.floating != tab.id { CallStage.run("off", on: web) }
                return
            }
            if self.floater.homing { self.floater.drop() }
            self.putOut(tab, web: web)
            // Under the stage now, the page's menus can be opened unseen.
            tab.readCallDevices { [weak self] in self?.floater.refreshCall() }
        }
    }

    /// The tab whose call is out in the window.
    var floatingCall: Tab? {
        guard floater.kind == .call, let id = floating else { return nil }
        return everyTab.first { $0.id == id }
    }

    /// The window's buttons for a call, set once.
    func wireCallWindow() {
        floater.callState = { [weak self] in
            let tab = self?.floatingCall
            return (tab?.mic ?? .none, tab?.cam ?? .none)
        }
        floater.callLeft = { [weak self] in
            guard let tab = self?.floatingCall else { return nil }
            return Meetings.shared.minutesLeft(for: CallLink.key(tab.callStarted ?? tab.address))
        }
        floater.onCallSize = { [weak self] size, shown in
            guard let web = self?.floatingCall?.builtPage else { return }
            CallStage.run("size", ["w": Double(size.width), "h": Double(size.height), "x": Double(shown.minX),
                                   "y": Double(shown.minY), "cw": Double(shown.width), "ch": Double(shown.height)], on: web)
        }
        floater.onCallNear = { [weak self] near in
            guard let web = self?.floatingCall?.builtPage else { return }
            CallStage.run("names", near ? 1 : 0, on: web)
        }
        floater.onCallBand = { [weak self] taken in
            guard let web = self?.floatingCall?.builtPage else { return }
            CallStage.run("band", Double(taken), on: web)
        }
        // With every tick of the window: who waits, the chat, your hand, the
        // captions, a recording (CallNews).
        floater.onCallTick = { [weak self] in
            guard let self, let tab = self.floatingCall, let web = self.callControls(tab) else { return }
            CallStage.run("news", on: web) { [weak self] answer in
                guard answer != nil else { return }
                self?.floater.showCallNews(CallNews(answer))
            }
        }
        floater.onCallAsk = { [weak self] ask in
            guard let self, let tab = self.floatingCall, let web = tab.builtPage else { return }
            self.askCall(ask, of: web, controls: self.callControls(tab) ?? web)
        }
        floater.onMic = { [weak self] in
            guard let tab = self?.floatingCall, tab.microphone != .none else { return }
            tab.muteMicrophone(tab.heard)
        }
        floater.onCamera = { [weak self] in
            guard let tab = self?.floatingCall, tab.cam != .none else { return }
            tab.turnCamera(tab.cam == .muted)
        }
        floater.onLeave = { [weak self] in
            guard let self, let tab = self.floatingCall else { return }
            self.leaveCall(tab)
        }
        floater.onShare = { [weak self] in
            guard let self, let tab = self.floatingCall else { return }
            self.shareScreen(tab)
        }
        // Read as the window ticks: your screen from WebKit itself, which
        // says so before any notice of it could arrive.
        floater.callRow = { [weak self] in
            guard let tab = self?.floatingCall else { return (false, false, (false, false)) }
            let devices = tab.callDevices
            return (tab.presentingScreen, devices?.sharable ?? false, devices?.choice ?? (false, false))
        }
        floater.callMenu = { [weak self] which in
            guard let self, let tab = self.floatingCall else { return nil }
            return self.callMenu(which, for: tab)
        }
        watchCallDevices()
    }

    /// Where a call's own controls are: its page, or the window a Slack
    /// huddle keeps them in, opened from the call's tab (its hand, its
    /// thread, its reactions; the tab keeps only a bar with Leave).
    func callControls(_ tab: Tab) -> (any PageHandle)? {
        guard tab.address?.host()?.lowercased() == "app.slack.com" else { return tab.builtPage }
        let window = everyTab.first { $0.opener == tab.id && !$0.onCall && $0.builtPage != nil
            && $0.address?.host()?.lowercased() == "app.slack.com" }
        return window?.builtPage ?? tab.builtPage
    }

    /// What the call window asks of the page, done in the page's own
    /// controls (CallStage): it lets in, raises the hand, sends the message,
    /// so the meeting knows, as if done in its tab.
    func askCall(_ ask: CallAsk, of web: any PageHandle, controls: (any PageHandle)? = nil) {
        let refresh: (Any?) -> Void = { [weak self] _ in self?.floater.refreshCall() }
        // The meeting's own buttons: in a huddle's window where it has one.
        let controls = controls ?? web
        switch ask {
        case .admit(let name): CallStage.run("admit", name ?? "", on: controls, refresh)
        case .deny(let name): CallStage.run("deny", name ?? "", on: controls, refresh)
        case .hand: CallStage.run("hand", on: controls, refresh)
        case .captions: CallStage.run("captions", on: controls, refresh)
        case .react(let face): CallStage.run("react", face, on: controls)
        case .send(let words): CallStage.run("send", words, on: controls)
        case .read: CallStage.run("read", on: controls, refresh)
        case .thread(let on): CallStage.run("thread", on, on: web)
        case .overlay(let island, let marks):
            CallStage.run("overlay", ["x": Double(island.minX), "y": Double(island.minY), "w": Double(island.width),
                                      "h": Double(island.height), "marks": Double(marks)], on: web)
        case .tap(let point):
            CallStage.run("hit", ["x": Double(point.x), "y": Double(point.y)], on: web) { [weak self] hit in
                guard let said = hit as? String, !said.isEmpty else { return }
                self?.floater.openCallReply()
            }
        }
    }

    // MARK: - the screen

    /// Share, from the window or its key: the page's own Share pressed, so
    /// the meeting knows you present and macOS's picker asks what to show.
    /// Already showing, it stops, on any site: WebKit ends the capture and
    /// the page sees its track end, as with the system's own Stop.
    func shareScreen(_ tab: Tab) {
        guard let web = tab.builtPage else { return }
        if tab.presentingScreen { return tab.stopSharing() }
        // Pressed by you, in Yab: what the page asks next is yours (RelayGuard).
        RelayGuard.vouch(web)
        CallStage.run("share", on: web) { [weak self] pressed in
            guard pressed as? Bool != true else { return }
            // The page's Share went missing since the row was made.
            tab.readCallDevices()
            self?.floater.refreshCall()
        }
    }

    // MARK: - the devices

    /// The microphone's or the camera's menu over the call window's arrow:
    /// the page's devices, the one in use ticked, a pick made in the page's
    /// own menu; then the Mac's own Mic Mode or Video Effects, for any site.
    func callMenu(_ which: CallControls.Devices, for tab: Tab) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let devices = tab.callDevices ?? CallDevices()
        func section(_ title: String, _ list: [CallDevices.Device], _ kind: CallDeviceKind) {
            guard !list.isEmpty else { return }
            menu.addItem(.sectionHeader(title: title))
            for device in list {
                let item = PageMenuItem(device.isDefault ? "System Default" : device.label) { [weak tab] in
                    tab?.pickCallDevice(kind, device)
                }
                if device.isDefault { item.subtitle = CallDevices.plain(device.label) }
                item.state = device.on ? .on : .off
                menu.addItem(item)
            }
        }
        switch which {
        case .mic:
            if devices.choice.mic {
                section("Microphone", devices.mics, .mic)
                section("Speaker", devices.speakers, .speaker)
                menu.addItem(.separator())
            }
            // The Mac chooses the mode, in Control Center; what it is now
            // shows under the item.
            let mode = PageMenuItem("Mic Mode…") { AVCaptureDevice.showSystemUserInterface(.microphoneModes) }
            mode.subtitle = {
                switch AVCaptureDevice.activeMicrophoneMode {
                case .voiceIsolation: return "Voice Isolation"
                case .wideSpectrum: return "Wide Spectrum"
                default: return "Standard"
                }
            }()
            menu.addItem(mode)
        case .camera:
            if devices.choice.camera {
                section("Camera", devices.cameras, .camera)
                menu.addItem(.separator())
            }
            let effects = PageMenuItem("Video Effects…") { AVCaptureDevice.showSystemUserInterface(.videoEffects) }
            let on = [(AVCaptureDevice.isPortraitEffectEnabled, "Portrait"), (AVCaptureDevice.isCenterStageEnabled, "Center Stage"),
                      (AVCaptureDevice.isStudioLightEnabled, "Studio Light"), (AVCaptureDevice.reactionEffectsEnabled, "Reactions")]
                .filter(\.0).map(\.1)
            effects.subtitle = on.isEmpty ? "Off" : ListFormatter.englishString(byJoining: on)
            menu.addItem(effects)
        }
        return menu
    }

    /// A microphone or a camera come or gone while a call is out: its
    /// devices read again, and a word in the window: a device come, with
    /// Use; the microphone in use gone, what the call hears now.
    private func watchCallDevices() {
        for (name, came) in [(AVCaptureDevice.wasConnectedNotification, true), (AVCaptureDevice.wasDisconnectedNotification, false)] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let device = note.object as? AVCaptureDevice
                let label = device?.localizedName
                let kind: CallDeviceKind = device?.hasMediaType(.video) == true ? .camera : .mic
                MainActor.assumeIsolated { self?.callDeviceChanged(label, kind, came: came) }
            }
        }
    }

    func callDeviceChanged(_ name: String?, _ kind: CallDeviceKind, came: Bool) {
        guard let tab = floatingCall else { return }
        let before = tab.callDevices
        // The page hears of it a moment after the Mac does (devicechange).
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self, weak tab] in
            guard let self, let tab, self.floatingCall === tab else { return }
            tab.readCallDevices { [weak self, weak tab] in
                guard let self, let tab, self.floatingCall === tab, let now = tab.callDevices else { return }
                if came, let name, let match = now.list(kind).first(where: { !$0.isDefault && CallDevices.same($0.label, name) }), !match.on {
                    self.floater.sayCall("\(name) connected", use: { [weak tab] in
                        tab?.pickCallDevice(kind, match, speakerToo: kind == .mic)
                    }, for: 6)
                } else if !came, kind == .mic, let was = before?.mics.first(where: \.on),
                          let hears = now.mics.first(where: \.on), was.label != hears.label {
                    self.floater.sayCall("Now using \(CallDevices.plain(hears.label))", for: 3)
                }
            }
        }
    }

    /// Leave, from the window: the page's own Leave, so the meeting knows
    /// you left rather than lost you; a page with none has its tab closed,
    /// which is leaving too. Meet asking the one who started the call to
    /// end it for everyone or just leave gets Just Leave, as Leave says;
    /// a page with another question is brought back to its tab with the
    /// question up, to answer there.
    func leaveCall(_ tab: Tab) {
        guard let web = tab.builtPage else { return close(tab) }
        if let page = web as? ChromiumPage, page.routeNativeMediaAction("hangUp") { return }
        CallStage.run("leave", on: web) { [weak self] pressed in
            guard let self else { return }
            if pressed as? String == "asked" {
                if self.floating == tab.id { self.returnFloatingTab() }
            } else if pressed as? Bool == true {
                // The page lets go of the camera and the microphone as it
                // leaves; the window folds with that (callEnded). One that
                // never does is put back all the same.
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                    guard let self, self.floating == tab.id, tab.onCall else { return }
                    self.land()
                }
            } else {
                // No Leave of the page's own: the call goes back to its tab,
                // closed only when the tab is the call itself. A huddle in
                // Slack's tab or a call in the Teams app would take the app.
                self.land()
                if Self.closesOnLeave(tab.address) { self.close(tab) }
            }
        }
    }

    /// A tab whose address is a meeting and nothing else (meet.google.com/abc-…,
    /// zoom.us/j/…): Leave may close it when its page has no Leave of its own.
    nonisolated static func closesOnLeave(_ address: URL?) -> Bool {
        CallLink.key(address) != nil
    }

    // MARK: - links to calls

    /// A link to a meeting that is already open in a tab, in any space:
    /// that tab, rather than a second copy of the call.
    func openCall(_ url: URL) -> Bool {
        guard let key = CallLink.key(url) else { return false }
        let match = { (tab: Tab) in CallLink.key(tab.address) == key || CallLink.key(tab.callStarted) == key }
        if let tab = tabs.first(where: match) {
            select(tab)
            return true
        }
        for row in parked.values {
            guard let tab = row.tabs.first(where: match), let space = spaceHolding(tab.id) else { continue }
            switchSpace(to: space)
            if let tab = tabs.first(where: match) { select(tab) }
            return true
        }
        return false
    }
}

// MARK: - the screen and the devices, per tab

/// The devices a call's page offers, as its own menus list them, the one
/// in use ticked, and whether it has a Share of its own to press.
struct CallDevices: Equatable {
    struct Device: Equatable, Identifiable {
        let label: String
        let on: Bool
        /// The page's id for it; "default" for the Mac's own choice,
        /// which the page lists beside the device it is.
        var device = ""
        var id: String { device.isEmpty ? label : device }
        var isDefault: Bool { device == "default" }
        /// "System Default (MacBook Pro Speakers)" for the Mac's choice,
        /// else the name.
        var title: String { isDefault ? "System Default (\(CallDevices.plain(label)))" : label }
    }

    var mics: [Device] = []
    var speakers: [Device] = []
    var cameras: [Device] = []
    var sharable = false

    init() {}

    /// From CallStage's `devices`: {mics, speakers, cameras: [{label, on}], sharable}.
    init(_ answer: Any?) {
        guard let body = answer as? [String: Any] else { return }
        func list(_ key: String) -> [Device] {
            (body[key] as? [[String: Any]] ?? []).compactMap { entry in
                guard let label = entry["label"] as? String, !label.isEmpty else { return nil }
                return Device(label: label, on: entry["on"] as? Bool ?? false, device: entry["id"] as? String ?? "")
            }
        }
        mics = list("mics")
        speakers = list("speakers")
        cameras = list("cameras")
        sharable = body["sharable"] as? Bool ?? false
    }

    /// Whether the microphone's menu and the camera's have anything to
    /// choose between: what brings their arrows.
    /// The speakers count with the microphones: two speakers and one
    /// microphone still bring the arrow, and the Speaker list in its menu.
    /// The Mac's own choice beside the very device it is now is no choice.
    var choice: (mic: Bool, camera: Bool) { (Self.several(mics) || Self.several(speakers), Self.several(cameras)) }

    static func several(_ list: [Device]) -> Bool {
        Set(list.map { plain($0.label).lowercased() }).count > 1
    }

    func list(_ kind: CallDeviceKind) -> [Device] {
        switch kind {
        case .mic: return mics
        case .speaker: return speakers
        case .camera: return cameras
        }
    }

    /// A device's name as the page writes it and as the Mac does: the
    /// page may put "Default - " before it or "(Bluetooth)" after.
    static func plain(_ label: String) -> String {
        var name = label
        for lead in ["Default - ", "Default – ", "System default - ", "Communications - "] where name.hasPrefix(lead) {
            name = String(name.dropFirst(lead.count))
        }
        if let open = name.range(of: " (", options: .backwards), name.hasSuffix(")") { name = String(name[..<open.lowerBound]) }
        return name.trimmingCharacters(in: .whitespaces)
    }

    static func same(_ a: String, _ b: String) -> Bool {
        let x = plain(a).lowercased(), y = plain(b).lowercased()
        return !x.isEmpty && !y.isEmpty && (x == y || x.contains(y) || y.contains(x))
    }
}

enum CallDeviceKind: String { case mic, speaker, camera }

/// A key WebKit keeps apart, watched by name: NSKeyValueObservation needs
/// a key path Swift can see, and `_displayCaptureState` is private.
final class KeyWatch: NSObject {
    private weak var object: NSObject?
    private let key: String
    private let changed: () -> Void
    private var watching = false

    init(_ object: NSObject, _ key: String, changed: @escaping () -> Void) {
        self.object = object
        self.key = key
        self.changed = changed
        super.init()
        guard object.responds(to: NSSelectorFromString(key)) else { return }
        object.addObserver(self, forKeyPath: key, options: [.new], context: nil)
        watching = true
    }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                               change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        changed()
    }

    deinit {
        if watching { object?.removeObserver(self, forKeyPath: key) }
    }
}

extension Tab {
    /// Showing the screen or a window to the page, however it is shown:
    /// what the call window, the dot's menu and floating go by.
    var presentingScreen: Bool { sharing || screen != .none || builtPage.map { $0.captureStatus.screen != .none } == true }

    /// Your screen, shown no more: by the page's own Stop, so it ends its
    /// share as it would by hand; a page with none, or one whose Stop
    /// didn't take within a second, has WebKit end the capture, which any
    /// page hears as its track ending. Not first: WebKit then also takes
    /// back the page's sight of the devices' names and ids, which a call's
    /// own device menus go on needing.
    func stopSharing() {
        // What Yab shows the page itself (Share.swift), and a share from
        // the system's picker it knows of, stop in the page, which hears
        // its track end.
        if Share.shared.sharing(self) { return Share.shared.stop(caller: self) }
        guard let web = builtPage else { return }
        CallStage.run("unshare", on: web) { [weak self] pressed in
            DispatchQueue.main.asyncAfter(deadline: .now() + (pressed as? Bool == true ? 1 : 0)) {
                guard let self, self.presentingScreen, let web = self.builtPage else { return }
                web.stopDisplayCapture()
            }
        }
    }

    /// The call's devices read from its page's own menus (CallStage).
    func readCallDevices(_ done: (() -> Void)? = nil) {
        guard let web = builtPage else { done?(); return }
        CallStage.run("devices", on: web) { [weak self] answer in
            if let self, answer != nil {
                let read = CallDevices(answer)
                if read != self.callDevices { self.callDevices = read }
            }
            done?()
        }
    }

    /// A device picked, in the page's own menu, so the page and everyone on
    /// the call hear what it says it uses; the list read again after. A
    /// microphone that is also a speaker (AirPods) takes the speaker along
    /// when asked.
    func pickCallDevice(_ kind: CallDeviceKind, _ device: CallDevices.Device, speakerToo: Bool = false) {
        guard let web = builtPage else { return }
        CallStage.run("pick", ["kind": kind.rawValue, "label": device.label, "id": device.device], on: web) { [weak self] _ in
            guard let self else { return }
            if speakerToo, let speaker = self.callDevices?.speakers.first(where: { !$0.isDefault && CallDevices.same($0.label, device.label) }),
               !speaker.on {
                return self.pickCallDevice(.speaker, speaker)
            }
            self.readCallDevices()
        }
    }
}

/// The call's devices in the dot's menu, as the call window has them:
/// the microphone's, the speaker's and the camera's lists, and the Mac's
/// own Mic Mode and Video Effects.
struct CallDeviceMenus: View {
    @ObservedObject var tab: Tab

    var body: some View {
        let devices = tab.callDevices ?? CallDevices()
        if tab.microphone != .none || tab.camera != .none || tab.pageMic != nil {
            Divider()
            if devices.choice.mic, !devices.mics.isEmpty { Menu("Microphone") { pick(devices.mics, .mic) } }
            if devices.choice.mic, !devices.speakers.isEmpty { Menu("Speaker") { pick(devices.speakers, .speaker) } }
            if devices.choice.camera, !devices.cameras.isEmpty { Menu("Camera") { pick(devices.cameras, .camera) } }
            if tab.microphone != .none || tab.pageMic != nil {
                Button("Mic Mode…") { AVCaptureDevice.showSystemUserInterface(.microphoneModes) }
            }
            if tab.camera != .none || tab.pageCamera != nil {
                Button("Video Effects…") { AVCaptureDevice.showSystemUserInterface(.videoEffects) }
            }
        }
    }

    @ViewBuilder private func pick(_ list: [CallDevices.Device], _ kind: CallDeviceKind) -> some View {
        ForEach(list) { device in
            Toggle(device.title, isOn: Binding(get: { device.on }, set: { _ in tab.pickCallDevice(kind, device) }))
        }
    }
}

/// What waits while a call is on: shown only with no call anywhere. The
/// update's note, which would otherwise be written in over a meeting.
struct UnlessOnCall<Content: View>: View {
    @ObservedObject var calls: Calls
    @ViewBuilder var content: () -> Content

    var body: some View {
        if !calls.any { content() }
    }
}

/// The Tabs menu's Mute Tab: the tab's own mute, as its speaker has it,
/// ticked while muted, so its title never changes and App Shortcuts can
/// give it a key by name, as Mute Call does. With several picked, ticked
/// when every one is muted.
struct MuteCommand: View {
    let browser: Browser
    let tab: Tab?

    var body: some View {
        if let tab {
            MuteToggle(browser: browser, tab: tab)
        } else {
            Toggle("Mute Tab", isOn: .constant(false)).shortcut(.mute).disabled(true)
        }
    }
}

private struct MuteToggle: View {
    let browser: Browser
    @ObservedObject var tab: Tab

    var body: some View {
        let group = browser.several ? browser.chosen : [tab]
        Toggle(group.count > 1 ? "Mute \(group.count) Tabs" : "Mute Tab", isOn: Binding(
            get: { group.allSatisfy(\.muted) },
            set: { _ in browser.toggleMute(browser.several ? browser.chosen : nil) }
        ))
        .shortcut(.mute)
        .disabled(tab.isBlank && group.count == 1)
    }
}

/// The Tabs menu's calls: the microphone of the call on, and the next
/// meeting. Mute Call is ticked while muted, so its title never changes
/// and App Shortcuts can give it a key by name.
struct CallCommands: View {
    let browser: Browser
    @ObservedObject var calls: Calls

    var body: some View {
        let tab = calls.any ? browser.call : nil
        Toggle("Mute Call", isOn: Binding(
            get: { tab?.mic == .muted },
            set: { _ in browser.toggleCallMic() }
        ))
        .shortcut(.muteCall)
        .disabled(tab?.microphone == nil || tab?.microphone == PageMediaState.none)
        Button("Join Next Meeting") { browser.joinNextMeeting() }
            .shortcut(.joinMeeting)
    }
}
