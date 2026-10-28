//
//  AgentsSettings.swift
//  boringNotch
//

import Defaults
import SwiftUI

struct AgentsSettings: View {
    @Default(.disabledAgentProviders) private var disabledProviders
    @State private var integrations: [HookProvider.Integration] = []

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
                Defaults.Toggle(key: .agentSounds) {
                    Text("Play a sound with alerts")
                }
                Defaults.Toggle(key: .agentApprovals) {
                    Text("Answer permission requests from the notch")
                }
                Defaults.Toggle(key: .showClaudeUsage) {
                    Text("Show Claude plan usage")
                }
            } header: {
                Text("General")
            } footer: {
                Text("Agents other than Claude Code and OpenCode wait for an answer before showing their own prompt, so their requests go back to them after 20 seconds or as soon as you switch to them. Plan usage is relayed by Claude Code's status line while a session runs; your own status line keeps showing.")
                    .foregroundStyle(.secondary)
            }

            Section {
                ForEach(integrations.filter(\.available)) { integration in
                    IntegrationRow(integration: integration) { install in
                        Task {
                            integrations = install
                                ? await HookProvider.install(integration)
                                : await HookProvider.uninstall(integration)
                        }
                    }
                }
            } header: {
                Text("Integrations")
            } footer: {
                Text(integrationsFooter)
                    .foregroundStyle(.secondary)
            }
            .task {
                integrations = await HookProvider.integrations()
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

    private var integrationsFooter: String {
        let others = integrations.filter { !$0.available }.map(\.name)
        let base = "Connecting adds a small hook to the agent's configuration, so it reports its activity wherever it runs. The rest of the file is left untouched and backed up first."
        return others.isEmpty ? base : base + " Also supported once installed: " + ListFormatter.localizedString(byJoining: others) + "."
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

private struct IntegrationRow: View {
    let integration: HookProvider.Integration
    let onChange: (_ install: Bool) -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(integration.name)
                if let note = integration.note, integration.installed {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if integration.installed {
                Label("Connected", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Button("Remove") { onChange(false) }
            } else {
                Button("Connect") { onChange(true) }
            }
        }
    }
}
