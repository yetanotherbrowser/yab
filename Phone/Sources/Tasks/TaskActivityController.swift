import ActivityKit
import CoreGraphics
import Foundation
import UIKit
import os

/// Starts, updates and ends the Live Activity from the task model, here on
/// the iPhone. The activity follows the Now line's task: the most important
/// one, in the same words. It is one activity for all tasks, so a task that
/// comes next takes it over instead of asking for a new one (which iOS allows
/// only while Yab is in front); it stays up while the Mac sleeps ("Waits")
/// and ends only when nothing is left to say, done ones staying on the Lock
/// Screen with their result.
///
/// Until the Mac can push, Yab updates it while it runs. A moving task's
/// stale date lets the Lock Screen say when its words stop being current.
@MainActor
final class TaskActivityController {
    let enabled: Bool
    private var activity: Activity<TaskActivityAttributes>?
    private var last: TaskActivityAttributes.ContentState?
    private let log = Logger(subsystem: "dev.serafim.fast.iphone", category: "activity")
    /// What the activity says now, for tests and the log.
    private(set) var shown: TaskActivityAttributes.ContentState?
    /// A state that wanted an activity while Yab was away: asked for when Yab is back.
    private var waiting = false
    private weak var desk: TaskDesk?
    private var foreground: NSObjectProtocol?

    /// How long a moving task's words stay true without news.
    static let staleAfter: TimeInterval = 90

    /// Off in named states: their pictures draw the activity themselves, and
    /// a real one would outlive the launch.
    init(enabled: Bool) {
        self.enabled = enabled
        guard enabled else { return }
        // A run of the virtual Mac lives one launch: last launch's activities say nothing true now.
        for stale in Activity<TaskActivityAttributes>.activities {
            Task { await stale.end(nil, dismissalPolicy: .immediate) }
        }
        foreground = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cameBack() }
        }
    }

    func sync(_ desk: TaskDesk) {
        self.desk = desk
        let state = TaskActivityContent.state(desk: desk)
        guard state != last || waiting else { return }
        let before = last
        last = state
        shown = state
        guard enabled, ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        guard let state else {
            waiting = false
            if let activity { end(activity, with: nil) }
            activity = nil
            return
        }
        // Done and nothing after it: the result stays on the Lock Screen until
        // the system takes it away; the next task starts a new one.
        if state.status == TaskStatus.done.rawValue {
            waiting = false
            if let activity { end(activity, with: state) }
            activity = nil
            return
        }
        // Needs you: the Island opens and the phone lights, when Yab isn't in front.
        let needs = state.warn && before?.status != state.status
        let alert = needs ? AlertConfiguration(title: "\(state.name)", body: "\(state.title)", sound: .default) : nil
        let content = ActivityContent(state: state, staleDate: Self.staleDate(state))
        if let activity, activity.activityState == .active || activity.activityState == .stale {
            Task { await activity.update(content, alertConfiguration: alert) }
            return
        }
        activity = nil
        guard let app = desk.app else { return }
        request(content, mac: app.macName)
    }

    /// Asks iOS for the activity. In the background iOS says no; it is asked
    /// again when Yab is in front.
    private func request(_ content: ActivityContent<TaskActivityAttributes.ContentState>, mac: String) {
        let attributes = TaskActivityAttributes(mac: mac)
        do {
            let started = try Activity.request(attributes: attributes, content: content, pushType: nil)
            activity = started
            waiting = false
            log.info("live activity started for \(content.state.task, privacy: .public)")
        } catch {
            waiting = UIApplication.shared.applicationState != .active
            log.error("no live activity\(self.waiting ? " until Yab is in front" : "", privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    /// Yab in front again: what wanted an activity while it was away gets one.
    private func cameBack() {
        guard waiting, let desk else { return }
        sync(desk)
    }

    isolated deinit {
        if let foreground { NotificationCenter.default.removeObserver(foreground) }
    }

    /// Yab is about to stop updating it (its background time ends): the
    /// words it shows are marked old now rather than in a while.
    func goesQuiet() {
        guard desk?.app != nil else { return }
        guard let activity, let last, last.status != TaskStatus.done.rawValue else { return }
        let content = ActivityContent(state: last, staleDate: Date())
        Task { await activity.update(content) }
    }

    /// While it moves, its words hold for a while; waiting for the person
    /// or the Mac, they hold until something changes.
    static func staleDate(_ state: TaskActivityAttributes.ContentState) -> Date? {
        switch TaskStatus(rawValue: state.status) {
        case .running?, .sending?, .paying?: Date().addingTimeInterval(staleAfter)
        default: nil
        }
    }

    private func end(_ activity: Activity<TaskActivityAttributes>, with state: TaskActivityAttributes.ContentState?) {
        let content = state.map { ActivityContent(state: $0, staleDate: nil) }
        Task { await activity.end(content, dismissalPolicy: state == nil ? .immediate : .default) }
    }
}

/// What the activity says for the Now line's task, in the prototype's words
/// (laHTML, islandFor): never an amount, never who is paid.
@MainActor
enum TaskActivityContent {
    static func state(desk: TaskDesk) -> TaskActivityAttributes.ContentState? {
        guard let app = desk.app else { return nil }
        let tasks = app.tasks
        guard let run = tasks.top, let def = tasks.definition(run.id) else { return nil }
        let script = desk.virtualMac?.script.script(run.id) ?? MacScript.TaskScript()
        return state(run: run, def: def, code: desk.codes[run.id] ?? script.code, yes: desk.yeses[run.id] ?? script.yes,
                     failure: desk.failures[run.id] ?? script.failure, script: script, refused: desk.refused.contains(run.id),
                     later: desk.later.contains(run.id))
    }

    static func state(run: TaskRun, def: TaskDefinition, code: CodeRequest?, yes: YesRequest?, failure: TaskFailure?,
                      script: MacScript.TaskScript, refused: Bool = false, later: Bool = false) -> TaskActivityAttributes.ContentState? {
        guard !def.steps.isEmpty else { return nil }
        let k = min(max(run.step, 0), def.steps.count - 1)
        let step = def.steps[k]
        var state = TaskActivityAttributes.ContentState(
            task: run.id, name: def.name, status: run.status.rawValue, icon: step.icon, word: step.island, warn: false,
            head: "On your Mac", title: step.run, line: step.sub ?? "Step \(k + 1) of about \(def.steps.count)",
            buttons: [ActivityButton(action: "stop", label: "Stop", style: .plain)])
        switch run.status {
        case .running:
            break
        case .sending:
            state.word = "Sending"
            state.title = "Sending to your Mac"
            state.line = def.ask
        case .code:
            state.warn = true
            state.word = "Code"
            state.head = "Needs you"
            state.title = code?.title ?? def.code ?? "A code needs you"
            state.line = refused ? "That code didn’t work. Enter the newest one."
                : code.map { "Your Mac is signing in to \($0.site)" } ?? "Your Mac is signing in"
            state.buttons = [ActivityButton(action: "code", label: "Enter Code", style: .warn)]
        case .yes:
            state.warn = true
            state.word = "Needs you"
            state.head = "Needs you"
            state.title = yes?.lockTitle ?? "A payment needs you"
            state.line = later ? "Not now. It waits for you in Yab." : yes?.lockLine ?? "The amount shows in Yab after Face ID"
            state.buttons = (later ? [] : [ActivityButton(action: "notNow", label: "Not Now", style: .plain)])
                + [ActivityButton(action: "review", label: "Review", style: .warn)]
        case .paying:
            state.word = "Paying"
            state.title = def.paying ?? "Pressing the site’s button"
            state.line = "Signed with Face ID on this \(DeviceWord.name)"
            state.buttons = []
        case .failed:
            state.warn = true
            state.word = "Failed"
            state.head = "Stopped"
            state.title = failure?.lockTitle ?? "It stopped"
            state.line = failure?.lockLine ?? "Retry from Yab."
            state.buttons = [ActivityButton(action: "retry", label: "Retry", style: .plain)]
        case .done:
            state.icon = def.icon
            state.word = "Done"
            state.head = "Done"
            state.title = script.doneTitle ?? def.result
            state.line = script.doneLine ?? ""
            state.buttons = []
        case .waits:
            // Nothing moves while the Mac sleeps, and nothing is lost: the
            // Island says Waits, gray, and the task goes on when it wakes.
            state.icon = def.icon
            state.word = "Waits"
            state.head = "Waits"
            state.title = "Waits for your Mac"
            state.line = run.asleepSince.map { "Asleep since \($0). It starts when the Mac wakes." } ?? "It starts when the Mac answers."
        case .stopped:
            // Stopped by the person: nothing left to say.
            return nil
        }
        return state
    }
}

/// Where the Lock Screen's buttons stand, in screen points: a sheet opened
/// from one grows out of it. The card is 12 from the sides and 118 over the
/// bottom; its buttons sit at its right, 16 in, 34 high (out.5).
enum TaskActivityLayout {
    /// The prototype's measured widths of the words on their capsules.
    private static let widths: [String: CGFloat] = ["code": 106, "review": 82.5, "notNow": 92.9, "retry": 70, "stop": 65.3]

    static func buttonRect(action: String?, screen: CGSize) -> CGRect? {
        guard let action, let width = widths[action] else { return nil }
        let right = screen.width - Metrics.Edge.bar - ActivityLook.padding.trailing
        let bottom = screen.height - Metrics.LiveActivity.bottom - ActivityLook.padding.bottom
        return CGRect(x: right - width, y: bottom - ActivityLook.button, width: width, height: ActivityLook.button)
    }
}
