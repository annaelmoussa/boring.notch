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
                    id: "orca:\(agent.paneKey)",
                    provider: id,
                    agent: agent.agentType,
                    title: title,
                    detail: firstAgentLine(agent.taskTitle ?? agent.displayName ?? agent.prompt),
                    status: Self.status(agent.state),
                    since: agent.stateStartedAt.map { Date(timeIntervalSince1970: $0 / 1000) },
                    focusTarget: agent.paneKey
                )
            }
        }
    }

    static func focus(_ session: AgentSession) async {
        // Orca pane keys are "<tabId>:<leafId>"; terminal commands take a handle instead.
        if let terminals = await runAgentCLI("orca", ["terminal", "list", "--json"], as: TerminalList.self),
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
