import CryptoKit
import Foundation
import os

/// A stand-in for the Mac, inside the app: it behaves the way the Mac does
/// in the prototype's chapters "Tasks" and "Mac". It takes a task, walks
/// its steps on a timer (a step every 1.7 s), asks for the site's code and
/// for a yes, checks the yes's signature, presses Pay, finishes; or it
/// sleeps (tasks wait, and go on when it wakes), answers slowly, or breaks
/// once where its script says. The world picks how (MacScript); the real
/// Mac replaces it through sync behind the same TaskBackend.
@MainActor
final class VirtualMac: TaskBackend {
    var onEvent: ((MacEvent) -> Void)?
    private(set) var presence: MacPresence
    private(set) var script: MacScript
    /// What a task is, from the world: its steps and what each needs.
    private let definitions: [TaskDefinition.ID: TaskDefinition]
    /// The iPhone's run of a task the Mac hasn't heard of (a named state, a
    /// world's own runs): the Mac picks it up from there.
    var known: ((TaskRun.ID) -> TaskRun?)?
    /// Still: nothing moves on its own (named states and pictures).
    var still = false

    private var jobs: [TaskRun.ID: Job] = [:]
    private var trusted: P256.Signing.PublicKey?
    private var sleepers: [CheckedContinuation<Void, Never>] = []
    private var wakeTimer: Task<Void, Never>?
    private let log = Logger(subsystem: "dev.serafim.fast.iphone", category: "virtual-mac")

    /// What the Mac did, in its own words, oldest first: "Signed in to
    /// flytap.com with the code from your iPhone". Tests and the log read it.
    private(set) var diary: [String] = []

    init(script: MacScript, definitions: [TaskDefinition]) {
        self.script = script
        self.definitions = Dictionary(definitions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        presence = script.mode == .asleep ? .asleep(since: script.asleepSince) : .awake
        if script.mode == .asleep, let after = script.wakeAfter { wake(after: after) }
    }

    // MARK: - one task on the Mac

    private final class Job {
        let id: TaskRun.ID
        var words: String
        var step: Int
        var phase: Phase = .queued
        var codeGiven = false
        var yesGiven = false
        var brokeOnce = false
        var runner: Task<Void, Never>?
        var answer: CheckedContinuation<Answer?, Never>?

        enum Phase: Equatable {
            case queued, waiting, working, needsCode, needsYes, paying, done, failed, stopped
        }

        init(id: TaskRun.ID, words: String, step: Int) {
            self.id = id
            self.words = words
            self.step = step
        }
    }

    private enum Answer {
        case code(String)
        case yes(SignedYes)
    }

    // MARK: - TaskBackend

    func send(_ order: TaskOrder) {
        if let job = jobs[order.id], job.phase != .done, job.phase != .stopped { return }
        let job = Job(id: order.id, words: order.words, step: order.step)
        jobs[order.id] = job
        note("from \(DeviceWord.name) · \(order.words)")
        start(job)
    }

    func giveCode(_ id: TaskRun.ID, code: String) {
        guard let job = job(id), job.phase != .stopped else { return }
        if let answer = job.answer {
            job.answer = nil
            answer.resume(returning: .code(code))
        } else if job.phase != .done {
            // Given before the Mac asked (a named state's task): kept for when it does.
            job.codeGiven = code == (script.script(id).expectedCode ?? code)
            if job.runner == nil { start(job) }
        }
    }

    func giveYes(_ id: TaskRun.ID, _ yes: SignedYes) {
        guard let job = job(id), job.phase != .stopped else { return }
        if let answer = job.answer {
            job.answer = nil
            answer.resume(returning: .yes(yes))
        } else if job.runner == nil, job.phase != .done {
            // A yes for a task the Mac picked up from a named state: it asks,
            // gets this one, and goes on.
            pendingYes[id] = yes
            start(job)
        }
    }

    private var pendingYes: [TaskRun.ID: SignedYes] = [:]

    func notNow(_ id: TaskRun.ID) {
        note("The yes waits on the \(DeviceWord.name)")
    }

    func retry(_ id: TaskRun.ID) {
        guard let job = job(id), job.phase == .failed || job.phase == .stopped || job.runner == nil else { return }
        note("Again from step \(job.step + 1)")
        job.phase = .working
        start(job)
    }

    func stop(_ id: TaskRun.ID) {
        guard let job = jobs[id] else { return }
        job.runner?.cancel()
        job.runner = nil
        job.answer?.resume(returning: nil)
        job.answer = nil
        job.phase = .stopped
        note("Stopped from the \(DeviceWord.name)")
        emit(.stopped(id))
    }

    func tell(_ id: TaskRun.ID, _ words: String) {
        note("Told: \(words)")
    }

    func trust(_ key: P256.Signing.PublicKey) {
        trusted = key
    }

    func whenAwake() async {
        if presence.awake { return }
        await withCheckedContinuation { sleepers.append($0) }
    }

    /// Everything stops where it is and nothing more is said: the app going
    /// away (and a test done with its Mac).
    func halt() {
        still = true
        wakeTimer?.cancel()
        for job in jobs.values {
            job.runner?.cancel()
            job.runner = nil
            job.answer?.resume(returning: nil)
            job.answer = nil
        }
        onEvent = nil
    }

    // MARK: - asleep and awake

    /// The Mac wakes: what waited goes on by itself.
    func wake() {
        wakeTimer?.cancel()
        wakeTimer = nil
        guard !presence.awake else { return }
        presence = .awake
        note("Awake")
        emit(.presence(presence))
        let waiting = sleepers
        sleepers = []
        waiting.forEach { $0.resume() }
    }

    func wake(after seconds: Double) {
        wakeTimer?.cancel()
        wakeTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.wake()
        }
    }

    /// The Mac falls asleep: tasks not started wait.
    func sleep() {
        guard presence.awake else { return }
        presence = .asleep(since: script.asleepSince)
        emit(.presence(presence))
    }

    func setMode(_ mode: MacScript.Mode) {
        script.mode = mode
        if mode == .asleep { sleep() } else { wake() }
    }

    // MARK: - walking a task

    /// The job for a task, adopting one the iPhone knows and the Mac doesn't
    /// (a named state, a world's own runs).
    private func job(_ id: TaskRun.ID) -> Job? {
        if let job = jobs[id] { return job }
        guard definitions[id] != nil, let run = known?(id) else { return nil }
        let job = Job(id: id, words: definitions[id]?.ask ?? id, step: run.step)
        job.codeGiven = run.codeGiven
        job.yesGiven = run.yesGiven
        switch run.status {
        case .code: job.phase = .needsCode
        case .yes: job.phase = .needsYes
        case .failed:
            job.phase = .failed
            // It broke already; Retry goes on past it.
            job.brokeOnce = true
        case .done: job.phase = .done
        case .stopped: job.phase = .stopped
        case .waits: job.phase = .waiting
        case .sending: job.phase = .queued
        default: job.phase = .working
        }
        jobs[id] = job
        return job
    }

    /// Picks up a run the iPhone already had (a world's own), so it moves on.
    func adopt(_ run: TaskRun) {
        guard jobs[run.id] == nil, run.status != .done, run.status != .failed, run.status != .stopped, let job = job(run.id) else { return }
        start(job)
    }

    private func start(_ job: Job) {
        job.runner?.cancel()
        // Whatever the old run waited for, it waits no more.
        job.answer?.resume(returning: nil)
        job.answer = nil
        job.runner = Task { [weak self] in
            await self?.work(job)
        }
    }

    private var stepPause: Double { script.mode == .slow ? max(script.stepSeconds, script.slowSeconds) : script.stepSeconds }
    private var takePause: Double { script.mode == .slow ? script.slowSeconds : script.takeSeconds }
    private var payPause: Double { script.mode == .slow ? script.slowSeconds : script.paySeconds }

    /// Waits `seconds`, or false when the job was stopped meanwhile.
    private func pause(_ seconds: Double) async -> Bool {
        if seconds > 0 { try? await Task.sleep(for: .seconds(seconds)) }
        return !Task.isCancelled
    }

    private func work(_ job: Job) async {
        guard let def = definitions[job.id] else { return }
        if still { return }
        // Asleep: it waits, said once, and goes on when the Mac wakes.
        guard await awake(job) else { return }
        if job.phase == .queued || job.phase == .waiting {
            guard await pause(takePause) else { return }
            job.phase = .working
            note("Took \(def.name)")
            emit(.taken(job.id))
        }
        // A world's task with no steps has nothing to walk: taken is done.
        guard !def.steps.isEmpty else {
            finish(job, def)
            return
        }
        while !Task.isCancelled {
            // Fell asleep between steps: it waits there, and goes on from the same step.
            if !presence.awake {
                let was = job.phase
                guard await awake(job) else { return }
                emit(.taken(job.id))
                job.phase = was == .waiting ? .working : was
            }
            let k = min(max(job.step, 0), def.steps.count - 1)
            let step = def.steps[k]
            let script = self.script.script(job.id)
            // A code given before the Mac asked for it again: signed in, go on.
            if job.phase == .needsCode, job.codeGiven { job.phase = .working }
            // Waiting for a code or a yes it asked for earlier: ask again below.
            if job.phase != .needsCode, job.phase != .needsYes {
                job.phase = .working
                emit(.step(job.id, k))
                guard await pause(stepPause) else { return }
                // The fail mode: it breaks here once; Retry goes on from this step.
                if self.script.mode == .fail, script.failStep == k, !job.brokeOnce {
                    job.brokeOnce = true
                    job.phase = .failed
                    job.runner = nil
                    let failure = script.failure ?? TaskFailure(line: "Couldn’t go on · \(step.run)", long: "Couldn’t go on: \(step.run)",
                                                                lockTitle: "Couldn’t go on", lockLine: "Retry from Yab.")
                    note(failure.long)
                    emit(.failed(job.id, failure))
                    return
                }
            }
            if step.needs == .code, !job.codeGiven {
                job.phase = .needsCode
                let request = script.code ?? CodeRequest(sender: def.name, icon: step.icon, site: def.name)
                note("Waiting for the code from the \(DeviceWord.name)")
                emit(.needsCode(job.id, request))
                guard case let .code(code)? = await answer(job) else { return }
                if let expected = script.expectedCode, code.filter(\.isNumber) != expected {
                    note("The code didn’t work")
                    emit(.codeRefused(job.id, request))
                    continue // asks again
                }
                job.codeGiven = true
                job.phase = .working
                note("\(step.done) with the code from your \(DeviceWord.name)")
                continue // the same step, signed in now
            }
            if step.needs == .yes, !job.yesGiven {
                job.phase = .needsYes
                let request = script.yes ?? YesRequest(kind: .pay, icon: step.icon, title: def.yes ?? "Go on?", subtitle: def.name,
                                                       facts: [], button: "Approve with Face ID", waiting: "Waiting for you")
                note("Asked on the \(DeviceWord.name): you’ve been away \(self.script.idleMinutes) min")
                emit(.needsYes(job.id, request))
                let given: SignedYes?
                if let early = pendingYes.removeValue(forKey: job.id) {
                    given = early
                } else if case let .yes(yes)? = await answer(job) {
                    given = yes
                } else {
                    return
                }
                guard let given, verify(given, request: request, task: job.id) else {
                    job.phase = .failed
                    job.runner = nil
                    note("The signature didn’t check out")
                    emit(.failed(job.id, TaskFailure(line: "The yes didn’t check out · nothing was paid", long: "Your Mac couldn’t check the signature from this \(DeviceWord.name), so it pressed nothing.",
                                                     lockTitle: "Nothing was paid", lockLine: "The yes didn’t check out. Retry from Yab.")))
                    return
                }
                job.yesGiven = true
                job.phase = .paying
                note("Checked the Face ID signature from the \(DeviceWord.name)")
                emit(.paying(job.id))
                guard await pause(payPause) else { return }
                finish(job, def)
                return
            }
            if k < def.steps.count - 1 {
                note(step.done)
                job.step = k + 1
            } else {
                note(step.done)
                finish(job, def)
                return
            }
        }
    }

    /// Waits for the Mac to wake if it sleeps, saying so once; false when
    /// the job was stopped meanwhile.
    private func awake(_ job: Job) async -> Bool {
        guard !presence.awake else { return true }
        job.phase = .waiting
        emit(.waits(job.id))
        await whenAwake()
        return !Task.isCancelled
    }

    private func finish(_ job: Job, _ def: TaskDefinition) {
        job.phase = .done
        job.step = max(0, def.steps.count - 1)
        job.runner = nil
        note(def.result)
        emit(.done(job.id))
    }

    private func answer(_ job: Job) async -> Answer? {
        await withCheckedContinuation { job.answer = $0 }
    }

    /// The yes signs this exact request with the key the Mac trusts.
    private func verify(_ yes: SignedYes, request: YesRequest, task: TaskRun.ID) -> Bool {
        guard yes.digest == request.digest(task: task), let key = trusted,
              let signature = try? P256.Signing.ECDSASignature(rawRepresentation: yes.signature) else { return false }
        return key.isValidSignature(signature, for: yes.digest)
    }

    // MARK: - saying it

    private func emit(_ event: MacEvent) {
        onEvent?(event)
    }

    private func note(_ words: String) {
        diary.append(words)
        log.info("mac: \(words, privacy: .public)")
    }
}
