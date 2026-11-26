import Foundation

// The person: a tab handed over, a question, a sign-in, autofill. Part of
// Mcp.registry (McpTool).

extension Mcp {
    static let personTools: [McpTool] = [
        McpTool("handoff", .read("Hand Over to the User"),
                "Ask the user to take over a tab, sign in, pass a captcha, enter a code, and wait until they say they are done (up to `seconds`, default 300; call again to keep waiting). A captcha is always theirs: hand it over at once, never try to solve it. A sign-in is yours first: a way in the snapshot names under `signs in with:` (Continue with Google), sign_in for a saved password, a mailed code; hand it over only when those can't. A sign-in handed over ends by itself once the tab is back on the site. It shows as one line at the page's foot. For something that would help but the task can go on without (reading chats behind a QR sign-in), pass optional: the line stays for the user, with Skip, and you carry on at once instead of waiting.",
                ["tab": tab, "reason": ["type": "string", "description": "What the user should do, at most 60 characters, e.g. Sign in to Google"],
                  "detail": ["type": "string", "description": "Anything more, shown only if they open it"], "seconds": ["type": "number"],
                  "optional": ["type": "boolean", "description": "The task can go on without it: don't wait"]],
                required: ["tab", "reason"],
                subs: false,
                refuse: McpTool.subagentsCantAsk) { name, input, id in
            var request: [String: Any] = ["do": "handoff", "id": id ?? "", "reason": input["reason"] as? String ?? "Needs you"]
            if let detail = input["detail"] { request["detail"] = detail }
            // A nice-to-have never holds the task: a moment for a user who
            // is right there, then it goes on and the line stays for them.
            let optional = input["optional"] as? Bool ?? false
            request["optional"] = optional
            let got = ask(request)
            if let error = got["error"] as? String { return text(error, error: true) }
            // An assistant doesn't wait on it: it asks after it.
            if assistant != nil, got["answered"] == nil { return text(needsUser(["tab": id ?? ""], request)["error"] as? String ?? "", error: true) }
            // Answered while it worked on: Done or Skip, said now.
            if let said = got["answered"] as? String {
                if said == Agents.skipped { return text("The user skipped this earlier. Carry on without it; don't ask for it again.") }
                return snap(id)
            }
            let limit = Date().addingTimeInterval(optional ? min(input["seconds"] as? Double ?? 15, 15) : input["seconds"] as? Double ?? personWait)
            while Date() < limit {
                if outside, !optional { progress("Waiting for you in Yab: \(request["reason"] as? String ?? "")") }
                let heard = ask(["do": "handoff-wait", "id": id ?? "", "seconds": min(20, max(1, limit.timeIntervalSinceNow))])
                if let error = heard["error"] as? String { return text(error, error: true) }
                switch heard["state"] as? String {
                case "done":
                    if heard["answer"] as? String == Agents.skipped { return text("The user skipped this. Carry on without it.") }
                    return snap(id)
                case "stopped": return text("The user stopped this task. Stop now.", error: true)
                case "taken": return text(Agents.takenWords)
                default: continue
                }
            }
            if optional {
                return text("Left at the foot of the tab: the user can do it or skip it whenever. Carry on without it now. Before you finish, if you still want it, call handoff on this tab again (without optional) to wait for it.")
            }
            if outside {
                return text("status: needs_user\nsays: Yab shows the user “\(request["reason"] as? String ?? "")” at the foot of the tab, and waits for them there.\nfix: Tell the user now, in your reply, what to do in Yab. Once they say it's done, call handoff again (or snapshot the tab).")
            }
            return text("The user has not finished yet. Call handoff again to keep waiting, or carry on without it.")
        },
        McpTool("ask", .read("Ask the User"),
                "Ask the user to pick: a question with up to four options (they may also write their own), shown at the foot of a tab (yours, or the one named). Waits for the answer and returns it. For forks only they can decide: which flight, which account.",
                ["question": ["type": "string", "description": "At most 60 characters"], "options": ["type": "array", "items": ["type": "string"]],
                  "detail": ["type": "string"], "tab": tab, "seconds": ["type": "number"]],
                required: ["question", "options"],
                subs: false,
                refuse: McpTool.subagentsCantAsk) { name, input, id in
            var request: [String: Any] = ["do": "agent-ask", "question": input["question"] as? String ?? "Which one?",
                                          "options": input["options"] as? [String] ?? [], "pick": true]
            if let id { request["id"] = id }
            if let detail = input["detail"] { request["detail"] = detail }
            let got = ask(request)
            if let error = got["error"] as? String { return text(error, error: true) }
            if let end = got["end_turn"] as? String { return text(end) }
            let where_ = got["id"] as? String ?? id ?? ""
            let limit = Date().addingTimeInterval(input["seconds"] as? Double ?? personWait)
            while Date() < limit {
                if outside { progress("Waiting for you in Yab: \(request["question"] as? String ?? "")") }
                let heard = ask(["do": "handoff-wait", "id": where_, "seconds": min(20, max(1, limit.timeIntervalSinceNow))])
                if let error = heard["error"] as? String { return text(error, error: true) }
                switch heard["state"] as? String {
                case "done":
                    let said = heard["answer"] as? String ?? ""
                    return text(said.isEmpty ? "The user put the question away without picking." : "The user picked: \(said)")
                case "stopped": return text("The user stopped this task. Stop now.", error: true)
                case "taken": return text("The user took the tab for themselves without picking. Carry on without an answer and don't use that tab again.")
                default: continue
                }
            }
            if outside {
                return text("status: needs_user\nsays: The question “\(request["question"] as? String ?? "")” waits for the user at the foot of a tab in Yab.\nfix: Tell the user now, or ask them in your own reply instead; don't call ask again for the same question.")
            }
            return text("No answer yet. Call ask again to keep waiting, or carry on without it.")
        },
        McpTool("sign_in", .change("Sign In", outside: true),
                "Sign in on this tab's page with a password Yab has saved for the site (the user may be asked first). The password is filled by Yab and never shown to you. user picks the account when Yab keeps several (it says which). Call again for the next step (a password page after a name page). Without one in Yab, it looks for a connected password manager's menu on the page and says: its menu is open (pick the account in it), it is locked (call unlock_manager, or handoff when the person unlocks it), or there is none (call handoff).",
                ["tab": tab, "user": ["type": "string", "description": "The account's name or email, when there are several"]],
                required: ["tab"],
                acts: true, subs: false,
                refuse: McpTool.subagentsCantAsk) { name, input, id in
            var request: [String: Any] = ["do": "agent-sign-in", "id": id ?? ""]
            if let user = input["user"] as? String { request["user"] = user }
            let got = patient(request)
            return done(got) {
                usleep(800_000)
                _ = ask(["do": "wait", "id": id ?? "", "seconds": 10])
                return allowed(got, text((got["said"] as? String ?? "Signed in.") + "\n\n" + page(ask(["do": "snapshot", "id": id ?? "", "interactive": true]), tab: id)))
            }
        },
        McpTool("unlock_manager", .change("Unlock Password Manager", outside: true),
                "Unlock a connected password manager when sign_in says it is locked and Yab has its unlock password. Yab types the password into the manager's own unlock page in a background tab and says whether it unlocked; you never see the password. On unlocked, call sign_in again and pick the account in the manager's menu. On not_unlocked, don't try again: call handoff. Never for a manager the person unlocks themselves.",
                ["tab": tab, "provider": ["type": "string", "description": "As sign_in names it: 1password, bitwarden, nordpass, proton-pass, dashlane, lastpass"]],
                required: ["provider"],
                acts: true, subs: false,
                refuse: McpTool.subagentsCantAsk) { name, input, id in
            var request: [String: Any] = ["do": "agent-unlock-manager", "provider": input["provider"] as? String ?? ""]
            if let id { request["id"] = id }
            let got = patient(request)
            return done(got) { text(got["said"] as? String ?? "Unlocked. Call sign_in again.") }
        },
        McpTool("autofill", .change("Autofill", outside: true),
                "Fill a form on this tab with what Yab keeps for the user. what: form fills a whole form (sign-up, event registration, application, contact) from the user's address, their profile (company, title, location, LinkedIn, X, GitHub, site, bio) and what they answered the same questions before, all at once and faster than typing, and says which boxes are left: questions only words answer (write those with type, from the profile it sends back), and ones that are the user's alone (money, bank details, ids, consent), which you leave or ask about. Never ticks consent and never submits. card or address fill a checkout: a card waits for the user's Touch ID and its number is never shown to you; its security code fills with it when the user paid with one before; if the page still asks for one, call handoff for the user to type it. An address is filled once the user says yes. With several cards, pass card (its last four digits) when the task says which; without it the user picks one.",
                ["tab": tab, "what": ["type": "string", "enum": ["form", "card", "address"]],
                  "card": ["type": "string", "description": "The last four digits of the card to use"]],
                required: ["tab", "what"],
                acts: true, subs: false,
                refuse: McpTool.subagentsCantAsk) { name, input, id in
            let what = ["address", "form"].contains(input["what"] as? String ?? "") ? input["what"] as? String ?? "card" : "card"
            var request: [String: Any] = ["do": "agent-autofill", "id": id ?? "", "what": what]
            if let card = input["card"] as? String { request["card"] = card }
            var got = patient(request)
            // Several cards and none named: the person picks one at the
            // tab's foot, by the cards themselves, and that one is filled.
            if let cards = got["choose"] as? [String], !cards.isEmpty {
                let asked = ask(["do": "agent-ask", "id": id ?? "", "question": "Which card on \(got["site"] as? String ?? "this site")?",
                                 "detail": "Yab fills it after Touch ID; the agent never sees its number.", "options": Array(cards.prefix(4))])
                if let error = asked["error"] as? String { return text(error, error: true) }
                let limit = Date().addingTimeInterval(personWait)
                var said: String?
                while Date() < limit, said == nil {
                    let heard = ask(["do": "handoff-wait", "id": asked["id"] as? String ?? id ?? "", "seconds": 20])
                    if let error = heard["error"] as? String { return text(error, error: true) }
                    if heard["state"] as? String == "stopped" { return text("The user stopped this task. Stop now.", error: true) }
                    if heard["state"] as? String == "taken" { return text(Agents.takenWords + " Nothing was filled.", error: true) }
                    if heard["state"] as? String == "done" { said = heard["answer"] as? String ?? "" }
                }
                let digits = (said ?? "").filter(\.isNumber)
                guard digits.count >= 4, cards.contains(said ?? "") else {
                    return text(said == nil ? (outside ? unanswered("Which card on \(got["site"] as? String ?? "this site")?") : "The user hasn't picked a card; nothing was filled.") : "The user didn't pick a kept card (\(said ?? "")). Ask what they want, or call handoff.", error: true)
                }
                request["card"] = String(digits.suffix(4))
                got = patient(request)
            }
            return done(got) {
                usleep(500_000)
                return allowed(got, text((got["said"] as? String ?? "Filled.") + "\n\n" + page(ask(["do": "snapshot", "id": id ?? "", "interactive": true]), tab: id)))
            }
        },
    ]
}
