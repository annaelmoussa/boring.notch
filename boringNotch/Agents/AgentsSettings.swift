//
//  AgentsSettings.swift
//  boringNotch
//

import Defaults
import SwiftUI

struct AgentsSettings: View {
    @Default(.disabledAgentProviders) private var disabledProviders
    @State private var integrations: [String: HookProvider.IntegrationStatus] = [:]

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
            } header: {
                Text("General")
            } footer: {
                Text("Codex waits for an answer before showing its own prompt, so its requests go back to Codex after 20 seconds or as soon as you switch to it.")
                    .foregroundStyle(.secondary)
            }

            Section {
                ForEach(HookProvider.integrations, id: \.id) { integration in
                    IntegrationRow(name: integration.name, status: integrations[integration.id]) { install in
                        Task {
                            integrations = install
                                ? await HookProvider.install(integration.id)
                                : await HookProvider.uninstall(integration.id)
                        }
                    }
                }
            } header: {
                Text("Integrations")
            } footer: {
                Text("Adds a small hook to each agent's configuration so it reports its activity directly, wherever it runs. Codex asks to trust new hooks once: run /hooks in Codex.")
                    .foregroundStyle(.secondary)
            }
            .task {
                integrations = await HookProvider.integrationStatus()
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

private struct IntegrationRow: View {
    let name: String
    let status: HookProvider.IntegrationStatus?
    let onChange: (_ install: Bool) -> Void

    var body: some View {
        HStack {
            Text(name)
            Spacer()
            switch status {
            case .none:
                ProgressView().controlSize(.small)
            case .some(let status) where !status.available:
                Text("Not found").foregroundStyle(.secondary)
            case .some(let status) where status.installed:
                Label("Connected", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Button("Remove") { onChange(false) }
            case .some:
                Button("Connect") { onChange(true) }
            }
        }
    }
}
