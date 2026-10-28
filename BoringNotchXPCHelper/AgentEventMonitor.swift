//
//  AgentEventMonitor.swift
//  BoringNotchXPCHelper
//
//  Event-driven agent state. Each supported tool has an `AgentMonitor` that publishes a new
//  payload only when its agents change, so nothing runs while agents are idle.
//

import Foundation

/// Watches one agent tool and publishes its state whenever it changes, without polling.
///
/// To support a new tool, add a monitor to `AgentEventMonitor.monitorTypes` and an `AgentProvider`
/// with the same `id` to the app, which decodes the published payload.
protocol AgentMonitor: AnyObject {
    /// Identifier shared with the app-side provider.
    static var id: String { get }
    /// Command line tools the app may run through the helper for this monitor.
    static var tools: [String] { get }

    /// Starts watching. `onChange` receives the latest payload, or nil when the tool is not running.
    init(queue: DispatchQueue, onChange: @escaping (Data?) -> Void)

    /// Answers a tool-specific request from the app, e.g. to locate the window hosting an agent.
    func handle(_ request: Data, reply: @escaping (Data?) -> Void)
}

extension AgentMonitor {
    func handle(_ request: Data, reply: @escaping (Data?) -> Void) {
        reply(nil)
    }
}

/// Runs every monitor, merges their payloads and answers long-poll requests from the app.
final class AgentEventMonitor {
    static let shared = AgentEventMonitor()

    static let monitorTypes: [any AgentMonitor.Type] = [HookMonitor.self, HerdrMonitor.self, OrcaMonitor.self]

    private let queue = DispatchQueue(label: "theboringteam.boringnotch.agents")
    private var monitors: [String: any AgentMonitor] = [:]
    private var generation = 0
    private var payloads: [String: Data] = [:]
    private var waiters: [(Int, [String: Data]) -> Void] = []

    /// Replies as soon as the state differs from the given generation.
    func waitForUpdate(after knownGeneration: Int, reply: @escaping (Int, [String: Data]) -> Void) {
        queue.async { [self] in
            startIfNeeded()
            if knownGeneration != generation {
                reply(generation, payloads)
            } else {
                waiters.append(reply)
            }
        }
    }

    func handle(_ request: Data, for provider: String, reply: @escaping (Data?) -> Void) {
        queue.async { [self] in
            startIfNeeded()
            guard let monitor = monitors[provider] else { return reply(nil) }
            monitor.handle(request, reply: reply)
        }
    }

    private func startIfNeeded() {
        guard monitors.isEmpty else { return }
        for type in Self.monitorTypes {
            let id = type.id
            monitors[id] = type.init(queue: queue) { [weak self] data in
                guard let self, data != payloads[id] else { return }
                payloads[id] = data
                publish()
            }
        }
    }

    private func publish() {
        generation += 1
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0(generation, payloads) }
    }
}
