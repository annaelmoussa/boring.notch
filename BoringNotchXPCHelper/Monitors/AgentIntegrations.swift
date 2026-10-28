//
//  AgentIntegrations.swift
//  BoringNotchXPCHelper
//
//  Installs and removes the hooks and plugins that report agent activity to `HookMonitor`.
//  Existing configuration is preserved: only entries pointing at our hook script are touched,
//  and each config file is backed up before its first change.
//

import Foundation

enum AgentIntegrations {
    static let agents = ["claude", "codex", "opencode", "pi"]

    private static let home = NSHomeDirectory()
    private static let hookScript = HookMonitor.directory + "/agent-hook"
    private static let hookCommand = "\"$HOME/.boringnotch/agent-hook\""

    private static let claudeSettings = home + "/.claude/settings.json"
    private static let codexHooks = home + "/.codex/hooks.json"
    private static let openCodePlugin = home + "/.config/opencode/plugins/boringnotch.js"
    private static let piExtension = home + "/.pi/agent/extensions/boringnotch.js"

    private static let claudeEvents = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest", "Notification", "Stop", "SessionEnd"]
    private static let codexEvents = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest", "Stop", "SessionEnd"]

    /// For each agent: whether it is installed on this Mac, and whether our integration is.
    static func status() -> [String: [String: Bool]] {
        Dictionary(uniqueKeysWithValues: agents.map { agent in
            (agent, ["available": isAvailable(agent), "installed": isInstalled(agent)])
        })
    }

    static func install(_ agent: String) {
        guard isAvailable(agent) else { return }
        writeHookScript()
        switch agent {
        case "claude": updateHooks(at: claudeSettings, events: claudeEvents, agent: agent, install: true)
        case "codex": updateHooks(at: codexHooks, events: codexEvents, agent: agent, install: true)
        case "opencode": write(openCodePluginSource, to: openCodePlugin)
        case "pi": write(piExtensionSource, to: piExtension)
        default: break
        }
    }

    static func uninstall(_ agent: String) {
        switch agent {
        case "claude": updateHooks(at: claudeSettings, events: claudeEvents, agent: agent, install: false)
        case "codex": updateHooks(at: codexHooks, events: codexEvents, agent: agent, install: false)
        case "opencode": try? FileManager.default.removeItem(atPath: openCodePlugin)
        case "pi": try? FileManager.default.removeItem(atPath: piExtension)
        default: break
        }
    }

    // MARK: - Detection

    private static func isAvailable(_ agent: String) -> Bool {
        let directory: String
        switch agent {
        case "claude": directory = home + "/.claude"
        case "codex": directory = home + "/.codex"
        case "opencode": directory = home + "/.config/opencode"
        case "pi": directory = home + "/.pi/agent"
        default: return false
        }
        return FileManager.default.fileExists(atPath: directory)
    }

    private static func isInstalled(_ agent: String) -> Bool {
        switch agent {
        case "claude": return (try? String(contentsOfFile: claudeSettings, encoding: .utf8))?.contains(".boringnotch/agent-hook") == true
        case "codex": return (try? String(contentsOfFile: codexHooks, encoding: .utf8))?.contains(".boringnotch/agent-hook") == true
        case "opencode": return FileManager.default.fileExists(atPath: openCodePlugin)
        case "pi": return FileManager.default.fileExists(atPath: piExtension)
        default: return false
        }
    }

    // MARK: - Hook configuration (Claude Code and Codex share the same format)

    /// Adds or removes our handler in `{"hooks": {<event>: [{"hooks": [handler]}]}}`, keeping everything else.
    private static func updateHooks(at path: String, events: [String], agent: String, install: Bool) {
        var root: [String: Any] = [:]
        if let data = FileManager.default.contents(atPath: path) {
            // Never overwrite a file we cannot parse.
            guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            root = parsed
            let backup = path + ".boringnotch-backup"
            if !FileManager.default.fileExists(atPath: backup) {
                try? data.write(to: URL(fileURLWithPath: backup))
            }
        } else if !install {
            return
        }

        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for event in events {
            var groups = (hooks[event] as? [[String: Any]] ?? []).compactMap { group -> [String: Any]? in
                var group = group
                let handlers = (group["hooks"] as? [[String: Any]] ?? []).filter {
                    ($0["command"] as? String)?.contains(".boringnotch/agent-hook") != true
                }
                guard !handlers.isEmpty else { return nil }
                group["hooks"] = handlers
                return group
            }
            if install {
                var handler: [String: Any] = ["type": "command", "command": "\(hookCommand) \(agent)"]
                // A permission request waits for an answer from the notch; everything else returns at once.
                // SessionEnd hooks get a short budget from both agents (at most 3 s for Codex).
                if event == "SessionEnd" { handler["timeout"] = 3 } else if event != "PermissionRequest" { handler["timeout"] = 5 }
                groups.append(["hooks": [handler]])
            }
            hooks[event] = groups.isEmpty ? nil : groups
        }
        root["hooks"] = hooks.isEmpty ? nil : hooks

        guard let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return }
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    // MARK: - Files

    private static func write(_ contents: String, to path: String, executable: Bool = false) {
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? contents.write(toFile: path, atomically: true, encoding: .utf8)
        if executable {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        }
    }

    private static func writeHookScript() {
        write(hookScriptSource, to: hookScript, executable: true)
    }

    /// Perl ships with macOS and starts in a few milliseconds, so each event costs one short process.
    private static let hookScriptSource = #"""
    #!/usr/bin/perl
    # Installed by Boring Notch. Forwards a coding agent hook event to the notch and prints its
    # reply, if any. Exits at once when Boring Notch is not running, so agents are never slowed down.
    use strict;
    use warnings;
    use IO::Socket::UNIX;

    my $agent = shift // 'unknown';
    my $event = do { local $/; <STDIN> } // '';
    $event =~ s/[\r\n]+/ /g;
    my $socket = IO::Socket::UNIX->new(Type => SOCK_STREAM(), Peer => "$ENV{HOME}/.boringnotch/agents.sock") or exit 0;
    print $socket join("\t", $agent, getppid(), map { $ENV{$_} // '' } qw(TERM_PROGRAM HERDR_PANE_ID HERDR_SOCKET_PATH ORCA_PANE_KEY)), "\n", $event, "\n";
    # A permission request keeps the connection open, so the notch notices if the agent gives up on it.
    shutdown($socket, 1) unless $event =~ /"hook_event_name"\s*:\s*"PermissionRequest"/;
    print while <$socket>;

    """#

    /// Shared by the OpenCode plugin and the Pi extension: sends one event in the hook format.
    private static let javaScriptTransport = #"""
    import net from "node:net";
    import os from "node:os";

    const SOCKET = `${os.homedir()}/.boringnotch/agents.sock`;
    const ENVIRONMENT = ["TERM_PROGRAM", "HERDR_PANE_ID", "HERDR_SOCKET_PATH", "ORCA_PANE_KEY"];

    function send(agent, event, onReply) {
      const socket = net.createConnection(SOCKET);
      let reply = "";
      socket.on("error", () => {});
      socket.on("data", (chunk) => { reply += chunk; });
      socket.on("close", () => onReply?.(reply));
      const header = [agent, process.pid, ...ENVIRONMENT.map((name) => process.env[name] ?? "")].join("\t");
      const message = `${header}\n${JSON.stringify(event)}\n`;
      // A permission request keeps the connection open until the notch answers.
      if (onReply) socket.write(message);
      else socket.end(message);
    }
    """#

    private static let openCodePluginSource = """
    // Installed by Boring Notch: reports OpenCode sessions to the notch and relays permission
    // answers given there. Turn it off in Boring Notch → Settings → Agents.
    \(javaScriptTransport)

    function decision(reply) {
      try {
        return JSON.parse(reply).hookSpecificOutput.decision.behavior;
      } catch {
        return undefined;
      }
    }

    export const BoringNotch = async ({ client, directory }) => {
      const event = (sessionID, name, extra = {}, onReply) =>
        send("opencode", { session_id: sessionID, hook_event_name: name, cwd: directory, ...extra }, onReply);
      const children = new Set();

      return {
        "chat.message": async ({ sessionID }) => {
          if (!children.has(sessionID)) event(sessionID, "UserPromptSubmit");
        },
        "tool.execute.before": async ({ tool, sessionID }, { args }) => {
          if (!children.has(sessionID)) event(sessionID, "PreToolUse", { tool_name: tool, tool_input: args });
        },
        event: async ({ event: { type, properties = {} } }) => {
          if (properties.info?.id && properties.info.parentID) children.add(properties.info.id);
          const sessionID = properties.sessionID ?? properties.info?.id;
          if (!sessionID) return;

          if (type === "permission.asked" || type === "permission.updated") {
            const patterns = [properties.patterns ?? properties.pattern ?? []].flat().join(" ");
            const tool_input = { description: patterns || properties.title };
            event(sessionID, "PermissionRequest", { tool_name: properties.permission ?? properties.type, tool_input }, async (reply) => {
              const behavior = decision(reply);
              if (behavior !== "allow" && behavior !== "deny") return;
              const response = behavior === "allow" ? "once" : "reject";
              try {
                if (client.permission?.reply) await client.permission.reply({ requestID: properties.id, reply: response });
                else await client.postSessionIdPermissionsPermissionId({ path: { id: sessionID, permissionID: properties.id }, body: { response } });
              } catch {}
            });
            return;
          }
          if (children.has(sessionID)) return;

          switch (type) {
            case "session.created": event(sessionID, "SessionStart"); break;
            case "permission.replied": event(sessionID, "PermissionReplied"); break;
            case "session.idle":
            case "session.error": event(sessionID, "Stop"); break;
            case "session.deleted": event(sessionID, "SessionEnd"); break;
          }
        },
      };
    };

    """

    private static let piExtensionSource = """
    // Installed by Boring Notch: reports Pi sessions to the notch.
    // Turn it off in Boring Notch → Settings → Agents.
    \(javaScriptTransport)

    function text(message) {
      const content = message?.content;
      if (typeof content === "string") return content;
      return Array.isArray(content) ? content.filter((part) => part?.type === "text").map((part) => part.text).join("\\n") : "";
    }

    export default function (pi) {
      let interactive = false;
      let lastReply = "";
      const event = (ctx, name, extra = {}) => {
        if (!interactive) return;
        send("pi", { session_id: ctx.sessionManager.getSessionId(), hook_event_name: name, cwd: ctx.cwd, ...extra });
      };

      pi.on("session_start", (_event, ctx) => {
        // Print and RPC modes are driven by other programs; only interactive sessions are shown.
        interactive = ctx?.mode === "tui";
        event(ctx, "SessionStart");
      });
      pi.on("agent_start", (_event, ctx) => event(ctx, "UserPromptSubmit"));
      pi.on("tool_call", (toolCall, ctx) => {
        event(ctx, "PreToolUse", { tool_name: toolCall.toolName, tool_input: toolCall.input });
      });
      pi.on("message_end", (messageEvent) => {
        if (messageEvent.message?.role === "assistant") lastReply = text(messageEvent.message) || lastReply;
      });
      pi.on("agent_settled", (_event, ctx) => {
        if (ctx?.isIdle?.() === false) return;
        event(ctx, "Stop", { last_assistant_message: lastReply });
        lastReply = "";
      });
      pi.on("session_shutdown", (_event, ctx) => event(ctx, "SessionEnd"));
    }

    """
}
