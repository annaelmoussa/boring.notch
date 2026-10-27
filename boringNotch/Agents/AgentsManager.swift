//
//  AgentsManager.swift
//  boringNotch
//

import Combine
import Defaults
import Foundation

extension Defaults.Keys {
    static let showAgents = Key<Bool>("showAgents", default: true)
    static let showHerdrAgents = Key<Bool>("showHerdrAgents", default: true)
    static let showOrcaAgents = Key<Bool>("showOrcaAgents", default: true)
    static let agentAttentionAlerts = Key<Bool>("agentAttentionAlerts", default: true)
}

/// Receives agent state pushed by the XPC helper and publishes a merged, priority-sorted list.
@MainActor
final class AgentsManager: ObservableObject {
    static let shared = AgentsManager()

    @Published private(set) var sessions: [AgentSession] = []
    /// The latest session that started waiting for the user or finished its work.
    @Published private(set) var attentionSession: AgentSession?

    private var updatesTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    /// When each session entered its status, for sources that do not report it.
    private var statusDates: [String: (status: AgentStatus, date: Date)] = [:]
    private var hasReceivedUpdate = false
    private var latest: (herdr: Data?, orca: Data?) = (nil, nil)

    var needsInputCount: Int { sessions.filter { $0.status == .needsInput }.count }
    var workingCount: Int { sessions.filter { $0.status == .working }.count }
    var isActive: Bool { needsInputCount + workingCount > 0 }

    private init() {
        Defaults.publisher(.showAgents)
            .map(\.newValue)
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                enabled ? self?.start() : self?.stop()
            }
            .store(in: &cancellables)

        // Re-filter the last state when a source is toggled, without waiting for a change.
        Defaults.publisher(keys: .showHerdrAgents, .showOrcaAgents, options: [])
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                guard let self else { return }
                apply(herdr: latest.herdr, orca: latest.orca)
            }
            .store(in: &cancellables)
    }

    func focus(_ session: AgentSession) {
        Task {
            switch session.source {
            case .herdr: await HerdrSource.focus(session)
            case .orca: await OrcaSource.focus(session)
            }
        }
    }

    /// Waits for the helper to push changes; nothing runs while agent state is unchanged.
    private func start() {
        guard updatesTask == nil else { return }
        updatesTask = Task {
            var generation = -1
            while !Task.isCancelled {
                guard let update = await XPCHelperClient.shared.waitForAgentUpdate(after: generation) else {
                    // The helper was interrupted; reconnect and resynchronise.
                    generation = -1
                    try? await Task.sleep(for: .seconds(1))
                    continue
                }
                guard !Task.isCancelled else { return }
                generation = update.generation
                apply(herdr: update.herdr, orca: update.orca)
            }
        }
    }

    private func stop() {
        updatesTask?.cancel()
        updatesTask = nil
        sessions = []
        statusDates = [:]
        hasReceivedUpdate = false
        latest = (nil, nil)
    }

    private func apply(herdr: Data?, orca: Data?) {
        latest = (herdr, orca)
        let fetched = (Defaults[.showHerdrAgents] ? HerdrSource.sessions(from: herdr) : [])
            + (Defaults[.showOrcaAgents] ? OrcaSource.sessions(from: orca) : [])

        let now = Date()
        let previous = Dictionary(sessions.map { ($0.id, $0.status) }, uniquingKeysWith: { first, _ in first })
        var dates: [String: (status: AgentStatus, date: Date)] = [:]

        let updated = fetched.map { session in
            var session = session
            let known = statusDates[session.id]
            session.since = session.since ?? (known?.status == session.status ? known?.date : nil) ?? now
            dates[session.id] = (session.status, session.since ?? now)
            return session
        }
        .sorted { ($0.status, $1.since ?? now) < ($1.status, $0.since ?? now) }

        if hasReceivedUpdate, let alert = updated.first(where: { needsAttention($0, previous: previous[$0.id]) }) {
            raiseAttention(for: alert)
        }

        statusDates = dates
        hasReceivedUpdate = true
        if updated != sessions {
            sessions = updated
        }
    }

    /// An agent needs attention when it starts waiting for input or finishes active work.
    private func needsAttention(_ session: AgentSession, previous: AgentStatus?) -> Bool {
        guard let previous, previous != session.status else { return false }
        return session.status == .needsInput || (session.status == .done && previous == .working)
    }

    private func raiseAttention(for session: AgentSession) {
        attentionSession = session
        guard Defaults[.agentAttentionAlerts] else { return }
        BoringViewCoordinator.shared.toggleExpandingView(status: true, type: .agents)
    }
}
