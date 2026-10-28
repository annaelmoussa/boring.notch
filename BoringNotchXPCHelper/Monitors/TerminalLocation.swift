//
//  TerminalLocation.swift
//  BoringNotchXPCHelper
//
//  Where an agent runs, and how to bring that exact tab forward or type into it.
//  Scriptable terminals are matched by the agent's tty; tmux panes by their id.
//

import Foundation

struct TerminalLocation {
    /// Process names of terminals whose tabs can be found by tty through AppleScript.
    static let scriptableApps: Set<String> = ["ghostty", "Terminal", "iTerm2"]

    /// `TERM_PROGRAM`, used to name the terminal when its app cannot be identified.
    let program: String?
    let tty: String?
    /// The scriptable terminal app hosting the agent, if any.
    let app: String?
    let tmuxPane: String?
    let tmuxSocket: String?

    var canSendText: Bool {
        tmuxPane != nil || (tty != nil && app != nil)
    }

    /// Selects the agent's pane or tab. Returns false when it cannot be located precisely.
    func focus() -> Bool {
        if let tmuxPane {
            return tmux(["select-window", "-t", tmuxPane]) && tmux(["select-pane", "-t", tmuxPane])
        }
        guard let tty, let script = app.flatMap({ Self.focusScripts[$0] }) else { return false }
        return Self.runAppleScript(script, arguments: [tty])
    }

    /// Types `text` into the agent's terminal and submits it.
    func send(_ text: String) -> Bool {
        if let tmuxPane {
            return tmux(["send-keys", "-t", tmuxPane, "-l", text]) && tmux(["send-keys", "-t", tmuxPane, "Enter"])
        }
        guard let tty, let script = app.flatMap({ Self.sendScripts[$0] }) else { return false }
        return Self.runAppleScript(script, arguments: [tty, text])
    }

    // MARK: - tmux

    private func tmux(_ arguments: [String]) -> Bool {
        guard let executable = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
            .first(where: FileManager.default.isExecutableFile(atPath:))
        else { return false }
        let socket = tmuxSocket.map { ["-S", $0] } ?? []
        return Command.run(executable, socket + arguments) != nil
    }

    // MARK: - AppleScript

    private static let focusScripts = [
        "ghostty": """
        on run argv
            tell application "Ghostty"
                repeat with t in terminals
                    if tty of t is item 1 of argv then
                        focus t
                        return true
                    end if
                end repeat
            end tell
            return false
        end run
        """,
        "Terminal": """
        on run argv
            tell application "Terminal"
                repeat with w in windows
                    repeat with t in tabs of w
                        if tty of t is item 1 of argv then
                            set selected of t to true
                            set index of w to 1
                            activate
                            return true
                        end if
                    end repeat
                end repeat
            end tell
            return false
        end run
        """,
        "iTerm2": """
        on run argv
            tell application "iTerm2"
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            if tty of s is item 1 of argv then
                                select w
                                select t
                                select s
                                activate
                                return true
                            end if
                        end repeat
                    end repeat
                end repeat
            end tell
            return false
        end run
        """,
    ]

    private static let sendScripts = [
        "ghostty": """
        on run argv
            tell application "Ghostty"
                repeat with t in terminals
                    if tty of t is item 1 of argv then
                        input text (item 2 of argv) to t
                        send key "enter" to t
                        return true
                    end if
                end repeat
            end tell
            return false
        end run
        """,
        "Terminal": """
        on run argv
            tell application "Terminal"
                repeat with w in windows
                    repeat with t in tabs of w
                        if tty of t is item 1 of argv then
                            do script (item 2 of argv) in t
                            return true
                        end if
                    end repeat
                end repeat
            end tell
            return false
        end run
        """,
        "iTerm2": """
        on run argv
            tell application "iTerm2"
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            if tty of s is item 1 of argv then
                                tell s to write text (item 2 of argv)
                                return true
                            end if
                        end repeat
                    end repeat
                end repeat
            end tell
            return false
        end run
        """,
    ]

    private static func runAppleScript(_ script: String, arguments: [String]) -> Bool {
        Command.run("/usr/bin/osascript", ["-e", script] + arguments)?.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
    }
}
