//
//  AgentsSettings.swift
//  boringNotch
//

import Defaults
import SwiftUI

struct AgentsSettings: View {
    var body: some View {
        Form {
            Section {
                Defaults.Toggle(key: .showAgents) {
                    Text("Show coding agents")
                }
                Defaults.Toggle(key: .agentAttentionAlerts) {
                    Text("Expand the notch when an agent needs input or finishes")
                }
            } header: {
                Text("General")
            }

            Section {
                Defaults.Toggle(key: .showHerdrAgents) {
                    Text("Herdr")
                }
                Defaults.Toggle(key: .showOrcaAgents) {
                    Text("Orca")
                }
            } header: {
                Text("Sources")
            } footer: {
                Text("Agent states are pushed by Herdr and Orca as they change. Jumping to an agent requires the `herdr` and `orca` command line tools in /opt/homebrew/bin, /usr/local/bin or ~/.local/bin.")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Agents")
    }
}
