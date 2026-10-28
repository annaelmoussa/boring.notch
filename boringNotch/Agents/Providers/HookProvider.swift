//
//  HookProvider.swift
//  boringNotch
//

import AppKit
import Foundation

/// Agents that report themselves through hooks or plugins: Claude Code, Codex, OpenCode and Pi.
/// The helper's `HookMonitor` receives their events; this provider also answers their
/// permission requests and manages the integrations.
enum HookProvider: AgentProvider {
    static let id = "hooks"
    static let name = "Terminal"

    /// Agents with an integration, in display order.
    static let integrations: [(id: String, name: String)] = [
        ("claude", "Claude Code"), ("codex", "Codex"), ("opencode", "OpenCode"), ("pi", "Pi"),
    ]

    struct IntegrationStatus: Decodable {
        let available: Bool
        let installed: Bool
    }

    private struct Payload: Decodable {
        struct Session: Decodable {
            let id: String
            let agent: String
            let ancestors: [Int]
            let terminal: String?
            let container: [String: String]?
            let project: String
            let branch: String?
            let status: String
            let detail: String?
            let since: Double
            let approval: String?
            let approvalBlocksAgent: Bool?
        }

        let sessions: [Session]
    }

    static func sessions(from payload: Data) -> [AgentSession] {
        guard let payload = try? JSONDecoder().decode(Payload.self, from: payload) else { return [] }
        return payload.sessions.map { session in
            let host = hostApplication(among: session.ancestors)
            return AgentSession(
                id: session.id,
                provider: id,
                agent: session.agent,
                title: session.branch.map { "\(session.project) · \($0)" } ?? session.project,
                detail: session.detail,
                status: status(session.status),
                since: Date(timeIntervalSince1970: session.since / 1000),
                focusTarget: session.id,
                location: host?.localizedName ?? session.terminal.map { terminalNames[$0] ?? $0 },
                hostPID: host?.processIdentifier,
                containerID: containerID(session.container),
                approval: session.approval,
                approvalBlocksAgent: session.approvalBlocksAgent ?? false
            )
        }
    }

    static func focus(_ session: AgentSession) async {
        await MainActor.run {
            session.hostPID.flatMap { NSRunningApplication(processIdentifier: $0) }?.activate()
        }
    }

    // MARK: - Permission requests

    static func respond(to session: AgentSession, with decision: AgentDecision) async {
        _ = await request(["decide": session.id, "behavior": decision.rawValue])
    }

    // MARK: - Integrations

    static func integrationStatus() async -> [String: IntegrationStatus] {
        await integrations(["integrations": "status"])
    }

    static func install(_ agent: String) async -> [String: IntegrationStatus] {
        await integrations(["install": agent])
    }

    static func uninstall(_ agent: String) async -> [String: IntegrationStatus] {
        await integrations(["uninstall": agent])
    }

    private static func integrations(_ body: [String: String]) async -> [String: IntegrationStatus] {
        guard let reply = await request(body) else { return [:] }
        return (try? JSONDecoder().decode([String: IntegrationStatus].self, from: reply)) ?? [:]
    }

    private static func request(_ body: [String: String]) async -> Data? {
        guard let payload = try? JSONEncoder().encode(body) else { return nil }
        return await XPCHelperClient.shared.agentRequest(id, payload: payload)
    }

    /// Display names for `TERM_PROGRAM`, used when the hosting app cannot be identified.
    private static let terminalNames = [
        "Apple_Terminal": "Terminal", "ghostty": "Ghostty", "iTerm.app": "iTerm", "vscode": "VS Code",
        "WarpTerminal": "Warp", "WezTerm": "WezTerm", "zed": "Zed", "tmux": "tmux",
    ]

    /// `{"provider": "herdr", "scope": "", "target": "w1:p1"}` → the id that provider gives the agent.
    private static func containerID(_ container: [String: String]?) -> String? {
        guard let container, let provider = container["provider"], let target = container["target"] else { return nil }
        let scope = container["scope"].flatMap { $0.isEmpty ? nil : $0 }
        return AgentSession.id(provider: provider, scope: scope, target: target)
    }

    private static func status(_ raw: String) -> AgentStatus {
        switch raw {
        case "needsInput": .needsInput
        case "working": .working
        case "done": .done
        default: .idle
        }
    }
}
