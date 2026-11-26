import AppKit
import Combine
import WebKit

// What a tab is playing, and the one line over the column's foot that says
// so while you are somewhere else (PlayerBand.swift).
//
// WebKit already keeps a now-playing session for every page with media, the
// one Control Center and the media keys talk to, and it answers a few quiet
// names about it: `_setNowPlayingMetadataObserver:` hands over the title and
// the artist whenever the page changes them (about 40 ms after, measured),
// `_requestActiveNowPlayingSessionInfo:` the length and where playback stood
// at the last change, and `_pauseNowPlayingMediaSession:` and
// `_playPredominantOrNowPlayingMediaSession:` stop and start it. Nothing is
// polled: every question is asked because something just happened. The
// observer has to be set once the page has a session, one set before the
// page loads is lost with the page (measured on macOS 27).
//
// What WebKit doesn't say, the cover and whether the site has next and
// previous buttons, is read in yab's own world, never the page's, once per
// track. Skipping presses the site's own button: there is no quiet name for
// the media session's next track, and a handler of ours would replace the
// page's.

/// What a tab is playing.
struct Tune: Equatable {
    var title = ""
    var artist = ""
    /// Seconds; 0 when the page doesn't say, a live stream.
    var duration: Double = 0
    /// A live stream (LiveEdge.swift), which has no length: how far behind
    /// its edge it played at `stamp`, and how long a stretch it keeps, 0
    /// where nobody says.
    var live = false
    var behind: Double = 0
    var span: Double = 0
    /// In a live stream, as last read: an advert plays inside it, and
    /// whether the page's media is muted; and it waits at its edge,
    /// fetching, where it was Live (LiveEdge.subtitle).
    var ad = false
    var quiet = false
    var catching = false
    /// Where playback stood at `stamp` (CACurrentMediaTime).
    var elapsed: Double = 0
    var stamp: CFTimeInterval = 0
    var playing = false
    /// The media starts over at its end by itself (`loop`), which says
    /// nothing to WebKit or the page: playing, its place goes round the
    /// length rather than stopping at it.
    var loops = false
    /// The site has a button for these that yab can press.
    var next = false
    var previous = false
    /// The cover's color, once worked out.
    var accent: NSColor?
    /// The cover itself, 112 pixels across, or the site's icon without one.
    var cover: CGImage?

    /// A notification is audible, but is not a track to keep in the player.
    /// Short loops and live streams still have useful playback controls.
    var shortSound: Bool { duration > 0 && duration <= 3 && !loops && !live }

    func position(at now: CFTimeInterval = CACurrentMediaTime()) -> Double {
        guard playing else { return elapsed }
        let run = elapsed + max(0, now - stamp)
        guard duration > 0 else { return run }
        // A loop wraps with no event to read it by: round the length, not
        // stuck at its end (0:30, −0:00 and a full line while it played on).
        return loops ? run.truncatingRemainder(dividingBy: duration) : min(duration, run)
    }

    /// How far behind a live stream's edge it is now: paused, it falls
    /// behind as the edge goes on.
    func lag(at now: CFTimeInterval = CACurrentMediaTime()) -> Double {
        guard live, !catching else { return 0 }
        return behind + (playing ? 0 : max(0, now - stamp))
    }

    /// A live stream that keeps a stretch to go back into: a line to show.
    var rewinds: Bool { live && span >= LiveEdge.shortest }

    /// Live, or how far behind; only Live where it keeps nothing to go
    /// back into.
    func words(at now: CFTimeInterval = CACurrentMediaTime()) -> String {
        rewinds ? LiveEdge.words(behind: lag(at: now)) : "Live"
    }

    /// Behind, with a way back: its words go to the edge.
    func goesLive(at now: CFTimeInterval = CACurrentMediaTime()) -> Bool {
        rewinds && lag(at: now) >= LiveEdge.near
    }

    /// The line under the title: the artist, or in a live stream what else
    /// goes on in it.
    var subtitle: String {
        guard live else { return artist }
        return LiveEdge.subtitle(ad: ad, muted: quiet, waiting: catching, atEdge: true) ?? artist
    }

    /// How long a stretch a live stream keeps now: paused, its edge goes on
    /// and the stretch with it.
    func kept(at now: CFTimeInterval = CACurrentMediaTime()) -> Double {
        span + (playing ? 0 : max(0, now - stamp))
    }

    /// How far along the line, nought to one. A live stream's line is the
    /// stretch it keeps, its right end live; all of it where nobody says
    /// how long that is.
    func through(at now: CFTimeInterval = CACurrentMediaTime()) -> Double {
        if live {
            let lag = lag(at: now)
            guard rewinds, lag >= LiveEdge.near else { return 1 }
            return min(1, max(0, 1 - lag / kept(at: now)))
        }
        return duration > 0 ? min(1, position(at: now) / duration) : 0
    }

    /// It has a line to scrub: a length, or a live stretch to go back into.
    var scrubs: Bool { live ? rewinds : duration > 0 }

    /// Beside play in the island: 15 seconds back and on, as the floating
    /// window has, wherever there is a line to move along, unless the site
    /// gives both its own previous and next (an album, a playlist). A lone
    /// next, a video's autoplay, is left to the menu.
    var seeks: Bool { scrubs && !(previous && next) }

    /// Where `seconds` on, or back where negative, lands along the line,
    /// nought to one: a live stream never past its edge, nor further back
    /// than the stretch it keeps.
    func through(after seconds: Double, at now: CFTimeInterval = CACurrentMediaTime()) -> Double {
        if live {
            let span = kept(at: now)
            guard span > 0 else { return 1 }
            return 1 - min(span, max(0, lag(at: now) - seconds)) / span
        }
        guard duration > 0 else { return 0 }
        return min(1, max(0, (position(at: now) + seconds) / duration))
    }

    /// There is something to name.
    var named: Bool { !title.isEmpty }
}

/// The native fallback belongs to the latest play/pause request. A page's
/// own button may answer after another request, a session change or stop.
/// Only the current completion may then touch WebKit's native session.
@MainActor
final class TuneTransport {
    private var pending: UUID?

    func invalidate() { pending = nil }

    func answer(fallback: @escaping () -> Void) -> (Any?) -> Void {
        let token = UUID()
        pending = token
        return { [weak self] pressed in
            guard let self, self.pending == token else { return }
            // Consume before calling out: a fallback can start a new request.
            self.pending = nil
            if (pressed as? Bool) != true { fallback() }
        }
    }
}

/// One tab's side of it: WebKit's session, heard and asked.
@MainActor
final class TuneWatch: NSObject {
    private weak var web: WKWebView?
    /// A Chromium tab's page instead (`chromium(_:page:tab:)`): its session
    /// comes from YabCore's media reports, not WebKit's private names.
    private weak var remote: ChromiumPage?
    private var remoteReport: ChromiumMediaReport?
    private weak var tab: Tab?
    private var session = false
    private let transport = TuneTransport()
    /// The observer is WebKit's to keep; it is set again whenever the page
    /// gets a session, since a page that loads another loses it.
    private var observing = false
    /// The cover last read, so a track with the same artwork isn't fetched again.
    private var cover: URL?
    /// Asks in flight are answered in order; an older answer never lands on
    /// a newer track.
    private var asked = 0

    private static let sessionKey = "_hasActiveNowPlayingSession"
    private static let observe = NSSelectorFromString("_setNowPlayingMetadataObserver:")
    private static let info = NSSelectorFromString("_requestActiveNowPlayingSessionInfo:")
    private static let pauseName = NSSelectorFromString("_pauseNowPlayingMediaSession:")
    private static let playName = NSSelectorFromString("_playPredominantOrNowPlayingMediaSession:")

    /// Every name above answers on this WebKit.
    static let works: Bool = [observe, info, pauseName, playName, NSSelectorFromString(sessionKey)]
        .allSatisfy { WKWebView.instancesRespond(to: $0) }

    func watch(_ web: WKWebView, tab: Tab) {
        transport.invalidate()
        guard TuneWatch.works else { return }
        self.web = web
        self.tab = tab
        web.addObserver(self, forKeyPath: TuneWatch.sessionKey, options: [.initial, .new], context: nil)
    }

    func stop() {
        transport.invalidate()
        if remote != nil { stopChromium() }
        guard let web else { return }
        web.removeObserver(self, forKeyPath: TuneWatch.sessionKey)
        self.web = nil
        session = false
        observing = false
        pageMedia = false
        liveTimer?.invalidate()
        liveTimer = nil
        livePace = 0
        tab?.tune = nil
        tab.map { $0.onTune?($0) }
    }

    override nonisolated func observeValue(
        forKeyPath path: String?, of object: Any?,
        change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?
    ) {
        let on = (change?[.newKey] as? Bool) ?? false
        DispatchQueue.main.async { MainActor.assumeIsolated { self.sessioned(on) } }
    }

    private func sessioned(_ on: Bool) {
        guard on != session else { return }
        transport.invalidate()
        session = on
        if on {
            listen()
        } else {
            observing = false
            cover = nil
            pageMedia = false
            liveTimer?.invalidate()
            liveTimer = nil
            livePace = 0
            tab?.tune = nil
            tab.map { $0.onTune?($0) }
        }
    }

    private func listen() {
        guard let web, !observing else { return }
        observing = true
        let heard: @convention(block) (AnyObject?) -> Void = { [weak self] meta in
            let title = meta?.value(forKey: "title") as? String ?? ""
            let artist = meta?.value(forKey: "artist") as? String ?? ""
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.named(title, artist) } }
        }
        web.perform(TuneWatch.observe, with: heard)
    }

    /// The page named what it plays, or named it again.
    private func named(_ title: String, _ artist: String) {
        guard session, let tab else { return }
        var tune = tab.tune ?? Tune(playing: tab.noisy)
        if settling == nil, tab.noisy { tune.playing = true }
        let fresh = tune.title != title || tune.artist != artist
        tune.title = title
        tune.artist = artist
        if fresh {
            // A new track starts at its beginning; the length comes with
            // the next answer.
            tune.elapsed = 0
            tune.stamp = CACurrentMediaTime()
        }
        tab.tune = tune
        tab.onTune?(tab)
        // Named again with the same words: what changed is the rest of the
        // metadata, most often the artwork a site sets a beat after the
        // title. Read the page again for it.
        ask(track: true)
    }

    /// The page started or stopped making noise.
    func heard(playing: Bool) {
        if playing, web != nil { ChromiumNowPlaying.shared.yieldToWebKit() }
        settling?.cancel()
        settling = nil
        guard !playing else { settle(true); return }
        // A page going on to its next track stops for a tenth of a second
        // between the two (measured: 60 to 110 ms); a pause shown for that
        // long is a flicker. A stop counts once it has lasted.
        let item = DispatchWorkItem { [weak self] in
            self?.settling = nil
            self?.settle(false)
        }
        settling = item
        DispatchQueue.main.asyncAfter(deadline: .now() + TuneWatch.settle, execute: item)
    }

    private var settling: DispatchWorkItem?
    /// The page's own reading found its media element; until then, or
    /// where it never does, WebKit's word that a stream is endless counts.
    private var pageMedia = false
    static let settle: TimeInterval = 0.3

    private func settle(_ on: Bool) {
        guard session, let tab, var tune = tab.tune else { return }
        guard tune.playing != on else { return }
        tune.elapsed = tune.position()
        tune.stamp = CACurrentMediaTime()
        tune.playing = on
        tab.tune = tune
        tab.onTune?(tab)
        ask(track: false)
    }

    /// Asked from the band: shown at once (P6), and the page's own word
    /// follows.
    func want(playing on: Bool) {
        guard let tab, var tune = tab.tune, tune.playing != on else { return }
        settling?.cancel()
        settling = nil
        tune.elapsed = tune.position()
        tune.stamp = CACurrentMediaTime()
        tune.playing = on
        tab.tune = tune
        tab.onTune?(tab)
        play(on)
    }

    /// How long the track is, from WebKit, which knows it for a stream the
    /// page's media element calls endless; and on a new track what WebKit
    /// doesn't know, from the page. Where playback stands is never taken
    /// from here: WebKit's is the one at its last change, with no word of
    /// when that was, and two clocks disagreeing made the time jump.
    private func ask(track: Bool) {
        guard let web else { if remote != nil { askChromium(track: track) }; return }
        asked += 1
        let turn = asked
        typealias Answer = @convention(block) (Bool, Bool, NSString?, Double, Double, Int) -> Void
        typealias Ask = @convention(c) (AnyObject, Selector, Answer) -> Void
        let call = unsafeBitCast(web.method(for: TuneWatch.info), to: Ask.self)
        let answer: Answer = { [weak self] _, _, _, duration, _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    // A live stream's length is no more WebKit's than the
                    // page's: about an hour past its edge on YouTube.
                    guard let self, turn == self.asked, let tab = self.tab, var tune = tab.tune, !tune.live else { return }
                    if duration.isInfinite, duration > 0, !self.pageMedia {
                        // Endless to WebKit, and no media the page shows
                        // us (a radio's player of its own, a stream opened
                        // by itself): live, with nothing to go back into.
                        tune.live = true
                        tune.duration = 0
                        tune.behind = 0
                        tune.span = 0
                        tab.tune = tune
                        self.followLive(tune)
                        tab.onTune?(tab)
                        return
                    }
                    guard duration.isFinite, duration > 0, duration != tune.duration else { return }
                    tune.duration = duration
                    tab.tune = tune
                    tab.onTune?(tab)
                }
            }
        }
        call(web, TuneWatch.info, answer)
        // A live stream: how far behind its edge, read again as it plays
        // or stops.
        if track || tab?.tune?.live == true { look() }
    }

    /// What the page knows and WebKit doesn't: the cover, the site's next
    /// and previous buttons, and the media element's own clock, which is
    /// right even after a seek WebKit wasn't told about.
    func look() {
        guard let title = tab?.tune?.title else { return }
        // A read, every 15 s while a live stream plays: without a gesture,
        // which would take a click's activation from the page (QuietScript).
        inYab(TuneWatch.probe, quiet: true) { [weak self] value in
            guard let self, let tab = self.tab, var tune = tab.tune, tune.title == title,
                  let found = value as? [String: Any] else { return }
            self.pageMedia = (found["t"] as? Double ?? -1) >= 0
            tune.next = found["next"] as? Bool ?? false
            tune.previous = found["prev"] as? Bool ?? false
            // Read sitting at its very end, a loop that didn't go round
            // (seen with Media Source Extensions): held there, not wrapped.
            let at = found["t"] as? Double ?? -1, length = found["d"] as? Double ?? -1
            tune.loops = (found["loop"] as? Bool ?? false) && !(length > 0 && at >= length - 0.25)
            let ad = found["ad"] as? Bool ?? false
            if ad, tune.live {
                // An advert inside the stream: the stream's own place stays
                // as it was; the advert's times are none of it.
                tune.ad = true
                tune.quiet = found["muted"] as? Bool ?? false
            } else if let at = found["t"] as? Double, at >= 0 {
                // Live when it was last read, and now held up fetching: a
                // stall at the edge, not a step back from it.
                let wasLive = tune.live && (tune.catching || tune.lag() < LiveEdge.near)
                tune.elapsed = at
                tune.stamp = CACurrentMediaTime()
                tune.ad = false
                if let reach = TuneWatch.reach(found["live"]) {
                    tune.live = true
                    tune.duration = 0
                    tune.behind = max(0, reach.edge - at)
                    tune.span = reach.start.map { max(0, reach.edge - $0) } ?? 0
                    tune.catching = (found["wait"] as? Bool ?? false) && wasLive
                } else {
                    // A video, or a broadcast over and kept as one: the
                    // length it has now, a recording's, counts.
                    if tune.live { tune.duration = 0 }
                    tune.live = false
                    tune.catching = false
                    if let length = found["d"] as? Double, length > 0, tune.duration == 0 { tune.duration = length }
                }
            }
            tab.tune = tune
            followLive(tune)
            tab.onTune?(tab)
            let art = (found["art"] as? String).flatMap { URL(string: $0) }
            if art != self.cover || tune.accent == nil {
                self.cover = art
                self.paint(from: art, tab: tab)
            }
        }
    }

    /// A live stream says nothing to WebKit as it goes on: an advert inside
    /// it, a wait at its edge, the edge leaving a paused one behind. So it
    /// is read again every 15 seconds while it plays, and once a minute
    /// while paused, where only the minutes behind change. Nothing for a
    /// video.
    private var liveTimer: Timer?
    private var livePace: TimeInterval = 0

    private func followLive(_ tune: Tune) {
        let pace: TimeInterval = !tune.live ? 0 : tune.playing ? 15 : 60
        guard pace != livePace else { return }
        livePace = pace
        liveTimer?.invalidate()
        liveTimer = nil
        guard pace > 0 else { return }
        liveTimer = Timer.scheduledTimer(withTimeInterval: pace, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.look() }
        }
        liveTimer?.tolerance = pace / 5
    }

    /// Back to a live stream's edge, from the island's words.
    func goLive() {
        guard let tab, var tune = tab.tune, tune.live else { return }
        tune.behind = 0
        tune.elapsed = tune.position()
        tune.stamp = CACurrentMediaTime()
        tab.tune = tune
        tab.onTune?(tab)
        inYab("""
        (function () {
          var live = \(LiveEdge.reader);
          var media = Array.prototype.find.call(document.querySelectorAll('video, audio'), function (m) { return !m.paused; })
            || document.querySelector('video, audio');
          var reach = media ? live(media) : null;
          if (reach) media.currentTime = reach[1];
          return !!reach;
        })()
        """) { [weak self] _ in self?.look() }
    }

    /// To a point along the island's line, nought to one. `rough` while a
    /// finger still holds it: the nearest frame the engine can show at
    /// once, the tune left as it is. Let go, exactly there, shown at once
    /// (P6), and the page's own clock read back after.
    func seek(to fraction: Double, rough: Bool) {
        let at = min(1, max(0, fraction.isFinite ? fraction : 0))
        if !rough, let tab, var tune = tab.tune {
            let now = CACurrentMediaTime()
            if tune.live {
                tune.elapsed = tune.position(at: now)
                tune.span = tune.kept(at: now)
                tune.behind = (1 - at) * tune.span
            } else if tune.duration > 0 {
                tune.elapsed = at * tune.duration
            }
            tune.stamp = now
            tab.tune = tune
            tab.onTune?(tab)
        }
        send(at, rough: rough)
    }

    /// `seconds` on, or back where negative, from where it plays now: the
    /// island's 15 seconds, shown at once as a let-go seek is.
    func jump(by seconds: Double) {
        guard let tune = tab?.tune, tune.scrubs else { return }
        seek(to: tune.through(after: seconds), rough: false)
    }

    /// One seek in flight at a time, the newest waiting behind it, so a
    /// drag never piles them up in the page.
    private var seeking = false
    private var nextSeek: (fraction: Double, rough: Bool)?

    private func send(_ fraction: Double, rough: Bool) {
        guard web != nil || remote != nil else { return }
        guard !seeking else {
            nextSeek = (fraction, rough)
            return
        }
        seeking = true
        inYab("(\(TuneWatch.seeker))(\(fraction), \(rough))") { [weak self] _ in
            guard let self else { return }
            self.seeking = false
            if let next = self.nextSeek {
                self.nextSeek = nil
                self.send(next.fraction, rough: next.rough)
            } else if !rough {
                self.look()
            }
        }
    }

    /// The same media tree for artwork and transport buttons.
    /// A document query alone misses a web component's video and a player
    /// in a same-origin frame. Cross-origin frames remain WebKit's to play
    /// and pause through its native session.
    private static let mediaTree = """
    function () {
      var roots = [document];
      for (var i = 0; i < roots.length; i++) {
        var nodes = roots[i].querySelectorAll('*');
        for (var j = 0; j < nodes.length; j++) {
          var node = nodes[j];
          if (node.shadowRoot && roots.indexOf(node.shadowRoot) < 0) roots.push(node.shadowRoot);
          try {
            var inner = /^(IFRAME|FRAME)$/.test(node.tagName) ? node.contentDocument : null;
            if (inner && roots.indexOf(inner) < 0) roots.push(inner);
          } catch (_) {}
        }
      }
      function all(selector) {
        var found = [];
        roots.forEach(function (root) { found = found.concat(Array.from(root.querySelectorAll(selector))); });
        return found;
      }
      var media = all('video, audio');
      return { all: all, media: media.find(function (m) { return !m.paused; }) || media[0] };
    }
    """

    /// `(fraction, rough) -> moved`: the page's media to that point along
    /// it, as the floating window seeks (Float.swift), a live stream along
    /// the stretch it keeps. A player that keeps its media out of the page,
    /// as Spotify's does, is moved by its own progress bar, the way its
    /// keys move it, and only where the finger lets go.
    static let seeker = """
    function (fraction, rough) {
      var live = \(LiveEdge.reader);
      var at = Math.max(0, Math.min(1, fraction));
      var own = document.querySelector('[data-testid="playback-progressbar"] input[type="range"]');
      if (own) {
        if (rough) return true;
        var low = parseFloat(own.min) || 0, high = parseFloat(own.max);
        if (!(high > low)) return false;
        own.value = String(Math.round(low + at * (high - low)));
        own.dispatchEvent(new Event('input', { bubbles: true }));
        own.dispatchEvent(new Event('change', { bubbles: true }));
        return true;
      }
      var all = document.querySelectorAll('video, audio');
      var media = Array.prototype.find.call(all, function (m) { return !m.paused; }) || all[0];
      if (!media) return false;
      var reach = live(media), time;
      if (reach) {
        if (reach[0] < 0) return false;
        time = at >= 1 ? reach[1] : reach[0] + at * (reach[1] - reach[0]);
      } else {
        if (!media.duration || !isFinite(media.duration)) return false;
        time = at * media.duration;
      }
      if (rough && media.fastSeek) media.fastSeek(time); else media.currentTime = time;
      return true;
    }
    """

    /// A live stream's stretch, as the page's `live` answers it: its start,
    /// nil where nobody says, and its edge. Nil for a video.
    nonisolated static func reach(_ found: Any?) -> (start: Double?, edge: Double)? {
        guard let pair = found as? [Any], pair.count == 2,
              let start = (pair[0] as? NSNumber)?.doubleValue, let edge = (pair[1] as? NSNumber)?.doubleValue,
              start.isFinite, edge.isFinite
        else { return nil }
        return (start >= 0 ? start : nil, edge)
    }

    /// The cover's color, or the site's icon's without a cover.
    private func paint(from art: URL?, tab: Tab) {
        let title = tab.tune?.title
        let done: (Accent.Art?) -> Void = { [weak tab] art in
            guard let tab, var tune = tab.tune, tune.title == title else { return }
            tune.accent = art?.color
            tune.cover = art?.image
            tab.tune = tune
            tab.onTune?(tab)
        }
        if let art {
            Accent.of(art, shy: tab.shy) { [weak tab] found in
                if let found { done(found) } else { Accent.of(tab?.icon, then: done) }
            }
        } else {
            Accent.of(tab.icon, then: done)
        }
    }

    func play(_ on: Bool) {
        if web == nil, let remote {
            if remote.routeNativeMediaAction(on ? "play" : "pause") { return }
            // Older helpers retain their existing renderer route.
            // Keep play inside the CDP user gesture. A later renderer IPC
            // callback has no activation and autoplay policy rejects it.
            inYab("""
            (async function () {
              if ((\(TuneWatch.toggler))(\(on))) return true;
              var tree = (\(TuneWatch.mediaTree))();
              if (!tree.media) return false;
              if (\(on)) await tree.media.play();
              else tree.all('video, audio').forEach(function (m) { if (!m.paused) m.pause(); });
              return true;
            })()
            """) { [weak remote] pressed in
                guard (pressed as? Bool) != true else { return }
                remote?.mediaAction(on ? "play" : "pause")
            }
            return
        }
        guard session, let web else { return }
        // A player with a play button of its own, Spotify's, is pressed
        // there: Spotify's player doesn't stop for WebKit's session pause
        // (register #418). Everything else, YouTube among them, through
        // WebKit's session.
        let answer = transport.answer { [weak self, weak web] in
            guard let self, self.session, let web, self.web === web else { return }
            typealias Done = @convention(block) () -> Void
            typealias Call = @convention(c) (AnyObject, Selector, Done) -> Void
            let name = on ? TuneWatch.playName : TuneWatch.pauseName
            unsafeBitCast(web.method(for: name), to: Call.self)(web, name, {})
        }
        web.evaluateInYab("(\(TuneWatch.toggler))(\(on))", then: answer)
    }

    /// Presses a known player's own play/pause button when its label says
    /// the other state is wanted; true when that player answered for it.
    static let toggler = """
    function (on) {
      // YouTube Music's own bar button too (register 1450); its web
      // components may keep it in a shadow root, so every tree is read.
      var known = ['[data-testid="control-button-playpause"]', '.playControls .playControl', 'ytmusic-player-bar #play-pause-button'];
      var tree = (\(mediaTree))();
      for (var i = 0; i < known.length; i++) {
        var el = tree.all(known[i]).find(function (e) { return e.getClientRects().length > 0; });
        if (!el || el.disabled || el.getAttribute('aria-disabled') === 'true') continue;
        var label = (el.getAttribute('aria-label') || el.getAttribute('title') || '').trim();
        var pauses = /^pause/i.test(label);
        if (!pauses && !/^play/i.test(label)) continue;
        if (pauses !== on) el.click();
        return true;
      }
      return false;
    }
    """

    /// Presses the site's own next or previous button.
    func skip(forward: Bool) {
        if remote?.routeNativeMediaAction(forward ? "next" : "previous") == true { return }
        inYab("(\(TuneWatch.finder))(\(forward), true)")
    }

    /// Yab's own world, in whichever engine draws the page.
    private func inYab(_ script: String, quiet: Bool = false, then: ((Any?) -> Void)? = nil) {
        if let web {
            if quiet { web.evaluateQuietly(script, in: nil, in: Web.world) { then?(try? $0.get()) } }
            else { web.evaluateInYab(script, then: then) }
        } else if let remote {
            remote.run(script, in: .yab, gesture: !quiet) { then?(try? $0.get()) }
        }
    }

    /// Finds, and when asked presses, the site's next or previous button:
    /// the ones the big players name, then any button labeled plainly so.
    /// Only a button someone could see counts.
    private static let finder = """
    function (forward, press, tree) {
      tree = tree || (\(mediaTree))();
      var known = forward
        ? ['[data-testid="control-button-skip-forward"]', '.ytp-next-button', 'ytmusic-player-bar .next-button', '.skipControl__next', '[aria-label="Next track"]', '[aria-label="Next song"]']
        : ['[data-testid="control-button-skip-back"]', '.ytp-prev-button', 'ytmusic-player-bar .previous-button', '.skipControl__previous', '[aria-label="Previous track"]', '[aria-label="Previous song"]'];
      var plain = forward ? /^(next|next track|next song|skip)$/i : /^(previous|previous track|previous song)$/i;
      function usable(el) { return el && !el.disabled && el.getAttribute('aria-disabled') !== 'true' && el.getClientRects().length > 0; }
      var hit = null;
      for (var i = 0; i < known.length && !hit; i++) { hit = tree.all(known[i]).find(usable) || null; }
      if (!hit) {
        var all = tree.all('button, [role="button"]');
        for (var j = 0; j < all.length && !hit; j++) {
          var label = (all[j].getAttribute('aria-label') || all[j].getAttribute('title') || '').trim();
          if (plain.test(label) && usable(all[j])) hit = all[j];
        }
      }
      if (hit && press) hit.click();
      return !!hit;
    }
    """

    private static let probe = """
    (function () {
      var find = \(finder);
      var live = \(LiveEdge.reader);
      var advert = \(LiveEdge.advert);
      var tree = (\(mediaTree))(), media = tree.media;
      var owner = media && media.ownerDocument.defaultView;
      var session = owner && owner.navigator.mediaSession;
      var meta = session && session.metadata;
      if (!meta) meta = navigator.mediaSession && navigator.mediaSession.metadata;
      var art = null, best = 0;
      if (meta) {
        for (var i = 0; i < meta.artwork.length; i++) {
          var a = meta.artwork[i], side = parseInt((a.sizes || '0').split('x')[0], 10) || 96;
          if (!art || (side <= 512 && side > best)) { art = a.src; best = side; }
        }
      }
      return {
        art: art,
        t: media ? media.currentTime : -1,
        d: media && isFinite(media.duration) ? media.duration : -1,
        live: media ? live(media) : null,
        ad: media ? advert(media) : false,
        muted: media ? (media.muted || media.volume === 0) : false,
        loop: media ? !!media.loop : false,
        wait: media ? (!media.paused && (media.readyState < 3 || media.seeking)) : false,
        next: find(true, false, tree),
        prev: find(false, false, tree)
      };
    })()
    """
}

// MARK: a Chromium tab's session

extension TuneWatch {
    /// YabCore's media report for a Chromium tab (ChromiumPage+Media.swift):
    /// the same session WebKit keeps, made from the page's media and its
    /// MediaSession. A page has one from the first time it is heard until
    /// its media goes: a muted preview playing or a MediaSession set up
    /// with nothing heard is none, as WebKit's Now Playing session isn't.
    func chromium(_ report: ChromiumMediaReport, page: ChromiumPage, tab: Tab) {
        if web != nil { return }
        self.tab = tab
        remote = page
        let before = remoteReport?.media?.time
        remoteReport = report
        sessioned(report.heard && (report.session != nil || report.media != nil))
        guard session else { return }
        let title = report.session.map(\.title).flatMap { $0.isEmpty ? nil : $0 } ?? page.title ?? ""
        let artist = report.session?.artist ?? ""
        if tab.tune?.title != title || tab.tune?.artist != artist {
            named(title, artist)
        } else if let media = report.media, media.time >= 0, media.time != before, var tune = tab.tune, !tune.live {
            // Where it stands, as the page said at its last play, pause or
            // seek; a report for anything else keeps the running clock.
            tune.elapsed = media.time
            tune.stamp = CACurrentMediaTime()
            if media.duration > 0, media.duration.isFinite { tune.duration = media.duration }
            tune.loops = media.loop
            tab.tune = tune
            tab.onTune?(tab)
        }
        heard(playing: report.audible)
    }

    /// The length from the report; the rest from the page, as for WebKit.
    private func askChromium(track: Bool) {
        if let tab, var tune = tab.tune, !tune.live, let media = remoteReport?.media,
           media.duration > 0, media.duration.isFinite, media.duration != tune.duration {
            tune.duration = media.duration
            tab.tune = tune
            tab.onTune?(tab)
        }
        if track || tab?.tune?.live == true { look() }
    }

    private func stopChromium() {
        remote = nil
        remoteReport = nil
        session = false
        pageMedia = false
        cover = nil
        liveTimer?.invalidate()
        liveTimer = nil
        livePace = 0
        settling?.cancel()
        settling = nil
        tab?.tune = nil
        tab.map { $0.onTune?($0) }
    }
}

/// A cover: a picture of it 112 pixels across, for the open island's
/// 48-point one, and its color, the one most of its colorful pixels agree on.
/// Worked out off the main thread, and kept.
@MainActor
enum Accent {
    struct Art {
        let color: NSColor
        let image: CGImage
    }

    private static var known: [URL: Art] = [:]
    private static var waiting: [URL: [(Art?) -> Void]] = [:]
    private static let work = DispatchQueue(label: "yab.accent", qos: .utility)

    static func of(_ url: URL, shy: Bool, then: @escaping (Art?) -> Void) {
        if let hit = known[url] { then(hit); return }
        if waiting[url] != nil { waiting[url]?.append(then); return }
        waiting[url] = [then]
        guard url.scheme == "https" || url.scheme == "http" || url.scheme == "data" else { land(url, nil, keep: false); return }
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        let session = shy ? URLSession.ephemeralFetcher : URLSession.shared
        session.dataTask(with: request) { data, _, _ in
            let art = data.flatMap(Accent.read)
            DispatchQueue.main.async { MainActor.assumeIsolated { land(url, art, keep: !shy) } }
        }.resume()
    }

    static func of(_ image: NSImage?, then: @escaping (Art?) -> Void) {
        guard let image, let tiff = image.tiffRepresentation else { then(nil); return }
        work.async {
            let art = Accent.read(tiff)
            DispatchQueue.main.async { then(art) }
        }
    }

    private static func land(_ url: URL, _ art: Art?, keep: Bool) {
        if keep, let art { known[url] = art }
        if known.count > 64 { known.removeAll() }
        let calls = waiting.removeValue(forKey: url) ?? []
        calls.forEach { $0(art) }
    }

    /// Colorful pixels count by how colorful they are; a gray cover gives
    /// its average, a little lifted so it shows on the column.
    nonisolated static func read(_ data: Data) -> Art? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 112,
              ] as CFDictionary)
        else { return nil }
        let w = 24, h = 24
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard let context = CGContext(
            data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var r = 0.0, g = 0.0, b = 0.0, weight = 0.0, plainR = 0.0, plainG = 0.0, plainB = 0.0, n = 0.0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let a = Double(pixels[i + 3]) / 255
            guard a > 0.5 else { continue }
            let pr = Double(pixels[i]) / 255 / a, pg = Double(pixels[i + 1]) / 255 / a, pb = Double(pixels[i + 2]) / 255 / a
            let hi = max(pr, pg, pb), lo = min(pr, pg, pb)
            let saturation = hi > 0 ? (hi - lo) / hi : 0
            let w = saturation * saturation * hi
            r += pr * w; g += pg * w; b += pb * w; weight += w
            plainR += pr; plainG += pg; plainB += pb; n += 1
        }
        guard n > 0 else { return nil }
        let color = weight > n * 0.02
            ? NSColor(srgbRed: r / weight, green: g / weight, blue: b / weight, alpha: 1)
            : NSColor(srgbRed: plainR / n, green: plainG / n, blue: plainB / n, alpha: 1)
        // Neither so dark it vanishes on a dark column nor so pale it does
        // on a light one: the lightness held to the middle, the hue kept.
        let (l, c, hue) = color.oklch
        return Art(color: NSColor(oklch: (min(0.74, max(0.52, l)), min(0.2, c), hue)), image: image)
    }
}

/// Which tab the band is about, and whether it is up.
///
/// A tab counts while its page has a session with something named, and
/// playing or paused less than five minutes ago, and isn't on screen: the
/// page in front, or either half of a pair, is already its own player.
///
/// One of them is the island, the rest its buds. The island keeps the one
/// it shows: a tab that starts playing later goes into a bud and doesn't
/// take it, or every advert would move the island. Only a lead paused for
/// three seconds while another plays gives way, and a tap, a swipe or a
/// closed tab change it; going to its tab takes it down, and another
/// comes up after the beat. The buds are the others, the one that started
/// last first. It comes up 0.4 s after the tab is left, so ⌃Tab running
/// past a playing tab doesn't flash it, and goes at once.
@MainActor
final class Player {
    weak var browser: Browser?
    /// Whether the band has its row over the column's foot, and the rows
    /// room for it (Side.swift); the band sets it as it arrives and once it
    /// has left.
    let room = PlayerRoom()

    /// Another tab playing off screen: a bud beside the island.
    struct Other: Equatable {
        let tab: Tab.ID
        let tune: Tune
    }

    /// What the band shows. Nil while it is down.
    struct Face: Equatable {
        let tab: Tab.ID
        let tune: Tune
        /// The others playing off screen, the one that started last first.
        let others: [Other]
    }

    private(set) var face: Face?
    /// The band's view, told whenever the face changes.
    var onFace: ((Face?) -> Void)?

    /// When each tab last started playing, the newest counting first.
    private var started: [Tab.ID: CFTimeInterval] = [:]
    /// When each paused tab stopped.
    private var stopped: [Tab.ID: CFTimeInterval] = [:]
    /// The island's tab, kept while it counts.
    private var lead: Tab.ID?
    /// A paused source picked on purpose keeps its controls until it plays
    /// again or stops counting. An update from another page must not undo
    /// that choice through the automatic handoff to a playing source.
    private var chosenPaused: Tab.ID?
    private var raising: DispatchWorkItem?
    private var dozing: DispatchWorkItem?
    private var yielding: DispatchWorkItem?

    static let delay: TimeInterval = 0.4
    /// Past the delay, how much longer it waits for its cover, so it comes
    /// up whole rather than with a plate the cover pops into.
    static let coverWait: TimeInterval = 0.6
    /// When the island was first wanted, while it waits to come up.
    private var wanted: CFTimeInterval?
    static let patience: TimeInterval = 5 * 60
    /// A paused lead gives way to one playing after this.
    static let yield: TimeInterval = 3

    init(browser: Browser) {
        self.browser = browser
    }

    /// A tab's tune changed.
    func heard(_ tab: Tab) {
        let now = CACurrentMediaTime()
        if let tune = tab.tune, tune.named {
            if tune.playing {
                if stopped[tab.id] != nil || started[tab.id] == nil { started[tab.id] = now }
                stopped[tab.id] = nil
            } else if stopped[tab.id] == nil {
                stopped[tab.id] = now
            }
        } else {
            started[tab.id] = nil
            stopped[tab.id] = nil
        }
        restage()
    }

    /// What is on screen changed, or the tabs did.
    /// Main-thread time spent here and in the band, ms, for the bench.
    static var cost: Double = 0

    /// Already on screen some other way, and so never the band's: a call,
    /// which has its dot, its window and its own sound, and a page out in
    /// the floating window, video or call, playing where you can see it.
    static func elsewhere(_ tab: Tab) -> Bool { tab.onCall || tab.floating }

    /// The tabs on screen: the one in front, and the other half of its pair.
    private var onScreen: Set<Tab.ID> {
        guard let browser, let active = browser.active else { return [] }
        var shown: Set<Tab.ID> = [active.id]
        shown.formUnion(browser.mates(of: active.id))
        return shown
    }

    /// Every tab that counts and isn't on screen, the newest first.
    private func counting(now: CFTimeInterval) -> [Tab] {
        guard let browser else { return [] }
        let shown = onScreen
        // Every space's tabs: one playing in a space you left still plays,
        // and the island stays.
        return browser.everyTab
            .filter { tab in
                guard let tune = tab.tune, tune.named, !tune.shortSound, started[tab.id] != nil, !shown.contains(tab.id),
                      !Player.elsewhere(tab) else { return false }
                return tune.playing || now - (stopped[tab.id] ?? now) < Player.patience
            }
            .sorted { (started[$0.id] ?? 0) > (started[$1.id] ?? 0) }
    }

    func restage(immediate: Bool = false) {
        let t0 = CACurrentMediaTime()
        defer { Player.cost += (CACurrentMediaTime() - t0) * 1000 }
        guard let browser else { return }
        let now = CACurrentMediaTime()
        let alive = Set(browser.everyTab.map(\.id))
        started = started.filter { alive.contains($0.key) }
        stopped = stopped.filter { alive.contains($0.key) }

        let candidates = counting(now: now)
        if let chosenPaused, !candidates.contains(where: { $0.id == chosenPaused && $0.tune?.playing == false }) {
            self.chosenPaused = nil
        }
        var top = candidates.first { $0.id == lead } ?? candidates.first
        // A lead paused a while gives way to the newest one playing; until
        // then, look again when its time is up.
        yielding?.cancel()
        yielding = nil
        if let held = top, held.id != chosenPaused, held.tune?.playing == false, let since = stopped[held.id],
           let playing = candidates.first(where: { $0.id != held.id && $0.tune?.playing == true }) {
            if now - since >= Player.yield {
                top = playing
            } else {
                let item = DispatchWorkItem { [weak self] in self?.restage() }
                yielding = item
                DispatchQueue.main.asyncAfter(deadline: .now() + since + Player.yield - now + 0.02, execute: item)
            }
        }
        // Up only for what is heard: a tab paused before it was left, or a
        // feed's muted video that never made a sound, doesn't bring the
        // island up when the tab is left (#454), as Arc's controls come
        // only for audible playback. Once up, a paused lead stays.
        if face == nil, top?.tune?.playing != true {
            top = candidates.first { $0.tune?.playing == true }
        }
        lead = top?.id
        let next = top.map { top in
            Face(tab: top.id, tune: top.tune!,
                 others: candidates.filter { $0.id != top.id }.map { Other(tab: $0.id, tune: $0.tune!) })
        }
        // The island's own tab come on screen, its title or the way back
        // clicked, Show Tab, the tab picked in the column: the island goes
        // down with it, and what else plays comes up after the usual beat,
        // an island of its own, never slid in under the pointer as a swap
        // nobody asked for.
        if let face, let next, next.tab != face.tab,
           let was = browser.everyTab.first(where: { $0.id == face.tab }),
           onScreen.contains(was.id) || Player.elsewhere(was) {
            set(nil)
        }

        // Asleep only once everything counting is paused: the earliest a
        // paused one runs out of patience, look again.
        dozing?.cancel()
        if let soonest = candidates.compactMap({ stopped[$0.id] }).min() {
            let item = DispatchWorkItem { [weak self] in self?.restage() }
            dozing = item
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0.5, soonest + Player.patience - now + 0.05), execute: item)
        }

        if next == nil {
            raising?.cancel()
            raising = nil
            wanted = nil
            set(nil)
        } else if face == nil, !immediate, let next {
            // Up after the delay, and only if still wanted then; with its
            // cover, or once that has had a moment more to come.
            let since = wanted ?? now
            wanted = since
            let waited = now - since
            if waited >= Player.delay, next.tune.cover != nil || waited >= Player.delay + Player.coverWait {
                raising?.cancel()
                raising = nil
                wanted = nil
                set(next)
            } else if raising == nil {
                let item = DispatchWorkItem { [weak self] in
                    self?.raising = nil
                    self?.restage()
                }
                raising = item
                let at = waited < Player.delay ? Player.delay : Player.delay + Player.coverWait
                DispatchQueue.main.asyncAfter(deadline: .now() + at - waited + 0.01, execute: item)
            }
        } else {
            raising?.cancel()
            raising = nil
            wanted = nil
            set(next)
        }
    }

    private func set(_ next: Face?) {
        guard next != face else { return }
        let fresh = next?.tab != face?.tab
        face = next
        // A live stream coming up: how far behind its edge it is now,
        // after whatever was done in its tab.
        if fresh, next?.tune.live == true { tab?.tuneWatch.look() }
        onFace?(next)
    }

    // MARK: - what the band asks for

    var tab: Tab? { face.flatMap { id in browser?.everyTab.first { $0.id == id.tab } } }

    func toggle() {
        guard let tab, let tune = tab.tune else { return }
        tab.tuneWatch.want(playing: !tune.playing)
    }

    func skip(forward: Bool) { tab?.tuneWatch.skip(forward: forward) }

    /// The island's page read again: its place, its length, whether it
    /// loops (TuneWatch.look).
    func reread() {
        guard let tab, tab.tune?.live == false else { return }
        tab.tuneWatch.look()
    }

    /// A live stream played behind its edge, back to it.
    func goLive() { tab?.tuneWatch.goLive() }

    /// The island's line held at a point, nought to one: roughly while the
    /// finger is down, exactly where it lets go (TuneWatch.seek).
    func seek(_ fraction: Double, rough: Bool) { tab?.tuneWatch.seek(to: fraction, rough: rough) }

    /// 15 seconds back or on, from the island's buttons beside play.
    func jump(_ seconds: Double) { tab?.tuneWatch.jump(by: seconds) }

    /// The band's tab, muted or heard again.
    func mute() {
        guard let tab else { return }
        tab.mute(!tab.muted)
    }

    /// Every tab the band could show, the island's first, then its buds.
    func all() -> [Tab] {
        guard let browser, let face else { return [] }
        let ids = [face.tab] + face.others.map(\.tab)
        return ids.compactMap { id in browser.everyTab.first { $0.id == id } }
    }

    /// One of them played or paused.
    func toggle(_ id: Tab.ID) {
        guard let tab = browser?.everyTab.first(where: { $0.id == id }), let tune = tab.tune else { return }
        tab.tuneWatch.want(playing: !tune.playing)
    }

    /// Pause All: every one playing, paused where it is.
    func pauseAll() {
        for tab in all() where tab.tune?.playing == true { tab.tuneWatch.want(playing: false) }
    }

    /// Its video out in the little window, from the island's menu, without
    /// going to its tab first.
    func float() {
        guard let tab, let browser else { return }
        browser.float(tab)
    }

    func go() {
        guard let tab, let browser else { return }
        // In a space you left: that space first, then the tab in it.
        if !browser.tabs.contains(where: { $0.id == tab.id }), let space = browser.spaceHolding(tab.id) {
            browser.switchSpace(to: space)
        }
        browser.select(tab)
    }

    /// A bud tapped: it becomes the island, and the island its bud.
    func promote(_ id: Tab.ID) {
        guard let other = face?.others.first(where: { $0.tab == id }) else { return }
        lead = id
        chosenPaused = other.tune.playing ? nil : id
        restage(immediate: true)
    }

    /// A swipe on the island: forward, the first bud; back, the last.
    func cycle(_ step: Int) {
        guard let others = face?.others, !others.isEmpty else { return }
        promote(step > 0 ? others[0].tab : others[others.count - 1].tab)
    }

    // MARK: - for the bench

    /// Test runs only: the first `count` tabs other than the one in front
    /// play made-up tunes, each started a beat after the last.
    func pretend(_ count: Int) {
        guard Store.testing, let browser else { return }
        let names: [(String, String, NSColor, NSColor)] = [
            ("Paper Lanterns", "Maren Holt", NSColor(srgbRed: 0.85, green: 0.35, blue: 0.17, alpha: 1), NSColor(srgbRed: 0.95, green: 0.65, blue: 0.29, alpha: 1)),
            ("Night Swim", "Lumen Kid", NSColor(srgbRed: 0.23, green: 0.13, blue: 0.72, alpha: 1), NSColor(srgbRed: 0.54, green: 0.42, blue: 1, alpha: 1)),
            ("Low Tide", "Harbor Club", NSColor(srgbRed: 0.11, green: 0.31, blue: 0.54, alpha: 1), NSColor(srgbRed: 0.31, green: 0.62, blue: 0.88, alpha: 1)),
            ("Cedar and Salt", "The Lindens", NSColor(srgbRed: 0.09, green: 0.39, blue: 0.31, alpha: 1), NSColor(srgbRed: 0.31, green: 0.66, blue: 0.51, alpha: 1)),
        ]
        let tabs = browser.tabs.filter { $0.id != browser.activeID }.prefix(count)
        for (i, tab) in tabs.enumerated() {
            let (title, artist, a, b) = names[i % names.count]
            var tune = Tune(title: title, artist: artist, duration: 200 + Double(i) * 23, elapsed: 40 + Double(i) * 9,
                            stamp: CACurrentMediaTime(), playing: true, next: true, previous: true)
            tune.accent = b
            tune.cover = Player.madeCover(a, b)
            tab.tune = tune
            started[tab.id] = CACurrentMediaTime() + Double(i) * 0.001
            stopped[tab.id] = nil
        }
        restage(immediate: true)
    }

    /// Test runs only: what the band's island plays now changes, as a site
    /// skipping would.
    func pretendNext(forward: Bool = true) {
        guard Store.testing, let tab, var tune = tab.tune else { return }
        let titles = [("Cedar and Salt", "The Lindens"), ("Low Tide", "Harbor Club"), ("Paper Lanterns", "Maren Holt"), ("Night Swim", "Lumen Kid")]
        let at = titles.firstIndex { $0.0 == tune.title } ?? 0
        let (title, artist) = titles[(at + (forward ? 1 : titles.count - 1)) % titles.count]
        tune.title = title
        tune.artist = artist
        tune.elapsed = 0
        tune.stamp = CACurrentMediaTime()
        let hue = CGFloat(title.count % 7) / 7
        tune.accent = NSColor(hue: hue, saturation: 0.55, brightness: 0.8, alpha: 1)
        tune.cover = Player.madeCover(NSColor(hue: hue, saturation: 0.7, brightness: 0.55, alpha: 1), NSColor(hue: hue, saturation: 0.45, brightness: 0.9, alpha: 1))
        tab.tune = tune
        heard(tab)
    }

    /// Test runs only: the island's tune made a live stream that keeps two
    /// hours, `behind` seconds behind its edge.
    func pretendLive(behind: Double) {
        guard Store.testing, let tab, var tune = tab.tune else { return }
        tune.live = true
        tune.duration = 0
        tune.behind = behind
        tune.span = 7200
        tune.elapsed = 46_864
        tune.stamp = CACurrentMediaTime()
        tab.tune = tune
        heard(tab)
    }

    /// Test runs only: the island's live stream as it can be besides
    /// playing: `ad` (an advert inside it, muted), `catching` (waiting at
    /// its edge), `paused`, `ended` (over, a recording 25:12 long), `radio`
    /// (keeping nothing to go back into), `plain` (none of those).
    func pretendLiveState(_ what: String) {
        guard Store.testing, let tab, var tune = tab.tune else { return }
        tune.elapsed = tune.position()
        tune.stamp = CACurrentMediaTime()
        switch what {
        case "ad": tune.ad = true; tune.quiet = true
        case "catching": tune.catching = true; tune.behind = 0
        case "paused": tune.playing = false
        case "ended":
            tune.live = false
            tune.ad = false
            tune.catching = false
            tune.duration = 3600
            tune.elapsed = 3600 - 1512
        case "radio": tune.span = 0; tune.behind = 0
        default: tune.ad = false; tune.catching = false; tune.playing = true
        }
        tab.tune = tune
        heard(tab)
    }

    /// Test runs only: a tab stops counting, as if closed.
    func pretendGone(_ index: Int) {
        guard Store.testing, let face, let browser else { return }
        let ids = [face.tab] + face.others.map(\.tab)
        guard index < ids.count, let tab = browser.everyTab.first(where: { $0.id == ids[index] }) else { return }
        tab.tune = nil
        heard(tab)
    }

    /// Test runs only: the island's tune paused or played, as the site would.
    func pretendToggle() {
        guard Store.testing, let tab, var tune = tab.tune else { return }
        tune.elapsed = tune.position()
        tune.stamp = CACurrentMediaTime()
        tune.playing.toggle()
        tab.tune = tune
        heard(tab)
    }

    static func madeCover(_ a: NSColor, _ b: NSColor) -> CGImage? {
        let px = 112
        guard let context = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [a.cgColor, b.cgColor] as CFArray, locations: [0, 1])
        else { return nil }
        let side = CGFloat(px)
        context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: side), end: CGPoint(x: side, y: 0), options: [])
        context.setFillColor(NSColor.white.withAlphaComponent(0.55).cgColor)
        context.fillEllipse(in: CGRect(x: side * 0.4, y: side * 0.36, width: side * 0.48, height: side * 0.48))
        context.setFillColor(a.withAlphaComponent(0.6).cgColor)
        context.fillEllipse(in: CGRect(x: -side * 0.08, y: -side * 0.12, width: side * 0.72, height: side * 0.72))
        return context.makeImage()
    }
}

/// The room kept for the band under the rows: the one thing SwiftUI hears
/// about the band, and only when it comes up or goes.
@MainActor
final class PlayerRoom: ObservableObject {
    @Published var up = false
}
