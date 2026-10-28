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
    /// One supported agent. Most copy Claude Code's hook system and differ only in where
    /// the configuration lives and how its entries are shaped.
    struct Integration {
        let id: String
        let name: String
        /// Paths relative to the home directory; the agent is considered installed if any exists.
        let markers: [String]
        let kind: Kind
        /// Shown under the integration in Settings.
        var note: String? = nil
    }

    enum Kind {
        /// A JSON file with hooks keyed by event name.
        case hooks(file: String, layout: Layout, events: [String], millisecondTimeouts: Bool = false)
        /// `[[hooks]]` tables appended to a TOML file.
        case tomlHooks(file: String, events: [String])
        /// One executable per event in a directory.
        case scripts(directory: String, events: [String])
        /// A JavaScript plugin file loaded by the agent.
        case plugin(file: String, source: String)
    }

    /// How a JSON hooks file is organised.
    enum Layout {
        /// `{"hooks": {Event: [{"matcher": "*", "hooks": [handler]}]}}`, used by Claude Code and its forks.
        case claude
        /// The same without a matcher (Codex, Gemini CLI, Grok).
        case nested
        /// `{"version": 1, "hooks": {event: [{"command": …}]}}` (Cursor).
        case flat
        /// Copilot CLI: `{"version": 1, "hooks": {event: [{"type": "command", "bash": …, "timeoutSec": …}]}}`.
        case copilot
        /// Trae: Claude entries plus a loop limit, under a versioned file.
        case trae
        /// Kiro agent file: `{"name": …, "hooks": {event: [{"command": …, "matcher": "*", "timeout_ms": …}]}}`.
        case kiro
        /// ZCode: `{"hooks": {"enabled": true, "events": {Event: [{"hooks": [handler]}]}}}`.
        case zcode
        /// Google Antigravity: hooks under a named key; model events take bare handlers.
        case antigravity
    }

    private static let claudeEvents = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest", "Notification", "Stop", "StopFailure", "SessionEnd"]
    /// Claude Code forks that are not known to support answering permission requests through hooks.
    private static let forkEvents = ["SessionStart", "UserPromptSubmit", "PreToolUse", "Notification", "Stop", "SessionEnd"]
    private static let forkApprovalEvents = forkEvents + ["PermissionRequest"]

    static let all: [Integration] = [
        Integration(id: "claude", name: "Claude Code", markers: [".claude"],
                    kind: .hooks(file: ".claude/settings.json", layout: .claude, events: claudeEvents)),
        Integration(id: "codex", name: "Codex", markers: [".codex"],
                    kind: .hooks(file: ".codex/hooks.json", layout: .nested,
                                 events: ["SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest", "Stop", "SessionEnd"]),
                    note: "Run /hooks in Codex once to trust the new hooks."),
        Integration(id: "opencode", name: "OpenCode", markers: [".config/opencode"],
                    kind: .plugin(file: ".config/opencode/plugins/boringnotch.js", source: openCodePluginSource)),
        Integration(id: "pi", name: "Pi", markers: [".pi/agent"],
                    kind: .plugin(file: ".pi/agent/extensions/boringnotch.js", source: piExtensionSource(agent: "pi"))),
        Integration(id: "omp", name: "Oh My Pi", markers: [".omp/agent"],
                    kind: .plugin(file: ".omp/agent/extensions/boringnotch.js", source: piExtensionSource(agent: "omp"))),
        Integration(id: "gemini", name: "Gemini CLI", markers: [".gemini/settings.json"],
                    kind: .hooks(file: ".gemini/settings.json", layout: .nested,
                                 events: ["SessionStart", "BeforeAgent", "BeforeTool", "AfterAgent", "SessionEnd"], millisecondTimeouts: true)),
        Integration(id: "cursor", name: "Cursor", markers: [".cursor"],
                    kind: .hooks(file: ".cursor/hooks.json", layout: .flat,
                                 events: ["beforeSubmitPrompt", "beforeShellExecution", "beforeMCPExecution", "afterFileEdit", "afterAgentResponse", "stop"])),
        Integration(id: "copilot", name: "GitHub Copilot CLI", markers: [".copilot"],
                    kind: .hooks(file: ".copilot/hooks/boringnotch.json", layout: .copilot,
                                 events: ["sessionStart", "userPromptSubmitted", "preToolUse", "errorOccurred", "sessionEnd"])),
        Integration(id: "qwen", name: "Qwen Code", markers: [".qwen"],
                    kind: .hooks(file: ".qwen/settings.json", layout: .claude, events: forkApprovalEvents, millisecondTimeouts: true)),
        Integration(id: "droid", name: "Factory Droid", markers: [".factory"],
                    kind: .hooks(file: ".factory/settings.json", layout: .claude, events: forkEvents)),
        Integration(id: "qoder", name: "Qoder", markers: [".qoder"],
                    kind: .hooks(file: ".qoder/settings.json", layout: .claude, events: forkApprovalEvents)),
        Integration(id: "qoder", name: "Qoder CN", markers: [".qoder-cn"],
                    kind: .hooks(file: ".qoder-cn/settings.json", layout: .claude, events: forkApprovalEvents)),
        Integration(id: "qoderwork", name: "QoderWork", markers: [".qoderwork"],
                    kind: .hooks(file: ".qoderwork/settings.json", layout: .claude, events: forkApprovalEvents),
                    note: "Restart QoderWork after connecting."),
        Integration(id: "codebuddy", name: "CodeBuddy", markers: [".codebuddy"],
                    kind: .hooks(file: ".codebuddy/settings.json", layout: .claude, events: forkEvents)),
        Integration(id: "codebuddy", name: "CodeBuddy CN", markers: [".codybuddycn"],
                    kind: .hooks(file: ".codybuddycn/settings.json", layout: .claude, events: forkEvents)),
        Integration(id: "workbuddy", name: "WorkBuddy", markers: [".workbuddy"],
                    kind: .hooks(file: ".workbuddy/settings.json", layout: .claude, events: forkEvents)),
        Integration(id: "stepfun", name: "StepFun", markers: [".stepfun"],
                    kind: .hooks(file: ".stepfun/settings.json", layout: .claude, events: forkEvents)),
        Integration(id: "grok", name: "Grok CLI", markers: [".grok"],
                    kind: .hooks(file: ".grok/hooks/boringnotch.json", layout: .nested,
                                 events: ["SessionStart", "UserPromptSubmit", "PreToolUse", "Notification", "Stop", "StopFailure"])),
        Integration(id: "kimi", name: "Kimi Code CLI", markers: [".kimi-code"],
                    kind: .tomlHooks(file: ".kimi-code/config.toml", events: forkEvents)),
        Integration(id: "kimi", name: "Kimi CLI", markers: [".kimi"],
                    kind: .tomlHooks(file: ".kimi/config.toml", events: forkEvents)),
        Integration(id: "kiro", name: "Kiro CLI", markers: [".kiro"],
                    kind: .hooks(file: ".kiro/agents/boringnotch.json", layout: .kiro,
                                 events: ["agentSpawn", "userPromptSubmit", "preToolUse", "stop"]),
                    note: "Start Kiro with --agent boringnotch."),
        Integration(id: "trae", name: "Trae", markers: [".trae"],
                    kind: .hooks(file: ".trae/hooks.json", layout: .trae,
                                 events: ["SessionStart", "UserPromptSubmit", "PreToolUse", "Notification", "Stop"])),
        Integration(id: "trae", name: "Trae CN", markers: [".trae-cn"],
                    kind: .hooks(file: ".trae-cn/hooks.json", layout: .trae,
                                 events: ["SessionStart", "UserPromptSubmit", "PreToolUse", "Notification", "Stop"])),
        Integration(id: "trae", name: "Trae CLI", markers: [".trae/cli"],
                    kind: .hooks(file: ".trae/cli/hooks.json", layout: .nested,
                                 events: ["SessionStart", "UserPromptSubmit", "PreToolUse", "Stop", "SessionEnd"])),
        Integration(id: "zcode", name: "ZCode", markers: [".zcode"],
                    kind: .hooks(file: ".zcode/cli/config.json", layout: .zcode,
                                 events: ["SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest", "Stop"]),
                    note: "Restart ZCode after connecting."),
        Integration(id: "antigravity", name: "Google Antigravity", markers: [".gemini/config", ".gemini/antigravity-cli"],
                    kind: .hooks(file: ".gemini/config/hooks.json", layout: .antigravity, events: ["PreToolUse", "Stop"])),
        Integration(id: "cline", name: "Cline", markers: ["Documents/Cline", "Library/Application Support/Code/User/globalStorage/saoudrizwan.claude-dev"],
                    kind: .scripts(directory: "Documents/Cline/Hooks",
                                   events: ["TaskStart", "TaskResume", "UserPromptSubmit", "PreToolUse", "TaskComplete", "TaskCancel"])),
    ]

    private static let home = NSHomeDirectory()
    private static let hookScript = HookMonitor.directory + "/agent-hook"
    private static let marker = ".boringnotch/agent-hook"

    /// Every integration in display order, with whether its agent and our hooks are present.
    static func status() -> [[String: Any]] {
        all.map { integration in
            var entry: [String: Any] = [
                "name": integration.name, "agent": integration.id,
                "available": isAvailable(integration), "installed": isInstalled(integration),
            ]
            entry["note"] = integration.note
            return entry
        }
    }

    static func install(_ name: String) {
        guard let integration = all.first(where: { $0.name == name }), isAvailable(integration) else { return }
        write(hookScriptSource, to: hookScript, executable: true)
        update(integration, install: true)
    }

    static func uninstall(_ name: String) {
        guard let integration = all.first(where: { $0.name == name }) else { return }
        update(integration, install: false)
    }

    // MARK: - Claude Code status line

    private static let claudeSettings = home + "/.claude/settings.json"

    /// Puts our relay in front of Claude Code's status line command, which receives plan usage,
    /// or restores the original command. The user's own status line keeps showing either way.
    static func setStatusLineRelay(_ enabled: Bool) {
        guard var root = readJSON(at: claudeSettings, creating: false) else { return }
        let relay = command(agent: "claude", event: "StatusLine")
        var statusLine = root["statusLine"] as? [String: Any]
        let current = statusLine?["command"] as? String
        let isRelayed = current?.hasPrefix(relay) == true

        if enabled {
            guard !isRelayed else { return }
            write(hookScriptSource, to: hookScript, executable: true)
            var line = statusLine ?? ["type": "command"]
            line["command"] = current.map { relay + " " + shellQuoted($0) } ?? relay
            root["statusLine"] = line
        } else {
            guard isRelayed, let current else { return }
            let original = current.dropFirst(relay.count).trimmingCharacters(in: .whitespaces)
            if original.isEmpty {
                root["statusLine"] = nil
            } else {
                statusLine?["command"] = shellUnquoted(original)
                root["statusLine"] = statusLine
            }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return }
        try? data.write(to: URL(fileURLWithPath: claudeSettings), options: .atomic)
    }

    private static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func shellUnquoted(_ text: String) -> String {
        guard text.count >= 2, text.hasPrefix("'"), text.hasSuffix("'") else { return text }
        return String(text.dropFirst().dropLast()).replacingOccurrences(of: "'\\''", with: "'")
    }

    private static func isAvailable(_ integration: Integration) -> Bool {
        integration.markers.contains { FileManager.default.fileExists(atPath: home + "/" + $0) }
    }

    private static func isInstalled(_ integration: Integration) -> Bool {
        let containsMarker = { (file: String) in
            (try? String(contentsOfFile: home + "/" + file, encoding: .utf8))?.contains(marker) == true
        }
        switch integration.kind {
        case let .hooks(file, _, _, _), let .tomlHooks(file, _):
            return containsMarker(file)
        case let .scripts(directory, events):
            return events.allSatisfy { containsMarker("\(directory)/\($0)") }
        case let .plugin(file, _):
            return FileManager.default.fileExists(atPath: home + "/" + file)
        }
    }

    private static func update(_ integration: Integration, install: Bool) {
        switch integration.kind {
        case let .hooks(file, layout, events, milliseconds):
            updateHooks(at: home + "/" + file, layout: layout, events: events, agent: integration.id,
                        timeoutScale: milliseconds ? 1000 : 1, install: install)
        case let .tomlHooks(file, events):
            updateTomlHooks(at: home + "/" + file, events: events, agent: integration.id, install: install)
        case let .scripts(directory, events):
            for event in events {
                let path = home + "/\(directory)/\(event)"
                if install {
                    write(clineScript(event: event), to: path, executable: true)
                } else if (try? String(contentsOfFile: path, encoding: .utf8))?.contains(marker) == true {
                    try? FileManager.default.removeItem(atPath: path)
                }
            }
        case let .plugin(file, source):
            if install {
                write(source, to: home + "/" + file)
            } else {
                try? FileManager.default.removeItem(atPath: home + "/" + file)
            }
        }
    }

    // MARK: - JSON hooks

    private static func command(agent: String, event: String) -> String {
        "\"\(hookScript)\" \(agent) \(event)"
    }

    /// Adds or removes our entries, keeping everything else in the file.
    private static func updateHooks(at path: String, layout: Layout, events: [String], agent: String, timeoutScale: Int, install: Bool) {
        if let text = commentedJSON(at: path) {
            return updateCommentedHooks(at: path, text: text, events: events, agent: agent, timeoutScale: timeoutScale, install: install)
        }
        guard var root = readJSON(at: path, creating: install) else { return }

        // The event map lives under "hooks", except for Antigravity's named entry and ZCode's "hooks.events".
        let key = layout == .antigravity ? "boringnotch" : "hooks"
        var section = root[key] as? [String: Any] ?? [:]
        var hooks = (layout == .zcode ? section["events"] : section) as? [String: Any] ?? [:]

        for event in events {
            var entries = (hooks[event] as? [[String: Any]] ?? []).filter { !containsOurHook($0) }
            if install {
                entries.append(entry(layout: layout, event: event, agent: agent, timeoutScale: timeoutScale))
            }
            hooks[event] = entries.isEmpty ? nil : entries
        }

        if layout == .zcode {
            section["events"] = hooks.isEmpty ? nil : hooks
            // `enabled` is the user's switch for all their hooks; it is only set when absent.
            if !hooks.isEmpty, section["enabled"] == nil { section["enabled"] = true }
            if hooks.isEmpty, section.keys.allSatisfy({ $0 == "enabled" }) { section = [:] }
        } else {
            section = hooks
        }
        root[key] = section.isEmpty ? nil : section
        if install {
            if [.flat, .copilot, .trae].contains(layout), root["version"] == nil { root["version"] = 1 }
            if layout == .kiro, root["name"] == nil { root["name"] = "boringnotch" }
        }

        // Files we created only for our hooks are removed with them.
        let isOurs = path.hasSuffix("/boringnotch.json")
        if !install, isOurs {
            try? FileManager.default.removeItem(atPath: path)
            return
        }
        guard let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return }
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    /// Our handler for one event, shaped for the agent's configuration format.
    private static func entry(layout: Layout, event: String, agent: String, timeoutScale: Int) -> [String: Any] {
        // A permission request waits for an answer from the notch; everything else returns at once.
        let seconds = event == "PermissionRequest" ? 86_400 : (event == "SessionEnd" ? 3 : 5)
        let command = command(agent: agent, event: event)
        let handler: [String: Any] = ["type": "command", "command": command, "timeout": seconds * timeoutScale]
        switch layout {
        case .claude: return ["matcher": "*", "hooks": [handler]]
        case .nested, .zcode: return ["hooks": [handler]]
        case .flat: return ["command": command]
        case .copilot: return ["type": "command", "bash": command, "timeoutSec": seconds]
        case .trae: return ["matcher": "*", "loop_limit": 5, "hooks": [handler]]
        case .kiro: return ["command": command, "matcher": "*", "timeout_ms": seconds * 1000]
        case .antigravity: return event == "PreToolUse" ? ["matcher": "*", "hooks": [handler]] : handler
        }
    }

    // MARK: - JSON with comments

    private static let commentedBegin = "// >>> Boring Notch hooks"
    private static let commentedEnd = "// <<< Boring Notch hooks"

    /// The text of a configuration file written as JSON with comments, such as Factory's settings.
    /// Nil for plain JSON, missing files and files that are not JSON at all.
    private static func commentedJSON(at path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path),
              (try? JSONSerialization.jsonObject(with: data)) == nil
        else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        guard let stripped = stripComments(text).data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: stripped)) is [String: Any]
        else { return nil }
        return text
    }

    /// Adds our hooks as a delimited block right after the opening brace, so the user's comments
    /// survive and the block can be removed exactly. Files that already have hooks are left alone.
    private static func updateCommentedHooks(at path: String, text original: String, events: [String], agent: String, timeoutScale: Int, install: Bool) {
        var text = original
        if let start = text.range(of: commentedBegin), let end = text.range(of: commentedEnd, range: start.upperBound ..< text.endIndex) {
            let lineStart = text[..<start.lowerBound].lastIndex(of: "\n").map { text.index(after: $0) } ?? start.lowerBound
            let lineEnd = text[end.upperBound...].firstIndex(of: "\n").map { text.index(after: $0) } ?? end.upperBound
            text.removeSubrange(lineStart ..< lineEnd)
        }
        if install {
            guard let data = stripComments(text).data(using: .utf8),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any], root["hooks"] == nil,
                  let brace = text.range(of: "\n{\n") ?? (text.hasPrefix("{\n") ? text.range(of: "{\n") : nil)
            else { return }
            let hooks = Dictionary(uniqueKeysWithValues: events.map { ($0, [entry(layout: .claude, event: $0, agent: agent, timeoutScale: timeoutScale)]) })
            guard let encoded = try? JSONSerialization.data(withJSONObject: hooks, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return }
            let body = String(decoding: encoded, as: UTF8.self).replacingOccurrences(of: "\n", with: "\n  ")
            text.insert(contentsOf: "  \(commentedBegin)\n  \"hooks\": \(body),\n  \(commentedEnd)\n", at: brace.upperBound)
        }
        backUp(Data(original.utf8), of: path)
        write(text, to: path)
    }

    /// Removes `//` and `/* */` comments outside strings, and trailing commas.
    private static func stripComments(_ text: String) -> String {
        var result = ""
        var iterator = Array(text).makeIterator()
        var inString = false
        var previous: Character?
        while let character = iterator.next() {
            if inString {
                result.append(character)
                if character == "\"", previous != "\\" { inString = false }
                previous = previous == "\\" && character == "\\" ? nil : character
                continue
            }
            if character == "/", let next = iterator.next() {
                if next == "/" {
                    while let skipped = iterator.next(), skipped != "\n" {}
                    result.append("\n")
                } else if next == "*" {
                    var last: Character?
                    while let skipped = iterator.next(), !(last == "*" && skipped == "/") { last = skipped }
                } else {
                    result.append(character)
                    result.append(next)
                }
                continue
            }
            if character == "\"" { inString = true }
            result.append(character)
            previous = character
        }
        return result.replacingOccurrences(of: ",\\s*([}\\]])", with: "$1", options: .regularExpression)
    }

    /// Reads a JSON object, backing the file up once. Returns nil for a file we must not touch.
    private static func readJSON(at path: String, creating: Bool) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: path), !data.isEmpty else {
            return creating ? [:] : nil
        }
        // Never overwrite a file we cannot parse.
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        backUp(data, of: path)
        return root
    }

    private static func backUp(_ data: Data, of path: String) {
        let backup = path + ".boringnotch-backup"
        if !FileManager.default.fileExists(atPath: backup) {
            try? data.write(to: URL(fileURLWithPath: backup))
        }
    }

    private static func containsOurHook(_ entry: [String: Any]) -> Bool {
        let text = (try? JSONSerialization.data(withJSONObject: entry)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        return text.contains(marker) || text.contains(marker.replacingOccurrences(of: "/", with: "\\/"))
    }

    // MARK: - TOML hooks

    /// Kimi keeps hooks as `[[hooks]]` tables; ours are delimited by comments so they can be removed exactly.
    private static func updateTomlHooks(at path: String, events: [String], agent: String, install: Bool) {
        let begin = "# >>> Boring Notch hooks"
        let end = "# <<< Boring Notch hooks"
        guard let data = FileManager.default.contents(atPath: path) ?? (install ? Data() : nil) else { return }
        var text = String(decoding: data, as: UTF8.self)
        if !data.isEmpty { backUp(data, of: path) }

        if let start = text.range(of: begin), let finish = text.range(of: end, range: start.upperBound ..< text.endIndex) {
            text.removeSubrange(start.lowerBound ..< finish.upperBound)
            text = text.trimmingCharacters(in: .newlines)
            if !text.isEmpty { text += "\n" }
        }
        if install {
            let tables = events.map { event in
                let value = command(agent: agent, event: event)
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                var table = "[[hooks]]\nevent = \"\(event)\"\ncommand = \"\(value)\"\ntimeout = 5"
                if event == "PreToolUse" { table += "\nmatcher = \".*\"" }
                return table
            }
            text += (text.isEmpty ? "" : "\n") + ([begin] + tables + [end]).joined(separator: "\n\n") + "\n"
        }
        write(text, to: path)
    }

    // MARK: - Files

    private static func write(_ contents: String, to path: String, executable: Bool = false) {
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? contents.write(toFile: path, atomically: true, encoding: .utf8)
        if executable {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        }
    }

    /// Cline runs one executable per event and expects a JSON answer on stdout.
    private static func clineScript(event: String) -> String {
        """
        #!/bin/sh
        # Installed by Boring Notch (\(marker)): reports Cline activity to the notch.
        input=$(cat)
        printf '%s' "$input" | "\(hookScript)" cline \(event) >/dev/null 2>&1 &
        printf '{"cancel":false}'

        """
    }

    /// Perl ships with macOS and starts in a few milliseconds, so each event costs one short process.
    private static let hookScriptSource = #"""
    #!/usr/bin/perl
    # Installed by Boring Notch. Forwards a coding agent hook event to the notch and prints its
    # reply, if any. Exits at once when Boring Notch is not running, so agents are never slowed down.
    use strict;
    use warnings;
    use IO::Socket::UNIX;

    my ($agent, $name) = (shift // 'unknown', shift // '');
    my $input = do { local $/; <STDIN> } // '';
    (my $event = $input) =~ s/[\r\n]+/ /g;
    my $path = "$ENV{HOME}/.boringnotch/agents.sock";

    # Claude Code's status line carries plan usage: relay it, then show the user's own status line.
    if ($name eq 'StatusLine') {
        if (my $socket = IO::Socket::UNIX->new(Type => SOCK_STREAM(), Peer => $path)) {
            print $socket join("\t", $agent, getppid(), $name), "\n", $event, "\n";
            close $socket;
        }
        if (my $command = shift) {
            open(my $line, '|-', '/bin/sh', '-c', $command) or exit 0;
            print $line $input;
            close $line;
        }
        exit 0;
    }

    # Google Antigravity treats a silent pre-tool hook as a denial; let it ask as usual.
    print '{"decision":"ask"}' if $agent eq 'antigravity' && $name eq 'PreToolUse';
    my $socket = IO::Socket::UNIX->new(Type => SOCK_STREAM(), Peer => $path) or exit 0;
    my @environment = map { $ENV{$_} // '' } qw(TERM_PROGRAM HERDR_PANE_ID HERDR_SOCKET_PATH ORCA_PANE_KEY TMUX_PANE TMUX);
    print $socket join("\t", $agent, getppid(), $name, @environment), "\n", $event, "\n";
    # A permission request keeps the connection open, so the notch notices if the agent gives up on it.
    shutdown($socket, 1) unless "$name $event" =~ /PermissionRequest|permission_request/;
    print while <$socket>;

    """#

    /// Shared by the OpenCode plugin and the Pi extension: sends one event in the hook format.
    private static let javaScriptTransport = #"""
    import net from "node:net";
    import os from "node:os";

    const SOCKET = `${os.homedir()}/.boringnotch/agents.sock`;
    const ENVIRONMENT = ["TERM_PROGRAM", "HERDR_PANE_ID", "HERDR_SOCKET_PATH", "ORCA_PANE_KEY", "TMUX_PANE", "TMUX"];

    function send(agent, event, onReply) {
      const socket = net.createConnection(SOCKET);
      let reply = "";
      socket.on("error", () => {});
      socket.on("data", (chunk) => { reply += chunk; });
      socket.on("close", () => onReply?.(reply));
      const header = [agent, process.pid, "", ...ENVIRONMENT.map((name) => process.env[name] ?? "")].join("\t");
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

    /// Pi and its Oh My Pi fork share the extension API.
    private static func piExtensionSource(agent: String) -> String {
        """
        // Installed by Boring Notch: reports \(agent == "pi" ? "Pi" : "Oh My Pi") sessions to the notch.
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
            send("\(agent)", { session_id: ctx.sessionManager.getSessionId(), hook_event_name: name, cwd: ctx.cwd, ...extra });
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
}
