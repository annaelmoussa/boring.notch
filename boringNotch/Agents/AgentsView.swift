//
//  AgentsView.swift
//  boringNotch
//

import Defaults
import SwiftUI

/// Open-notch tab listing every agent, most urgent first. Clicking a row focuses it.
struct AgentsView: View {
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject var agents = AgentsManager.shared

    var body: some View {
        VStack(spacing: 0) {
            if let usage = agents.claudeUsage {
                ClaudeUsageBar(usage: usage)
            }
            if agents.sessions.isEmpty {
                AgentsEmptyState()
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 2) {
                        ForEach(agents.sessions) { session in
                            AgentRow(session: session) {
                                agents.focus(session)
                                vm.close()
                            } onReply: {
                                vm.close()
                                AgentReplyPanel.show(for: session)
                            }
                        }
                    }
                    .padding(.top, 4)
                }
            }
        }
        // The view stays alive while the notch is closed, so usage is refreshed on each opening.
        .onAppear(perform: agents.refreshClaudeUsage)
        .onChange(of: vm.notchState) { _, state in
            if state == .open { agents.refreshClaudeUsage() }
        }
    }
}

/// Claude plan usage: the 5-hour session window and the weekly limit.
private struct ClaudeUsageBar: View {
    let usage: HookProvider.Usage

    var body: some View {
        HStack(spacing: 16) {
            Text("Claude")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
            if let session = usage.session {
                UsageGauge(label: "5h", window: session)
            }
            if let week = usage.week {
                UsageGauge(label: "Week", window: week)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }
}

private struct UsageGauge: View {
    let label: String
    let window: HookProvider.Usage.Window

    private var color: Color {
        switch window.percent {
        case 90...: .red
        case 70...: .orange
        default: .white.opacity(0.7)
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .foregroundStyle(.gray)
            Capsule()
                .fill(.white.opacity(0.12))
                .frame(width: 56, height: 4)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(color)
                        .frame(width: 56 * min(1, max(0, window.percent / 100)), height: 4)
                }
            Text("\(Int(window.percent.rounded()))%")
                .monospacedDigit()
                .foregroundStyle(color)
            if let resetsAt = window.resetsAt, resetsAt > .now {
                Text("· \(resetsAt, style: .relative)")
                    .foregroundStyle(.gray)
            }
        }
        .font(.system(size: 10))
    }
}

private struct AgentsEmptyState: View {
    @Default(.disabledAgentProviders) private var disabledProviders

    private var allProvidersDisabled: Bool {
        AgentProviders.all.allSatisfy { disabledProviders.contains($0.id) }
    }

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.white.opacity(0.75))
                .frame(width: 42, height: 42)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(.white.opacity(0.06))
                        .strokeBorder(.white.opacity(0.08))
                )

            VStack(spacing: 3) {
                Text(allProvidersDisabled ? "Agent sources are off" : "No active agents")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                Text(allProvidersDisabled ? "Turn one on in Settings → Agents" : "Agents show up here as soon as they start working")
                    .font(.system(size: 11))
                    .foregroundStyle(.gray)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct AgentRow: View {
    let session: AgentSession
    let onSelect: () -> Void
    let onReply: () -> Void

    @ObservedObject private var agents = AgentsManager.shared
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: session.status.icon)
                .font(.system(size: 15))
                .foregroundStyle(session.status.color)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(agents.displayName(of: session.agent))
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                    Text(session.title)
                        .foregroundStyle(.gray)
                }
                .font(.system(size: 13))

                if let detail = session.approval ?? session.detail {
                    Text(detail)
                        .font(.system(size: 11, design: session.approval == nil ? .default : .monospaced))
                        .foregroundStyle(session.approval == nil ? .gray.opacity(0.8) : .white.opacity(0.85))
                }
            }
            .lineLimit(1)

            Spacer(minLength: 12)

            if session.approval != nil {
                approvalButtons
            } else {
                if isHovering, session.canReply {
                    Button("Reply", action: onReply)
                        .buttonStyle(ApprovalButtonStyle(fill: .white.opacity(0.1), foreground: .white))
                }
                VStack(alignment: .trailing, spacing: 2) {
                    Text(session.status.label)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(session.status.color)
                    HStack(spacing: 4) {
                        Text(session.providerName)
                        if let since = session.since {
                            Text("·")
                            ElapsedText(since: since)
                        }
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(.gray)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isHovering ? Color.white.opacity(0.08) : .clear)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
    }

    private var approvalButtons: some View {
        HStack(spacing: 6) {
            Button("Deny") { agents.respond(to: session, with: .deny) }
                .buttonStyle(ApprovalButtonStyle(fill: .white.opacity(0.1), foreground: .white))
            Button("Allow") { agents.respond(to: session, with: .allow) }
                .buttonStyle(ApprovalButtonStyle(fill: .orange, foreground: .black))
        }
    }
}

private struct ApprovalButtonStyle: ButtonStyle {
    let fill: Color
    let foreground: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(fill.opacity(configuration.isPressed ? 0.7 : 1)))
            .contentShape(Capsule())
    }
}

/// Compact elapsed time ("now", "4m", "2h", "3d") refreshed every few seconds.
private struct ElapsedText: View {
    let since: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { context in
            Text(Self.format(context.date.timeIntervalSince(since)))
                .monospacedDigit()
        }
    }

    private static func format(_ interval: TimeInterval) -> String {
        let seconds = Int(max(0, interval))
        switch seconds {
        case ..<60: return "now"
        case ..<3600: return "\(seconds / 60)m"
        case ..<86400: return "\(seconds / 3600)h"
        default: return "\(seconds / 86400)d"
        }
    }
}
