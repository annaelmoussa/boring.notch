//
//  AgentProvider.swift
//  boringNotch
//
//  The app knows nothing about specific tools: each one is an `AgentProvider` here, paired
//  with an `AgentMonitor` in the XPC helper, which reaches the tool outside the sandbox.
//

import Foundation

/// A tool that runs coding agents, such as a terminal workspace manager or an agent IDE.
///
/// To support a new tool, add a type conforming to this protocol to `AgentProviders.all`, and an
/// `AgentMonitor` with the same `id` to the XPC helper's `AgentEventMonitor.monitorTypes`.
protocol AgentProvider {
    /// Identifier shared with the helper-side monitor.
    static var id: String { get }
    /// Name shown next to each agent and in Settings.
    static var name: String { get }
    /// Decodes the latest payload published by the helper-side monitor.
    static func sessions(from payload: Data) -> [AgentSession]
    /// Brings the agent to the front.
    static func focus(_ session: AgentSession) async
}

enum AgentProviders {
    static let all: [any AgentProvider.Type] = [HerdrProvider.self, OrcaProvider.self]

    static func provider(id: String) -> (any AgentProvider.Type)? {
        all.first { $0.id == id }
    }
}

// MARK: - Helpers for providers

/// The `{"result": ...}` envelope used by JSON-RPC style tool APIs.
struct AgentResponse<Result: Decodable>: Decodable {
    let result: Result
}

func decodeAgentResponse<Result: Decodable>(_ data: Data?, as _: Result.Type) -> Result? {
    guard let data else { return nil }
    return try? JSONDecoder().decode(AgentResponse<Result>.self, from: data).result
}

/// Runs a tool's command line through the helper and decodes its JSON-RPC style output.
func runAgentCLI<Result: Decodable>(_ tool: String, _ arguments: [String], as type: Result.Type) async -> Result? {
    decodeAgentResponse(await XPCHelperClient.shared.runAgentCLI(tool, arguments: arguments), as: type)
}

/// Collapses a free-form text to its first non-empty line.
func firstAgentLine(_ text: String?) -> String? {
    text?
        .split(whereSeparator: \.isNewline)
        .lazy
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .first { !$0.isEmpty }
}
