//
//  HookProvider.swift
//  boringNotch
//

import AppKit
import Foundation

/// Agents that report themselves through hooks or plugins (Claude Code, Codex, Gemini CLI, Cursor,
/// OpenCode, Pi and more). The helper's `HookMonitor` receives their events; this provider also
/// answers their permission requests, types replies into their terminal and manages the integrations.
enum HookProvider: AgentProvider {
    static let id = "hooks"
    static let name = "Terminal"

    struct Integration: Decodable, Identifiable {
        let name: String
        let agent: String
        let available: Bool
        let installed: Bool
        let note: String?

        var id: String { name }
    }

    /// Plan usage per provider: rate limit windows (Claude, Codex) or a credit balance (OpenRouter).
    struct Usage: Decodable, Equatable {
        struct Provider: Decodable, Equatable, Identifiable {
            let name: String
            let windows: [Window]?
            let balance: Double?

            var id: String { name }
        }

        struct Window: Decodable, Equatable {
            let label: String
            let percent: Double
            let resetsAt: Date?
        }

        let providers: [Provider]
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
            let approvalBlocksAgent: Bool
            let canReply: Bool
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
                container: container(session.container),
                approval: session.approval,
                approvalBlocksAgent: session.approvalBlocksAgent,
                canReply: session.canReply
            )
        }
    }

    /// Selects the agent's exact tab or pane when its terminal allows it, otherwise brings the terminal forward.
    static func focus(_ session: AgentSession) async {
        if await request(["focus": session.id]) == Data("true".utf8) { return }
        await MainActor.run {
            _ = session.hostPID.flatMap { NSRunningApplication(processIdentifier: $0) }?.activate()
        }
    }

    static func reply(to session: AgentSession, text: String) async -> Bool {
        await request(["reply": session.id, "text": text]) == Data("true".utf8)
    }

    static func respond(to session: AgentSession, with decision: AgentDecision) async {
        _ = await request(["decide": session.id, "behavior": decision.rawValue])
    }

    // MARK: - Integrations

    static func integrations() async -> [Integration] {
        await integrations(["integrations": "status"])
    }

    static func install(_ integration: Integration) async -> [Integration] {
        await integrations(["install": integration.name])
    }

    static func uninstall(_ integration: Integration) async -> [Integration] {
        await integrations(["uninstall": integration.name])
    }

    private static func integrations(_ body: [String: String]) async -> [Integration] {
        guard let reply = await request(body) else { return [] }
        return (try? JSONDecoder().decode([Integration].self, from: reply)) ?? []
    }

    // MARK: - Usage

    static func usage(includeOpenRouter: Bool) async -> Usage? {
        guard let reply = await request(["usage": "all", "openrouter": includeOpenRouter ? "on" : "off"]) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return (try? decoder.decode(Usage.self, from: reply)).flatMap { $0.providers.isEmpty ? nil : $0 }
    }

    /// Relays Claude Code's status line, which carries plan usage, to the notch.
    static func setUsageRelay(_ enabled: Bool) async {
        _ = await request(["usageRelay": enabled ? "on" : "off"])
    }

    private static func request(_ body: [String: String]) async -> Data? {
        guard let payload = try? JSONEncoder().encode(body) else { return nil }
        return await XPCHelperClient.shared.agentRequest(id, payload: payload)
    }

    // MARK: - Helpers

    /// Display names for `TERM_PROGRAM`, used when the hosting app cannot be identified.
    private static let terminalNames = [
        "Apple_Terminal": "Terminal", "ghostty": "Ghostty", "iTerm.app": "iTerm", "vscode": "VS Code",
        "WarpTerminal": "Warp", "WezTerm": "WezTerm", "zed": "Zed", "tmux": "tmux",
    ]

    /// `{"provider": "herdr", "scope": "", "target": "w1:p1"}`
    private static func container(_ container: [String: String]?) -> AgentContainer? {
        guard let container, let provider = container["provider"], let target = container["target"] else { return nil }
        return AgentContainer(provider: provider, scope: container["scope"].flatMap { $0.isEmpty ? nil : $0 }, target: target)
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
