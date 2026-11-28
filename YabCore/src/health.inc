// Main-thread native IPC, not script evaluation. Chromium suppresses its
// ordinary hang callback while our persistent CDP controller is attached.
// Only accepted native input starts a challenge; idle pages are not pinged.
static void HealthSignal(Tab* t, bool responsive) {
  if (!t || t->internal || t->rendererPID <= 0 || t->healthUnresponsive == !responsive) return;
  t->healthUnresponsive = !responsive;
  Event(@"page.responsive", t, @{@"responsive": @(responsive), @"rendererPID": @(t->rendererPID)});
}
static void HealthReset(Tab* t, bool answering) {
  if (!t) return;
  bool notify = answering && t->healthUnresponsive && !t->internal && t->rendererPID > 0;
  t->healthToken.clear(); t->healthFrame.clear(); t->healthPID = 0;
  t->healthSent = t->healthUnresponsive = t->healthAgain = false;
  if (notify) Event(@"page.responsive", t, @{@"responsive": @YES, @"rendererPID": @(t->rendererPID)});
}
static void HealthArm(Tab& t) {
  if (t.internal || t.closing || !t.visible || !t.browser || t.rendererPID <= 0 ||
      !t.healthToken.empty() || (t.browser->GetHost()->HasDevTools() || !t.devToolsFront.empty())) return;
  auto frame = t.browser->GetMainFrame();
  if (!frame || !frame->IsValid()) return;
  t.healthToken = Key(NSUUID.UUID.UUIDString);
  t.healthFrame = frame->GetIdentifier().ToString();
  t.healthPID = t.rendererPID;
  // Let the accepted AppKit input reach the renderer first. Consecutive
  // events share one outstanding probe, including while it is unresponsive.
  t.healthSendAt = Now() + 0.1;
  t.healthDeadline = 0;
  t.healthSent = false;
}
static void HealthInput(Tab& t) {
  if (!t.healthToken.empty()) {
    // A pong already in flight predates input accepted after its ping.
    // Keep one challenge, then rearm for that newer input when it answers.
    if (t.healthSent) t.healthAgain = true;
    return;
  }
  HealthArm(t);
}
static void HealthPoll(Tab& t) {
  if (t.healthToken.empty()) return;
  if (t.closing || !t.browser || t.rendererPID != t.healthPID ||
      (t.browser->GetHost()->HasDevTools() || !t.devToolsFront.empty())) { HealthReset(&t, true); return; }
  auto frame = t.browser->GetMainFrame();
  if (!frame || !frame->IsValid() || frame->GetIdentifier().ToString() != t.healthFrame) {
    HealthReset(&t, true); return;
  }
  if (!t.visible && !t.healthUnresponsive) { HealthReset(&t, false); return; }
  double now = Now();
  if (!t.healthSent && now >= t.healthSendAt) {
    auto message = CefProcessMessage::Create("yab.health.ping");
    message->GetArgumentList()->SetString(0, t.healthToken);
    t.healthSent = true;
    ++t.healthPings;
    t.healthDeadline = now + 3;
    frame->SendProcessMessage(PID_RENDERER, message);
  }
  if (t.healthSent && now >= t.healthDeadline) HealthSignal(&t, false);
}
static bool AdoptRendererPID(Tab* t, pid_t pid) {
  if (!t || pid <= 0) return false;
  struct proc_bsdinfo info = {};
  if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) != sizeof(info) ||
      info.pbi_ppid != getpid()) return false;
  const uint64_t born = info.pbi_start_tvsec * 1000000ULL + info.pbi_start_tvusec;
  // Repeated reports for the same renderer (isolated worlds, navigation probes)
  // must not cancel an active input challenge for that renderer.
  const bool swapped = t->rendererPID != pid || t->rendererBorn != born;
  if (swapped) HealthReset(t, true);
  t->rendererPID = pid;
  t->rendererBorn = born;
#if YABCORE_OWNCEF_SURFACES
  // A new renderer behind the same compositor: say who owns the surface.
  if (swapped) PublishOwnCEFSurface(*t);
#endif
  State(t, @{ @"rendererPID": @(pid), @"nativeDiscard": NativeHookCapabilities()[@"nativeDiscard"],
    @"audible": @(t->audible), @"audibleSource": YABCORE_NATIVE_AUDIBLE ? @"native" : @"page" });
  return true;
}
static bool HealthMessage(Tab* t, CefRefPtr<CefFrame> frame,
                          CefRefPtr<CefProcessMessage> message) {
  if (message->GetName() != "yab.health.pong") return false;
  if (!t || t->closing || !t->browser || !frame || !frame->IsValid() || !frame->IsMain()) return true;
  auto current = t->browser->GetMainFrame();
  if (!current || current->GetIdentifier().ToString() != t->healthFrame) return true;
  auto args = message->GetArgumentList();
  if (args->GetSize() != 2 || args->GetType(0) != VTYPE_STRING || args->GetType(1) != VTYPE_INT ||
      t->healthToken.empty() || args->GetString(0).ToString() != t->healthToken ||
      frame->GetIdentifier().ToString() != t->healthFrame) return true;
  const pid_t pid = args->GetInt(1);
  const bool again = t->healthAgain;
  // A BFCache restore or prerender activation skips OnContextCreated, so an
  // immediate input probe can still hold the previous page's PID. This pong
  // carries the matching token from the live main frame; verify and adopt it.
  if (pid != t->healthPID || t->rendererPID != t->healthPID) {
    if (!AdoptRendererPID(t, pid)) return true;
  }
  ++t->healthPongs;
  // This authenticated pong ran on the current renderer's main thread.
  // Newer input still needs its own challenge, but cannot keep an earlier
  // hang alive across successful replies. Its fresh deadline detects a
  // subsequent stall without treating continued input as continued silence.
  HealthReset(t, true);
  if (again) HealthArm(*t);
  return true;
}
