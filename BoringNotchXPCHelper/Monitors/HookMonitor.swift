//
//  HookMonitor.swift
//  BoringNotchXPCHelper
//
//  Agents that run on their own (Claude Code, Codex, OpenCode, Pi) report their lifecycle
//  through hooks or plugins installed by `AgentIntegrations`. Each event arrives as one
//  connection on a Unix socket, so nothing runs between events.
//

import Foundation

/// Tracks hook-reported sessions and holds permission requests until the user answers them.
///
/// Wire format, one connection per event:
/// ```
/// <agent>\t<pid>\t<TERM_PROGRAM>\t<HERDR_PANE_ID>\t<HERDR_SOCKET_PATH>\t<ORCA_PANE_KEY>\n
/// <event JSON, using Claude Code hook field names>\n
/// ```
/// A `PermissionRequest` connection stays open until a decision line is written back.
final class HookMonitor: AgentMonitor {
    static let id = "hooks"
    static let tools: [String] = []

    static let directory = NSHomeDirectory() + "/.boringnotch"
    static let socketPath = directory + "/agents.sock"

    private struct Session {
        let id: String
        let agent: String
        let pid: pid_t
        var ancestors: [Int]
        var terminal: String?
        var container: [String: String]?
        var cwd: String
        var project: String
        var branch: String?
        var status = "idle"
        var detail: String?
        var since = Date()
        var approval: String?
        /// The agent shows nothing else until the request is answered.
        var approvalBlocksAgent = false

        var json: [String: Any] {
            var json: [String: Any] = [
                "id": id, "agent": agent, "pid": Int(pid), "ancestors": ancestors,
                "project": project, "status": status, "since": since.timeIntervalSince1970 * 1000,
            ]
            json["terminal"] = terminal
            json["container"] = container
            json["branch"] = branch
            json["detail"] = detail
            json["approval"] = approval
            json["approvalBlocksAgent"] = approvalBlocksAgent
            return json
        }
    }

    /// Agents that wait for permission hooks before showing their own prompt, and how long
    /// the notch may hold a request before handing it back to them.
    private static let blockingAgents: [String: TimeInterval] = ["codex": 20]

    private let queue: DispatchQueue
    private let onChange: (Data?) -> Void
    private var listener: LineSocketListener?
    /// Connections still sending their event.
    private var connections: [ObjectIdentifier: LineSocket] = [:]
    private var sessions: [String: Session] = [:]
    /// Open `PermissionRequest` connections, keyed by session id.
    private var pendingApprovals: [String: LineSocket] = [:]
    private var exitWatchers: [pid_t: DispatchSourceProcess] = [:]

    init(queue: DispatchQueue, onChange: @escaping (Data?) -> Void) {
        self.queue = queue
        self.onChange = onChange
        try? FileManager.default.createDirectory(atPath: Self.directory, withIntermediateDirectories: true)
        listener = LineSocketListener(path: Self.socketPath, queue: queue) { [weak self] socket in
            self?.receive(on: socket)
        }
        publish()
    }

    /// Requests from the app:
    /// - `{"decide": <session id>, "behavior": "allow" | "deny" | "defer"}`
    /// - `{"integrations": "status"}`, `{"install": <agent>}`, `{"uninstall": <agent>}`
    func handle(_ request: Data, reply: @escaping (Data?) -> Void) {
        guard let object = try? JSONSerialization.jsonObject(with: request) as? [String: String] else { return reply(nil) }

        if let id = object["decide"], let behavior = object["behavior"] {
            decide(id, behavior: behavior)
            return reply(Data())
        }
        if let agent = object["install"] {
            AgentIntegrations.install(agent)
        } else if let agent = object["uninstall"] {
            AgentIntegrations.uninstall(agent)
        } else if object["integrations"] == nil {
            return reply(nil)
        }
        reply(try? JSONSerialization.data(withJSONObject: AgentIntegrations.status()))
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
            guard let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return socket.close() }
            handle(event, header: header, socket: socket)
        }
        socket.onClose = { [weak self] in self?.drop(key) }
        queue.asyncAfter(deadline: .now() + 5) { [weak self] in self?.drop(key) }
    }

    /// Closes a connection that never delivered a complete event.
    private func drop(_ key: ObjectIdentifier) {
        connections.removeValue(forKey: key)?.close()
    }

    private func handle(_ event: [String: Any], header: [String], socket: LineSocket) {
        let field = { (index: Int) in header.indices.contains(index) && !header[index].isEmpty ? header[index] : nil }
        guard let agent = field(0), let rawPID = field(1).flatMap(Int32.init),
              let sessionID = event["session_id"] as? String,
              let name = event["hook_event_name"] as? String
        else { return socket.close() }

        let id = "\(agent):\(sessionID)"
        if name == "SessionEnd" {
            socket.close()
            end(id)
            return publish()
        }

        guard var session = sessions[id] ?? makeSession(id: id, agent: agent, pid: rawPID, header: field, event: event) else {
            return socket.close()
        }
        var holdsConnection = false
        let previousStatus = session.status

        switch name {
        case "SessionStart":
            session.status = "idle"
        case "UserPromptSubmit":
            session.status = "working"
            session.detail = Self.firstLine(event["prompt"] as? String) ?? session.detail
        case "PreToolUse", "PostToolUse":
            session.status = "working"
            session.detail = Self.summary(tool: event["tool_name"] as? String, input: event["tool_input"], preferDescription: true)
        case "PermissionRequest":
            session.status = "needsInput"
            let summary = Self.summary(tool: event["tool_name"] as? String, input: event["tool_input"], preferDescription: false) ?? "Permission requested"
            session.detail = summary
            session.approval = summary
            resolveApproval(for: id, behavior: "defer")
            pendingApprovals[id] = socket
            holdsConnection = true
            if let grace = Self.blockingAgents[agent] {
                session.approvalBlocksAgent = true
                queue.asyncAfter(deadline: .now() + grace) { [weak self, weak socket] in
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
            let type = event["notification_type"] as? String
            if ["permission_prompt", "elicitation_dialog", "agent_needs_input"].contains(type ?? ""), session.approval == nil {
                session.status = "needsInput"
                session.detail = Self.firstLine(event["message"] as? String) ?? session.detail
            }
        case "Stop", "StopFailure":
            session.status = "done"
            session.detail = Self.firstLine(Self.plainText(event["last_assistant_message"] as? String)) ?? session.detail
        default:
            break
        }

        // Any later event means a pending request was answered elsewhere.
        if name != "PermissionRequest", name != "Notification", session.approval != nil {
            resolveApproval(for: id, behavior: "defer")
            session.approval = nil
            session.approvalBlocksAgent = false
        }
        if session.status != previousStatus { session.since = Date() }
        sessions[id] = session
        if !holdsConnection { socket.close() }
        publish()
    }

    private func makeSession(id: String, agent: String, pid rawPID: pid_t, header field: (Int) -> String?, event: [String: Any]) -> Session? {
        // Hooks run through a shell; the agent is the first ancestor that is not one.
        var pid = rawPID
        while let info = ProcessInfoReader.info(pid), Self.shells.contains(info.name), info.parent > 1 {
            pid = info.parent
        }
        // Late events from an agent that already exited would leave a session nothing removes.
        guard let name = ProcessInfoReader.info(pid)?.name else { return nil }
        // Some OpenCode plugins replay Claude Code hooks; that agent already reports itself.
        if AgentIntegrations.agents.contains(name), name != agent {
            return nil
        }
        watchExit(of: pid)

        var container: [String: String]?
        if let pane = field(3) {
            // Named sessions live in ~/.config/herdr/sessions/<name>/herdr.sock.
            let sessionDirectory = URL(fileURLWithPath: field(4) ?? "").deletingLastPathComponent()
            let isNamed = sessionDirectory.deletingLastPathComponent().lastPathComponent == "sessions"
            container = ["provider": "herdr", "scope": isNamed ? sessionDirectory.lastPathComponent : "", "target": pane]
        } else if let pane = field(5) {
            container = ["provider": "orca", "scope": "", "target": pane]
        }

        let cwd = event["cwd"] as? String ?? ""
        let repository = Self.repository(containing: cwd)
        return Session(
            id: id, agent: agent, pid: pid,
            ancestors: ProcessInfoReader.ancestors(of: pid),
            terminal: field(2), container: container, cwd: cwd,
            project: URL(fileURLWithPath: repository?.root ?? cwd).lastPathComponent,
            branch: repository?.branch
        )
    }

    private static let shells: Set<String> = ["sh", "bash", "zsh", "dash", "fish"]

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
        let list = sessions.values.sorted { $0.id < $1.id }.map(\.json)
        onChange(try? JSONSerialization.data(withJSONObject: ["sessions": list], options: .sortedKeys))
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
    private static func summary(tool rawTool: String?, input: Any?, preferDescription: Bool) -> String? {
        guard var tool = rawTool, !tool.isEmpty else { return nil }
        if tool.hasPrefix("mcp__") {
            tool = tool.dropFirst(5).replacingOccurrences(of: "__", with: " · ")
        }
        let input = input as? [String: Any] ?? [:]
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

/// Reads process parents and names with sysctl, without spawning anything.
enum ProcessInfoReader {
    static func info(_ pid: pid_t) -> (parent: pid_t, name: String)? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let name = withUnsafeBytes(of: info.kp_proc.p_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return (info.kp_eproc.e_ppid, name)
    }

    /// Parents of `pid`, nearest first.
    static func ancestors(of pid: pid_t) -> [Int] {
        var chain: [Int] = []
        var current = info(pid)?.parent
        while let parent = current, parent > 1, chain.count < 32 {
            chain.append(Int(parent))
            current = info(parent)?.parent
        }
        return chain
    }
}
