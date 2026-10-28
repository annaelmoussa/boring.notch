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
        if agents.sessions.isEmpty {
            EmptyStateView(message: emptyMessage)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 2) {
                    ForEach(agents.sessions) { session in
                        AgentRow(session: session) {
                            agents.focus(session)
                            vm.close()
                        }
                    }
                }
                .padding(.top, 4)
            }
        }
    }

    private var emptyMessage: String {
        let sources = [
            Defaults[.showHerdrAgents] ? AgentSource.herdr.rawValue : nil,
            Defaults[.showOrcaAgents] ? AgentSource.orca.rawValue : nil,
        ].compactMap { $0 }
        return sources.isEmpty
            ? "Enable an agent source in Settings"
            : "No recent agents in \(sources.joined(separator: " or "))"
    }
}

private struct AgentRow: View {
    let session: AgentSession
    let onSelect: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                Image(systemName: session.status.icon)
                    .font(.system(size: 15))
                    .foregroundStyle(session.status.color)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(session.agent)
                            .fontWeight(.semibold)
                            .foregroundStyle(.white)
                        Text(session.title)
                            .foregroundStyle(.gray)
                    }
                    .font(.system(size: 13))

                    if let detail = session.detail {
                        Text(detail)
                            .font(.system(size: 11))
                            .foregroundStyle(.gray.opacity(0.8))
                    }
                }
                .lineLimit(1)

                Spacer(minLength: 12)

                VStack(alignment: .trailing, spacing: 2) {
                    Text(session.status.label)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(session.status.color)
                    HStack(spacing: 4) {
                        Text(session.source.rawValue)
                        if let since = session.since {
                            Text("·")
                            ElapsedText(since: since)
                        }
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(.gray)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isHovering ? Color.white.opacity(0.08) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .onHover { isHovering = $0 }
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
