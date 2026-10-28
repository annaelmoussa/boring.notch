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

enum AgentSource: String {
    case herdr = "Herdr"
    case orca = "Orca"
}

/// A coding agent reported by one of the supported workspace managers.
struct AgentSession: Identifiable, Equatable {
    let id: String
    let source: AgentSource
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
    /// Namespace of `focusTarget` when the source has several, e.g. a named Herdr session.
    var scope: String? = nil
}
