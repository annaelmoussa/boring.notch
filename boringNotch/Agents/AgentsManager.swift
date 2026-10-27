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

/// Polls the enabled agent sources and publishes a merged, priority-sorted list.
@MainActor
final class AgentsManager: ObservableObject {
    static let shared = AgentsManager()

    @Published private(set) var sessions: [AgentSession] = []
    /// The latest session that started waiting for the user or finished its work.
    @Published private(set) var attentionSession: AgentSession?

    private let pollInterval: Duration = .seconds(2)
    private var pollTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    /// When each session entered its status, for sources that do not report it.
    private var statusDates: [String: (status: AgentStatus, date: Date)] = [:]
    private var hasPolled = false

    var needsInputCount: Int { sessions.filter { $0.status == .needsInput }.count }
    var workingCount: Int { sessions.filter { $0.status == .working }.count }
    var isActive: Bool { needsInputCount + workingCount > 0 }

    private init() {
        Defaults.publisher(.showAgents)
            .map(\.newValue)
            .removeDuplicates()
            .sink { [weak self] enabled in
                enabled ? self?.start() : self?.stop()
            }
            .store(in: &cancellables)
    }

    func focus(_ session: AgentSession) {
        Task { await source(for: session.source).focus(session) }
    }

    private func start() {
        guard pollTask == nil else { return }
        pollTask = Task {
            while !Task.isCancelled {
                await poll()
                try? await Task.sleep(for: pollInterval)
            }
        }
    }

    private func stop() {
        pollTask?.cancel()
        pollTask = nil
        sessions = []
        statusDates = [:]
        hasPolled = false
    }

    private func source(for source: AgentSource) -> any AgentSessionSource {
        switch source {
        case .herdr: HerdrSource()
        case .orca: OrcaSource()
        }
    }

    private func poll() async {
        async let herdr = Defaults[.showHerdrAgents] ? HerdrSource().fetchSessions() : []
        async let orca = Defaults[.showOrcaAgents] ? OrcaSource().fetchSessions() : []
        let fetched = await herdr + orca
        guard !Task.isCancelled else { return }

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

        if hasPolled, let alert = updated.first(where: { needsAttention($0, previous: previous[$0.id]) }) {
            raiseAttention(for: alert)
        }

        statusDates = dates
        hasPolled = true
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
