//
//  AgentsManager.swift
//  boringNotch
//

import AppKit
import Combine
import Defaults
import Foundation

extension Defaults.Keys {
    static let showAgents = Key<Bool>("showAgents", default: true)
    /// Ids of the providers turned off in Settings.
    static let disabledAgentProviders = Key<Set<String>>("disabledAgentProviders", default: [])
    static let agentAttentionAlerts = Key<Bool>("agentAttentionAlerts", default: true)
    static let hideInactiveAgents = Key<Bool>("hideInactiveAgents", default: true)
    static let agentSounds = Key<Bool>("agentSounds", default: true)
    /// Answer agents' permission requests from the notch instead of their own interface.
    static let agentApprovals = Key<Bool>("agentApprovals", default: true)
    /// Show Claude plan usage in the Agents tab, relayed from Claude Code's status line.
    static let showClaudeUsage = Key<Bool>("showClaudeUsage", default: false)
}

/// What the rest of the notch needs to know about agents. It changes far less often than the agent
/// list, so views that only need it are not redrawn on every agent event.
@MainActor
final class AgentsSummary: ObservableObject {
    static let shared = AgentsSummary()

    @Published fileprivate(set) var isActive = false
    @Published fileprivate(set) var hasPendingApproval = false
}

/// Receives agent state pushed by the XPC helper and publishes a merged, priority-sorted list.
@MainActor
final class AgentsManager: ObservableObject {
    static let shared = AgentsManager()

    @Published private(set) var sessions: [AgentSession] = []
    /// The latest session that started waiting for the user or finished its work.
    @Published private(set) var attentionSession: AgentSession?
    /// Claude plan usage, refreshed when the notch opens.
    @Published private(set) var claudeUsage: HookProvider.Usage?
    /// Display names of agent ids, e.g. "claude" → "Claude Code".
    private var agentNames: [String: String] = [:]

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
    /// Sessions waiting for a permission answer at the last update.
    private var pendingApprovalIDs: Set<String> = []
    /// Sessions hidden because a richer session describes the same agent, by id.
    private var containers: [String: AgentSession] = [:]
    /// Latest payload of each provider, keyed by provider id.
    private var latest: [String: Data] = [:]
    /// Sessions decoded from each provider's payload, reused while that payload is unchanged.
    private var decoded: [String: (payload: Data, sessions: [AgentSession])] = [:]

    var needsInputCount: Int { sessions.filter { $0.status == .needsInput }.count }
    var workingCount: Int { sessions.filter { $0.status == .working }.count }
    var isActive: Bool { needsInputCount + workingCount > 0 }
    var hasPendingApproval: Bool { sessions.contains { $0.approval != nil } }

    private static let needsInputSound = NSSound(named: "Glass")
    private static let doneSound = NSSound(named: "Tink")

    private init() {
        Defaults.publisher(.showAgents)
            .map(\.newValue)
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                enabled ? self?.start() : self?.stop()
            }
            .store(in: &cancellables)

        // Re-filter the last state when a provider is toggled, without waiting for a change.
        Defaults.publisher(keys: .disabledAgentProviders, .hideInactiveAgents, options: [])
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                guard let self else { return }
                apply(latest)
            }
            .store(in: &cancellables)

        Defaults.publisher(.showClaudeUsage, options: [])
            .map(\.newValue)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                Task {
                    await HookProvider.setUsageRelay(enabled)
                    self?.refreshClaudeUsage()
                }
            }
            .store(in: &cancellables)

        // An agent that waits for the notch gets its request back once the user switches to it.
        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didActivateApplicationNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.releaseApprovals() }
            .store(in: &cancellables)
    }

    /// Jumps to the agent, through the workspace manager hosting it when there is one.
    func focus(_ session: AgentSession) {
        let target = paneSession(of: session)
        guard let provider = AgentProviders.provider(id: target.provider) else { return }
        Task {
            await provider.focus(target)
        }
    }

    /// Types a reply into the agent's terminal, through the workspace manager hosting it when there is one.
    func reply(to session: AgentSession, text: String) async -> Bool {
        let target = paneSession(of: session)
        guard let provider = AgentProviders.provider(id: target.provider) else { return false }
        return await provider.reply(to: target, text: text)
    }

    /// The workspace manager's session for the pane hosting `session`, even when that manager does not
    /// recognise the agent itself; otherwise `session`.
    private func paneSession(of session: AgentSession) -> AgentSession {
        guard let container = session.container else { return session }
        if let known = containers[container.id] { return known }
        guard AgentProviders.provider(id: container.provider) != nil else { return session }
        return AgentSession(
            id: container.id, provider: container.provider, agent: session.agent, title: session.title,
            detail: nil, status: session.status, focusTarget: container.target, scope: container.scope
        )
    }

    func displayName(of agent: String) -> String {
        agentNames[agent] ?? agent
    }

    /// Reads the latest Claude usage the helper received; nothing is fetched or polled.
    func refreshClaudeUsage() {
        guard Defaults[.showClaudeUsage] else {
            claudeUsage = nil
            return
        }
        Task {
            let usage = await HookProvider.claudeUsage()
            if usage != claudeUsage { claudeUsage = usage }
        }
    }

    func respond(to session: AgentSession, with decision: AgentDecision) {
        guard let provider = AgentProviders.provider(id: session.provider) else { return }
        Task {
            await provider.respond(to: session, with: decision)
        }
    }

    /// Waits for the helper to push changes; nothing runs while agent state is unchanged.
    private func start() {
        guard updatesTask == nil else { return }
        updatesTask = Task {
            let integrations = await HookProvider.integrations()
            agentNames = Dictionary(integrations.map { ($0.agent, $0.name) }, uniquingKeysWith: { first, _ in first })
            if Defaults[.showClaudeUsage] { await HookProvider.setUsageRelay(true) }
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
                apply(update.payloads)
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
        latest = [:]
    }

    private func apply(_ payloads: [String: Data]) {
        latest = payloads
        let disabled = Defaults[.disabledAgentProviders]
        let all = AgentProviders.all
            .filter { !disabled.contains($0.id) }
            .flatMap { provider -> [AgentSession] in
                guard let payload = payloads[provider.id] else { return [] }
                if let cached = decoded[provider.id], cached.payload == payload { return cached.sessions }
                let sessions = provider.sessions(from: payload)
                decoded[provider.id] = (payload, sessions)
                return sessions
            }

        // An agent reported both by its own hooks and by the workspace manager it runs in is shown once.
        let containedIDs = Set(all.compactMap(\.containerID))
        containers = Dictionary(all.filter { containedIDs.contains($0.id) }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // Several sessions in one pane (a resumed conversation, say) are shown as the latest one.
        var latestInContainer: [String: AgentSession] = [:]
        for session in all where session.containerID != nil {
            let current = latestInContainer[session.containerID!]
            if current == nil || (session.since ?? .distantPast) > (current?.since ?? .distantPast) {
                latestInContainer[session.containerID!] = session
            }
        }
        let fetched = all.filter { session in
            guard !containedIDs.contains(session.id) else { return false }
            return session.containerID.map { latestInContainer[$0]?.id == session.id } ?? true
        }
        .map { session in
            var session = session
            if let container = session.containerID.flatMap({ containers[$0] }) {
                session.location = container.providerName
            }
            return session
        }

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
            let alerts = updated.filter {
                needsAttention($0, previous: statusDates[$0.id]?.status) || ($0.approval != nil && !pendingApprovalIDs.contains($0.id))
            }
            if !alerts.isEmpty { raiseAttention(for: alerts) }
        }
        statusDates = dates
        pendingApprovalIDs = Set(updated.filter { $0.approval != nil }.map(\.id))
        hasReceivedUpdate = true

        let visible = visibleSessions(updated, now: now)
            .sorted { ($0.status, $1.since ?? now) < ($1.status, $0.since ?? now) }
        if visible != sessions {
            sessions = visible
        }
        let summary = AgentsSummary.shared
        if summary.isActive != isActive { summary.isActive = isActive }
        if summary.hasPendingApproval != hasPendingApproval { summary.hasPendingApproval = hasPendingApproval }
        releaseApprovals()
    }

    /// Hands permission requests back to the agent when the notch should not answer them:
    /// approvals are turned off, or the agent waits on the notch while its window is in front.
    private func releaseApprovals() {
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        for session in sessions where session.approval != nil {
            let isWaitingInFront = session.approvalBlocksAgent && session.hostPID != nil && session.hostPID == frontmost
            if !Defaults[.agentApprovals] || isWaitingInFront {
                respond(to: session, with: .defer)
            }
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
            apply(latest)
        }
        return visible
    }

    /// An agent needs attention when it starts waiting for input or finishes active work.
    private func needsAttention(_ session: AgentSession, previous: AgentStatus?) -> Bool {
        guard previous != session.status else { return false }
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
                if Defaults[.agentSounds] {
                    (alert.status == .needsInput ? Self.needsInputSound : Self.doneSound)?.play()
                }
                try? await Task.sleep(for: Self.alertInterval)
            }
            if !Task.isCancelled { self?.alertTask = nil }
        }
    }
}
