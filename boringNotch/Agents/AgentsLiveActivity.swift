//
//  AgentsLiveActivity.swift
//  boringNotch
//

import SwiftUI

/// Closed-notch indicator: a status icon on the left and a counter on the right.
/// When an agent needs attention, the notch widens to show which one.
struct AgentsLiveActivity: View {
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject var coordinator = BoringViewCoordinator.shared
    @ObservedObject var agents = AgentsManager.shared

    private var isExpanded: Bool {
        coordinator.expandingView.show && coordinator.expandingView.type == .agents
    }

    /// The status summarised by the indicator, most urgent first.
    private var status: AgentStatus {
        if isExpanded, let session = agents.attentionSession { return session.status }
        return agents.needsInputCount > 0 ? .needsInput : .working
    }

    private var count: Int {
        status == .needsInput ? agents.needsInputCount : agents.workingCount
    }

    var body: some View {
        let side = max(0, vm.effectiveClosedNotchHeight - 12)

        HStack {
            Image(systemName: status.icon)
                .resizable()
                .scaledToFit()
                .foregroundStyle(status.color)
                .symbolEffect(.pulse, isActive: status == .working)
                .frame(width: side, height: side)

            Rectangle()
                .fill(.black)
                .overlay {
                    if isExpanded, let session = agents.attentionSession {
                        HStack {
                            Text(session.title)
                                .foregroundStyle(.white)
                            Spacer(minLength: vm.closedNotchSize.width)
                            Text(session.status.label)
                                .foregroundStyle(session.status.color)
                        }
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .transition(.opacity)
                    }
                }
                .frame(width: isExpanded ? 420 : vm.closedNotchSize.width - cornerRadiusInsets.closed.top)

            Text("\(max(count, 1))")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(status.color)
                .frame(width: side, height: side)
        }
        .frame(height: vm.effectiveClosedNotchHeight, alignment: .center)
    }
}
