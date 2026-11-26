#include <string_view>
#include "core.h"
#include "launch_trace.h"
#include "core_lifetime.h"
#include "clone_sweep.h"
#include "original_caller.h"
#include <limits.h>
#include <stdlib.h>
#include <errno.h>
#include <ApplicationServices/ApplicationServices.h>
#include <objc/runtime.h>
#include "include/cef_application_mac.h"
#include "include/cef_browser.h"
#include "include/cef_command_line.h"
#include "include/wrapper/cef_helpers.h"
#include "include/wrapper/cef_library_loader.h"
@interface YabCoreApplication : NSApplication <CefAppProtocol>
@property(nonatomic) BOOL handlingSendEvent;
@end
// Yab is the app a person uses: this process draws its pages into windows
// at no alpha that nobody presses, and Yab shows them. If this process is
// the active app while Yab's window looks in front, the keyboard's app, the
// Edit menu's Cmd+V and Accessibility's focused application are this one,
// with no Edit menu and no key window (R2565: dictation apps paste nothing
// until a restart). Chromium asks to activate its app to show a widget
// (NativeWidgetNSWindowBridge's kShowAndActivateWindow, mouse capture), and
// a click on one of the few windows it does show (Chrome's own save panel,
// a menu an extension's popup opens) activates it, and it stayed active
// after them. Now it activates only for such a window, and once none is up
// activation goes back to Yab, as an app shim's helper never keeps it.
static bool Concealed(NSWindow* window) { return window.alphaValue <= 0 || window.ignoresMouseEvents; }
static bool ShowsOwnWindow() {
  for (NSWindow* window in NSApp.windows) {
    if ([window isKindOfClass:NSSavePanel.class]) return true;
    if (window.isVisible && !Concealed(window)) return true;
  }
  return false;
}
static void HandActivationBack(const char* why) {
  const bool trace = getenv("YAB_PROBE") && *getenv("YAB_PROBE");
  if (!NSApp.isActive || ShowsOwnWindow()) {
    if (trace && NSApp.isActive) fprintf(stderr, "YabCore activation stays: %s, a window of its own is up\n", why);
    return;
  }
  if (trace) fprintf(stderr, "YabCore activation back to Yab: %s\n", why);
  NSRunningApplication* owner = [NSRunningApplication runningApplicationWithProcessIdentifier:getppid()];
  if (!owner || owner.terminated) { [NSApp deactivate]; return; }
  if (@available(macOS 14.0, *)) [NSApp yieldActivationToApplication:owner];
  [owner activateWithOptions:0];
}
static void HandActivationBackSoon(const char* why) {
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 150 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ HandActivationBack(why); });
}
@implementation YabCoreApplication
- (BOOL)isHandlingSendEvent { return self.handlingSendEvent; }
- (void)activateIgnoringOtherApps:(BOOL)flag {
  if (ShowsOwnWindow()) [super activateIgnoringOtherApps:flag];
  else if (getenv("YAB_PROBE") && *getenv("YAB_PROBE")) fprintf(stderr, "YabCore activation refused: activateIgnoringOtherApps\n");
}
- (void)activate {
  if (ShowsOwnWindow()) [super activate];
  else if (getenv("YAB_PROBE") && *getenv("YAB_PROBE")) fprintf(stderr, "YabCore activation refused: activate\n");
}
- (void)sendEvent:(NSEvent*)event { CefScopedSendingEvent scope; [super sendEvent:event]; }
- (void)terminate:(id)sender { yc::Shutdown(); }
// Assistive apps' focus queries arrive here from Yab's page view.
- (id)accessibilityFocusedUIElement { return yc::AccessibilityFocusedElement() ?: [super accessibilityFocusedUIElement]; }
@end
#include "application_navigation.inc"
#include "apple_events.inc"
// Chromium shows each page's window with makeKeyAndOrderFront:, so a hidden
// page window was this process's key window and its focused field made this
// the focused application to Accessibility while Yab was in front. Window
// managers (Magnet) then moved the hidden window, and the page slid inside
// Yab's (#816). A concealed window is never key.
static IMP cefCanBecomeKeyOriginal = nullptr;
static BOOL CefCanBecomeKey(NSWindow* self, SEL command) {
  if (Concealed(self)) return NO;
  return ((BOOL (*)(NSWindow*, SEL))cefCanBecomeKeyOriginal)(self, command);
}
static void KeepHiddenWindowsFromKey() {
  Class window = NSClassFromString(@"CefNSWindow");
  Method method = window ? class_getInstanceMethod(window, @selector(canBecomeKeyWindow)) : nullptr;
  if (!method) return;
  cefCanBecomeKeyOriginal = method_getImplementation(method);
  class_replaceMethod(window, @selector(canBecomeKeyWindow), (IMP)CefCanBecomeKey, method_getTypeEncoding(method));
}
static void Mark(const char* step) {
  if (getenv("YAB_CEF_TRACE_TIMING")) fprintf(stderr, "YabCore T %.1f %s\n", NSDate.date.timeIntervalSince1970 * 1000, step);
}
int main(int argc, char* argv[]) {
  @autoreleasepool {
    // Native windows belong to Yab; an idle, windowless engine still owns
    // live pages. Keep these opt-outs for the process lifetime, including
    // if AppKit/CEF enables termination support later during startup.
    // OwnerWatch and explicit shutdown, not window visibility, end its work.
    [NSProcessInfo.processInfo disableAutomaticTermination:@"Yab engine"];
    [NSProcessInfo.processInfo disableSuddenTermination];
  }
  // The assembled host's own plist declares LSUIElement. Keep the early
  // role setup for standalone/legacy diagnostic launches too; it does not
  // change or substitute the nested bundle's independent identity.
  ProcessSerialNumber process = {0, kCurrentProcess};
  const OSStatus role = TransformProcessType(&process, kProcessTransformToUIElementApplication);
  if (role != noErr) fprintf(stderr, "YabCore background role: %d\n", static_cast<int>(role));
  Mark("main");
  yc::OwnerWatch owner;
  if (!owner.Start()) { fprintf(stderr, "YabCore client is unavailable\n"); return 2; }
  @autoreleasepool {
    bool observeOriginalCaller = false, deadlineOriginalCaller = false;
    for (int i = 1; i < argc; ++i) {
      if (std::string_view(argv[i]) == "--observe-original-caller") observeOriginalCaller = true;
      if (std::string_view(argv[i]) == "--original-caller-deadline-gate") deadlineOriginalCaller = true;
    }
    yc::original_caller::CaptureBeforeCEF(STDIN_FILENO, observeOriginalCaller, deadlineOriginalCaller);
  }
  // Copies of this app Chromium made for a YabCore before and never deleted
  // (clone_sweep.h): off the main thread, as Chromium makes this one's.
  if (NSString* bundleID = NSBundle.mainBundle.bundleIdentifier) {
    std::string id(bundleID.UTF8String);
    pid_t me = getpid();
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
      if (int gone = yc::clones::Sweep(id, me)) fprintf(stderr, "YabCore: removed %d copies of the app left by earlier runs\n", gone);
    });
  }
  CefScopedLibraryLoader loader;
  if (!loader.LoadInMain()) return 1;
  @autoreleasepool {
    [YabCoreApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    KeepHiddenWindowsFromKey();
    NSNotificationCenter* center = NSNotificationCenter.defaultCenter;
    [center addObserverForName:NSApplicationDidBecomeActiveNotification object:NSApp queue:NSOperationQueue.mainQueue
                    usingBlock:^(NSNotification*) { HandActivationBack("became active"); }];
    // A panel or menu of its own that kept it active has gone.
    for (NSNotificationName name in @[NSWindowWillCloseNotification, NSWindowDidResignKeyNotification, NSMenuDidEndTrackingNotification])
      [center addObserverForName:name object:nil queue:NSOperationQueue.mainQueue
                      usingBlock:^(NSNotification*) { if (NSApp.isActive) HandActivationBackSoon("its window went"); }];
    // And whatever else left it active (a widget concealed after it showed).
    static dispatch_source_t watch = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(watch, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), NSEC_PER_SEC, NSEC_PER_SEC / 2);
    dispatch_source_set_event_handler(watch, ^{ if (NSApp.isActive) HandActivationBack("still active"); });
    dispatch_resume(watch);
    // AppleScript sent to Yab that lands here goes on to Yab (apple_events.inc).
    [center addObserverForName:NSApplicationDidFinishLaunchingNotification object:NSApp queue:NSOperationQueue.mainQueue
                    usingBlock:^(NSNotification*) { dispatch_async(dispatch_get_main_queue(), ^{ [YabCoreScriptingRelay install]; }); }];
    auto command = CefCommandLine::CreateCommandLine(); command->InitFromArgv(argc, argv);
    NSString* root = @(command->GetSwitchValue("data-root").ToString().c_str());
    NSString* socket = @(command->GetSwitchValue("socket").ToString().c_str());
    if (!root.isAbsolutePath || !socket.isAbsolutePath) {
      fprintf(stderr, "YabCore requires absolute --data-root and --socket paths\n"); return 2;
    }
    // The owner supplies Safe Storage before profile services start. An old
    // SDK must not silently ignore the broker switch and read Keychain itself.
    if (!command->HasSwitch("use-mock-keychain")) {
#if defined(CEF_YAB_SAFE_STORAGE_BROKER_VERSION) && CEF_YAB_SAFE_STORAGE_BROKER_VERSION == 1
      if (command->GetSwitchValue("yab-safe-storage-socket").empty()) {
        fprintf(stderr, "YabCore requires its owner's Safe Storage launch channel\n"); return 2;
      }
#else
      fprintf(stderr, "YabCore requires a Safe Storage broker-capable CEF SDK\n"); return 2;
#endif
    }
    NSError* directoryError = nil;
    if (![NSFileManager.defaultManager createDirectoryAtPath:root withIntermediateDirectories:YES
          attributes:@{NSFilePosixPermissions: @0700} error:&directoryError]) {
      fprintf(stderr, "Cannot create YabCore data root: %s\n", directoryError.localizedDescription.UTF8String); return 2;
    }
    // Chromium canonicalizes --user-data-dir. Match it for request contexts,
    // including macOS's /tmp -> /private/tmp symlink.
    char canonicalRoot[PATH_MAX];
    if (!realpath(root.fileSystemRepresentation, canonicalRoot)) {
      fprintf(stderr, "Cannot resolve YabCore data root: %s\n", strerror(errno)); return 2;
    }
    root = @(canonicalRoot);
    yc::TraceLaunch(root, @"core.entry");
    // After a helper crash Chrome offers "Restore pages?" from a window Yab
    // never shows; building that bubble has also killed the helper again.
    // Yab restores its own tabs, so every profile starts as if it exited
    // cleanly. Only the exit type changes; a malformed file is left alone.
    NSDirectoryEnumerator* walk = [NSFileManager.defaultManager enumeratorAtPath:root];
    for (NSString* name in walk) {
      if (walk.level >= 3) { [walk skipDescendants]; continue; }
      if (![name.lastPathComponent isEqualToString:@"Preferences"]) continue;
      NSString* path = [root stringByAppendingPathComponent:name];
      NSData* data = [NSData dataWithContentsOfFile:path];
      id prefs = data ? [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:nil] : nil;
      if (![prefs isKindOfClass:NSMutableDictionary.class]) continue;
      NSMutableDictionary* profile = prefs[@"profile"];
      if (![profile isKindOfClass:NSMutableDictionary.class] || [profile[@"exit_type"] isEqual:@"Normal"]) continue;
      profile[@"exit_type"] = @"Normal";
      profile[@"exited_cleanly"] = @YES;
      NSData* written = [NSJSONSerialization dataWithJSONObject:prefs options:0 error:nil];
      if (written) [written writeToFile:path atomically:YES];
    }
    // Chrome's global profile first of all: its services start with the browser.
    for (NSString* name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:root error:nil]) {
      if (![name hasPrefix:@"space-"]) continue;
      NSString* space = [root stringByAppendingPathComponent:name];
      yc::SeedPreferences([space stringByAppendingPathComponent:@"Preferences"]);
      // Chrome's own record of open tabs, addresses included. Yab restores its
      // tabs itself and nothing ever reads this, so no run outlives the next.
      for (NSString* kept in @[@"Sessions", @"Sessions_Encrypted"])
        [NSFileManager.defaultManager removeItemAtPath:[space stringByAppendingPathComponent:kept] error:nil];
    }
    yc::SeedPreferences([root stringByAppendingPathComponent:@"Default/Preferences"]);
    // Page-use signals, addresses included, for Chrome features Yab has none of:
    // turned off they trap in the Settings page, so they last one run instead.
    [NSFileManager.defaultManager removeItemAtPath:[root stringByAppendingPathComponent:@"segmentation_platform"] error:nil];
    CefSettings settings;
    // Supplied by the owning app, whose AppleLanguages domain differs from
    // this helper's. Set both: extension message catalogs use the UI locale,
    // while navigator.languages and HTTP use the accept-language preference.
    CefString(&settings.locale) = command->GetSwitchValue("lang");
    CefString(&settings.accept_language_list) = command->GetSwitchValue("accept-lang");
    // The owning app's executable is yab, not YabCore. Do not let CEF
    // derive a nonexistent yab Helper from its top-level Info.plist.
    NSString* bundle = NSBundle.mainBundle.bundlePath;
    NSString* subprocess = [bundle stringByAppendingPathComponent:
      @"Contents/Frameworks/YabCore Helper.app/Contents/MacOS/YabCore Helper"];
    CefString(&settings.browser_subprocess_path) = subprocess.UTF8String;
    // Started from a bundle the updater set aside (yab.app.old), CEF's own
    // lookup, the first path component ending in .app, finds no bundle at
    // all. Say where it is.
    CefString(&settings.main_bundle_path) = bundle.UTF8String;
    CefString(&settings.framework_dir_path) =
      [bundle stringByAppendingPathComponent:@"Contents/Frameworks/Chromium Embedded Framework.framework"].UTF8String;
#if !defined(CEF_USE_SANDBOX)
    settings.no_sandbox = true;
#endif
    // Off. A window a tab opens stays Views-hosted because the tab has a view.
    // On, Document Picture-in-Picture got an empty Views window too, while CEF
    // put its page in Chrome's own Browser: Yab showed the empty one.
    settings.use_views_default_popup = false;
    // Chromium's log writes every page's console and its addresses into
    // chrome_debug.log beside the profile, private windows too. Nothing reads
    // it. A test world asks for its lines with --log-severity.
    settings.log_severity = LOGSEVERITY_DISABLE;
    [NSFileManager.defaultManager removeItemAtPath:[root stringByAppendingPathComponent:@"chrome_debug.log"] error:nil];
    CefString(&settings.root_cache_path) = root.UTF8String;
    CefString(&settings.cache_path) = root.UTF8String;
    auto app = yc::MakeApp(root, socket);
    Mark("cef-initialize");
    if (!CefInitialize(CefMainArgs(argc, argv), settings, app, nullptr)) {
      yc::TraceLaunch(root, @"core.initialize-exit");
      return CefGetExitCode();
    }
    CefRunMessageLoop();
    yc::TraceLaunch(root, @"core.loop-exit");
    // Release all browser references before CefShutdown, including observers.
    yc::TearDown();
    app = nullptr;
    CefShutdown();
  }
  return 0;
}
