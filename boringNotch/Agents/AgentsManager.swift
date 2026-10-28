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
    static let hideInactiveAgents = Key<Bool>("hideInactiveAgents", default: true)
}

/// Receives agent state pushed by the XPC helper and publishes a merged, priority-sorted list.
@MainActor
final class AgentsManager: ObservableObject {
    static let shared = AgentsManager()

    @Published private(set) var sessions: [AgentSession] = []
    /// The latest session that started waiting for the user or finished its work.
    @Published private(set) var attentionSession: AgentSession?

    /// Finished or idle agents are hidden once they have been inactive for this long.
    private static let inactivityLimit: TimeInterval = 30 * 60
    /// How long each alert stays on screen before the next one, slightly longer than the coordinator's 3 s.
    private static let alertInterval: Duration = .seconds(3.5)

    private var updatesTask: Task<Void, Never>?
    private var expiryTask: Task<Void, Never>?
    private var alertTask: Task<Void, Never>?
    private var pendingAlerts: [AgentSession] = []
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
        Defaults.publisher(keys: .showHerdrAgents, .showOrcaAgents, .hideInactiveAgents, options: [])
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
        expiryTask?.cancel()
        alertTask?.cancel()
        alertTask = nil
        pendingAlerts = []
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
        var dates: [String: (status: AgentStatus, date: Date)] = [:]

        let updated = fetched.map { session in
            var session = session
            let known = statusDates[session.id]
            session.since = session.since ?? (known?.status == session.status ? known?.date : nil) ?? now
            dates[session.id] = (session.status, session.since ?? now)
            return session
        }

        if hasReceivedUpdate {
            let alerts = updated.filter { needsAttention($0, previous: statusDates[$0.id]?.status) }
            if !alerts.isEmpty { raiseAttention(for: alerts) }
        }
        statusDates = dates
        hasReceivedUpdate = true

        let visible = visibleSessions(updated, now: now)
            .sorted { ($0.status, $1.since ?? now) < ($1.status, $0.since ?? now) }
        if visible != sessions {
            sessions = visible
        }
    }

    /// Drops agents that finished or went idle long ago, and schedules the next expiry.
    private func visibleSessions(_ all: [AgentSession], now: Date) -> [AgentSession] {
        expiryTask?.cancel()
        guard Defaults[.hideInactiveAgents] else { return all }

        let isInactive = { (session: AgentSession) in session.status == .done || session.status == .idle }
        let visible = all.filter { !isInactive($0) || now.timeIntervalSince($0.since ?? now) < Self.inactivityLimit }
        guard let nextExpiry = visible.filter(isInactive).compactMap(\.since).min()?.addingTimeInterval(Self.inactivityLimit) else {
            return visible
        }
        expiryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(1, nextExpiry.timeIntervalSinceNow)))
            guard let self, !Task.isCancelled else { return }
            apply(herdr: latest.herdr, orca: latest.orca)
        }
        return visible
    }

    /// An agent needs attention when it starts waiting for input or finishes active work.
    private func needsAttention(_ session: AgentSession, previous: AgentStatus?) -> Bool {
        guard let previous, previous != session.status else { return false }
        return session.status == .needsInput || (session.status == .done && previous == .working)
    }

    /// Shows alerts one after another, skipping those whose agent has moved on in the meantime.
    private func raiseAttention(for alerts: [AgentSession]) {
        guard Defaults[.agentAttentionAlerts] else {
            attentionSession = alerts.first
            return
        }
        pendingAlerts.removeAll { pending in alerts.contains { $0.id == pending.id } }
        pendingAlerts += alerts
        guard alertTask == nil else { return }

        alertTask = Task { [weak self] in
            while let self, !Task.isCancelled, !pendingAlerts.isEmpty {
                let alert = pendingAlerts.removeFirst()
                guard statusDates[alert.id]?.status == alert.status else { continue }
                attentionSession = alert
                BoringViewCoordinator.shared.toggleExpandingView(status: true, type: .agents)
                try? await Task.sleep(for: Self.alertInterval)
            }
            if !Task.isCancelled { self?.alertTask = nil }
        }
    }
}
