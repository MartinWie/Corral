import Foundation

/// One line on the Corral socket, written by corral-hook and the OpenCode/PI integrations.
///
///     {"surface":"<session uuid>","agent":"claude","event":"Stop","payload":{...raw hook JSON...}}
public enum HookWire {
    public struct Message: Equatable, Sendable {
        public var surface: UUID
        public var event: HookEvent
    }

    public static func decode(line: Data) -> Message? {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let surfaceStr = obj["surface"] as? String, let surface = UUID(uuidString: surfaceStr),
              let agentStr = obj["agent"] as? String, let agent = AgentKind(rawValue: agentStr)
        else { return nil }
        let payload = obj["payload"] as? [String: Any] ?? [:]
        guard let name = (obj["event"] as? String).flatMap({ $0.isEmpty ? nil : $0 })
            ?? payload["hook_event_name"] as? String else { return nil }

        var e = HookEvent(agent: agent, event: name)
        e.sessionId = str(payload["session_id"])
        e.cwd = str(payload["cwd"])
        e.title = str(payload["title"])
        e.message = str(payload["message"]).map { String($0.prefix(300)) }
        e.notificationType = str(payload["notification_type"])
        e.status = str(payload["status"])
        e.source = str(payload["source"])
        e.trigger = str(payload["trigger"])
        if agent == .claude, name == "PermissionRequest", let tool = str(payload["tool_name"]) {
            e.tool = tool
            if e.message == nil { e.message = permissionDetail(tool: tool, input: payload["tool_input"] as? [String: Any]) }
        }
        e.isSubSession = (str(payload["parent_id"]) != nil)
        if name == AgentLaunch.exitEvent, let code = payload["exit"] as? NSNumber,
           CFGetTypeID(code) != CFBooleanGetTypeID() {
            e.exitCode = code.intValue
        }
        return Message(surface: surface, event: e)
    }

    public static func encode(surface: String, agent: String, event: String, payload: Any?) -> Data? {
        var obj: [String: Any] = ["surface": surface, "agent": agent, "event": event]
        if let payload { obj["payload"] = payload }
        guard var data = try? JSONSerialization.data(withJSONObject: obj) else { return nil }
        data.append(0x0A)
        return data
    }

    /// What a permission prompt is about, in one line: "Bash: git push", "Edit: Model.swift", the question
    /// AskUserQuestion puts. Falls back to "Permission: <tool>".
    static func permissionDetail(tool: String, input: [String: Any]?) -> String {
        let input = input ?? [:]
        let text: String?
        switch tool {
        case "AskUserQuestion":
            let first = (input["questions"] as? [[String: Any]])?.first
            return line(str(first?["question"]) ?? str(first?["header"])) ?? "Has a question"
        case "ExitPlanMode":
            return "Plan ready for review"
        case "Edit", "MultiEdit", "Write", "Read", "NotebookEdit":
            text = (str(input["file_path"]) ?? str(input["notebook_path"])).map { URL(fileURLWithPath: $0).lastPathComponent }
        case "WebFetch":
            text = str(input["url"]).flatMap { URL(string: $0)?.host } ?? str(input["url"])
        default:
            text = ["command", "description", "url", "pattern", "query", "path", "prompt"].lazy.compactMap { str(input[$0]) }.first
        }
        guard let detail = line(text) else { return "Permission: \(tool)" }
        return "\(displayTool(tool)): \(detail)"
    }

    /// `mcp__server__tool` reads as "server tool".
    private static func displayTool(_ tool: String) -> String {
        guard tool.hasPrefix("mcp__") else { return tool }
        return tool.dropFirst(5).split(separator: "_", omittingEmptySubsequences: true).joined(separator: " ")
    }

    /// One line (whitespace collapsed), at most 200 characters.
    private static func line(_ s: String?) -> String? {
        guard let s else { return nil }
        let words = s.split(whereSeparator: { $0.isWhitespace })
        guard !words.isEmpty else { return nil }
        let joined = words.joined(separator: " ")
        return joined.count > 200 ? String(joined.prefix(199)) + "…" : joined
    }

    private static func str(_ v: Any?) -> String? {
        guard let s = v as? String, !s.isEmpty else { return nil }
        return s
    }
}
