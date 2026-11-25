import AppKit
import WebKit
import SyncKit

// Bench.agentCommand's verbs (AgentBench). Sessions: attaching, tasks
// started, followed, steered and stopped, folders and Mac access, the app
// itself.

extension Bench {
    static let sessionsVerbs: [String: AgentHandler] = [
        "agent-fixture-control": { $0.handleAgentFixtureControl($1) },
        "agent-caps": { $0.handleAgentCaps($1) },
        "agent-folder-access-recheck": { $0.handleAgentFolderAccessRecheck($1) },
        "agent-spawn": { $0.handleAgentSpawn($1) },
        "agent-resume": { $0.handleAgentSpawn($1) },
        "agent-name": { $0.handleAgentName($1) },
        "agent-file": { $0.handleAgentFile($1) },
        "agent-attach": { $0.handleAgentAttach($1) },
        "agent-computer": { $0.handleAgentComputer($1) },
        "agent-folder-access": { $0.handleAgentFolderAccess($1) },
        "agent-chat": { $0.handleAgentChat($1) },
        "agent-detach": { $0.handleAgentDetach($1) },
        "app-status": { $0.handleAppStatus($1) },
        "app-serve": { $0.handleAppServe($1) },
        "app-import": { $0.handleAppImport($1) },
        "app-quit": { $0.handleAppQuit($1) },
        "agent-run": { $0.handleAgentRun($1) },
        "agent-task": { $0.handleAgentTask($1) },
        "agent-page-ask": { $0.handleAgentPageAsk($1) },
        "agent-wait": { $0.handleAgentWait($1) },
        "agent-steer": { $0.handleAgentSteer($1) },
        "agent-queue": { $0.handleAgentQueue($1) },
        "agent-stop": { $0.handleAgentStop($1) },
        "agents": { $0.handleAgents($1) },
    ]

    func handleAgentCaps(_ c: AgentCall) {
        let browser = c.browser
        let answer = c.answer
        let agents = c.agents
        let session = c.session
        // An assistant in the cloud's, or a task one started: what it may do.
        let mine = agents.assistant(of: session).map { AgentCapabilityCache.Assistant.read($0, browser: browser) }
        // Another app's agent through `yab mcp` gets mail tools only once the
        // person gave them to other apps (MailConsent.others).
        // Yab's own chat gets them with Mail you hand to Claude off too: its
        // first call asks the chat for the person's yes (Bench.mailAsks),
        // rather than the agent going to Gmail's pages for want of them.
        let asker = session.flatMap { agents.session($0) }
        let own = asker != nil && asker?.cli != "external"
        let mailHere = !agents.offMail(session)
            && (own || (MailCenter.agentsAllowed && (MailConsent.others || Store.testing)))
        // Getting to know the user: only then its own two tools.
        let state = AgentCapabilityCache.State(folder: Routines.shared.running(session)?.folder == true, boost: Boosts.shared.mayCreate(session: session),
                messages: browser.prefs.agentsMessages, mail: browser.prefs.mailCodes,
                // With Mail on, before any account is in too:
                // an agent setting one up needs mail_probe (docs/mail-providers.md, M3).
                mailbox: (MailCenter.shared.connected || MailExperiment.otherAccounts()) && mailHere,
                // Mail on, or an account in: mail_accounts connects one.
                mailAgents: (MailExperiment.enabled() || MailCenter.shared.connected) && mailHere && MailCenter.agentsAllowed,
                recall: MailRecall.wanted && mailHere,
                asking: browser.prefs.asking(session).rawValue, knowing: agents.session(session)?.knowing == true,
                assistant: mine)
        answer(agentCapabilities.answer(session: session, state: state))
    }

    func handleAgentFolderAccessRecheck(_ c: AgentCall) {
        let answer = c.answer
        // Back in Yab, as far as the closed-folder lines know, a --test run only.
        guard Store.testing else { answer(["error": "agent-folder-access-recheck only works on a --test run"]); return }
        FolderAccess.shared.recheck()
        answer(["ok": true])
    }

    func handleAgentSpawn(_ c: AgentCall) {
        let verb = c.verb
        let request = c.request
        let answer = c.answer
        let agents = c.agents
        let session = c.session
        let (made, trouble) = verb == "agent-spawn"
            ? agents.spawn(from: session ?? "", prompt: request["prompt"] as? String ?? "", profile: request["profile"] as? String ?? "default", name: request["name"] as? String,
                           minutes: request["minutes"] as? Double)
            : agents.resume(request["id"] as? String ?? "", from: session ?? "", prompt: request["prompt"] as? String ?? "", minutes: request["minutes"] as? Double)
        if let made { answer(["session": made.id, "name": made.name, "profile": made.profile]) } else { answer(["error": trouble ?? "could not start"]) }
    }

    func handleAgentName(_ c: AgentCall) {
        let request = c.request
        let answer = c.answer
        let agents = c.agents
        let session = c.session
        guard let root = agents.session(agents.root(of: session)) else { answer(["error": "no session"]); return }
        let words = (request["name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        // A routine's run keeps the routine's name: its chat is all its
        // runs. Work out of sight keeps Yab's own for it.
        if root.routine == nil, !root.sealed { root.title = words.isEmpty ? nil : String(words.prefix(40)) }
        let progress = (request["progress"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !progress.isEmpty, root.state.live { root.progress = String(progress.prefix(24)) }
        agents.objectWillChange.send()
        answer(["ok": true])
    }

    func handleAgentFile(_ c: AgentCall) {
        let request = c.request
        let browser = c.browser
        let answer = c.answer
        let agents = c.agents
        // An agent's new tab goes beside its task's others.
        guard let tab = find(request, in: browser) else { answer(missing(request)); return }
        Folders.shared.file(tab, in: browser)
        // A second tab makes a folder: said, so an agent that hasn't
        // named its task yet does.
        let root = agents.root(of: tab.agent)
        let many = browser.tabs.filter { $0.bench && $0.agent != nil && agents.root(of: $0.agent) == root }.count > 1
        answer(["ok": true, "unnamed": many && agents.session(root)?.title == nil && agents.session(root)?.sealed != true])
    }

    func handleAgentAttach(_ c: AgentCall) {
        let request = c.request
        let answer = c.answer
        let agents = c.agents
        let made = agents.attach(name: request["name"] as? String ?? "agent", client: request["client"] as? String)
        if request["mail"] as? Bool == true { made.mail = true }
        // Working for an assistant in the cloud (a --test run's grant):
        // its tabs stay in the grant's space instead of going with you.
        if Store.testing, let assistant = request["assistant"] as? String { made.assistant = assistant }
        answer(["session": made.id])
    }

    func handleAgentComputer(_ c: AgentCall) {
        let request = c.request
        let browser = c.browser
        let answer = c.answer
        let agents = c.agents
        let session = c.session
        guard let task = agents.session(session), task.cli != "external", task.parent == nil, task.state.live else {
            answer(["error": "only a running Yab task can request Mac access"])
            return
        }
        if task.full { answer(["full": true]); return }
        if task.macAccessDenied {
            answer(["error": "the person did not allow Mac access for this task; continue in the browser"])
            return
        }
        if browser.prefs.agentsAsking == .bypass {
            agents.allowMacAccess(task)
            answer(["full": true, "restarting": true])
            return
        }
        guard let tab = agents.askTab(for: task.id, in: browser) else { answer(["error": "no tab to ask in"]); return }
        if tab.permit != nil || tab.handoff != nil {
            answer(["error": "another question is waiting in that tab; try again in a moment"])
            return
        }
        let reason = (request["reason"] as? String ?? "This task needs files or the terminal")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        agents.ask(tab, AgentPermit(kind: .computer, session: task.id,
                                    detail: "Files and terminal for this task. " + String(reason.prefix(100))))
        agents.showAsk(tab, session: task.id, in: browser)
        agents.note(task, "Waiting for Mac access")
        answer(["error": "asking the person for Mac access", "asking": true, "tab": Bench.short(tab)])
    }

    func handleAgentFolderAccess(_ c: AgentCall) {
        let request = c.request
        let browser = c.browser
        let answer = c.answer
        let agents = c.agents
        let session = c.session
        // A folder macOS keeps closed (FolderAccess): read again by Yab,
        // and asked for at the chat's foot only if that fails too.
        guard let task = agents.session(session), task.cli != "external", task.parent == nil, task.state.live else {
            answer(["error": "only a running Yab task can ask for a folder; tell the parent task what it needs"])
            return
        }
        guard task.full else {
            answer(["error": "this task has no Mac access yet: call computer_access first"])
            return
        }
        Task {
            answer(await FolderAccess.shared.request(task, path: request["path"] as? String ?? "",
                                                     reason: request["reason"] as? String ?? "", browser: browser))
        }
    }

    func handleAgentChat(_ c: AgentCall) {
        let request = c.request
        let browser = c.browser
        let answer = c.answer
        let agents = c.agents
        // A kept chat is named by "chat": it is no running task, so as
        // "session" the bench's preflight turns it away.
        let session = request["chat"] as? String ?? c.session
        // The chat column (ChatColumn.swift): out with a session's chat,
        // or away; what it shows.
        var hit: [String] = []
        switch request["action"] as? String {
        case "show": browser.showChat(session)
        case "hide": browser.moveChat(open: false)
        case "pin": browser.chatPinned = session
        case "expand": browser.expandAnswer()
        case "width":
            browser.chatWidth = CGFloat(request["width"] as? Double ?? Double(ChatLook.normal))
            browser.settleChatWidth()
        case "menu": browser.chatAttach.menu.toggle()
        case "history": browser.chatHistory.toggle()
        case "new": browser.newChat()
        // Projects of chats (ChatProjectScreen): open one, close it, its
        // card, a new chat in it, and what they all hold now.
        case "project": browser.openProject(request["id"] as? String)
        case "chats": browser.chatHistory = true
        case "project-close":
            browser.chatProjectSheet = false
            ActionMenu.close()
            ChatSwipe.shared.shut()
            ChatBanners.shared.dismiss()
            if browser.fieldShowing { browser.close() }
            browser.openProject(nil)
        case "project-info": browser.chatProjectInfo = true
        case "project-sheet":
            ChatNewProjectSheet.preset = Set(request["chats"] as? [String] ?? [])
            ChatNewProjectSheet.presetChoosing = request["emoji"] as? Bool ?? false
            browser.chatProjectSheet = true
        case "project-create":
            // As New Project's Create makes one, with the chats ticked.
            let made = ChatNewProjectSheet.make(name: request["name"] as? String ?? "", emoji: request["emoji"] as? String ?? "",
                                                tint: request["tint"] as? String, instructions: request["instructions"] as? String ?? "",
                                                chats: request["chats"] as? [String] ?? [], browser: browser)
            answer(["id": made.id, "pinned": made.pinned])
            return
        case "project-delete":
            browser.openProject(nil)
            Projects.shared.delete(request["id"] as? String ?? "")
        case "project-banner":
            // A routine's news as its finished run shows it (Routines.finished).
            guard let routine = Routines.shared.all.first(where: { $0.id == request["id"] as? String }), let chat = routine.chat,
                  let kept = Chats.shared.chat(chat) else { answer(["error": "no such routine with a chat"]); return }
            ChatBanners.shared.show(.init(chat: chat, project: routine.project, title: routine.name,
                                          body: TaskAnswer.pick(kept.answer) ?? kept.answer))
        case "project-banner-open":
            if let banner = ChatBanners.shared.shown { ChatBanners.shared.dismiss(); browser.showChat(banner.chat) }
        case "project-field":
            // ⌘T's Chats with words typed, its rows as listed, and, with
            // "run", the first row's action ("open" ↩, "copy" ⌘↩).
            browser.openPlace(.chats, words: request["text"] as? String ?? "")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                let rows = browser.placeItems.prefix(6).map { ["id": $0.id, "title": $0.title, "section": $0.section] }
                var ran = false
                if let run = request["run"] as? String { ran = browser.runAction(run) }
                answer(["rows": Array(rows), "ran": ran, "shown": browser.chatProject ?? "", "newProject": browser.chatNewProject ?? ""])
            }
            return
        case "project-pin": Projects.shared.pin(request["id"] as? String ?? "", request["on"] as? Bool ?? true)
        case "project-new-chat": browser.newChat(in: request["id"] as? String ?? "")
        case "project-move":
            // A chat into a project the ways a hand does it: "key" presses
            // ⌃⌘P and picks the project's line in the menu it shows,
            // "drop" lets the chat's row go over the project's circle,
            // "menu" is the right click's line, "out" takes it out.
            let id = request["id"] as? String ?? ""
            let chat = session ?? ""
            switch request["via"] as? String {
            case "key":
                guard let window = Links.window,
                      let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.control, .command],
                                                   timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                   context: nil, characters: "p", charactersIgnoringModifiers: "p", isARepeat: false, keyCode: 35)
                else { answer(["error": "no window"]); return }
                NSApp.sendEvent(event)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    let shown = ActionMenu.state()
                    // Kept out for a picture of it, or its line taken.
                    if request["keep"] as? Bool != true {
                        ActionMenu.bench(type: nil, take: Projects.shared.project(id)?.name, key: nil)
                        ActionMenu.close()
                    }
                    answer(["menu": shown, "project": Chats.shared.chat(chat)?.project ?? ""])
                }
                return
            case "drop":
                guard let kept = Chats.shared.chat(chat) else { answer(["error": "no such chat"]); return }
                _ = ChatMoves.drop([ChatMoves.dragged(kept)], on: id)
            case "out": ChatMoves.move([chat], to: nil)
            default: ChatMoves.move([chat], to: id)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                answer(["project": Chats.shared.chat(chat)?.project ?? ""])
            }
            return
        case "project-swipe": ChatSwipe.shared.open(session ?? "")
        case "projects":
            answer(["projects": Projects.shared.all.map { project -> [String: Any] in
                        ["id": project.id, "name": project.name, "emoji": project.emoji, "pinned": project.pinned,
                         "order": project.order, "archived": project.archived == true, "instructions": project.instructions,
                         "memoryOn": project.memoryOn]
                    },
                    "chats": Dictionary(Chats.shared.all.map { ($0.id, $0.project ?? "") }, uniquingKeysWith: { a, _ in a }),
                    "shown": browser.chatProject ?? "", "info": browser.chatProjectInfo, "sheet": browser.chatProjectSheet,
                    "history": browser.chatHistory, "chat": browser.chatID ?? "", "newProject": browser.chatNewProject ?? ""])
            return
        case "attach":
            if let path = request["path"] as? String {
                browser.chatAttach.add(files: [URL(fileURLWithPath: path)], chat: Chats.shared.chat(browser.chatID), browser: browser)
            }
        case "paste":
            // ⌘V with the field's keys, as the window's key handler takes
            // it (ContentView.take): files or a picture to chips, else the
            // field's own Paste.
            let taken = browser.chatOpen && browser.chatAttach.typing && Links.window?.firstResponder is NSTextView
                && browser.chatAttach.paste(from: .general, chat: Chats.shared.chat(browser.chatID), browser: browser)
            if !taken { NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil) }
        case "model":
            guard Store.testing else { answer(["error": "model selection probe only works on a --test run"]); return }
            ChatModelLine.choose(browser: browser, chat: nil)
            browser.modelPicker?.pick(ModelChoice(cli: request["cli"] as? String,
                                                  model: request["model"] as? String,
                                                  effort: request["effort"] as? String))
            browser.modelPicker = nil
        case "agent":
            // The agent a new chat goes to: "claude" or "codex".
            browser.chatNext = ModelChoice(cli: request["cli"] as? String)
        case "drop": browser.chatDropShown.toggle()
        case "keep": Chats.shared.pin(session ?? "", request["on"] as? Bool ?? true)
        case "archive": Chats.shared.archive(session ?? "", request["on"] as? Bool ?? true)
        case "archived": browser.chatArchive.toggle()
        case "type":
            // Into the column's field, a letter at a time, as the keys put them.
            browser.chatFocus += 1
            let text = request["text"] as? String ?? ""
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                guard let editor = Links.window?.firstResponder as? NSTextView else { return }
                for letter in text { editor.insertText(String(letter), replacementRange: editor.selectedRange()) }
            }
        case "keys":
            // Into whatever has the keys now, the + menu's search say,
            // without moving them: words, then commands ("moveDown:").
            if let editor = Links.window?.firstResponder as? NSTextView {
                if let text = request["text"] as? String { editor.insertText(text, replacementRange: editor.selectedRange()) }
                for command in request["commands"] as? [String] ?? [] { editor.doCommand(by: NSSelectorFromString(command)) }
            }
        case "mark":
            // Words an input method is composing, Kana before a candidate is
            // picked, into whatever has the keys: marked text, not yet the
            // field's. With "commit", the candidate `text` takes their place.
            if let editor = Links.window?.firstResponder as? NSTextView {
                let text = request["text"] as? String ?? ""
                if request["commit"] as? Bool == true {
                    editor.insertText(text, replacementRange: editor.markedRange())
                } else {
                    editor.setMarkedText(text, selectedRange: NSRange(location: (text as NSString).length, length: 0),
                                         replacementRange: NSRange(location: NSNotFound, length: 0))
                }
            }
            answer(["composing": InputMethod.Marking.shared.composing,
                    "marked": InputMethod.composing(Links.window?.firstResponder)])
            return
        case "return":
            // Return in whatever has the keys, the column's field say, as
            // the key itself: a key event handed to the window, so the
            // field sends as it would for you (and the words fly).
            if let window = Links.window,
               let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: request["command"] as? Bool == true ? .command : [],
                                            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                            context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36) {
                window.sendEvent(event)
            }
        case "send-now":
            // A queued row's Send Now, by its place in the queue.
            agents.sendNow(session ?? "", at: request["index"] as? Int ?? 0)
        case "escape":
            // Esc in whatever has the keys, as the key itself.
            if let window = Links.window,
               let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                            context: nil, characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}", isARepeat: false, keyCode: 53) {
                window.sendEvent(event)
            }
        case "scroll":
            // The wheel over the column's middle, as a mouse's, by points:
            // up (+) or down (-). Its hand, not the turns, moves the scroll.
            if let window = Links.window, let content = window.contentView,
               let wheel = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                   wheel1: Int32(request["by"] as? Int ?? 120), wheel2: 0, wheel3: 0) {
                let inside = NSPoint(x: content.bounds.maxX - ChatLook.width / 2 - 12, y: content.bounds.midY)
                let screen = window.convertPoint(toScreen: content.convert(inside, to: nil))
                let top = NSScreen.screens.first?.frame.maxY ?? 0
                wheel.location = CGPoint(x: screen.x, y: top - screen.y)
                wheel.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window.windowNumber))
                wheel.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(window.windowNumber))
                if let event = NSEvent(cgEvent: wheel) { window.sendEvent(event) }
            }
        case "field":
            // The field being typed in (FieldWheel): how far its words are
            // scrolled, how tall they are and how much of them it shows.
            answer(Bench.fieldState())
            return
        case "field-scroll":
            // A scroll over the middle of the field being typed in, by
            // points, up (+) or down (-): a mouse's wheel, its lines, or
            // two fingers, began, `steps` moves a frame apart, ended.
            let by = request["by"] as? Double ?? 60
            let steps = max(1, request["steps"] as? Int ?? 6)
            let fingers = request["kind"] as? String == "fingers"
            Bench.fieldScroll(by: by, steps: steps, fingers: fingers)
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(steps + 2) / 60 + 0.3) { answer(Bench.fieldState()) }
            return
        case "blur":
            NSApp.deactivate()
        case "page-keys":
            // The keys to the page in front, as a click on it gives them.
            if let web = browser.active?.page { web.window?.makeFirstResponder(web) }
        case "press":
            // A click of the mouse in the column's field, as mouse events
            // handed to the window: `at` is where in its glass, by fractions
            // of its width and height from its top left ([0.5, 0.5] its middle).
            guard let window = browser.chatColumnView?.window else { answer(["error": "no column"]); return }
            let at = request["at"] as? [Double] ?? [0.5, 0.5]
            let glass = ChatComposer.glassInWindow(window, browser.chatAttach.glass)
            let point = CGPoint(x: glass.minX + glass.width * at[0], y: glass.maxY - glass.height * at[1])
            var chain: [String] = []
            var view = window.contentView?.superview?.hitTest(point)
            while let v = view, chain.count < 12 { chain.append(String(describing: Swift.type(of: v))); view = v.superview }
            hit = chain
            // Cold: as a click from another app, Yab not in front.
            if request["cold"] as? Bool != true {
                NSApp.activate()
                window.makeKeyAndOrderFront(nil)
            }
            func event(_ type: NSEvent.EventType) -> NSEvent? {
                NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                   timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                   context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)
            }
            // Into the app's queue, as the Mac hands a click over: through
            // NSApp.sendEvent and its monitors, the window's after. Both
            // queued, as a text field's press tracks the mouse until the
            // let-go comes, inside its mouseDown.
            if let down = event(.leftMouseDown), let up = event(.leftMouseUp) {
                NSApp.postEvent(down, atStart: false)
                NSApp.postEvent(up, atStart: false)
            }
        case "follow": agents.followUp(session ?? "", request["text"] as? String ?? "")
        case "edit":
            // Edit under one of your messages (its item), as the button does.
            if let id = session, let item = Chats.shared.chat(id)?.items.first(where: { $0.id == request["item"] as? String }) {
                browser.editChat(id, item)
            }
        default: break
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            let chat = Chats.shared.chat(browser.chatID)
            // Who has the keys in the window: a field's editor by the field it edits.
            let responder = Links.window?.firstResponder
            let keys = (responder as? NSTextView)?.delegate.map { "\(type(of: $0))" } ?? responder.map { "\(type(of: $0))" } ?? ""
            // The real Tab probe distinguishes an editor or page from a
            // SwiftUI button, including a hidden tab close target. Class names
            // alone cannot say which hosting subtree currently holds the keys.
            let keyView = responder as? NSView
            var keyChain: [String] = []
            var ancestor = keyView
            while let view = ancestor, keyChain.count < 20 {
                keyChain.append("\(type(of: view))")
                ancestor = view.superview
            }
            let keyInPage = browser.active?.built.map { keyView?.isDescendant(of: $0) == true } ?? false
            let current = browser.chatAttach.current(chat: chat, browser: browser)
            let files = current.compactMap(\.file?.path)
            answer(["provider": browser.chatAgent, "shownProvider": chat?.cli ?? browser.chatAgent, "model": browser.chatChoice.model ?? "",
                    "defaultProvider": ModelDefaults.shared[.chats].cli ?? "",
                    "keyChain": keyChain, "keyInPage": keyInPage,
                    "keyIsText": responder is NSTextView || responder is NSTextField,
                    "keyIsWindow": responder === Links.window,
                    "keys": keys, "files": files, "attached": current.map(\.id), "menu": browser.chatAttach.menu, "open": browser.chatOpen, "moving": browser.chatMoving, "chat": browser.chatID ?? "",
                    "title": chat?.title ?? "", "turns": chat?.turns.count ?? 0, "chats": Chats.shared.all.count,
                    "editing": browser.chatEditing?.item ?? "", "typing": browser.chatAttach.typing, "appActive": NSApp.isActive, "windowKey": browser.chatColumnView?.window?.isKeyWindow ?? false,
                    "hit": hit, "inColumn": (responder as? NSView).map { $0.isDescendant(of: browser.chatColumnView ?? NSView()) } ?? false, "glass": [browser.chatAttach.glass.minX, browser.chatAttach.glass.minY, browser.chatAttach.glass.width, browser.chatAttach.glass.height]])
        }
    }

    func handleAgentDetach(_ c: AgentCall) {
        let answer = c.answer
        let agents = c.agents
        let session = c.session
        if let after = c.request["after"] as? Double, let session {
            agents.leave(session, for: min(max(after, 1), Mcp.keptFor))
        } else {
            agents.detach(session ?? "")
        }
        answer(["ok": true])
    }

    func handleAppStatus(_ c: AgentCall) {
        let answer = c.answer
        answer(Headless.status)
    }

    func handleAppServe(_ c: AgentCall) {
        let request = c.request
        let answer = c.answer
        // Kept for good from now on (`yab serve` finding one running).
        Headless.serving = true
        SyncCenter.shared.launchIfNeeded()
        // Nobody at this Mac is for a hidden one: an open Yab has its person.
        if request["nobody"] as? Bool == true, Headless.hidden { Headless.nobody = true }
        answer(Headless.status)
    }

    func handleAppImport(_ c: AgentCall) {
        let request = c.request
        let browser = c.browser
        let answer = c.answer
        // Another browser's sign-ins, its passwords and its cookies, for
        // someone who uses Yab from a terminal (`yab import`). Anything
        // on this Mac can type a command, so the yes is Yab's own card,
        // in its window, pressed by a hand; then macOS asks for the other
        // browser's key.
        let installed = Chromium.installed()
        guard let name = request["source"] as? String, !name.isEmpty else {
            answer(["browsers": installed.map(\.name)])
            return
        }
        // Its name, or the start of it: "chrome" is Chrome Beta when that
        // is the Chrome there is.
        let asked = name.lowercased()
        guard let source = installed.first(where: { $0.name.lowercased() == asked })
                ?? installed.first(where: { $0.name.lowercased().hasPrefix(asked) }) else {
            answer(["error": "no browser \(name) on this Mac; there are: \(installed.map(\.name).joined(separator: ", "))"])
            return
        }
        if request["check"] as? Bool == true { answer(["source": source.name]); return }
        Headless.show(.person)
        Links.showBrowser()
        NSApp.activate()
        Task { @MainActor in
            let yes = await Questions.shared.ask(Question(
                title: "Bring in \(source.name)’s sign-ins?",
                detail: "Its passwords and cookies, for you and for the agents working in \(Links.appName).",
                icon: NSApp.applicationIconImage, ownIcon: true, yes: "Bring In"))
            guard yes else { answer(["error": "Not brought in: the answer in Yab was no."]); return }
            let source = source.authorizingImport()
            DispatchQueue.global(qos: .userInitiated).async {
                let read = Result { try Chromium.read(source) }
                let passwords = (try? read.get()).map { Vault.take($0) }
                DispatchQueue.main.async {
                    browser.takeCookies(from: source) { cookies in
                        var said: [String: Any] = ["source": source.name, "cookies": cookies, "passwords": passwords ?? 0]
                        if case .failure(Chromium.Trouble.noPassphrase) = read { said["trouble"] = "macOS was asked for \(source.name)'s key and it was turned down" }
                        else if case .failure = read { said["trouble"] = "\(source.name)'s passwords couldn't be read: quit it and try again" }
                        answer(said)
                    }
                }
            }
        }
    }

    func handleAppQuit(_ c: AgentCall) {
        let request = c.request
        let answer = c.answer
        let agents = c.agents
        // Only a yab nobody opened: one someone is using quits from
        // its own menu.
        guard Headless.hidden else { answer(["error": "Yab is open, and someone may be using it: quit it from Yab itself"]); return }
        let working = agents.sessions.filter(\.atWork)
        if !working.isEmpty, request["force"] as? Bool != true {
            answer(["error": "\(working.count == 1 ? "a task is" : "\(working.count) tasks are") still working, and quitting stops \(working.count == 1 ? "it" : "them"): `\(AgentSetup.command) quit --force`, or wait"])
            return
        }
        answer(["ok": true])
        DispatchQueue.main.async { Headless.leave() }
    }

    func handleAgentRun(_ c: AgentCall) {
        let request = c.request
        let answer = c.answer
        let agents = c.agents
        guard let prompt = request["prompt"] as? String, !prompt.isEmpty else { answer(["error": "agent-run needs a prompt"]); return }
        let cli = request["cli"] as? String
        guard cli == nil || AgentSetupModel.clis.contains(cli!) else { answer(["error": "cli is claude, codex, cursor or gemini"]); return }
        let access = request["access"] as? String
        guard access == nil || access == "browser" || access == "full" else { answer(["error": "access is browser or full"]); return }
        let person = request["person"] as? String
        guard person == nil || ["app", "tty", "caller", "none"].contains(person ?? "") else { answer(["error": "person is app, tty, caller or none"]); return }
        // An agent asked for by name stays that agent, room or not.
        let made = agents.run(prompt: prompt, cli: cli, model: request["model"] as? String, effort: request["effort"] as? String,
                              access: access, folder: request["folder"] as? String, resume: request["resume"] as? String, person: person,
                              strict: cli != nil, background: request["background"] as? Bool == true)
        // Started by an assistant in the cloud: its task, held as it is.
        if let assistant = request["assistant"] as? String { made.assistant = assistant }
        // A start refused (an AI not connected in this world) never joins the
        // sessions: say why now, not "no longer available" on the next call.
        if agents.session(made.id) == nil, !made.state.live { answer(["error": made.result.isEmpty ? "agent-run was refused" : made.result]); return }
        answer(["session": made.id, "cli": made.cli])
    }

    /// Words as the chat's composer sends them, in the space on screen
    /// (Agents.task, so with its framing and space line), for evals: a test
    /// run's only.
    func handleAgentTask(_ c: AgentCall) {
        guard Store.testing else { c.answer(["error": "agent-task only works on a --test run"]); return }
        guard let words = c.request["words"] as? String, !words.isEmpty else { c.answer(["error": "agent-task needs words"]); return }
        guard let made = c.agents.task(words, context: [], on: nil, in: c.browser) else { c.answer(["error": "not started"]); return }
        c.answer(["session": made.id, "cli": made.cli, "space": c.browser.space.name, "prompt": made.prompt])
    }

    /// ⌘J's line or the chat column brought up on the page in front (no
    /// words), then words sent from it, as a person asks about a page:
    /// evals/page-answer times the answer's first word. A --test run only.
    func handleAgentPageAsk(_ c: AgentCall) {
        guard Store.testing else { c.answer(["error": "agent-page-ask only works on a --test run"]); return }
        guard let tab = c.browser.active else { c.answer(["error": "no tab in front"]); return }
        if c.request["how"] as? String == "hide" { c.browser.moveChat(open: false); c.answer(["ok": true]); return }
        let chat = c.request["how"] as? String == "chat"
        let words = c.request["words"] as? String ?? ""
        if words.isEmpty {
            if c.request["how"] as? String == "shortcut" {
                c.browser.prefs.askOpens = c.request["view"] as? String == "chat" ? .chat : .line
                TaskLine.shared.open(on: tab)
            } else if chat {
                c.browser.askInChat(about: tab)
            } else {
                c.browser.prefs.askOpens = .line
                TaskLine.shared.open(on: tab)
            }
            c.answer(["ok": true])
            return
        }
        let before = Set(c.agents.sessions.map(\.id))
        if chat {
            ChatComposer.begin(words, with: c.browser.chatAttach.current(chat: nil, browser: c.browser), in: c.browser)
        } else {
            TaskLine.shared.words = words
            TaskLine.shared.run(on: tab)
        }
        guard let made = c.agents.sessions.first(where: { !before.contains($0.id) }) else { c.answer(["error": "not started"]); return }
        c.answer(["session": made.id, "prompt": made.prompt])
    }

    func handleAgentWait(_ c: AgentCall) {
        let request = c.request
        let browser = c.browser
        let answer = c.answer
        let agents = c.agents
        let session = c.session
        guard let found = agents.session(session) else { answer(["error": "no session \(session ?? "")"]); return }
        let after = request["after"] as? Int ?? -1
        func report() {
            var out: [String: Any] = [
                "session": found.id, "state": found.state.rawValue, "now": found.now,
                "result": found.state.live ? "" : found.result, "seen": found.events.count,
                // Its steps as the chat will show them (ChatItem).
                "items": found.items.suffix(24).map { "\($0.kind.rawValue) \($0.state.rawValue) \($0.name) \($0.detail.prefix(60))" },
                // Every step's line as the chat's rows say it (StepWords).
                "steps": found.items.filter { [.tool, .command, .edit, .subagent].contains($0.kind) }.map { item in
                    let words = StepWords.of(item)
                    return ["tool": item.name, "line": words.line(item.state), "state": item.state.rawValue, "quiet": words.quiet,
                            "error": item.state == .failed ? String(item.text.prefix(400)) : ""] as [String: Any]
                },
            ]
            if after >= 0 { out["events"] = Array(found.events.dropFirst(after)) }
            // When each step began, from the session's start (evals/page-answer).
            if request["timeline"] as? Bool == true {
                out["began"] = found.began.timeIntervalSince1970
                out["timeline"] = found.items.compactMap { item -> [String: Any]? in
                    item.began.map { ["kind": item.kind.rawValue, "name": item.name, "ms": Int($0.timeIntervalSince(found.began) * 1000)] }
                }
            }
            // What it waits on a person for: a pick (answerable where the
            // task was started), hands in a page, or a yes; on a tab of
            // its own or one of yours it was let into.
            let everyone = browser.everyTab
            if let tab = everyone.first(where: { $0.handoff != nil && ($0.id == found.asking || $0.guest == found.id || $0.permit?.session == found.id) })
                ?? agents.tabs(of: found).first(where: { $0.handoff != nil }) {
                out["needs"] = tab.handoff
                out["needs_kind"] = tab.permit != nil ? "yes" : tab.id == found.asking ? "pick" : "hands"
                if tab.id == found.asking, !tab.choices.isEmpty { out["choices"] = tab.choices }
            }
            if !found.state.live, let asked = found.question { out["asked"] = asked }
            if let failure = found.archiveError { out["archive_error"] = failure }
            // Its parent has its answer now.
            if request["report"] as? Bool == true, !found.state.live { found.reported = true }
            answer(out)
        }
        // Something new already, or over: say so now. Otherwise hold on.
        if !found.state.live || (after >= 0 && found.events.count > after) {
            report()
        } else {
            agents.wait(found.id, seconds: request["seconds"] as? Double ?? 20) { report() }
        }
    }

    func handleAgentSteer(_ c: AgentCall) {
        let request = c.request
        let answer = c.answer
        let agents = c.agents
        let session = c.session
        let trouble = agents.steer(session ?? "", request["text"] as? String ?? "")
        answer(trouble.map { ["error": $0] } ?? ["ok": true])
    }

    func handleAgentQueue(_ c: AgentCall) {
        let request = c.request
        let answer = c.answer
        let agents = c.agents
        let session = c.session
        guard agents.session(session) != nil else { answer(["error": "no session \(session ?? "")"]); return }
        agents.queue(session ?? "", request["text"] as? String ?? "")
        answer(["ok": true])
    }

    func handleAgentStop(_ c: AgentCall) {
        let answer = c.answer
        let agents = c.agents
        let session = c.session
        answer(agents.stop(session ?? "") ? ["ok": true] : ["error": "no running session \(session ?? "")"])
    }

    func handleAgents(_ c: AgentCall) {
        let browser = c.browser
        let answer = c.answer
        let agents = c.agents
        answer(["agents": agents.sessions.map { found -> [String: Any] in
            // What it has done so far, for an eval to hold it to: its
            // tool calls by name, your tabs it is in, and what waits on you.
            let tools = Dictionary(grouping: found.items.filter { $0.kind == .tool }, by: \.name).mapValues(\.count)
            let iso = ISO8601DateFormatter()
            let finished: Any = (found.state.live ? nil : found.ended).map { iso.string(from: $0) } ?? NSNull()
            return ["session": found.id, "name": found.name, "cli": found.cli, "state": found.state.rawValue, "now": found.now,
                    "title": found.title ?? Chat.title(from: found.prompt), "started": iso.string(from: found.began),
                    "finished": finished,
                    "waiting": found.state == .waiting,
                    "prompt": found.prompt, "tabs": agents.tabs(of: found).map(Bench.short),
                    "parent": found.parent ?? "", "reported": found.reported, "profile": found.profile,
                    "sealed": found.sealed, "knowing": found.knowing, "tools": tools,
                    "guests": browser.everyTab.filter { $0.guest == found.id }.map(Bench.short),
                    "handoffs": browser.everyTab.filter { $0.handoff != nil && $0.worker == found.id }.map(Bench.short)]
        }])
    }
}

// The field being typed in, for the bench (agent-chat "field",
// "field-scroll"): FieldWheel's evidence.
extension Bench {
    @MainActor static func fieldState() -> [String: Any] {
        func chain(_ from: NSView?) -> [String] {
            var names: [String] = []
            var view = from
            while let each = view, names.count < 6 { names.append("\(type(of: each))"); view = each.superview }
            return names
        }
        guard let window = Links.window, let (editor, clip, field) = FieldWheel.editing(window) else {
            let responder = Links.window?.firstResponder
            return ["editing": false, "keys": responder.map { "\(type(of: $0))" } ?? "", "chain": chain(responder as? NSView)]
        }
        let frame = field.convert(field.bounds, to: nil)
        func r(_ v: CGFloat) -> Double { (Double(v) * 10).rounded() / 10 }
        // Which words are in sight: the characters at the field's top left
        // and bottom left, whatever moves them.
        return ["editing": true, "length": editor.string.count, "caret": editor.selectedRange().location,
                "top": editor.characterIndex(for: window.convertPoint(toScreen: NSPoint(x: frame.minX + 8, y: frame.maxY - 6))),
                "bottom": editor.characterIndex(for: window.convertPoint(toScreen: NSPoint(x: frame.minX + 8, y: frame.minY + 6))),
                "y": r(clip.bounds.origin.y), "room": r(FieldWheel.room(editor, clip)), "shown": r(clip.bounds.height),
                "tall": r(editor.frame.height), "words_h": r(editor.textLayoutManager?.usageBoundsForTextContainer.height ?? -1),
                "chain": chain(editor), "field": [r(frame.minX), r(frame.minY), r(frame.width), r(frame.height)]]
    }

    /// Scroll events over the middle of the field being typed in, posted to
    /// the app as the window server's are, so they find their view as a
    /// hand's do (through the local monitors and the window's hit test).
    @MainActor static func fieldScroll(by distance: Double, steps: Int, fingers: Bool) {
        guard let window = Links.window, let content = window.contentView, let (_, _, field) = FieldWheel.editing(window) else { return }
        let middle = field.convert(NSPoint(x: field.bounds.midX, y: field.bounds.midY), to: nil)
        let start = DispatchTime.now().uptimeNanoseconds
        func post(_ dy: Int32, phase: Int64, step: Int) {
            guard let event = CGEvent(scrollWheelEvent2Source: nil, units: fingers ? .pixel : .line, wheelCount: 1,
                                      wheel1: dy, wheel2: 0, wheel3: 0) else { return }
            let screen = window.convertPoint(toScreen: middle)
            event.location = CGPoint(x: screen.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - screen.y)
            event.setIntegerValueField(.scrollWheelEventIsContinuous, value: fingers ? 1 : 0)
            if fingers { event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase) }
            event.timestamp = CGEventTimestamp(start + UInt64(step) * 1_000_000_000 / 60)
            event.setIntegerValueField(CGEventField(rawValue: 51)!, value: Int64(window.windowNumber))
            typealias Place = @convention(c) (CGEvent, CGPoint) -> Void
            guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGEventSetWindowLocation") else { return }
            unsafeBitCast(symbol, to: Place.self)(event, CGPoint(x: middle.x, y: content.bounds.height - middle.y))
            guard let wheel = NSEvent(cgEvent: event) else { return }
            NSApp.postEvent(wheel, atStart: false)
        }
        // A wheel's lines: `by` in lines of about 16 points, one a step.
        let total = fingers ? distance : (distance / 16).rounded()
        if fingers { post(0, phase: 1, step: 0) }
        for step in 1...steps {
            let each = Int32((total * Double(step) / Double(steps)).rounded() - (total * Double(step - 1) / Double(steps)).rounded())
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(step) / 60) { post(each, phase: 2, step: step) }
        }
        if fingers {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(steps + 1) / 60) { post(0, phase: 4, step: steps + 1) }
        }
    }
}


extension Bench {
    /// The isolated eval controller acts as the person, never as a task with
    /// an expired tool admission. Only existing chat/stop/state UI is exposed.
    /// Production agent requests still pass ContextConsent and Bench's reply
    /// admission check, including after stopping their own task.
    func handleAgentFixtureControl(_ c: AgentCall) {
        guard Store.testing, c.session == nil,
              let target = c.request["target"] as? String,
              c.agents.session(target) != nil else {
            c.answer(["error": "fixture control requires an isolated test and a known target"]); return
        }
        let verb = c.request["verb"] as? String ?? ""
        guard ["agent-chat", "agent-stop", "agent-wait"].contains(verb) else {
            c.answer(["error": "unsupported fixture UI operation"]); return
        }
        var values = c.request; values["do"] = verb; values["session"] = target
        let call = AgentCall(bench: self, verb: verb, request: values, browser: c.browser, answer: c.answer)
        switch verb {
        case "agent-chat": handleAgentChat(call)
        case "agent-stop": handleAgentStop(call)
        default: handleAgentWait(call)
        }
    }
}
