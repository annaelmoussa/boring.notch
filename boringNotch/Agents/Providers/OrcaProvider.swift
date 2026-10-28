//
//  OrcaProvider.swift
//  boringNotch
//

import AppKit
import Foundation

/// https://github.com/stablyai/orca — desktop app for running agents in git worktrees.
enum OrcaProvider: AgentProvider {
    static let id = "orca"
    static let name = "Orca"

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

    static func sessions(from payload: Data) -> [AgentSession] {
        guard let list = decodeAgentResponse(payload, as: WorktreeList.self) else { return [] }

        return list.worktrees.flatMap { worktree in
            let title = worktree.repo == worktree.displayName
                ? worktree.repo
                : "\(worktree.repo) · \(worktree.displayName)"

            return (worktree.agents ?? []).map { agent in
                AgentSession(
                    id: AgentSession.id(provider: id, scope: nil, target: agent.paneKey),
                    provider: id,
                    agent: agent.agentType,
                    title: title,
                    detail: firstAgentLine(agent.taskTitle ?? agent.displayName ?? agent.prompt),
                    status: Self.status(agent.state),
                    since: agent.stateStartedAt.map { Date(timeIntervalSince1970: $0 / 1000) },
                    focusTarget: agent.paneKey,
                    canReply: true
                )
            }
        }
    }

    static func focus(_ session: AgentSession) async {
        if let handle = await terminalHandle(of: session) {
            _ = await XPCHelperClient.shared.runAgentCLI("orca", arguments: ["terminal", "switch", "--terminal", handle])
        }
        await MainActor.run {
            NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier).first?.activate()
        }
    }

    static func reply(to session: AgentSession, text: String) async -> Bool {
        guard let handle = await terminalHandle(of: session) else { return false }
        return await XPCHelperClient.shared.runAgentCLI("orca", arguments: ["terminal", "send", "--terminal", handle, "--text", text, "--enter"]) != nil
    }

    /// Orca pane keys are "<tabId>:<leafId>"; terminal commands take a handle instead.
    private static func terminalHandle(of session: AgentSession) async -> String? {
        await runAgentCLI("orca", ["terminal", "list", "--json"], as: TerminalList.self)?
            .terminals
            .first { "\($0.tabId ?? ""):\($0.leafId ?? "")" == session.focusTarget }?
            .handle
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
