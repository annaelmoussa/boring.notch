//
//  HerdrProvider.swift
//  boringNotch
//

import AppKit
import Foundation

/// https://herdr.dev — terminal workspace manager for coding agents.
enum HerdrProvider: AgentProvider {
    static let id = "herdr"
    static let name = "Herdr"

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
        let response: AgentResponse<SnapshotResult>
    }

    static func sessions(from payload: Data) -> [AgentSession] {
        guard let servers = try? JSONDecoder().decode([Session].self, from: payload) else { return [] }
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
                id: AgentSession.id(provider: id, scope: session, target: agent.pane_id),
                provider: id,
                agent: kind,
                title: agent.name ?? workspaceLabels[agent.workspace_id] ?? agent.pane_id,
                detail: firstAgentLine(agent.title),
                status: Self.status(agent.agent_status),
                since: nil,
                focusTarget: agent.pane_id,
                scope: session,
                canReply: true
            )
        }
    }

    /// Focuses the pane in Herdr, then brings the terminal running that Herdr session forward.
    static func focus(_ session: AgentSession) async {
        _ = await XPCHelperClient.shared.runAgentCLI("herdr", arguments: sessionArguments(session) + ["agent", "focus", session.focusTarget])

        let request = try? JSONEncoder().encode(["terminalFor": session.scope ?? ""])
        let reply = await XPCHelperClient.shared.agentRequest(id, payload: request ?? Data())
        let ancestors = reply.flatMap { try? JSONDecoder().decode([Int].self, from: $0) } ?? []
        await MainActor.run {
            _ = hostApplication(among: ancestors)?.activate()
        }
    }

    static func reply(to session: AgentSession, text: String) async -> Bool {
        await XPCHelperClient.shared.runAgentCLI("herdr", arguments: sessionArguments(session) + ["pane", "run", session.focusTarget, text]) != nil
    }

    private static func sessionArguments(_ session: AgentSession) -> [String] {
        session.scope.map { ["--session", $0] } ?? []
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
