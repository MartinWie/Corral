import AppKit
import CorralCore

/// Per-session facts the `corral` command reports that the status doesn't carry, and who waits for what.
final class ControlState {
    /// What `corral wait` already reported for a session: each event goes out once.
    struct Token: Equatable {
        var state: String
        var since: Date
        var prompt: UUID?
        var detail: String?
    }

    final class Waiter {
        enum Scope {
            case ids(Set<UUID>)
            /// The sessions started from this one.
            case children(UUID)
        }

        let scope: Scope
        /// Only a session's end counts (`wait --done`): prompts on the way are left for someone else.
        let final: Bool
        let reply: ([String: Any]) -> Void
        var timeout: DispatchWorkItem?

        init(scope: Scope, final: Bool, reply: @escaping ([String: Any]) -> Void) {
            self.scope = scope
            self.final = final
            self.reply = reply
        }
    }

    var waiters: [Waiter] = []
    var delivered: [UUID: Token] = [:]
    /// Tool input of the permission prompt that is up.
    var requests: [UUID: String] = [:]
    /// Closing message of the last turn.
    var results: [UUID: String] = [:]
    var transcripts: [UUID: String] = [:]
    /// What a started session handed back with `corral report` this turn.
    var reports: [UUID: (text: String, failed: Bool)] = [:]
    /// Sessions whose agent quit (the terminal is back at its shell).
    var quit: Set<UUID> = []
    /// Started with `corral spawn --trust`: Claude's folder trust question is answered with yes.
    var trusted: Set<UUID> = []
    /// `corral events` listeners, and the state each session was last announced in.
    final class Subscriber {
        let scope: Waiter.Scope?
        let push: ([String: Any]) -> Void
        init(scope: Waiter.Scope?, push: @escaping ([String: Any]) -> Void) {
            self.scope = scope
            self.push = push
        }
    }
    var subscribers: [Subscriber] = []
    var announced: [UUID: String] = [:]
    /// Pending auto-close of a finished session, and the held-back notification of a quiet one.
    var tidy: [UUID: DispatchWorkItem] = [:]
    var quiet: [UUID: DispatchWorkItem] = [:]

    func forget(_ id: UUID) {
        delivered[id] = nil
        requests[id] = nil
        results[id] = nil
        transcripts[id] = nil
        reports[id] = nil
        quit.remove(id)
        trusted.remove(id)
        announced[id] = nil
        tidy.removeValue(forKey: id)?.cancel()
        quiet.removeValue(forKey: id)?.cancel()
    }
}

/// The `corral` command's requests (`ControlServer`): start sessions, read them, answer their prompts,
/// and wait for them.
extension SessionManager {
    static let controlOff = "Command line control is off. Turn it on in Corral › Settings › Agents."
    /// States `corral wait` returns for.
    static let attentionStates: Set<String> = ["needs_permission", "needs_input", "done", "error", "exited"]
    static let screenLines = 40
    static let finalStates: Set<String> = ["done", "error", "exited"]
    static let measureOff = "Session measurement is off. Turn it on in Corral › Settings › Agents."
    static let diagnosticsOff = "Diagnostics are off. Turn them on in Corral › Settings › General."
    static let maxReport = 4_000
    /// The prompt rides on the agent's command line, quoted three shells deep.
    static let maxPrompt = 32_000

    // MARK: State

    func controlState(_ id: UUID) -> String {
        guard let ls = live[id] else { return workspace.sessions[id]?.closedAt == nil ? "starting" : "closed" }
        if control.quit.contains(id) { return "exited" }
        switch ls.status.activity {
        case .idle: return ls.launch != nil ? "starting" : "idle"
        case .working: return "working"
        case .needsInput: return ls.status.need == .permission ? "needs_permission" : "needs_input"
        case .done: return "done"
        case .error: return "error"
        case .exited: return "exited"
        }
    }

    func controlSession(_ id: UUID) -> [String: Any]? {
        guard let r = workspace.sessions[id] else { return nil }
        var s: [String: Any] = ["id": id.uuidString.lowercased(), "name": r.displayTitle, "agent": r.agent.rawValue,
                                "state": controlState(id), "cwd": live[id]?.status.cwd ?? r.cwd]
        if let detail = live[id]?.status.detail { s["detail"] = detail }
        if let model = r.model { s["model"] = model }
        if let parent = r.parent { s["parent"] = parent.uuidString.lowercased() }
        if let folder = workspace.parent(of: id) ?? nil { s["folder"] = folderPath(folder) }
        return s
    }

    /// The session with what its state is about: the pending request, or the turn's result.
    private func controlReport(_ id: UUID) -> [String: Any] {
        var out: [String: Any] = ["ok": true]
        guard let session = controlSession(id) else { return out }
        out["session"] = session
        if let report = control.reports[id] { out["report"] = ["text": report.text, "failed": report.failed] }
        switch session["state"] as? String {
        case "needs_permission":
            if let input = control.requests[id] { out["request"] = input }
        case "done":
            if let result = controlResult(id) { out["result"] = result }
        case "starting", "idle":
            // Maybe a prompt Corral can't see (a folder trust question): what the terminal shows.
            if let ls = live[id], ls.status.agent != .shell || ls.launch != nil {
                let screen = Self.tail(ls.terminal.viewportText(), lines: 12)
                if !screen.isEmpty { out["screen"] = screen }
            }
        default: break
        }
        return out
    }

    private func controlResult(_ id: UUID) -> String? {
        control.results[id] ?? control.transcripts[id].flatMap { TranscriptTail.lastAssistantText(path: $0) }
    }

    private func attention(_ id: UUID) -> ControlState.Token? {
        guard let ls = live[id] else { return nil }
        let state = controlState(id)
        guard Self.attentionStates.contains(state) else { return nil }
        // The shell left behind keeps changing (commands end): the agent's exit is still one event.
        if state == "exited" { return .init(state: state, since: .distantPast, prompt: nil, detail: nil) }
        return .init(state: state, since: ls.status.since, prompt: ls.status.promptId, detail: ls.status.detail)
    }

    // MARK: Hooks into the manager

    /// What a hook carries beyond the status.
    func controlNote(_ msg: HookWire.Message) {
        guard workspace.settings.control, live[msg.surface] != nil else { return }
        let e = msg.event
        // A new turn: the last one's closing message is no longer the result.
        if e.event == "UserPromptSubmit" {
            control.results[msg.surface] = nil
            control.reports[msg.surface] = nil
        }
        if let path = e.transcriptPath { control.transcripts[msg.surface] = path }
        if e.event == "PermissionRequest" { control.requests[msg.surface] = e.toolInput }
        if e.event == "Stop" { control.results[msg.surface] = e.lastMessage }
    }

    func controlStatusChanged(_ id: UUID, before: LiveStatus, after: LiveStatus) {
        if after.agent != .shell {
            control.quit.remove(id)
        } else if before.agent != .shell {
            control.quit.insert(id)
        }
        if after.activity != .needsInput { control.requests[id] = nil }
        if after.activity == .working, workspace.sessions[id]?.unreported != nil { setUnreported(nil, for: id) }
        // A new turn (also where no UserPromptSubmit hook says so): the last one's report is history.
        if after.activity == .working, [.done, .idle, .error].contains(before.activity) { control.reports[id] = nil }
    }

    /// A session changed: the first waiter watching it hears about a new event.
    func controlCheck(_ id: UUID) {
        guard workspace.settings.control, let token = attention(id), control.delivered[id] != token else { return }
        guard let i = control.waiters.firstIndex(where: { watches($0, id) && takes($0, token.state) }) else {
            // Nobody waits: an end is kept with the session, so the next wait hears of it even after a restart.
            if Self.finalStates.contains(token.state) { setUnreported(token.state, for: id) }
            return
        }
        deliver(id, token)
        finish(control.waiters.remove(at: i), controlReport(id))
    }

    private func deliver(_ id: UUID, _ token: ControlState.Token) {
        control.delivered[id] = token
        setUnreported(nil, for: id)
    }

    /// A session may act on (approve, type into, close) the sessions it started, and theirs. Commands
    /// from outside any session (the user's scripts) and, when the user allows it, every session may
    /// act on all. The caller comes from the environment: a guard rail against mix-ups, not a lock.
    func mayAct(_ caller: UUID?, on target: UUID) -> Bool {
        guard let caller, !workspace.settings.controlAll else { return true }
        var current = workspace.sessions[target]?.parent
        var seen: Set<UUID> = [target]
        while let parent = current, seen.insert(parent).inserted {
            if parent == caller { return true }
            current = workspace.sessions[parent]?.parent
        }
        return false
    }

    static let notYours = "That session wasn't started from this one. The user can allow steering any session in "
        + "Corral › Settings › Agents."

    /// Answers the permission prompt that is up: Claude's (1 / Esc) or OpenCode's (Return on its
    /// preselected "Allow once" / Esc).
    private func answerPermission(_ id: UUID, allow: Bool) -> Bool {
        guard let ls = live[id] else { return false }
        if ls.status.activity == .needsInput, ls.status.detail == Self.trustDetail { return answerTrust(id, yes: allow) }
        if let prompt = Self.promptToken(ls.status) {
            return answerPrompt(allow ? .allow : .deny, session: id, prompt: prompt)
        }
        guard ls.status.agent == .opencode, ls.status.activity == .needsInput, ls.status.need == .permission,
              ls.terminal.perform(binding: allow ? "text:\\r" : "text:\\x1b") else { return false }
        apply(allow ? .userSubmitted : .userCancelled, to: id)
        return true
    }

    // MARK: Events

    /// Tells `corral events` listeners when a session's state changed.
    func controlPublish(_ id: UUID, closed: Bool = false) {
        guard !control.subscribers.isEmpty else { return }
        let state = closed ? "closed" : controlState(id)
        guard control.announced[id] != state else { return }
        control.announced[id] = state
        var event = controlReport(id)
        event["ok"] = nil
        event["screen"] = nil
        event["event"] = state
        if closed, var session = event["session"] as? [String: Any] {
            session["state"] = state
            event["session"] = session
        }
        for s in control.subscribers where s.scope.map({ inScope($0, id) }) ?? true { s.push(event) }
    }

    private func subscribe(_ request: [String: Any], caller: UUID?, push: (([String: Any]) -> Void)?,
                           reply: @escaping ([String: Any]) -> Void) -> (() -> Void)? {
        guard let push else {
            reply(["ok": false, "error": "Events need a connection that stays open."])
            return nil
        }
        var scope: ControlState.Waiter.Scope?
        if let raw = request["ids"] as? [String], !raw.isEmpty {
            var ids = Set<UUID>()
            for r in raw {
                guard case .success(let id) = resolveSession(r) else {
                    reply(["ok": false, "error": "No open session with id \(r)."])
                    return nil
                }
                ids.insert(id)
            }
            scope = .ids(ids)
        } else if request["mine"] as? Bool == true {
            guard let caller else {
                reply(["ok": false, "error": "--mine works inside a Corral session."])
                return nil
            }
            scope = .children(caller)
        }
        // Only changes from here on are announced.
        if control.subscribers.isEmpty { for id in live.keys { control.announced[id] = controlState(id) } }
        let subscriber = ControlState.Subscriber(scope: scope, push: push)
        control.subscribers.append(subscriber)
        push(["ok": true])
        return { [weak self, weak subscriber] in
            guard let self, let subscriber else { return }
            self.control.subscribers.removeAll { $0 === subscriber }
            if self.control.subscribers.isEmpty { self.control.announced = [:] }
        }
    }

    // MARK: Auto-close

    /// Minutes become seconds; tests shorten it.
    static var tidyUnit: TimeInterval = 60

    /// After every status change: listeners hear of it, and a finished session started through
    /// `corral` gets (or loses) its date with auto-close.
    func controlSettled(_ id: UUID) {
        controlPublish(id)
        scheduleTidy(id)
    }

    func scheduleTidy(_ id: UUID) {
        control.tidy.removeValue(forKey: id)?.cancel()
        let minutes = workspace.settings.tidyMinutes
        guard minutes > 0, workspace.sessions[id]?.spawned == true, ["done", "exited"].contains(controlState(id)) else { return }
        let work = DispatchWorkItem { [weak self] in self?.tidy(id) }
        control.tidy[id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(minutes) * Self.tidyUnit, execute: work)
    }

    /// Closes the session (it stays in Closed, with its conversation; `close` removes folders the
    /// command made that are empty now). Not the one the user is looking at: that one gets another round.
    private func tidy(_ id: UUID) {
        control.tidy[id] = nil
        guard live[id] != nil, ["done", "exited"].contains(controlState(id)) else { return }
        guard workspace.selected != id else { return scheduleTidy(id) }
        close(id)
    }

    /// Before `close` takes the session apart.
    func controlClosed(_ id: UUID) {
        controlPublish(id, closed: true)
        defer { control.forget(id) }
        setUnreported(nil, for: id)
        guard var session = controlSession(id) else { return }
        session["state"] = "closed"
        // Everyone watching it: a waiter left with nothing to watch would never return.
        for waiter in control.waiters.filter({ watches($0, id) }) {
            control.waiters.removeAll { $0 === waiter }
            finish(waiter, ["ok": true, "session": session])
        }
    }

    private func takes(_ waiter: ControlState.Waiter, _ state: String) -> Bool {
        !waiter.final || Self.finalStates.contains(state)
    }

    /// Someone waits to hear what this session does next: the user needn't be told as well.
    func controlWatched(_ id: UUID) -> Bool {
        guard let token = attention(id), control.delivered[id] != token else { return false }
        return control.waiters.contains { watches($0, id) && takes($0, token.state) }
    }

    /// The session's Claude transcript: where its hooks said, else found by conversation id.
    func transcriptPath(_ id: UUID) -> String? {
        if let path = control.transcripts[id] { return path }
        guard let r = workspace.sessions[id], r.agent == .claude, let sid = r.agentSessionId else { return nil }
        let root = env.roots.claudeProjects
        let fm = FileManager.default
        return (try? fm.contentsOfDirectory(atPath: root.path))?.lazy
            .map { root.appendingPathComponent($0).appendingPathComponent("\(sid).jsonl").path }
            .first { fm.fileExists(atPath: $0) }
    }

    private func watches(_ waiter: ControlState.Waiter, _ id: UUID) -> Bool { inScope(waiter.scope, id) }

    private func inScope(_ scope: ControlState.Waiter.Scope, _ id: UUID) -> Bool {
        switch scope {
        case .ids(let ids): return ids.contains(id)
        case .children(let parent): return workspace.sessions[id]?.parent == parent
        }
    }

    /// The command was turned off: nobody keeps waiting, nothing cached stays.
    func controlStopped() {
        let waiting = control.waiters
        control.waiters = []
        waiting.forEach { finish($0, ["ok": false, "error": Self.controlOff]) }
        control.requests = [:]
        control.results = [:]
        control.reports = [:]
        let listening = control.subscribers
        control.subscribers = []
        control.announced = [:]
        listening.forEach { $0.push(["ok": false, "error": Self.controlOff]) }
    }

    private func finish(_ waiter: ControlState.Waiter, _ answer: [String: Any]) {
        waiter.timeout?.cancel()
        waiter.timeout = nil
        waiter.reply(answer)
    }

    // MARK: Requests

    /// Answers through `reply`, at once or (wait) later. Returns what to run when the client leaves
    /// before it was answered.
    @discardableResult
    func handleControl(_ request: [String: Any], push: (([String: Any]) -> Void)? = nil,
                       reply: @escaping ([String: Any]) -> Void) -> (() -> Void)? {
        func fail(_ message: String) -> (() -> Void)? {
            reply(["ok": false, "error": message])
            return nil
        }
        guard workspace.settings.control else { return fail(Self.controlOff) }
        let caller = (request["caller"] as? String).flatMap(UUID.init(uuidString:)).flatMap { live[$0] != nil ? $0 : nil }
        let command = request["cmd"] as? String ?? ""

        var target: UUID?
        if let raw = request["id"] as? String {
            switch resolveSession(raw) {
            case .success(let id): target = id
            case .failure(let error): return fail(error.message)
            }
        }

        switch command {
        case "spawn":
            guard let agent = (request["agent"] as? String).flatMap(AgentKind.init(rawValue:)), agent != .shell else {
                return fail("Unknown agent. Use claude, opencode or pi.")
            }
            guard installedAgents.contains(agent) else { return fail("\(agent.displayName) isn't installed on this Mac.") }
            let cwd = request["cwd"] as? String
            var isDir: ObjCBool = false
            if let cwd, !FileManager.default.fileExists(atPath: cwd, isDirectory: &isDir) || !isDir.boolValue {
                return fail("No such directory: \(cwd)")
            }
            let extra = request["extra"] as? [String] ?? []
            // A guard rail, not a boundary: a session asked for through here keeps its permission prompts.
            if extra.contains(where: { $0.lowercased().contains("dangerously") || $0.lowercased().contains("bypasspermissions") }) {
                return fail("Sessions started through corral keep their permission prompts.")
            }
            let prompt = Self.spawnPrompt(request["prompt"] as? String, settings: workspace.settings)
            if let prompt, prompt.utf8.count > Self.maxPrompt {
                return fail("The prompt is too long for a command line. Put it in a file and tell the session to read it.")
            }
            let folder: UUID
            if let path = request["folder"] as? String {
                guard let id = resolveFolder(path, create: true) else { return fail("--folder needs a name, like Monitoring/Disk.") }
                folder = id
            } else {
                folder = spawnFolder(for: caller)
            }
            var note: String?
            if !integrations.installed(agent) {
                note = "\(agent.displayName)'s status hooks aren't installed, so Corral can't tell when this session needs "
                    + "you or is done. Install them in Corral › Settings › Agents."
            }
            let named = request["model"] as? String
            let id = newSession(agent: agent, cwd: cwd, folder: folder, model: workspace.settings.model(for: agent, named: named),
                                prompt: prompt, extra: extra,
                                parent: caller, name: request["name"] as? String, spawned: true,
                                select: request["focus"] as? Bool == true)
            controlPublish(id)
            if request["trust"] as? Bool == true { control.trusted.insert(id) }
            var answer = controlReport(id)
            answer["screen"] = nil
            if let note { answer["note"] = note }
            reply(answer)
        case "list":
            let mine = request["mine"] as? Bool == true
            if mine, caller == nil { return fail("--mine works inside a Corral session.") }
            let ids = workspace.openSessionsInOrder.filter { !mine || workspace.sessions[$0]?.parent == caller }
            reply(["ok": true, "sessions": ids.compactMap(controlSession)])
        case "status":
            guard let target else { return fail("Which session?") }
            reply(controlReport(target))
        case "wait":
            return wait(request, caller: caller, reply: reply)
        case "approve", "deny":
            guard let target, live[target] != nil else { return fail("Which session?") }
            guard target != caller else { return fail("A session can't answer its own prompt.") }
            guard mayAct(caller, on: target) else { return fail(Self.notYours) }
            guard answerPermission(target, allow: command == "approve") else {
                return fail("No permission prompt Corral can answer is up there (state: \(controlState(target))). "
                    + "Read the screen with corral output ID --screen and press keys with corral send ID --raw.")
            }
            reply(controlReport(target))
        case "send":
            guard let target, let ls = live[target], let text = request["text"] as? String else { return fail("Which session?") }
            // At a shell prompt the text would run as a command, with no permission prompt in between.
            guard ls.status.agent != .shell else { return fail("No agent is running in that session.") }
            guard mayAct(caller, on: target) else { return fail(Self.notYours) }
            let raw = request["raw"] as? Bool == true
            if !raw, controlState(target) == "needs_permission" {
                return fail("That session waits on a permission prompt: approve or deny it first.")
            }
            guard typeText(text, into: target, submit: !raw) else { return fail("The terminal didn't take the text.") }
            // No state with it: the session only moves on once it has read what was typed.
            reply(["ok": true, "note": raw ? "Typed." : "Sent."])
        case "debug":
            guard workspace.settings.diagnostics else { return fail(Self.diagnosticsOff) }
            guard let id = target ?? workspace.selected, let ls = live[id] else { return fail("Which session?") }
            var answer: [String: Any] = ["ok": true, "render": ls.terminal.renderReport()]
            if let session = controlSession(id) { answer["session"] = session }
            reply(answer)
        case "output":
            guard let target, let ls = live[target] else { return fail("Which session?") }
            let lines = request["lines"] as? Int ?? Self.screenLines
            if request["screen"] as? Bool != true, let result = controlResult(target) {
                reply(["ok": true, "text": result])
            } else {
                reply(["ok": true, "text": Self.tail(ls.terminal.screenText(), lines: lines)])
            }
        case "folder":
            return folderRequest(request, reply: reply)
        case "events":
            return subscribe(request, caller: caller, push: push, reply: reply)
        case "report":
            guard let caller else { return fail("corral report works inside a session Corral started.") }
            guard let text = request["text"] as? String, !text.isEmpty else { return fail("Nothing to report.") }
            control.reports[caller] = (String(text.prefix(Self.maxReport)), request["failed"] as? Bool == true)
            reply(["ok": true, "note": "Reported."])
        case "stats":
            guard workspace.settings.measure else { return fail(Self.measureOff) }
            let ids = target.map { [$0] } ?? workspace.openSessionsInOrder.filter {
                workspace.sessions[$0]?.agent == .claude && (caller == nil || workspace.sessions[$0]?.parent == caller)
            }
            guard !ids.isEmpty else { return fail("No sessions to measure.") }
            let rows = ids.compactMap { id in controlSession(id).map { (session: $0, path: transcriptPath(id)) } }
            // Transcripts can be large: read off the main thread.
            DispatchQueue.global(qos: .userInitiated).async {
                let stats = rows.map { row -> [String: Any] in
                    var out: [String: Any] = ["session": row.session]
                    if let s = row.path.flatMap(SessionAnalysis.analyze(path:)) { out["stats"] = s.json }
                    return out
                }
                DispatchQueue.main.async { reply(["ok": true, "stats": stats]) }
            }
        case "close":
            guard let target else { return fail("Which session?") }
            guard target != caller else { return fail("A session can't close itself this way.") }
            guard mayAct(caller, on: target) else { return fail(Self.notYours) }
            close(target)
            reply(["ok": true, "note": "Closed."])
        default:
            return fail("Unknown command \(command)")
        }
        return nil
    }

    // MARK: Folders

    /// "Monitoring/Disk": the folder's names from the top.
    func folderPath(_ id: UUID) -> String {
        var names: [String] = []
        var current: UUID? = id
        while let folder = current {
            names.insert(workspace.folders[folder]?.name ?? "Folder", at: 0)
            current = workspace.parent(of: folder) ?? nil
        }
        return names.joined(separator: "/")
    }

    static let scriptFolder = "Automated"

    /// Where a spawn without `--folder` goes, so started sessions are always grouped: a folder of the
    /// caller's own, right below it (reused while it exists), or "Automated" for scripts.
    func spawnFolder(for caller: UUID?) -> UUID {
        guard let caller, workspace.contains(caller), let record = workspace.sessions[caller] else {
            return resolveFolder(Self.scriptFolder, create: true)!
        }
        if let own = workspace.folders.values.first(where: { $0.owner == caller && workspace.contains($0.id) }) { return own.id }
        let parent = workspace.parent(of: caller) ?? nil
        let index = workspace.children(of: parent).firstIndex { $0.id == caller }.map { $0 + 1 }
        return newFolder(name: "\(record.displayTitle) · agents", in: parent, at: index, auto: true, owner: caller)
    }

    /// The folder at `path` (names separated by "/", matched without case), made on the way with
    /// `create`. Nil when there is none, or for an empty path (the top level).
    func resolveFolder(_ path: String, create: Bool) -> UUID? {
        var parent: UUID?
        for name in path.split(separator: "/").map({ $0.trimmingCharacters(in: .whitespaces) }) where !name.isEmpty {
            let existing = workspace.children(of: parent).first {
                $0.isFolder && workspace.folders[$0.id]?.name.caseInsensitiveCompare(name) == .orderedSame
            }
            if let existing {
                parent = existing.id
            } else if create {
                parent = newFolder(name: name, in: parent, auto: true)
            } else {
                return nil
            }
        }
        return parent
    }

    private func folderRequest(_ request: [String: Any], reply: @escaping ([String: Any]) -> Void) -> (() -> Void)? {
        func fail(_ message: String) -> (() -> Void)? {
            reply(["ok": false, "error": message])
            return nil
        }
        let path = request["path"] as? String ?? ""
        let action = request["action"] as? String ?? ""
        func listing() -> [[String: Any]] {
            var rows: [[String: Any]] = []
            func walk(_ items: [TreeItem]) {
                for case .folder(let id, let children) in items {
                    rows.append(["path": folderPath(id), "sessions": children.filter { !$0.isFolder }.count,
                                 "expanded": workspace.folders[id]?.expanded ?? true])
                    walk(children)
                }
            }
            walk(workspace.tree)
            return rows
        }
        if action == "list" {
            reply(["ok": true, "folders": listing()])
            return nil
        }
        if action == "move" {
            // "/" (or nothing) is the top level; a folder that isn't there yet is made.
            let folder = resolveFolder(path, create: true)
            var ids: [UUID] = []
            for raw in request["ids"] as? [String] ?? [] {
                switch resolveSession(raw) {
                case .success(let id): ids.append(id)
                case .failure(let error): return fail(error.message)
                }
            }
            guard !ids.isEmpty else { return fail("Which sessions?") }
            ids.forEach { move($0, to: folder, at: nil) }
            reply(["ok": true, "sessions": ids.compactMap(controlSession)])
            return nil
        }
        if action == "create" {
            guard resolveFolder(path, create: true) != nil else { return fail("A folder needs a name.") }
            reply(["ok": true, "folders": listing()])
            return nil
        }
        guard let folder = resolveFolder(path, create: false) else { return fail("No folder \(path).") }
        switch action {
        case "collapse", "expand": showFolder(folder, expanded: action == "expand")
        case "rename":
            guard let name = (request["name"] as? String)?.trimmingCharacters(in: .whitespaces), !name.isEmpty,
                  !name.contains("/") else { return fail("A folder name can't be empty or hold a slash.") }
            rename(folder, to: name)
        case "delete": deleteFolder(folder)
        default: return fail("Unknown folder command \(action).")
        }
        reply(["ok": true, "folders": listing()])
        return nil
    }

    struct ControlError: Error { let message: String }

    /// An open session by id or unique id prefix.
    func resolveSession(_ raw: String) -> Result<UUID, ControlError> {
        let wanted = raw.lowercased()
        let matches = workspace.openSessionsInOrder.filter { $0.uuidString.lowercased().hasPrefix(wanted) }
        guard !wanted.isEmpty, let id = matches.first else { return .failure(.init(message: "No open session with id \(raw).")) }
        guard matches.count == 1 else { return .failure(.init(message: "\(raw) matches \(matches.count) sessions: use more of the id.")) }
        return .success(id)
    }

    private func wait(_ request: [String: Any], caller: UUID?, reply: @escaping ([String: Any]) -> Void) -> (() -> Void)? {
        let scope: ControlState.Waiter.Scope
        if let raw = request["ids"] as? [String], !raw.isEmpty {
            var ids = Set<UUID>()
            for r in raw {
                switch resolveSession(r) {
                case .success(let id): ids.insert(id)
                case .failure(let error):
                    reply(["ok": false, "error": error.message])
                    return nil
                }
            }
            scope = .ids(ids)
        } else if let caller {
            scope = .children(caller)
        } else {
            reply(["ok": false, "error": "Which sessions? Outside a Corral session, name the ids to wait for."])
            return nil
        }
        let waiter = ControlState.Waiter(scope: scope, final: request["final"] as? Bool == true, reply: reply)
        let watched = workspace.openSessionsInOrder.filter { watches(waiter, $0) }
        guard !watched.isEmpty else {
            reply(["ok": false, "error": "No open sessions to wait for."])
            return nil
        }
        // Something that already happened and wasn't reported yet.
        for id in watched {
            if let token = attention(id), control.delivered[id] != token, takes(waiter, token.state) {
                deliver(id, token)
                reply(controlReport(id))
                return nil
            }
            // An end from before a restart: the session is back (resumed, idle), its last turn's news isn't out yet.
            if attention(id) == nil, let state = workspace.sessions[id]?.unreported {
                setUnreported(nil, for: id)
                var answer = controlReport(id)
                var session = answer["session"] as? [String: Any] ?? [:]
                session["state"] = state
                answer["session"] = session
                answer["screen"] = nil
                if state == "done", let result = controlResult(id) ?? transcriptPath(id).flatMap({ TranscriptTail.lastAssistantText(path: $0) }) {
                    answer["result"] = result
                }
                reply(answer)
                return nil
            }
        }
        control.waiters.append(waiter)
        if let seconds = request["timeout"] as? Double, seconds > 0 {
            let work = DispatchWorkItem { [weak self, weak waiter] in
                guard let self, let waiter, self.control.waiters.contains(where: { $0 === waiter }) else { return }
                self.control.waiters.removeAll { $0 === waiter }
                let open = self.workspace.openSessionsInOrder.filter { self.watches(waiter, $0) }
                waiter.reply(["ok": true, "timeout": true, "sessions": open.compactMap(self.controlSession)])
            }
            waiter.timeout = work
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
        }
        return { [weak self, weak waiter] in
            guard let waiter else { return }
            waiter.timeout?.cancel()
            self?.control.waiters.removeAll { $0 === waiter }
        }
    }

    /// The prompt a started session gets: the caller's, plus the user's standing addition.
    static func spawnPrompt(_ prompt: String?, settings: AppSettings) -> String? {
        let note = settings.spawnNote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let prompt, settings.spawnNoteOn, !note.isEmpty else { return prompt }
        return prompt + "\n\n" + note
    }

    // MARK: Typing

    /// Ghostty's `text:` binding for `text`: Zig string syntax, every byte outside plain letters,
    /// digits and spaces escaped.
    static func textBinding(_ text: String) -> String {
        var out = "text:"
        for byte in text.utf8 {
            switch byte {
            case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: " "):
                out.unicodeScalars.append(Unicode.Scalar(byte))
            default:
                out += String(format: "\\x%02x", byte)
            }
        }
        return out
    }

    /// Pause between a typed prompt and its Return, so the agent doesn't read both as one paste.
    static var submitDelay: TimeInterval = 0.15

    /// Types into the session's terminal as the user would; with `submit`, Return follows.
    @discardableResult
    func typeText(_ text: String, into id: UUID, submit: Bool) -> Bool {
        guard let ls = live[id] else { return false }
        // Several lines go in as one paste, or each newline would submit.
        let lines = text.contains("\n") || text.contains("\r")
        // (Without an end-of-paste of its own, which would let the rest through as keys.)
        let payload = lines && submit ? "\u{1b}[200~\(text.replacingOccurrences(of: "\u{1b}[201~", with: ""))\u{1b}[201~" : text
        guard ls.terminal.perform(binding: Self.textBinding(payload)) else { return false }
        guard submit else { return true }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.submitDelay) { [weak self] in
            guard let self, let ls = self.live[id] else { return }
            ls.terminal.perform(binding: "text:\\r")
            self.apply(.userSubmitted, to: id)
        }
        return true
    }

    /// The last `lines` lines of a screen, without the empty ones below the content.
    static func tail(_ screen: String, lines: Int) -> String {
        var all = screen.components(separatedBy: "\n").map { $0.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) }
        while all.last?.isEmpty == true { all.removeLast() }
        return all.suffix(max(1, lines)).joined(separator: "\n")
    }
}
