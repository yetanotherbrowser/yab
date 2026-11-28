#pragma once
#include <unistd.h>
#include <map>
#include <string>
#include "include/cef_app.h"
#include "include/cef_browser.h"
#include "include/cef_process_message.h"
#include "include/cef_v8.h"
#include "extension_options_renderer.h"

// The renderer reports its own OS identity through CEF's authenticated IPC,
// never through page JavaScript or a guessed process-list association.
//
// It also watches each frame's media for the tab's sound and Now Playing
// state (media.inc). The watcher runs in the frame's own world but changes
// nothing a page can see: no prototype is replaced and nothing is added to
// window. It listens in the capture phase for the media elements' own events
// and reads navigator.mediaSession when they fire. Its report function is a
// native closure argument, never a global. Media created outside the
// document and WebAudio are invisible to it; with Yab's own CEF the browser's
// native audible state takes precedence (CEF_YAB_AUDIBLE_VERSION).
namespace yab_media {
static const char kWatch[] = R"JS((function (sink) {
  'use strict';
  // Taken before any page script runs, so a page that replaces them later
  // neither breaks nor observes this watcher.
  var later = setTimeout.bind(window), every = setInterval.bind(window), stop = clearInterval.bind(window);
  var stringify = JSON.stringify, finite = isFinite, Media = HTMLMediaElement, listen = window.addEventListener.bind(window);
  var tracked = new Set(), timer = 0, ticking = 0, last = '', clock = null;
  function playing(m) { return !m.paused && !m.ended && m.readyState >= 2; }
  function loud(m) {
    if (!playing(m) || m.muted || m.volume === 0) return false;
    // Chromium counts decoded audio; a video without a sound track has none.
    if ('webkitAudioDecodedByteCount' in m && m.webkitAudioDecodedByteCount === 0 && m.currentTime > 1.5) return false;
    return true;
  }
  function primary() {
    var best = null;
    tracked.forEach(function (m) {
      if (!m.isConnected && m.paused) { tracked.delete(m); return; }
      if (playing(m) && (!best || loud(m))) best = m;
    });
    if (!best) tracked.forEach(function (m) { if (!best && m.isConnected) best = m; });
    return best;
  }
  function session() {
    var s = navigator.mediaSession, meta = s && s.metadata;
    if (!meta) return null;
    var art = [];
    try {
      for (var i = 0; i < meta.artwork.length && art.length < 16; i++)
        art.push({ src: String(meta.artwork[i].src || ''), sizes: String(meta.artwork[i].sizes || '') });
    } catch (_) {}
    return { title: String(meta.title || ''), artist: String(meta.artist || ''), album: String(meta.album || ''), artwork: art };
  }
  function report(discrete) {
    timer = 0;
    var any = false, sound = false;
    tracked.forEach(function (m) { if (playing(m)) any = true; if (loud(m)) sound = true; });
    var m = primary();
    if (m && (discrete || !clock || clock.element !== m)) clock = { element: m, t: m.currentTime };
    if (!m) clock = null;
    var s = navigator.mediaSession;
    var state = {
      audible: sound, playing: any, session: session(), sessionState: s ? String(s.playbackState) : 'none',
      media: m ? { t: clock.t, d: finite(m.duration) ? m.duration : -1, paused: m.paused,
        muted: m.muted || m.volume === 0, loop: !!m.loop, video: m.tagName === 'VIDEO' } : null
    };
    var text = stringify(state);
    if (text !== last) { last = text; sink(text); }
    // Decoded audio and a session's metadata can arrive a beat after play.
    if (any && !ticking) ticking = every(function () { report(false); }, 1000);
    else if (!any && ticking) { stop(ticking); ticking = 0; }
  }
  function heard(event) {
    var m = event.target;
    if (!(m instanceof Media)) return;
    tracked.add(m);
    if (!timer) timer = later(function () { report(true); }, 40);
  }
  ['play', 'playing', 'pause', 'ended', 'volumechange', 'emptied', 'loadedmetadata', 'durationchange',
   'seeked', 'ratechange', 'waiting'].forEach(function (name) {
    listen(name, heard, { capture: true, passive: true });
  });
  // Yab's band and keys: the session's own work stays with the page.
  return function (action, value) {
    var m = primary();
    if (action === 'pause') { tracked.forEach(function (e) { if (!e.paused) e.pause(); }); return true; }
    if (!m) return false;
    if (action === 'play') { var p = m.play(); if (p && p.catch) p.catch(function () {}); return true; }
    if (action === 'seekto' && finite(value)) { m.currentTime = Math.max(0, value); return true; }
    return false;
  };
}))JS";

class Sink : public CefV8Handler {
 public:
  bool Execute(const CefString&, CefRefPtr<CefV8Value>, const CefV8ValueList& arguments,
               CefRefPtr<CefV8Value>&, CefString&) override {
    if (arguments.size() != 1 || !arguments[0]->IsString()) return true;
    std::string text = arguments[0]->GetStringValue();
    if (text.size() > 65536) return true;
    auto context = CefV8Context::GetCurrentContext();
    auto frame = context ? context->GetFrame() : nullptr;
    if (!frame || !frame->IsValid()) return true;
    auto message = CefProcessMessage::Create("yab.media.frame");
    message->GetArgumentList()->SetString(0, text);
    frame->SendProcessMessage(PID_BROWSER, message);
    return true;
  }
  IMPLEMENT_REFCOUNTING(Sink);
};
}  // namespace yab_media

class MediaRenderer : public CefApp, public CefRenderProcessHandler {
  struct Watch { CefRefPtr<CefV8Context> context; CefRefPtr<CefV8Value> act; };
  std::map<std::string, Watch> watches_;
 public:
  CefRefPtr<CefRenderProcessHandler> GetRenderProcessHandler() override { return this; }
  void OnContextCreated(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame,
                        CefRefPtr<CefV8Context> context) override {
    // One report and one watcher a document, in the page's own world. Every
    // isolated world makes a context too, and hears the same elements' events.
    auto pageWorld = frame->GetV8Context();
    if (!pageWorld || !pageWorld->IsSame(context)) return;
#if !defined(CEF_YAB_OPTIONS_CREATION_VERSION)
    // The native extension API remains native; route only its missing options
    // creation receipt through tabs.create until the SDK has patch 0056.
    CefRefPtr<CefV8Value> optionsResult;
    CefRefPtr<CefV8Exception> optionsException;
    context->Eval(yab_extension_options::kInstall, frame->GetURL(), 0, optionsResult, optionsException);
#endif
    if (frame->IsMain()) {
      auto message = CefProcessMessage::Create("yab.media.renderer");
      message->GetArgumentList()->SetInt(0, getpid());
      frame->SendProcessMessage(PID_BROWSER, message);
    }
    CefRefPtr<CefV8Value> install;
    CefRefPtr<CefV8Exception> exception;
    auto report = [&](const std::string& why) {
      if (!frame->IsValid()) return;
      auto message = CefProcessMessage::Create("yab.media.error");
      message->GetArgumentList()->SetString(0, why);
      frame->SendProcessMessage(PID_BROWSER, message);
    };
    if (!context->Eval(yab_media::kWatch, "", 0, install, exception) || !install || !install->IsFunction()) {
      report(exception ? "eval: " + exception->GetMessage().ToString() : "eval failed");
      return;
    }
    // CEF's generated wrapper refuses empty function names and returns
    // null before V8 is called. The name is private to this closure.
    auto sink = CefV8Value::CreateFunction("yabMediaReport", new yab_media::Sink);
    if (!sink) { report("could not create media sink"); return; }
    CefV8ValueList arguments{sink};
    auto act = install->ExecuteFunctionWithContext(context, nullptr, arguments);
    if (act && act->IsFunction()) watches_[frame->GetIdentifier().ToString()] = {context, act};
    else report(install->HasException() ? "install: " + install->GetException()->GetMessage().ToString() +
                                          " line " + std::to_string(install->GetException()->GetLineNumber())
                                        : act ? "install returned a non-function" : "install returned nothing");
  }
  void OnContextReleased(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame,
                         CefRefPtr<CefV8Context> context) override {
    auto found = watches_.find(frame->GetIdentifier().ToString());
    if (found == watches_.end() || !found->second.context->IsSame(context)) return;
    watches_.erase(found);
    if (!frame->IsValid()) return;
    auto message = CefProcessMessage::Create("yab.media.frame");
    message->GetArgumentList()->SetString(0, "{\"gone\":true}");
    frame->SendProcessMessage(PID_BROWSER, message);
  }
  bool OnProcessMessageReceived(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame, CefProcessId source,
                                CefRefPtr<CefProcessMessage> message) override {
    if (source == PID_BROWSER && message->GetName() == "yab.media.who") {
      if (frame->IsValid() && frame->IsMain()) {
        auto reply = CefProcessMessage::Create("yab.media.renderer");
        reply->GetArgumentList()->SetInt(0, getpid());
        frame->SendProcessMessage(PID_BROWSER, reply);
      }
      return true;
    }
    if (source == PID_BROWSER && message->GetName() == "yab.health.ping") {
      auto args = message->GetArgumentList();
      if (frame->IsValid() && frame->IsMain() && args->GetSize() == 1 && args->GetType(0) == VTYPE_STRING) {
        auto pong = CefProcessMessage::Create("yab.health.pong");
        pong->GetArgumentList()->SetString(0, args->GetString(0));
        pong->GetArgumentList()->SetInt(1, getpid());
        frame->SendProcessMessage(PID_BROWSER, pong);
      }
      return true;
    }
    if (source != PID_BROWSER || message->GetName() != "yab.media.action") return false;
    auto found = watches_.find(frame->GetIdentifier().ToString());
    auto args = message->GetArgumentList();
    if (found == watches_.end() || args->GetSize() != 2 || args->GetType(0) != VTYPE_STRING) return true;
    double value = args->GetType(1) == VTYPE_DOUBLE ? args->GetDouble(1) : 0;
    CefV8ValueList arguments{CefV8Value::CreateString(args->GetString(0)), CefV8Value::CreateDouble(value)};
    found->second.act->ExecuteFunctionWithContext(found->second.context, nullptr, arguments);
    return true;
  }
  IMPLEMENT_REFCOUNTING(MediaRenderer);
};
