//
//  AgentSession.swift
//  boringNotch
//

import SwiftUI

/// Lifecycle state of a coding agent, ordered by how urgently it needs attention.
enum AgentStatus: Int, Comparable {
    case needsInput
    case working
    case done
    case idle

    static func < (lhs: AgentStatus, rhs: AgentStatus) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var label: String {
        switch self {
        case .needsInput: "Needs input"
        case .working: "Working"
        case .done: "Done"
        case .idle: "Idle"
        }
    }

    var icon: String {
        switch self {
        case .needsInput: "exclamationmark.bubble.fill"
        case .working: "circle.dotted.circle"
        case .done: "checkmark.circle.fill"
        case .idle: "moon.zzz.fill"
        }
    }

    var color: Color {
        switch self {
        case .needsInput: .orange
        case .working: .blue
        case .done: .green
        case .idle: .gray
        }
    }
}

/// A coding agent reported by an `AgentProvider`.
struct AgentSession: Identifiable, Equatable {
    let id: String
    /// Id of the provider that reported the agent.
    let provider: String
    /// Agent kind as reported by the source, e.g. "codex".
    let agent: String
    /// Workspace or worktree the agent runs in.
    let title: String
    /// Short description of the current task, when the source provides one.
    let detail: String?
    let status: AgentStatus
    /// When the agent entered its current status, when the source provides it.
    var since: Date?
    /// Source-specific identifier used to bring the agent to the front.
    let focusTarget: String
    /// Namespace of `focusTarget` when the provider has several, e.g. a named terminal session.
    var scope: String? = nil
    /// Where the agent runs, e.g. "Ghostty", shown instead of the provider name when known.
    var location: String? = nil
    /// The app hosting the agent, used to bring it forward.
    var hostPID: pid_t? = nil
    /// The same agent as reported by a workspace manager, e.g. a Herdr pane. It is hidden in favour
    /// of this session, which knows more, and used to jump to the exact pane.
    var containerID: String? = nil
    /// What the agent asks permission for, while it waits for an answer that the notch can give.
    var approval: String? = nil
    /// The agent shows nothing until `approval` is answered, so it is handed back when its window is in front.
    var approvalBlocksAgent = false

    var providerName: String {
        location ?? AgentProviders.provider(id: provider)?.name ?? provider
    }

    /// The id a provider gives to the agent at `target`, shared so that sessions can refer to each other.
    static func id(provider: String, scope: String?, target: String) -> String {
        "\(provider):\(scope ?? ""):\(target)"
    }
}
