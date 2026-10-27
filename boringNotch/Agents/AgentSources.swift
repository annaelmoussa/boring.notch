//
//  AgentSources.swift
//  boringNotch
//
//  Reads agent state from workspace manager CLIs. The CLIs run in the XPC helper
//  because the sandboxed app cannot reach their local sockets.
//

import AppKit
import Foundation

protocol AgentSessionSource {
    func fetchSessions() async -> [AgentSession]
    func focus(_ session: AgentSession) async
}

private struct CLIResponse<Result: Decodable>: Decodable {
    let result: Result
}

private func runCLI<Result: Decodable>(_ tool: String, _ arguments: [String], as _: Result.Type) async -> Result? {
    guard let data = await XPCHelperClient.shared.runAgentCLI(tool, arguments: arguments) else { return nil }
    return try? JSONDecoder().decode(CLIResponse<Result>.self, from: data).result
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
struct HerdrSource: AgentSessionSource {
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

    func fetchSessions() async -> [AgentSession] {
        guard let snapshot = await runCLI("herdr", ["api", "snapshot"], as: SnapshotResult.self)?.snapshot else {
            return []
        }
        let workspaceLabels = Dictionary(
            snapshot.workspaces.map { ($0.workspace_id, $0.label) },
            uniquingKeysWith: { first, _ in first }
        )

        return snapshot.agents.compactMap { agent in
            guard let kind = agent.display_agent ?? agent.agent else { return nil }
            return AgentSession(
                id: "herdr:\(agent.pane_id)",
                source: .herdr,
                agent: kind,
                title: agent.name ?? workspaceLabels[agent.workspace_id] ?? agent.pane_id,
                detail: firstLine(agent.title),
                status: Self.status(agent.agent_status),
                since: nil,
                focusTarget: agent.pane_id
            )
        }
    }

    func focus(_ session: AgentSession) async {
        _ = await XPCHelperClient.shared.runAgentCLI("herdr", arguments: ["agent", "focus", session.focusTarget])
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
struct OrcaSource: AgentSessionSource {
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

    func fetchSessions() async -> [AgentSession] {
        guard let list = await runCLI("orca", ["worktree", "ps", "--json"], as: WorktreeList.self) else {
            return []
        }

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

    func focus(_ session: AgentSession) async {
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
