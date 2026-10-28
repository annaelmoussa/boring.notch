//
//  AgentSources.swift
//  boringNotch
//
//  Turns the raw state pushed by the XPC helper into agent sessions, and focuses agents.
//  The helper talks to the tools' local sockets, which the sandboxed app cannot reach.
//

import AppKit
import Foundation

/// Herdr socket responses and Orca runtime responses share the `{"result": ...}` envelope.
private struct Response<Result: Decodable>: Decodable {
    let result: Result
}

private func decode<Result: Decodable>(_ data: Data?, as _: Result.Type) -> Result? {
    guard let data else { return nil }
    return try? JSONDecoder().decode(Response<Result>.self, from: data).result
}

private func runCLI<Result: Decodable>(_ tool: String, _ arguments: [String], as type: Result.Type) async -> Result? {
    decode(await XPCHelperClient.shared.runAgentCLI(tool, arguments: arguments), as: type)
}

/// Collapses a free-form text to its first non-empty line.
private func firstLine(_ text: String?) -> String? {
    text?
        .split(whereSeparator: \.isNewline)
        .lazy
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .first { !$0.isEmpty }
}

// MARK: - Herdr

/// https://herdr.dev — terminal workspace manager for coding agents.
enum HerdrSource {
    private struct Snapshot: Decodable {
        struct Workspace: Decodable {
            let workspace_id: String
            let label: String
        }

        struct Agent: Decodable {
            let pane_id: String
            let workspace_id: String
            let agent: String?
            let display_agent: String?
            let name: String?
            let title: String?
            let agent_status: String
        }

        let workspaces: [Workspace]
        let agents: [Agent]
    }

    private struct SnapshotResult: Decodable {
        let snapshot: Snapshot
    }

    /// One entry per running Herdr server, as published by the helper.
    private struct Session: Decodable {
        /// Named session, or nil for the default one.
        let session: String?
        let response: Response<SnapshotResult>
    }

    static func sessions(from data: Data?) -> [AgentSession] {
        guard let data, let servers = try? JSONDecoder().decode([Session].self, from: data) else { return [] }
        return servers.flatMap { sessions(in: $0.response.result.snapshot, session: $0.session) }
    }

    private static func sessions(in snapshot: Snapshot, session: String?) -> [AgentSession] {
        let workspaceLabels = Dictionary(
            snapshot.workspaces.map { ($0.workspace_id, $0.label) },
            uniquingKeysWith: { first, _ in first }
        )

        return snapshot.agents.compactMap { agent in
            guard let kind = agent.display_agent ?? agent.agent else { return nil }
            return AgentSession(
                id: "herdr:\(session ?? ""):\(agent.pane_id)",
                source: .herdr,
                agent: kind,
                title: agent.name ?? workspaceLabels[agent.workspace_id] ?? agent.pane_id,
                detail: firstLine(agent.title),
                status: Self.status(agent.agent_status),
                since: nil,
                focusTarget: agent.pane_id,
                scope: session
            )
        }
    }

    /// Focuses the pane in Herdr, then brings the terminal running that Herdr session forward.
    static func focus(_ session: AgentSession) async {
        let sessionArguments = session.scope.map { ["--session", $0] } ?? []
        _ = await XPCHelperClient.shared.runAgentCLI("herdr", arguments: sessionArguments + ["agent", "focus", session.focusTarget])

        let ancestors = await XPCHelperClient.shared.herdrClientAncestors(forSession: session.scope ?? "")
        await MainActor.run {
            ancestors.lazy
                .compactMap { NSRunningApplication(processIdentifier: pid_t($0)) }
                .first { $0.activationPolicy == .regular }?
                .activate()
        }
    }

    private static func status(_ raw: String) -> AgentStatus {
        switch raw {
        case "blocked": .needsInput
        case "working": .working
        case "done": .done
        default: .idle
        }
    }
}

// MARK: - Orca

/// https://github.com/stablyai/orca — desktop app for running agents in git worktrees.
enum OrcaSource {
    private static let bundleIdentifier = "com.stablyai.orca"

    private struct WorktreeList: Decodable {
        struct Worktree: Decodable {
            let repo: String
            let displayName: String
            let agents: [Agent]?
        }

        struct Agent: Decodable {
            let paneKey: String
            let state: String
            let agentType: String
            let taskTitle: String?
            let displayName: String?
            let prompt: String?
            let stateStartedAt: Double?
        }

        let worktrees: [Worktree]
    }

    private struct TerminalList: Decodable {
        struct Terminal: Decodable {
            let handle: String
            let tabId: String?
            let leafId: String?
        }

        let terminals: [Terminal]
    }

    static func sessions(from data: Data?) -> [AgentSession] {
        guard let list = decode(data, as: WorktreeList.self) else { return [] }

        return list.worktrees.flatMap { worktree in
            let title = worktree.repo == worktree.displayName
                ? worktree.repo
                : "\(worktree.repo) · \(worktree.displayName)"

            return (worktree.agents ?? []).map { agent in
                AgentSession(
                    id: "orca:\(agent.paneKey)",
                    source: .orca,
                    agent: agent.agentType,
                    title: title,
                    detail: firstLine(agent.taskTitle ?? agent.displayName ?? agent.prompt),
                    status: Self.status(agent.state),
                    since: agent.stateStartedAt.map { Date(timeIntervalSince1970: $0 / 1000) },
                    focusTarget: agent.paneKey
                )
            }
        }
    }

    static func focus(_ session: AgentSession) async {
        // Orca pane keys are "<tabId>:<leafId>"; terminal commands take a handle instead.
        if let terminals = await runCLI("orca", ["terminal", "list", "--json"], as: TerminalList.self),
           let terminal = terminals.terminals.first(where: { "\($0.tabId ?? ""):\($0.leafId ?? "")" == session.focusTarget })
        {
            _ = await XPCHelperClient.shared.runAgentCLI("orca", arguments: ["terminal", "switch", "--terminal", terminal.handle])
        }
        await MainActor.run {
            NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier).first?.activate()
        }
    }

    private static func status(_ raw: String) -> AgentStatus {
        switch raw {
        case "blocked", "waiting": .needsInput
        case "working": .working
        case "done": .done
        default: .idle
        }
    }
}
