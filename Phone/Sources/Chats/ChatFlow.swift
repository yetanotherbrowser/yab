import SwiftUI
import UIKit
import SyncKit

/// What answers and chats do: the entry points other branches call (the
/// field asks, the Chats page opens a chat or a new chat) and every move of
/// the one sheet, each under its own Motion and signpost, each haptic as
/// the prototype's table says. Frequent paths (asking, answers) are quiet.
extension AppModel {
    // MARK: - entry points

    /// Asks `question`, about `page` when there is one: the answer grows out
    /// of the field (`origin`, the field's frame; nil: the plate's field),
    /// the question flies into its bubble. A page question before Claude
    /// joins is answered on this iPhone; the rest by Claude on the Mac.
    func ask(_ question: String, page: Tab?, from origin: CGRect? = nil) {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        let sheet = chatSheet
        sheet.answerers.mac.asleep = browser.macAsleep
        let id = sheet.nextID()
        var chat = Chat(id: id, title: StandIns.name(for: q, fixturesEnabled: isFixture), day: .today, time: sheet.now(), by: .claude,
                        messages: [Message(role: .you, text: q)])
        chat.by = sheet.answerers.who(for: q, in: chat, aboutPage: page != nil,
                                      fixturesEnabled: isFixture, privateContext: page?.isPrivate == true || browser.space.isPrivate)
        chat.ephemeral = true
        chats.add(chat, isPrivate: page?.isPrivate == true || browser.space.isPrivate)
        if let page { sheet.pages[id] = page.id; sheet.pageSources[id] = page }
        dropParked()
        reset(sheet, to: id, mode: .answer)
        respond(to: q, in: id, by: chat.by)

        typealias C = Metrics.Chat
        let field = origin ?? Self.plateFieldFrame(screen: screenSize)
        present(.answer(question: q, aboutPage: page != nil), from: field)
        sheet.origin = Self.originShape(field)
        sheet.pose = SheetPose(t: 0, o: 1, k: 0, e: 0, h: sheet.pose.h)
        sheet.arrival = Arrival(from: 1, shown: 0)
        syncBehind()
        // The words as typed: 17 pt, where the field's text began.
        let text = CGRect(x: field.minX + C.flightInset, y: field.midY - C.flightHeight / 2,
                          width: min(field.width - C.flightClear, C.flightMaxWidth), height: C.flightHeight)
        fly(q, from: text, fontSize: 17, padding: C.flightLead, bubble: 0)
        guard !Motion.disabled else {
            // Named states: the answer stands grown at once.
            sheet.pose.o = 0
            sheet.arrival?.shown = 1
            syncBehind()
            return
        }
        afterLayout {
            Motion.answerGrow.run { sheet.pose.o = 0; self.syncBehind() }
            Motion.answerWords.run { sheet.arrival?.shown = 1 }
        }
    }

    /// A chat at full height in the sheet, growing out of `origin` (the Now
    /// line, the island), else standing at once. From its card on New Tab's
    /// Chats page it is a page of its own instead (openChatPage).
    func openChat(_ id: Chat.ID, from origin: CGRect? = nil) {
        guard let chat = chats.chat(id),
              permitPrivateChat(id, then: { [weak self] in self?.openChat(id, from: origin) }) else { return }
        let sheet = chatSheet
        // A conversation opened from Chats stays in its one tray, including
        // tasks. Their code and consent still belong to the TaskDesk.
        if let task = chat.task, tasks.run(task)?.status == .done { taskDesk.seen(task) }
        chats.setUnread(id, false)
        dropParked(keeping: id)
        reset(sheet, to: id, mode: .chat)
        present(route(for: chat), from: origin)
        if let origin, !Motion.disabled {
            sheet.origin = Self.originShape(origin)
            sheet.pose = SheetPose(t: 1, o: 1, h: sheet.pose.h)
            syncBehind()
            // Out of the island at the top, or out of the Now line.
            let motion = origin.midY < screenSize.height / 2 ? Motion.islandToChat : Motion.nowToChat
            motion.run { sheet.pose.o = 0; self.syncBehind() }
            return
        }
        sheet.pose = SheetPose(t: 1, h: sheet.pose.h)
        syncBehind()
    }

    /// A chat out of its card on New Tab's Chats page: a page of its own in
    /// a native full-screen cover that zooms out of the card (ChatPageCover),
    /// as Chat Info out of the face, and back into it on ‹, a pull down or
    /// the edge swipe; UIKit owns that motion, its finger and its cancel.
    /// The Chats page stays under it as it was, its search words too.
    func openChatPage(_ id: Chat.ID, inProject project: ChatProject.ID? = nil) {
        guard let chat = chats.chat(id),
              permitPrivateChat(id, then: { [weak self] in self?.openChatPage(id, inProject: project) }) else { return }
        if let task = chat.task, tasks.run(task)?.status == .done { taskDesk.seen(task) }
        chats.setUnread(id, false)
        dropParked(keeping: id)
        reset(chatSheet, to: id, mode: .chat)
        // A card opens the chat to read: no keyboard over it until its field is tapped.
        chatSheet.focused = false
        presentPage(chat, source: id, project: project)
    }

    /// The chat in its cover, the field (New Tab's Chats page) kept under it;
    /// over the open project when it was opened from there (`project`).
    private func presentPage(_ chat: Chat, source: String, project: ChatProject.ID? = nil) {
        let sheet = chatSheet
        // The Chats page's search lets the keyboard go now, before UIKit
        // presents the cover: a first responder still in place then stays
        // with its keyboard over the chat. The page rests under the cover,
        // so ‹ finds it whole, not standing on the keyboard that went.
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        field.blur()
        field.rest()
        sheet.shown = true
        sheet.pose = SheetPose(t: 1, h: sheet.pose.h)
        sheet.page = ChatPagePresentation(id: sheet.navigationGeneration, chat: chat.id, source: source, project: project)
        surfaces.menu = nil
        surfaces.chatOrigin = nil
        surfaces.chatPage = nil
        surfaces.chat = route(for: chat)
        surfaces.recede = 0
        surfaces.scrim = 0
    }

    /// The cover goes back into its card: by ‹ (openHistory), or UIKit's own
    /// pull down or edge swipe once it has finished. A cancelled pull never
    /// comes here, and an old cover's dismissal can't close a newer one.
    func closeChatPage(_ presentation: ChatPagePresentation) {
        let sheet = chatSheet
        guard sheet.page == presentation else { return }
        let id = presentation.chat
        sheet.focused = false
        sheet.moreMenu = false
        sheet.attachMenu = false
        // The cover zooms back into its card under this change's own
        // animation; the sheet is put away once that has begun (hideSheet's
        // still transaction, in the same update, would take the zoom away).
        withAnimation(.default) {
            sheet.pageLeaving = true
            sheet.page = nil
        }
        let finish: @MainActor () -> Void = { [weak self] in
            guard let self, sheet.pageLeaving, sheet.page == nil else { return }
            self.hideSheet()
            sheet.chatID = nil
        }
        if Motion.disabled { finish() } else { DispatchQueue.main.async { finish() } }
        // A new chat nothing was asked in leaves nothing, once the zoom back
        // has drawn its last frame of it.
        guard chats.chat(id)?.ephemeral == true, chats.parked?.chat != id else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + (Motion.disabled ? 0 : 1)) { [weak self] in
            guard let self, self.chatSheet.chatID != id, self.chats.chat(id)?.ephemeral == true,
                  self.chats.parked?.chat != id else { return }
            self.forget(id)
        }
    }

    /// A task's chat: its steps, its tabs on the Mac, the result. A run this
    /// iPhone knows is the tasks' sheet (TaskDesk, Tasks/TasksLayer); only a
    /// chat whose run isn't here stands in this sheet.
    func openTaskChat(_ run: TaskRun.ID, from origin: CGRect? = nil) {
        if tasks.run(run) != nil {
            taskDesk.openChat(run, from: .other(origin))
            return
        }
        if let chat = chats.chats.first(where: { $0.task == run }) {
            openChat(chat.id, from: origin)
            return
        }
        guard let def = tasks.definition(run) else { return }
        chats.add(Chat(id: run, title: def.name, day: .today, time: chatSheet.now(), task: run))
        openChat(run, from: origin)
    }

    /// Your chats: New Tab's Chats page, out of where it was asked for (a
    /// task's history). It has search and, at the field's left, the archive.
    func openChats(from origin: CGRect? = nil) {
        let sheet = chatSheet
        if sheet.shown { hideSheet(); sheet.chatID = nil }
        NewTabPager.shared.startAt = NewTabPager.chatsPage
        field.openSpaces(from: origin)
    }

    /// A new chat like ⌘J on the Mac: ideas for the page in front over its
    /// field. From New Chat on the Chats page it is a page in its cover,
    /// zoomed out of that row (`asPage`); else it grows out of `origin`.
    /// Asked from the page menu it is about `page`: the page goes with its
    /// first words.
    /// In a project (`project`), it is the project's: its Mac answers, told
    /// the project's instructions, and the cover stands over the project.
    func newChat(from origin: CGRect? = nil, about page: Tab? = nil, focus: Bool = true, asPage: String? = nil,
                 project: ChatProject.ID? = nil) {
        let sheet = chatSheet
        let id = sheet.nextID()
        var chat = Chat(id: id, title: "New Chat", day: .today, time: sheet.now(), by: .claude, project: project)
        if project == nil {
            chat.by = sheet.answerers.who(for: "", in: chat, aboutPage: page != nil, fixturesEnabled: isFixture,
                                          privateContext: browser.space.isPrivate || browser.tab?.isPrivate == true)
        }
        chat.ephemeral = true
        chats.add(chat, isPrivate: browser.space.isPrivate || browser.tab?.isPrivate == true)
        if let page { sheet.pages[id] = page.id; sheet.pageSources[id] = page }
        sheet.fresh.insert(id)
        reset(sheet, to: id, mode: .chat)
        // The keyboard comes once the chat stands: asked for in the middle of
        // the grow, it lays out in the same frames and stalls the motion.
        let grown: @MainActor () -> Void = { if focus, sheet.chatID == id, sheet.shown { sheet.focused = true } }
        if let source = asPage {
            sheet.pose.h = Double(Metrics.Chats.newTrayHeight)
            presentPage(chats.chat(id)!, source: source, project: project)
            if project == nil { loadIdeas() }
            // After UIKit's zoom out of the row (about 0.45 s).
            if Motion.disabled { grown() } else {
                let generation = sheet.navigationGeneration
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    if sheet.navigationGeneration == generation { grown() }
                }
            }
            return
        }
        present(.newChat, from: origin)
        loadIdeas()
        if let origin, !Motion.disabled {
            sheet.origin = Self.originShape(origin, radius: Metrics.Chats.plusRadius)
            sheet.pose = SheetPose(t: 1, o: 1, h: Double(Metrics.Chats.newTrayHeight))
            syncBehind()
            Motion.chatGrow.run({ sheet.pose.o = 0; self.syncBehind() }, completion: grown)
        } else {
            sheet.pose = SheetPose(t: 1, h: Double(Metrics.Chats.newTrayHeight))
            syncBehind()
            grown()
        }
    }

    // MARK: - talking

    /// Words from the chat's field (or an idea): they fly into a new bubble,
    /// and whoever answers answers.
    func send(_ text: String, from field: CGRect? = nil) {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let sheet = chatSheet
        guard let id = sheet.chatID, var chat = chats.chat(id) else { return }
        // Photos and files in the field go with the words, or alone.
        let files = canAttach(id) ? sheet.attached[id] ?? [] : []
        guard !q.isEmpty || !files.isEmpty else { return }
        guard permitPrivateChat(id, then: { [weak self] in
            guard let self, self.chatSheet.chatID == id else { return }
            self.send(text, from: field)
        }) else { return }
        if !isFixture, sheet.answeringHere.contains(id) || sheet.sendingToMac.contains(id) || sync.isStartingChat(id) {
            say(SyncBridge.QuestionFailure.starting.localizedDescription, glyph: .macbook)
            return
        }
        if let failure = SendUpload.check(files.map(\.upload.data.count)) {
            say(failure.localizedDescription, glyph: .exclamationCircle)
            return
        }
        Haptics.play(.light, reason: Haptics.Reason.send)
        sheet.draft = ""
        sheet.attached[id] = nil
        for file in files { if let picture = file.thumbnail { ChatThumbs.keep(picture, digest: file.digest) } }
        if let task = chat.task {
            if isFixture, tasks.run(task) != nil { taskDesk.tell(task, q) }
            else { say("Tasks on your Mac aren’t available yet", glyph: .macbook) }
            return
        }
        let firstWords = sheet.fresh.remove(id) != nil
        if firstWords {
            chat.title = q.isEmpty ? Self.filesTitle(files.map(\.file)) : StandIns.name(for: q, fixturesEnabled: isFixture)
            chat.time = sheet.now()
        }
        chat.ephemeral = false
        chat.day = .today
        let questions = chat.messages.filter { $0.role == .you }.count
        chat.messages.append(Message(role: .you, text: q, files: files.map(\.file)))
        // Only the Mac takes photos and files, and a project's words.
        let who: Chat.Answerer = !files.isEmpty || chat.project != nil ? .claude
            : sheet.answerers.who(for: q, in: chat, aboutPage: sheet.pages[id] != nil,
                                  fixturesEnabled: isFixture, privateContext: privateQuestion(id), remoteChat: sync.engine?.chat(id) != nil || id.hasPrefix("a:") || id.hasPrefix("c:"))
        chats.update(id) { $0 = chat }
        if let field, !q.isEmpty, !Motion.disabled {
            typealias C = Metrics.Chat
            let from = CGRect(x: field.minX - C.flightLead, y: field.midY - C.flightHeight / 2,
                              width: min(field.width, C.flightMaxWidth), height: C.flightHeight)
            fly(q, from: from, fontSize: 16, padding: C.flightLead, bubble: questions)
        }
        sheet.arrival = Arrival(from: chat.messages.count, shown: Motion.disabled ? 1 : 0)
        respond(to: q, in: id, by: who, files: files.map(\.upload))
        if !Motion.disabled { Motion.answerWords.run { sheet.arrival?.shown = 1 } }
        if sheet.mode == .answer { expand() }
        else if firstWords {
            Motion.chatGrow.run { sheet.pose.t = 1; self.syncBehind() }
        }
        // A new chat asked its first words is a chat now: Surfaces says so,
        // or the layer would take the stale route for a new request.
        syncRoute()
    }

    /// Whoever answers `question` in chat `id` answers: the stand-in at once,
    /// the model on this iPhone in a moment, Claude after a beat of typing,
    /// or nobody while the Mac sleeps (the chat says so; it answers on waking).
    func respond(to question: String, in id: Chat.ID, by who: Chat.Answerer, files: [SendUpload] = []) {
        let sheet = chatSheet
        let answerers = sheet.answerers
        answerers.mac.asleep = browser.macAsleep
        let context = askContext(question, in: id)
        if who == .iphone {
            if !isFixture, answerers.device is StandInDevice || !answerers.device.isAvailable {
                localAnswerFailed(in: id, failure: .unavailable)
                return
            }
            if isFixture, answerers.device is StandInDevice {
                chats.append(Message(role: .answer, text: StandIns.answer(question), by: .iphone), to: id)
                return
            }
            if !isFixture, !sheet.answeringHere.insert(id).inserted { return }
            chats.append(Message(role: .typing, by: .iphone), to: id)
            Task { @MainActor in
                defer { sheet.answeringHere.remove(id) }
                let page = await self.pageContext(for: id)
                var asked = context
                asked.page = page
                do {
                    let text = try await answerers.device.answer(asked)
                    self.land(text, in: id, by: .iphone)
                } catch {
                    if self.isFixture {
                        self.chats.update(id) { chat in
                            chat.messages.removeAll { $0.role == .typing }
                            chat.by = .claude
                        }
                        self.askMac(question, in: id)
                    } else {
                        // Choosing this iPhone never exports a failed answer's page.
                        self.localAnswerFailed(in: id, failure: .interrupted)
                    }
                }
            }
            return
        }
        askMac(question, in: id, files: files)
    }

    private func privateQuestion(_ id: Chat.ID) -> Bool {
        chats.isPrivate(id) || chatSheet.pageSources[id]?.isPrivate == true
            || chatSheet.pages[id].flatMap({ browser.tab($0) })?.isPrivate == true
    }

    private func localAnswerFailed(in id: Chat.ID, failure: Answerers.LocalFailure) {
        chats.update(id) { chat in
            chat.by = .iphone
            chat.messages.removeAll { $0.role == .typing || $0.role == .wait }
            chat.messages.append(Message(role: .note, text: failure.localizedDescription))
            chat.ephemeral = false
        }
    }

    private func askMac(_ question: String, in id: Chat.ID, files: [SendUpload] = []) {
        let sheet = chatSheet
        guard let chat = chats.chat(id) else { return }
        if privateQuestion(id) {
            chats.update(id) { chat in
                chat.messages.removeAll { $0.role == .typing || $0.role == .wait }
                chat.messages.append(Message(role: .failed, text: SyncBridge.QuestionFailure.privateConversation.localizedDescription))
            }
            return
        }
        let answered = chat.messages.contains { $0.by == .iphone && $0.role == .answer }
        if answered, !chat.messages.contains(where: { $0.by == .claude }) {
            chats.append(Message(role: .note, text: isFixture ? "Claude carries on, on your Mac" : "Your Mac carries on"), to: id)
        }
        if !isFixture {
            chats.update(id) { $0.by = .claude }
            guard sheet.sendingToMac.insert(id).inserted else { return }
            chats.append(Message(role: .typing, by: .claude), to: id)
            let context = askContext(question, in: id)
            let agent = sheet.answerers.preferredMacAgent
            let sourceEngine = sync.engine
            Task { @MainActor in
                defer { sheet.sendingToMac.remove(id) }
                var asked = context
                asked.page = await self.pageContext(for: id)
                guard self.chats.chat(id) != nil else { return }
                do {
                    guard let sourceEngine else { throw SyncBridge.QuestionFailure.notJoined }
                    _ = try self.sync.sendQuestion(asked, in: id, agent: agent, expectedEngine: sourceEngine, files: files,
                                                   pick: sheet.picks[id])
                } catch {
                    self.chats.update(id) { chat in
                        chat.messages.removeAll { $0.role == .typing || $0.role == .wait }
                        chat.messages.append(Message(role: .failed, text: error.localizedDescription))
                        chat.ephemeral = false
                    }
                }
            }
            return
        }
        sheet.answerers.mac.usesStandIn = true
        if sheet.answerers.mac.asleep {
            chats.append(Message(role: .wait, text: "\(macName) is asleep \u{00B7} since \(sheet.macAsleepSince())\n\(MacWords.starts(.asleep(since: Date())))",
                                 by: .claude, mac: Message.MacWait(name: macName)), to: id)
            sheet.waitingForMac[id] = question
            return
        }
        chats.append(Message(role: .typing, by: .claude), to: id)
        let context = askContext(question, in: id)
        Task { @MainActor in
            guard let text = try? await sheet.answerers.mac.answer(context) else { return }
            self.land(text, in: id, by: .claude)
        }
    }

    /// An answer arrives: in place of the typing dots (or the wait), the
    /// sheet growing to hold it. Not on screen, the chat is marked new.
    func land(_ text: String, in id: Chat.ID, by who: Chat.Answerer) {
        let sheet = chatSheet
        chats.update(id) { chat in
            let message = Message(role: .answer, text: text, by: who)
            if let i = chat.messages.firstIndex(where: { $0.role == .typing || $0.role == .wait }) {
                chat.messages[i] = message
            } else {
                chat.messages.append(message)
            }
        }
        let onScreen = sheet.shown && sheet.chatID == id && chats.parked?.chat != id
        // New, unless it is a quick answer: those aren't on the Chats page,
        // and ‹ counts only what the page lists.
        if !onScreen, chats.chat(id)?.ephemeral == false { chats.setUnread(id, true) }
        if onScreen {
            sheet.arrival = Arrival(from: (chats.chat(id)?.messages.count ?? 1) - 1, shown: Motion.disabled ? 1 : 0)
            if !Motion.disabled { Motion.answerWords.run { sheet.arrival?.shown = 1 } }
        }
    }

    /// The Mac woke: what waited for it is answered.
    func macWoke() {
        let sheet = chatSheet
        browser.macAsleep = false
        sheet.answerers.mac.asleep = false
        sheet.macWoke()
        // The real Mac reads each journaled send itself on waking.
        guard isFixture else { return }
        let waiting = sheet.waitingForMac
        sheet.waitingForMac.removeAll()
        for (id, question) in waiting {
            chats.update(id) { chat in
                if let i = chat.messages.firstIndex(where: { $0.role == .wait }) { chat.messages[i] = Message(role: .typing, by: .claude) }
            }
            let context = askContext(question, in: id)
            Task { @MainActor in
                guard let text = try? await sheet.answerers.mac.answer(context) else { return }
                self.land(text, in: id, by: .claude)
            }
        }
    }

    /// The turns laid out where the answer rests: it takes their height (12 +
    /// 50 + up to 330 of turns + actions + foot); when Claude's answer lands
    /// the sheet grows, the height change is the signal that something came.
    func turnsMeasured(_ height: CGFloat) {
        typealias C = Metrics.Chat
        let sheet = chatSheet
        guard sheet.mode == .answer, let id = sheet.chatID else { return }
        let pill: CGFloat = sheet.pages[id] != nil ? C.pagePill + 8 : 0
        let foot = pill + C.field + C.footAnswer
        let body = min(C.answerTurnsMax, height + C.turnsTop + C.turnsBottom)
        let h = Double(Metrics.Column.grabTop + Metrics.Column.grabHeight + C.answerHead + body + C.actionsHeight + foot)
        guard abs(h - sheet.pose.h) > 0.5 else { return }
        if sheet.shown, sheet.pose.o < 0.01, abs(h - sheet.pose.h) > 2, !Motion.disabled {
            Motion.answerHeight.run { sheet.pose.h = h }
        } else {
            var still = Transaction(animation: nil)
            still.disablesAnimations = true
            withTransaction(still) { sheet.pose.h = h }
        }
    }

    /// Whatever Claude was typing lands now (named states).
    func landNow() { chatSheet.answerers.mac.landNow() }

    private func askContext(_ question: String, in id: Chat.ID) -> AskContext {
        let history = chats.chat(id)?.messages.filter { $0.role == .you || $0.role == .answer } ?? []
        return AskContext(question: question, page: nil, history: Array(history.dropLast()))
    }

    private func pageContext(for id: Chat.ID) async -> PageContext? {
        guard let tabID = chatSheet.pages[id], let tab = browser.tab(tabID) ?? chatSheet.pageSources[id] else { return nil }
        return await PageText.read(tab, pool: pages)
    }

    // MARK: - answer, chat, Now line

    /// The answer stands up into the chat: full height, the page behind
    /// steps back, the keyboard may rise with it.
    func expand(velocity: CGFloat = 0) {
        let sheet = chatSheet
        guard sheet.shown, let id = sheet.chatID else { return }
        if !sheet.fresh.contains(id) { chats.update(id) { $0.ephemeral = false } }
        sheet.mode = .chat
        syncRoute()
        Motion.answerToChat.run { sheet.pose.t = 1; self.syncBehind() }
    }

    /// A conversation returns to Chats; a quick answer folds into Now.
    func park() {
        let sheet = chatSheet
        guard sheet.shown, let id = sheet.chatID, let chat = chats.chat(id) else { return }
        if sheet.mode == .chat {
            openHistory()
            return
        }
        sheet.focused = false
        sheet.moreMenu = false
        if chat.task == nil {
            chats.parked = .init(chat: id, mode: sheet.mode == .answer ? .answer : .chat)
        }
        let motion = chat.task == nil ? Motion.park : Motion.chatToNow
        motion.run({
            sheet.pose.p = 1
            sheet.pose.drag = 0
            self.syncBehind()
        }, completion: {
            guard sheet.pose.p > 0.99 else { return }
            self.hideSheet()
        })
    }

    /// A tap on the Now line: the sheet grows back out of it.
    func restoreParked() {
        let sheet = chatSheet
        guard let parked = chats.parked, chats.chat(parked.chat) != nil,
              permitPrivateChat(parked.chat, then: { [weak self] in
                  guard let self, self.chats.parked?.chat == parked.chat else { return }
                  self.restoreParked()
              }) else { return }
        chats.setUnread(parked.chat, false)
        reset(sheet, to: parked.chat, mode: parked.mode == .answer ? .answer : .chat)
        present(route(for: chats.chat(parked.chat)!), from: nil)
        sheet.pose = SheetPose(t: parked.mode == .answer ? 0 : 1, p: 1, h: sheet.pose.h)
        syncBehind()
        Motion.unpark.run({ sheet.pose.p = 0; self.syncBehind() }, completion: {
            if sheet.shown, sheet.pose.p < 0.01 { self.chats.parked = nil }
        })
    }

    /// The Now line flicked aside: it flies off. An answer never continued
    /// leaves nothing; a chat stays on the Chats page.
    func letGoParked(direction: CGFloat) {
        let sheet = chatSheet
        guard let parked = chats.parked else { return }
        Haptics.play(.light, reason: Haptics.Reason.letGo)
        let away = Metrics.Chats.letGoFlight
        Motion.letGo.run({ sheet.lineGone = direction < 0 ? -away : away }, completion: {
            if self.chats.chat(parked.chat)?.ephemeral == true { self.forget(parked.chat) }
            self.chats.setUnread(parked.chat, false)
            self.chats.parked = nil
            var still = Transaction(animation: nil)
            still.disablesAnimations = true
            withTransaction(still) {
                sheet.lineGone = 0
                sheet.lineDrag = 0
            }
        })
    }

    /// The sheet goes down. A quick answer never continued leaves nothing.
    func closeSheet() {
        let sheet = chatSheet
        if let page = sheet.page {
            // A link out of a page in its cover: the cover goes with the
            // Chats page under it, the tab in front.
            closeChatPage(page)
            surfaces.closeField()
            return
        }
        sheet.focused = false
        sheet.navigationGeneration = UUID()
        let chat = sheet.chatID
        Motion.chatGone.run({ sheet.pose.e = 1; self.syncBehind() }, completion: {
            guard sheet.pose.e > 0.99 else { return }
            self.hideSheet()
            if let chat, self.chats.chat(chat)?.ephemeral == true, self.chats.parked?.chat != chat { self.forget(chat) }
            sheet.chatID = nil
        })
    }

    // MARK: - back to the Chats page

    /// ‹ in a chat, or a finger from the left edge: New Tab's Chats page,
    /// the chat zooming back into its card there as Chat Info into the face.
    /// One in its cover just closes it (UIKit's zoom). One in the sheet (from
    /// the Now line, the island, an answer grown into a chat) has the Chats
    /// page come under it and is handed, as it stands, to a cover over the
    /// page, which zooms into its card the same way: one way back for all.
    func openHistory() {
        let sheet = chatSheet
        if let page = sheet.page {
            closeChatPage(page)
            return
        }
        if sheet.shown, sheet.mode == .chat, let id = sheet.chatID {
            sheet.focused = false
            sheet.moreMenu = false
            NewTabPager.shared.startAt = NewTabPager.chatsPage
            if surfaces.field == nil { field.openSpacesInPlace() }
            guard !Motion.disabled, let chat = chats.chat(id) else { hideSheet(); sheet.chatID = nil; return }
            let generation = sheet.navigationGeneration
            // Once the page has laid its card out under the chat (or a moment
            // has gone by without it): the zoom needs the card where it is.
            sheet.rowFrames[id] = nil
            let asked = Date()
            func handOver() {
                guard sheet.navigationGeneration == generation, sheet.chatID == id, sheet.shown,
                      sheet.page == nil else { return }
                if rowOnScreen(id) == nil, Date().timeIntervalSince(asked) < 0.6 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.016) { handOver() }
                    return
                }
                sheet.pageClosesOnAppear = true
                sheet.pageHandover = true
                // Presented without a motion of its own: it covers the sheet's
                // chat with the same chat, in the same place.
                var still = Transaction(animation: nil)
                still.disablesAnimations = true
                withTransaction(still) {
                    // Its newest words have come in: the cover's fresh view
                    // doesn't write them out again.
                    sheet.arrival = nil
                    self.presentPage(chat, source: id)
                }
                // A page that never stood (no Chats page to present it): the
                // chat just goes, the page in front.
                let handed = sheet.page
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                    guard let self, let handed, sheet.page == handed, !sheet.pageOnScreen else { return }
                    self.closeChatPage(handed)
                }
            }
            afterLayout { handOver() }
            return
        }
        // Anything else (a quick answer, nothing up): the Chats page.
        openChats()
    }

    /// A chat's card on the Chats page where it was last laid out, if on screen.
    func rowOnScreen(_ id: Chat.ID) -> CGRect? {
        let box = CGRect(origin: .zero, size: screenSize)
        return chatSheet.rowFrames[id].flatMap { $0.width > 1 && $0.height > 1 && box.intersects($0) ? $0 : nil }
    }

    /// VoiceOver's escape (two fingers scrubbing) does what a swipe down
    /// does: the innermost thing open closes (Chat Info, the ⋯ menu), a
    /// conversation goes back to the Chats page, a quick answer hides into
    /// the Now line.
    func escapeSheet() {
        let sheet = chatSheet
        guard sheet.shown else { return }
        if sheet.info { closeChatInfo(); return }
        if sheet.moreMenu { Motion.menuClose.run { sheet.moreMenu = false }; return }
        park()
    }

    // MARK: - what a chat's row and menus do (no delete anywhere)

    func setPinned(_ id: Chat.ID, _ on: Bool) {
        Haptics.play(.light, reason: Haptics.Reason.pin)
        chatSheet.fresh.remove(id)
        Motion.columnRows.run { chats.update(id) { $0.pinned = on; $0.ephemeral = false } }
    }

    func setUnread(_ id: Chat.ID, _ on: Bool) {
        Haptics.play(.light, reason: Haptics.Reason.unread)
        chats.setUnread(id, on)
    }

    func archive(_ id: Chat.ID) {
        Haptics.play(.light, reason: Haptics.Reason.archive)
        guard let before = chats.chat(id), !before.archived else { return }
        chats.setArchived(id, true)
        registerArchiveUndo([before])
    }

    private func registerArchiveUndo(_ before: [Chat]) {
        registerActionUndo("Archive Chat") { app in
            for chat in before where app.chats.chat(chat.id)?.archived == true {
                app.chats.update(chat.id) { $0.archived = chat.archived; $0.ephemeral = chat.ephemeral }
            }
        }
    }

    func unarchive(_ id: Chat.ID) {
        Haptics.play(.light, reason: Haptics.Reason.archive)
        Motion.columnRows.run { chats.setArchived(id, false) }
    }

    /// Archive Chat in the chat's ⋯: archived, and the Chats page in its place.
    func archiveOpenChat() {
        let sheet = chatSheet
        guard let id = sheet.chatID else { return }
        Haptics.play(.light, reason: Haptics.Reason.archive)
        sheet.fresh.remove(id)
        guard let before = chats.chat(id) else { return }
        chats.update(id) { $0.archived = true; $0.ephemeral = false }
        registerArchiveUndo([before])
        openHistory()
    }

    /// Open on Mac for a chat isn't built yet: only the fixture worlds that
    /// draw it offer it, and none before this iPhone has a Mac.
    var canOpenChatOnMac: Bool { isFixture && hasMac }

    func rename(_ id: Chat.ID, to title: String) {
        let words = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return }
        Haptics.play(.soft, reason: Haptics.Reason.chatAction)
        chatSheet.fresh.remove(id)
        chats.rename(id, to: words)
    }

    enum MorePick: Sendable { case pin, copy, mac, archive, rename, unread, info, delete }

    // MARK: - a row held on New Tab's Chats page (as the Mac's chat list)

    /// The chat's Mac takes Stop and Delete from this iPhone.
    func canControl(_ id: Chat.ID) -> Bool { !isFixture && sync.canControlChat(id) }

    /// Stop its run on the Mac; the row says "working" until it stops.
    func stopChat(_ id: Chat.ID) {
        guard sync.controlChat(id, .stop) else { say("Your Mac can’t stop it from here", glyph: .exclamationCircle); return }
        Haptics.play(.light, reason: Haptics.Reason.menu)
    }

    /// Delete Chat is offered for any chat but a task's (its task record
    /// keeps it) and one its Mac is still working on or waking for. A chat
    /// whose question never reached its Mac goes, waiting or not (the
    /// stand-in world's chats are all its Mac's).
    func canDelete(_ id: Chat.ID) -> Bool {
        guard let chat = chats.chat(id), chat.task == nil else { return false }
        guard chat.working || chat.messages.last?.role == .wait else { return true }
        return !isFixture && !sync.engineChat(id)
    }

    /// What Delete Chat asks first: where the chat goes from.
    func deleteQuestion(_ id: Chat.ID) -> (title: String, detail: String?) {
        if canControl(id) { return ("Delete this chat on your Mac too?", nil) }
        if LocalChatProfile.isRemoteID(id) { return ("Delete this chat from this \(DeviceWord.name)?", "It stays on \(macName).") }
        return ("Delete this chat?", nil)
    }

    /// Delete Chat: a Mac's chat goes from the Mac too when it takes Delete
    /// from here (as its own Delete Chat), else from this iPhone only; a
    /// chat of this iPhone's goes for good. An open chat closes first.
    func deleteChat(_ id: Chat.ID) {
        guard canDelete(id) else { return }
        let onMac = canControl(id)
        Haptics.play(.light, reason: Haptics.Reason.archive)
        chatSheet.fresh.remove(id)
        chatSheet.waitingForMac[id] = nil
        if chatSheet.chatID == id { openHistory() }
        if onMac {
            if !sync.controlChat(id, .delete) { say("Your Mac can’t delete it from here", glyph: .exclamationCircle) }
        } else if LocalChatProfile.isRemoteID(id), !isFixture {
            sync.forgetChat(id)
        } else if !isFixture {
            // Its question, waiting or failed, is taken back with it.
            Motion.columnRows.run { sync.forgetOwnChat(id) }
        } else {
            Motion.columnRows.run { chats.remove(id) }
        }
    }

    /// Copy Answer for a chat's row: its last answer's words.
    func copyAnswer(of id: Chat.ID) {
        guard let answer = chats.chat(id)?.lastAnswer else { return }
        UIPasteboard.general.string = Self.copyText(answer)
        Haptics.play(.soft, reason: Haptics.Reason.copied)
        say("Copied", glyph: .squareBehindSquare1)
    }

    /// Archive Older (the Mac's Archive Below): the chats after it in its
    /// list, older as the list runs newest first, that aren't kept for good
    /// (pinned) or still working. In a grid "below" would leave out the card
    /// beside it; "older" holds in any layout.
    static func archivableBelow(_ id: Chat.ID, in list: [Chat]) -> [Chat] {
        guard let index = list.firstIndex(where: { $0.id == id }) else { return [] }
        return list[(index + 1)...].filter { !$0.pinned && !$0.archived && !$0.working }
    }

    func archive(below id: Chat.ID, in list: [Chat]) {
        let under = Self.archivableBelow(id, in: list)
        guard !under.isEmpty else { return }
        Haptics.play(.light, reason: Haptics.Reason.archive)
        Motion.columnRows.run { for chat in under { chats.setArchived(chat.id, true) } }
        registerArchiveUndo(under)
    }

    func openChatInfo() {
        let sheet = chatSheet
        guard sheet.shown, sheet.chatID != nil else { return }
        sheet.navigationGeneration = UUID()
        sheet.infoReturnFocus = sheet.focused
        sheet.focused = false
        sheet.moreMenu = false
        sheet.infoGeneration = UUID()
        Haptics.play(.soft, reason: Haptics.Reason.chatInfo)
        Motion.chatInfo.run { sheet.info = true }
    }

    func closeChatInfo() {
        let sheet = chatSheet
        guard sheet.shown, sheet.info else { return }
        let focus = sheet.infoReturnFocus
        sheet.navigationGeneration = UUID()
        Motion.chatInfo.run { sheet.info = false; sheet.infoGeneration = nil }
        sheet.infoReturnFocus = false
        sheet.focused = focus
    }

    /// A cancelled or retired native cover cannot close a newer Info page.
    func closeChatInfo(_ presentation: ChatInfoPresentation) {
        guard presentation.isCurrent(in: self) else { return }
        closeChatInfo()
    }

    func toggleMoreMenu() {
        let sheet = chatSheet
        Motion.chatMenu.run { sheet.moreMenu.toggle() }
    }

    /// A pick in a chat's ⋯: the sheet's chat, or `given` (a task's chat,
    /// whose ⋯ opens this menu over the tasks' sheet through Surfaces.menu).
    func pickMore(_ pick: MorePick, chat given: Chat.ID? = nil) {
        let sheet = chatSheet
        Motion.menuClose.run {
            sheet.moreMenu = false
            if case .chat? = self.surfaces.menu { self.surfaces.closeMenu() }
        }
        guard let id = given ?? sheet.chatID, let chat = chats.chat(id) else {
            if pick == .mac, canOpenChatOnMac { say("Opened on \(macName)", glyph: .macbook) }
            return
        }
        switch pick {
        case .pin: setPinned(id, !chat.pinned)
        case .rename: sheet.renaming = id; sheet.renameText = chat.title
        case .delete: sheet.deleting = id
        case .unread: setUnread(id, !chat.unread)
        case .info: openChatInfo()
        case .copy:
            UIPasteboard.general.string = chat.lastAnswer.map(Self.copyText) ?? ""
            Haptics.play(.soft, reason: Haptics.Reason.copied)
            say("Copied", glyph: .squareBehindSquare1)
        case .mac: if canOpenChatOnMac { say("Opened on \(macName)", glyph: .macbook) }
        case .archive:
            if given == nil { archiveOpenChat() } else { archive(id) }
        }
    }

    /// Copy in the answer: the last answer's words.
    func copyAnswer() {
        guard let id = chatSheet.chatID, let answer = chats.chat(id)?.lastAnswer else { return }
        UIPasteboard.general.string = Self.copyText(answer)
        Haptics.play(.soft, reason: Haptics.Reason.copied)
        say("Copied", glyph: .squareBehindSquare1)
    }

    static func copyText(_ message: Message) -> String {
        if let pick = message.pick { return ([pick.head, pick.why] + pick.rows.map { $0.joined(separator: " \u{00B7} ") }).joined(separator: "\n") }
        return message.plain
    }

    // MARK: - ideas

    /// Ideas for the page in front: the prototype's for its own pages in test
    /// worlds, else the model on this iPhone, else what any page can be asked.
    func loadIdeas() {
        let sheet = chatSheet
        guard let tab = browser.tab, isFixture ? Self.hasIdeas(tab) : (!tab.isPrivate && tab.navigationURL != nil), sheet.ideas[tab.id] == nil else { return }
        if isFixture, let known = StandIns.ideas(forPage: tab.page), !(sheet.answerers.device is OnDeviceModel) {
            sheet.ideas[tab.id] = known
            return
        }
        guard let model = sheet.answerers.device as? OnDeviceModel else {
            sheet.ideas[tab.id] = StandIns.plainIdeas
            return
        }
        Task { @MainActor in
            let page = await PageText.read(tab, pool: self.pages)
            let lines = await model.ideas(about: page) ?? StandIns.plainIdeas
            withAnimation(Motion.ideaRise.current) { sheet.ideas[tab.id] = lines }
        }
    }

    /// A page worth ideas: not a private tab, a search or a chat.
    static func hasIdeas(_ tab: Tab) -> Bool {
        !tab.isPrivate && tab.page != "google" && tab.page != "blank" && tab.page != nil
    }

    // MARK: - plumbing

    /// The sheet's route on Surfaces, so the other layers know it is up.
    func route(for chat: Chat) -> Surfaces.ChatRoute {
        let sheet = chatSheet
        if sheet.fresh.contains(chat.id) { return .newChat }
        if let task = chat.task { return .task(task) }
        if sheet.mode == .answer {
            return .answer(question: chat.messages.first { $0.role == .you }?.text ?? chat.title, aboutPage: sheet.pages[chat.id] != nil)
        }
        return .chat(chat.id)
    }

    /// What Surfaces.chat should say now.
    var sheetRoute: Surfaces.ChatRoute? {
        let sheet = chatSheet
        guard sheet.shown else { return nil }
        guard let id = sheet.chatID, let chat = chats.chat(id) else { return nil }
        return route(for: chat)
    }

    func syncRoute() {
        let route = sheetRoute
        if surfaces.chat != route { surfaces.chat = route }
    }

    /// The page behind follows the sheet's pose. The chats layer draws its
    /// own scrim, over the chrome as well as the page (the prototype's scrim
    /// stands over both), so the one under the chrome stays clear.
    func syncBehind() {
        let sheet = chatSheet
        guard sheet.shown else { return }
        let geometry = SheetGeometry(screen: screenSize, pose: sheet.pose, origin: nil, now: SheetGeometry.nowShape(screen: screenSize),
                                     tray: sheet.mode == .chat)
        surfaces.recede = geometry.recede
        if surfaces.scrim != 0 { surfaces.scrim = 0 }
    }

    /// Authenticate and select Private before a retained conversation can reopen.
    private func permitPrivateChat(_ id: Chat.ID, then action: @escaping @MainActor () -> Void) -> Bool {
        guard chats.isPrivate(id), !chats.isVisible(id) else { return true }
        enterPrivateChat { [weak self] in
            guard let self, self.chats.chat(id) != nil, self.chats.isVisible(id) else { return }
            action()
        }
        return false
    }

    /// The sheet on screen, the others closed.
    private func present(_ route: Surfaces.ChatRoute, from origin: CGRect?) {
        let sheet = chatSheet
        sheet.shown = true
        surfaces.openChat(route, from: origin)
    }

    /// A chat in the card, its menus and words cleared. A quick answer or an
    /// empty new chat it replaces, not hidden in the Now line, leaves nothing.
    private func reset(_ sheet: ChatSheet, to id: Chat.ID, mode: ChatSheet.Mode) {
        sheet.navigationGeneration = UUID()
        if let previous = sheet.chatID, previous != id, chats.parked?.chat != previous,
           chats.chat(previous)?.ephemeral == true {
            forget(previous)
        }
        if sheet.chatID != id { sheet.bubbleFrames = [:] }
        sheet.chatID = id
        sheet.mode = mode
        sheet.info = false
        sheet.infoGeneration = nil
        sheet.infoReturnFocus = false
        sheet.moreMenu = false
        sheet.origin = nil
        sheet.page = nil
        sheet.pageOnScreen = false
        sheet.pageClosesOnAppear = false
        sheet.pageHandover = false
        sheet.pageLeaving = false
        sheet.draft = chats.draft(in: id)
        sheet.arrival = nil
    }

    /// Off the screen: the page comes back, nothing is in the card.
    func hideSheet() {
        let sheet = chatSheet
        var still = Transaction(animation: nil)
        still.disablesAnimations = true
        withTransaction(still) {
            sheet.page = nil
            sheet.pageOnScreen = false
            sheet.pageClosesOnAppear = false
            sheet.pageHandover = false
            sheet.pageLeaving = false
            sheet.navigationGeneration = UUID()
            sheet.shown = false
            sheet.info = false
            sheet.infoGeneration = nil
            sheet.infoReturnFocus = false
            sheet.moreMenu = false
            sheet.focused = false
            sheet.pose = SheetPose(e: 1, h: sheet.pose.h)
            surfaces.recede = 0
            surfaces.scrim = 0
            surfaces.closeChat()
        }
    }

    /// The Now line gives up what it held for what comes now: a quick answer
    /// never continued leaves nothing, as letting it go would.
    private func dropParked(keeping id: Chat.ID? = nil) {
        guard let parked = chats.parked else { return }
        if parked.chat != id, chats.chat(parked.chat)?.ephemeral == true { forget(parked.chat) }
        chats.parked = nil
    }

    /// A chat that leaves nothing: a quick answer let go.
    private func forget(_ id: Chat.ID) {
        let sheet = chatSheet
        chats.remove(id)
        sheet.fresh.remove(id)
        sheet.pages[id] = nil
        sheet.waitingForMac[id] = nil
    }

    private func fly(_ text: String, from: CGRect, fontSize: CGFloat, padding: CGFloat, bubble: Int) {
        let sheet = chatSheet
        guard !Motion.disabled else { return }
        sheet.flight = .init(text: text, from: from, fontSize: fontSize, padding: padding, bubble: bubble)
        sheet.flown = 0
        afterLayout {
            Motion.questionFly.run({ sheet.flown = 1 }, completion: {
                if sheet.flown > 0.99 { sheet.flight = nil }
            })
        }
    }

    /// What summoned the sheet, as the shape it grows out of: its rect, its
    /// corners as round as it is (at most `radius`).
    static func originShape(_ rect: CGRect, radius: CGFloat = Metrics.Chat.originRadius) -> SheetShape {
        let r = min(radius, rect.height / 2)
        return SheetShape(rect: rect, top: r, bottom: r)
    }

    /// Runs `body` once the views have laid out what was just changed.
    func afterLayout(_ body: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(16))
            body()
        }
    }

    // The screen the sheet lays out on: AppModel.screenSize (Field/FieldActions).

    /// The plate's field: where an answer grows from when the field didn't say.
    static func plateFieldFrame(screen: CGSize) -> CGRect {
        CGRect(x: Metrics.Edge.bar, y: screen.height - Metrics.Field.keyboard - Metrics.Field.aboveKeyboard - Metrics.Field.height,
               width: screen.width - Metrics.Edge.bar * 2, height: Metrics.Field.height)
    }
}

/// The newest words coming in: from which turn, and how far in they are.
struct Arrival: Equatable {
    var from: Int
    var shown: Double
}

extension Haptics.Reason {
    static let send = "send"
    static let letGo = "let go"
    static let pin = "pin"
    static let unread = "unread"
    static let archive = "archive"
    static let openOnMac = "open on mac"
}
