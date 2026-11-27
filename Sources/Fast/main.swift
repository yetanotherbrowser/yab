import AppKit
import SyncKit

// One binary, several doors. With no word after it, the browser. With `mcp`,
// a Model Context Protocol server on stdin and stdout, for Claude Code,
// Codex or anything else that speaks it, a thin translator onto the
// bench's socket, never touching AppKit. With `agent`, the same from a
// terminal: a task handed to an agent the running browser starts, its steps
// printed as they happen, and with any other word, `yab` as Cli.swift
// reads it: a task, a page, the guide, sessions, memory, setup. `browse` is
// what a signing-in agent CLI calls for its browser (see Agents.login).
//
// The browser is what almost every launch is, so it is the default and the
// others cost it one comparison.

// CEF's native messaging launcher must remain a stdio-only browser process.
// Enter before LaunchCopy, settings, dates, CLI dispatch or AppKit startup.
if CommandLine.arguments.dropFirst().first == ChromiumNativeHostLauncher.flag {
    exit(ChromiumNativeHostLauncher.run(Array(CommandLine.arguments.dropFirst(2))))
}

// The app this was started from still there, and its bundle read while it
// is, before anything else asks for it (LaunchCopy).
LaunchCopy.ensure()

// Retire the old date locale override before native input services start.
EnglishDates.apply()

let launchWords = Array(CommandLine.arguments.dropFirst())
switch launchWords.first {
case "mcp":
    // An agent's server lives for hours, and an update can move the app
    // away under it: which settings and world it uses is settled now,
    // while the app is whole, not at initialize.
    _ = Store.settings
    Mcp.serve(Array(launchWords.dropFirst()))
case "browse":
    AgentCLI.browse(Array(launchWords.dropFirst()))
case let first where Cli.wants(first) || ProcessInfo.processInfo.environment["YAB_CLI"] == "1":
    Cli.run(launchWords)
default:
    LaunchArrivalPreview.prepareProcess()
    // A test run never reopens the windows macOS kept for the app, nor asks
    // to: that record is one per bundle id, shared by every dev build and
    // test world on a Mac, not one per world. Three probe runs that crashed
    // in their first seconds (0.46.24's bench probe, m2, 2026-11-05) left
    // AppKit asking "reopen its windows?" at every later launch of any tree
    // there, a question nobody saw, and no browser window ever came. In the
    // registration domain: nothing is written to the app's own settings.
    if Store.testing {
        UserDefaults.standard.register(defaults: ["ApplePersistenceIgnoreState": true, "NSQuitAlwaysKeepsWindows": false])
    }
    // No window server to join (an agent's sandbox, ssh): a line, not an
    // abort in AppKit. Dash words AppKit doesn't know still come here, as
    // NSUserDefaults reads `-Key value` from the command line.
    if NoScreen.here { NoScreen.leave() }
    // A launch to be profiled from its first line (evals/stand/startup.py
    // --sample): stopped here until `sample` is attached and sends SIGCONT.
    if ProcessInfo.processInfo.environment["YAB_LAUNCH_STOP"] == "1" { raise(SIGSTOP) }
    // A write to a socket or pipe whose other end has gone fails, and
    // nothing more: an agent's `yab mcp` killed in the middle of a call
    // took the whole browser down with SIGPIPE (exit 141), SO_NOSIGPIPE on
    // the bench's sockets notwithstanding.
    signal(SIGPIPE, SIG_IGN)
    // A Mac app opens with room for 256 files, and a long day of pages,
    // extensions and agents ran out of it: Core Animation could not open
    // its Metal library and took the browser down, and Pipe() handed back
    // a nil handle. OPEN_MAX is the most macOS takes for the soft limit.
    var files = rlimit()
    if getrlimit(RLIMIT_NOFILE, &files) == 0, files.rlim_cur < min(rlim_t(OPEN_MAX), files.rlim_max) {
        files.rlim_cur = min(rlim_t(OPEN_MAX), files.rlim_max)
        setrlimit(RLIMIT_NOFILE, &files)
    }
    // One browser on one set of files, before it touches any of them,
    // moved first from the name they had before (Store.folder).
    Store.movesOldFolder = true
    LaunchJournal.record("browser.entry")
    LaunchWarm.start()
    OneYab.take()
    MainActor.assumeIsolated {
        OneYab.listen()
        CrashSessions.start()
        CursorUpdateGuard.install()
        ScrollWheelGuard.install()
        _ = AppleWritingTools.shared
        _ = NativeTextSearch.shared
        YabApp.main()
    }
}
