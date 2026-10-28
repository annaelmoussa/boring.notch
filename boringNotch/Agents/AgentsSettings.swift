//
//  AgentsSettings.swift
//  boringNotch
//

import Defaults
import SwiftUI

struct AgentsSettings: View {
    @Default(.disabledAgentProviders) private var disabledProviders

    var body: some View {
        Form {
            Section {
                Defaults.Toggle(key: .showAgents) {
                    Text("Show coding agents")
                }
                Defaults.Toggle(key: .agentAttentionAlerts) {
                    Text("Expand the notch when an agent needs input or finishes")
                }
                Defaults.Toggle(key: .hideInactiveAgents) {
                    Text("Hide agents that have been done or idle for 30 minutes")
                }
            } header: {
                Text("General")
            }

            Section {
                ForEach(AgentProviders.all.map { ($0.id, $0.name) }, id: \.0) { id, name in
                    Toggle(name, isOn: enabledBinding(for: id))
                }
            } header: {
                Text("Sources")
            } footer: {
                Text("Each source pushes agent states as they change, so nothing runs while agents are idle.")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Agents")
    }

    private func enabledBinding(for id: String) -> Binding<Bool> {
        Binding(
            get: { !disabledProviders.contains(id) },
            set: { enabled in
                if enabled { disabledProviders.remove(id) } else { disabledProviders.insert(id) }
            }
        )
    }
}
