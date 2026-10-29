//
//  HookMonitor.swift
//  BoringNotchXPCHelper
//
//  Agents that run on their own (Claude Code, Codex, Gemini CLI, Cursor, OpenCode, Pi…) report
//  their lifecycle through hooks or plugins installed by `AgentIntegrations`. Each event arrives
//  as one connection on a Unix socket, so nothing runs between events.
//

import Foundation

/// Tracks hook-reported sessions and holds permission requests until the user answers them.
///
/// Wire format, one connection per event:
/// ```
/// <agent>\t<pid>\t<event name>\t<TERM_PROGRAM>\t<HERDR_PANE_ID>\t<HERDR_SOCKET_PATH>\t<ORCA_PANE_KEY>\t<TMUX_PANE>\t<TMUX>\n
/// <event JSON>\n
/// ```
/// Agents name events and fields differently; `HookEvent` maps them onto Claude Code's.
/// A permission request connection stays open until a decision line is written back.
final class HookMonitor: AgentMonitor {
    static let id = "hooks"
    static let tools: [String] = []

    static let directory = NSHomeDirectory() + "/.boringnotch"
    static let socketPath = directory + "/agents.sock"

    private struct Session: Codable {
        let id: String
        let agent: String
        let pid: pid_t
        /// Tells a restored session's process apart from a later one that reused its pid.
        let started: Double?
        let ancestors: [Int]
        let terminal: TerminalLocation
        let container: [String: String]?
        let project: String
        let branch: String?
        var status = "idle"
        var detail: String?
        var since = Date()
        var approval: String?
        /// The agent shows nothing else until the request is answered.
        var approvalBlocksAgent = false

        var json: [String: Any] {
            var json: [String: Any] = [
                "id": id, "agent": agent, "ancestors": ancestors,
                "project": project, "status": status, "since": since.timeIntervalSince1970 * 1000,
                "canReply": terminal.canSendText, "approvalBlocksAgent": approvalBlocksAgent,
            ]
            json["terminal"] = terminal.program
            json["container"] = container
            json["branch"] = branch
            json["detail"] = detail
            json["approval"] = approval
            return json
        }
    }

    /// Agents known to keep their own permission prompt on screen while a hook waits; any other
    /// agent gets its request back after this long, so it is never stuck on the notch.
    private static let promptingAgents: Set<String> = ["claude", "opencode"]
    private static let approvalGrace: TimeInterval = 20

    private let queue: DispatchQueue
    private let onChange: (Data?) -> Void
    private var listener: LineSocketListener?
    /// Connections still sending their event.
    private var connections: [ObjectIdentifier: LineSocket] = [:]
    private var sessions: [String: Session] = [:]
    /// Open permission request connections, keyed by session id.
    private var pendingApprovals: [String: LineSocket] = [:]
    private var exitWatchers: [pid_t: DispatchSourceProcess] = [:]
    /// The `rate_limits` object of Claude Code's latest status line update, kept on disk across restarts.
    private var rateLimits: [String: Any] = [:]
    private static let rateLimitsPath = directory + "/claude-rate-limits.json"
    /// Known sessions, so agents already running when the helper restarts show up at once
    /// instead of at their next event.
    private static let sessionsPath = directory + "/sessions.json"

    init(queue: DispatchQueue, onChange: @escaping (Data?) -> Void) {
        self.queue = queue
        self.onChange = onChange
        try? FileManager.default.createDirectory(atPath: Self.directory, withIntermediateDirectories: true)
        if let data = FileManager.default.contents(atPath: Self.rateLimitsPath),
           let saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            rateLimits = saved
        }
        restoreSessions()
        listener = LineSocketListener(path: Self.socketPath, queue: queue) { [weak self] socket in
            self?.receive(on: socket)
        }
        publish()
    }

    /// Requests from the app:
    /// - `{"decide": <session id>, "behavior": "allow" | "deny" | "defer"}`
    /// - `{"focus": <session id>}`, `{"reply": <session id>, "text": …}`: replies `true` when handled
    /// - `{"integrations": "status"}`, `{"install": <name>}`, `{"uninstall": <name>}`
    /// - `{"usage": "all", "openrouter": "on" | "off"}`: plan usage, see `UsageReport`
    /// - `{"usageRelay": "on" | "off"}`
    func handle(_ request: Data, reply: @escaping (Data?) -> Void) {
        guard let object = try? JSONSerialization.jsonObject(with: request) as? [String: String] else { return reply(nil) }

        if let id = object["decide"], let behavior = object["behavior"] {
            decide(id, behavior: behavior)
            return reply(Data())
        }
        if let id = object["focus"] {
            let terminal = sessions[id]?.terminal
            return DispatchQueue.global().async { reply(Self.encode(terminal?.focus() == true)) }
        }
        if let id = object["reply"], let text = object["text"] {
            let terminal = sessions[id]?.terminal
            return DispatchQueue.global().async { reply(Self.encode(terminal?.send(text) == true)) }
        }
        if object["usage"] != nil {
            let limits = rateLimits
            let includeOpenRouter = object["openrouter"] == "on"
            return DispatchQueue.global().async {
                UsageReport.build(claudeRateLimits: limits, includeOpenRouter: includeOpenRouter, reply: reply)
            }
        }
        if let state = object["usageRelay"] {
            AgentIntegrations.setStatusLineRelay(state == "on")
            return reply(Data())
        }
        if let name = object["install"] {
            AgentIntegrations.install(name)
        } else if let name = object["uninstall"] {
            AgentIntegrations.uninstall(name)
        } else if object["integrations"] == nil {
            return reply(nil)
        }
        reply(try? JSONSerialization.data(withJSONObject: AgentIntegrations.status()))
    }

    private static func encode(_ value: Bool) -> Data {
        Data((value ? "true" : "false").utf8)
    }

    // MARK: - Events

    private func receive(on socket: LineSocket) {
        let key = ObjectIdentifier(socket)
        connections[key] = socket
        var header: [String]?
        socket.onLine = { [weak self, weak socket] line in
            guard let self, let socket else { return }
            guard let header else {
                header = String(decoding: line, as: UTF8.self).components(separatedBy: "\t")
                return
            }
            socket.onLine = nil
            connections[key] = nil
            guard let payload = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let event = HookEvent(header: header, payload: payload)
            else { return socket.close() }
            handle(event, socket: socket)
        }
        socket.onClose = { [weak self] in self?.drop(key) }
        queue.asyncAfter(deadline: .now() + 5) { [weak self] in self?.drop(key) }
    }

    /// Closes a connection that never delivered a complete event.
    private func drop(_ key: ObjectIdentifier) {
        connections.removeValue(forKey: key)?.close()
    }

    private func handle(_ event: HookEvent, socket: LineSocket) {
        if event.name == "StatusLine" {
            socket.close()
            if let limits = event.rateLimits, !NSDictionary(dictionary: limits).isEqual(to: rateLimits) {
                rateLimits = limits
                try? JSONSerialization.data(withJSONObject: limits).write(to: URL(fileURLWithPath: Self.rateLimitsPath), options: .atomic)
            }
            return
        }
        guard let agentPID = agentProcess(for: event) else { return socket.close() }
        let id = "\(event.agent):\(event.sessionID ?? "pid-\(agentPID)")"

        if event.name == "SessionEnd" {
            socket.close()
            end(id)
            return publish()
        }

        var session = sessions[id] ?? makeSession(id: id, event: event, pid: agentPID)
        var holdsConnection = false
        let previousStatus = session.status

        switch event.name {
        case "SessionStart":
            session.status = "idle"
        case "UserPromptSubmit":
            session.status = "working"
            session.detail = Self.firstLine(event.prompt) ?? session.detail
        case "PreToolUse", "PostToolUse":
            session.status = "working"
            session.detail = Self.summary(tool: event.tool, input: event.toolInput, preferDescription: true) ?? session.detail
        case "PermissionRequest":
            session.status = "needsInput"
            let summary = Self.summary(tool: event.tool, input: event.toolInput, preferDescription: false) ?? "Permission requested"
            session.detail = summary
            session.approval = summary
            resolveApproval(for: id, behavior: "defer")
            pendingApprovals[id] = socket
            holdsConnection = true
            if !Self.promptingAgents.contains(event.agent) {
                session.approvalBlocksAgent = true
                queue.asyncAfter(deadline: .now() + Self.approvalGrace) { [weak self, weak socket] in
                    guard let self, let socket, pendingApprovals[id] === socket else { return }
                    decide(id, behavior: "defer")
                }
            }
            // The agent drops the hook when the user answers in its own interface.
            socket.onClose = { [weak self, weak socket] in
                guard let self, let socket, pendingApprovals[id] === socket else { return }
                resolveApproval(for: id, behavior: "defer")
                sessions[id]?.approval = nil
                sessions[id]?.approvalBlocksAgent = false
                publish()
            }
        case "PermissionReplied":
            session.status = "working"
        case "Notification":
            if event.needsInput, session.approval == nil {
                session.status = "needsInput"
                session.detail = Self.firstLine(event.message) ?? session.detail
            }
        case "AgentResponse":
            session.detail = Self.firstLine(Self.plainText(event.reply)) ?? session.detail
        case "Stop":
            session.status = "done"
            session.detail = Self.firstLine(Self.plainText(event.reply)) ?? session.detail
        default:
            break
        }

        // Any later event means a pending request was answered elsewhere.
        if !["PermissionRequest", "Notification"].contains(event.name), session.approval != nil {
            resolveApproval(for: id, behavior: "defer")
            session.approval = nil
            session.approvalBlocksAgent = false
        }
        if session.status != previousStatus { session.since = Date() }
        sessions[id] = session
        if !holdsConnection { socket.close() }
        publish()
    }

    /// The agent's process: hooks usually run through a shell, so it is the first ancestor that is not one.
    /// Returns nil for events that must be ignored.
    private func agentProcess(for event: HookEvent) -> pid_t? {
        var pid = event.pid
        while let info = ProcessInfoReader.info(pid), Self.shells.contains(info.name), info.parent > 1 {
            pid = info.parent
        }
        // Late events from an agent that already exited would leave a session nothing removes.
        guard let name = ProcessInfoReader.info(pid)?.name else { return nil }
        // Some plugins replay Claude Code hooks from another agent, which already reports itself.
        if event.agent == "claude", name != "claude", AgentIntegrations.all.contains(where: { $0.id == name }) {
            return nil
        }
        return pid
    }

    private static let shells: Set<String> = ["sh", "bash", "zsh", "dash", "fish"]

    private func makeSession(id: String, event: HookEvent, pid: pid_t) -> Session {
        watchExit(of: pid)
        let ancestors = ProcessInfoReader.ancestors(of: pid)

        var container: [String: String]?
        if let pane = event.herdrPane {
            // Named sessions live in ~/.config/herdr/sessions/<name>/herdr.sock.
            let sessionDirectory = URL(fileURLWithPath: event.herdrSocket ?? "").deletingLastPathComponent()
            let isNamed = sessionDirectory.deletingLastPathComponent().lastPathComponent == "sessions"
            container = ["provider": "herdr", "scope": isNamed ? sessionDirectory.lastPathComponent : "", "target": pane]
        } else if let pane = event.orcaPane {
            container = ["provider": "orca", "scope": "", "target": pane]
        }

        let repository = Self.repository(containing: event.cwd)
        return Session(
            id: id, agent: event.agent, pid: pid, started: ProcessInfoReader.startTime(of: pid), ancestors: ancestors.map(Int.init),
            terminal: TerminalLocation(program: event.terminal, tty: ProcessInfoReader.tty(of: pid),
                                       app: ancestors.lazy.compactMap { ProcessInfoReader.info($0)?.name }.first(where: TerminalLocation.scriptableApps.contains),
                                       tmuxPane: event.tmuxPane, tmuxSocket: event.tmuxSocket),
            container: container,
            project: URL(fileURLWithPath: repository?.root ?? event.cwd).lastPathComponent,
            branch: repository?.branch
        )
    }

    /// Removes an agent's sessions as soon as its process exits, even without a SessionEnd event.
    private func watchExit(of pid: pid_t) {
        guard exitWatchers[pid] == nil else { return }
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            exitWatchers.removeValue(forKey: pid)?.cancel()
            for id in sessions.values.filter({ $0.pid == pid }).map(\.id) { end(id) }
            publish()
        }
        source.resume()
        exitWatchers[pid] = source
    }

    private func end(_ id: String) {
        resolveApproval(for: id, behavior: "defer")
        sessions[id] = nil
    }

    // MARK: - Approvals

    private func decide(_ id: String, behavior: String) {
        guard pendingApprovals[id] != nil else { return }
        resolveApproval(for: id, behavior: behavior)
        guard var session = sessions[id] else { return publish() }
        session.approval = nil
        session.approvalBlocksAgent = false
        if behavior != "defer" {
            session.status = "working"
            session.since = Date()
        }
        sessions[id] = session
        publish()
    }

    /// Answers a held request. "defer" replies nothing, which lets the agent ask in its own UI.
    private func resolveApproval(for id: String, behavior: String) {
        guard let socket = pendingApprovals.removeValue(forKey: id) else { return }
        if behavior == "allow" || behavior == "deny" {
            var decision: [String: Any] = ["behavior": behavior]
            if behavior == "deny" { decision["message"] = "Denied from the notch" }
            let output = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]]
            if let data = try? JSONSerialization.data(withJSONObject: output) {
                socket.send(line: data)
            }
        }
        socket.close()
    }

    private func publish() {
        let list = sessions.values.sorted { $0.id < $1.id }
        onChange(try? JSONSerialization.data(withJSONObject: ["sessions": list.map(\.json)], options: .sortedKeys))
        try? JSONEncoder().encode(list).write(to: URL(fileURLWithPath: Self.sessionsPath), options: .atomic)
    }

    /// Keeps the saved sessions whose agent is still running. Their held permission requests
    /// did not survive the restart, so the agents answer those in their own interface.
    private func restoreSessions() {
        guard let data = FileManager.default.contents(atPath: Self.sessionsPath),
              let saved = try? JSONDecoder().decode([Session].self, from: data)
        else { return }
        for var session in saved where session.started != nil && ProcessInfoReader.startTime(of: session.pid) == session.started {
            session.approval = nil
            session.approvalBlocksAgent = false
            sessions[session.id] = session
            watchExit(of: session.pid)
        }
    }

    // MARK: - Formatting

    private static func firstLine(_ text: String?) -> String? {
        text?.split(whereSeparator: \.isNewline)
            .lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
    }

    /// Drops the Markdown marks that agents use in their replies.
    private static func plainText(_ text: String?) -> String? {
        text?.replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "`", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "# "))
    }

    /// "Bash: npm test", "Edit: ContentView.swift", "claude-in-chrome · navigate".
    /// Activity prefers the agent's own description of a command; a permission request shows the command.
    private static func summary(tool rawTool: String?, input: [String: Any], preferDescription: Bool) -> String? {
        guard var tool = rawTool, !tool.isEmpty else { return nil }
        if tool.hasPrefix("mcp__") {
            tool = tool.dropFirst(5).replacingOccurrences(of: "__", with: " · ")
        }
        let keys = ["command", "file_path", "filePath", "path", "pattern", "url", "query", "description"]
        let argument = (preferDescription ? ["description"] + keys : keys)
            .lazy
            .compactMap { input[$0] as? String }
            .first
            .map { $0.hasPrefix("/") ? URL(fileURLWithPath: $0).lastPathComponent : $0 }
        guard let argument = firstLine(argument) else { return tool }
        return "\(tool): \(argument)"
    }

    /// Finds the enclosing git repository and its current branch by reading `.git` directly.
    private static func repository(containing path: String) -> (root: String, branch: String?)? {
        guard !path.isEmpty else { return nil }
        var directory = URL(fileURLWithPath: path)
        for _ in 0 ..< 16 {
            let git = directory.appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: git.path, isDirectory: &isDirectory) {
                var gitDirectory = git
                if !isDirectory.boolValue,
                   let pointer = try? String(contentsOf: git, encoding: .utf8),
                   let target = pointer.components(separatedBy: "gitdir:").last?.trimmingCharacters(in: .whitespacesAndNewlines)
                {
                    gitDirectory = URL(fileURLWithPath: target, relativeTo: directory)
                }
                let head = try? String(contentsOf: gitDirectory.appendingPathComponent("HEAD"), encoding: .utf8)
                let branch = head.flatMap { $0.hasPrefix("ref: refs/heads/") ? String($0.dropFirst(16)).trimmingCharacters(in: .whitespacesAndNewlines) : nil }
                return (directory.path, branch)
            }
            let parent = directory.deletingLastPathComponent()
            guard parent.path != directory.path else { break }
            directory = parent
        }
        return nil
    }
}

/// One hook event, with each agent's naming mapped onto Claude Code's.
private struct HookEvent {
    let agent: String
    let pid: pid_t
    let name: String
    let sessionID: String?
    let cwd: String
    let tool: String?
    let toolInput: [String: Any]
    let prompt: String?
    let message: String?
    let reply: String?
    let needsInput: Bool
    let rateLimits: [String: Any]?
    let terminal: String?
    let herdrPane: String?
    let herdrSocket: String?
    let orcaPane: String?
    let tmuxPane: String?
    let tmuxSocket: String?

    /// Event names used by the supported agents, mapped onto Claude Code's.
    private static let names: [String: String] = [
        "beforeSubmitPrompt": "UserPromptSubmit", "userPromptSubmitted": "UserPromptSubmit", "userPromptSubmit": "UserPromptSubmit",
        "user_prompt_submit": "UserPromptSubmit", "BeforeAgent": "UserPromptSubmit", "TaskResume": "UserPromptSubmit",
        "beforeShellExecution": "PreToolUse", "beforeReadFile": "PreToolUse", "beforeMCPExecution": "PreToolUse",
        "preToolUse": "PreToolUse", "pre_tool_use": "PreToolUse", "BeforeTool": "PreToolUse",
        "afterShellExecution": "PostToolUse", "afterFileEdit": "PostToolUse", "afterMCPExecution": "PostToolUse",
        "postToolUse": "PostToolUse", "post_tool_use": "PostToolUse", "AfterTool": "PostToolUse",
        "afterAgentResponse": "AgentResponse",
        "stop": "Stop", "StopFailure": "Stop", "AfterAgent": "Stop", "TaskComplete": "Stop", "TaskCancel": "Stop", "errorOccurred": "Stop",
        "sessionStart": "SessionStart", "agentSpawn": "SessionStart", "session_start": "SessionStart", "TaskStart": "SessionStart",
        "sessionEnd": "SessionEnd", "session_end": "SessionEnd",
        "permission_request": "PermissionRequest", "notification": "Notification",
    ]

    init?(header: [String], payload: [String: Any]) {
        let field = { (index: Int) in header.indices.contains(index) && !header[index].isEmpty ? header[index] : nil }
        let text = { (keys: [String]) in keys.lazy.compactMap { payload[$0] as? String }.first { !$0.isEmpty } }
        guard var agent = field(0), let pid = field(1).flatMap(Int32.init),
              let rawName = text(["hook_event_name", "hookEventName", "eventName", "hookName"]) ?? field(2)
        else { return nil }

        // Cursor runs Claude Code's hooks too; its payloads say so.
        if agent == "claude", payload["cursor_version"] != nil { agent = "cursor" }

        self.agent = agent
        self.pid = pid
        name = Self.names[rawName] ?? rawName
        sessionID = text(["session_id", "sessionId", "conversation_id", "conversationId", "taskId"])
        cwd = text(["cwd", "workspaceRoot"]) ?? (payload["workspace_roots"] as? [String])?.first ?? ""

        // Cline nests tool details; Copilot sends its arguments as a JSON string.
        let nested = (payload["preToolUse"] ?? payload["postToolUse"]) as? [String: Any]
        tool = text(["tool_name", "toolName", "tool"]) ?? nested?["toolName"] as? String
            ?? (payload["command"] != nil ? "Shell" : nil)
        var input = (payload["tool_input"] ?? payload["parameters"] ?? nested?["parameters"]) as? [String: Any] ?? [:]
        if input.isEmpty, let arguments = (payload["toolArgs"] as? String)?.data(using: .utf8) {
            input = (try? JSONSerialization.jsonObject(with: arguments)) as? [String: Any] ?? [:]
        }
        if input.isEmpty, let command = payload["command"] as? String { input = ["command": command] }
        toolInput = input

        prompt = text(["prompt", "userPrompt", "user_prompt"])
        message = text(["message", "title"])
        reply = text(["last_assistant_message", "prompt_response", "text", "response"])
        let notificationType = text(["notification_type", "notificationType"]) ?? ""
        needsInput = ["permission_prompt", "elicitation_dialog", "agent_needs_input"].contains(notificationType)
        rateLimits = payload["rate_limits"] as? [String: Any]

        terminal = field(3)
        herdrPane = field(4)
        herdrSocket = field(5)
        orcaPane = field(6)
        tmuxPane = field(7)
        tmuxSocket = field(8)?.components(separatedBy: ",").first
    }
}

/// Reads process parents, names and terminals with sysctl, without spawning anything.
enum ProcessInfoReader {
    static func info(_ pid: pid_t) -> (parent: pid_t, name: String)? {
        guard let info = kinfo(pid) else { return nil }
        let name = withUnsafeBytes(of: info.kp_proc.p_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return (info.kp_eproc.e_ppid, name)
    }

    /// Parents of `pid`, nearest first.
    static func ancestors(of pid: pid_t) -> [pid_t] {
        var chain: [pid_t] = []
        var current = info(pid)?.parent
        while let parent = current, parent > 1, chain.count < 32 {
            chain.append(parent)
            current = info(parent)?.parent
        }
        return chain
    }

    /// When `pid` started, in seconds since 1970.
    static func startTime(of pid: pid_t) -> Double? {
        guard let start = kinfo(pid)?.kp_proc.p_starttime else { return nil }
        return Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000
    }

    /// The controlling terminal of `pid`, e.g. "/dev/ttys004".
    static func tty(of pid: pid_t) -> String? {
        guard let device = kinfo(pid)?.kp_eproc.e_tdev, device != -1, let name = devname(device, S_IFCHR) else { return nil }
        return "/dev/" + String(cString: name)
    }

    private static func kinfo(_ pid: pid_t) -> kinfo_proc? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info
    }
}
