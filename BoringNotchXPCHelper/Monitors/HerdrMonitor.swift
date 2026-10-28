//
//  HerdrMonitor.swift
//  BoringNotchXPCHelper
//

import Foundation

/// Follows the default Herdr session and every named session (`herdr --session <name>`).
/// Publishes `[{"session": <name or null>, "response": <session.snapshot response>}]`.
final class HerdrMonitor: AgentMonitor {
    static let id = "herdr"
    static let tools = ["herdr"]

    private static let directory = NSHomeDirectory() + "/.config/herdr"
    private static let sessionsDirectory = directory + "/sessions"

    private let queue: DispatchQueue
    private let onChange: (Data?) -> Void
    private var rootWatcher: DirectoryWatcher?
    private var sessionsWatcher: DirectoryWatcher?
    /// Keyed by session name, "" for the default session.
    private var monitors: [String: HerdrSessionMonitor] = [:]
    private var snapshots: [String: Data] = [:]

    init(queue: DispatchQueue, onChange: @escaping (Data?) -> Void) {
        self.queue = queue
        self.onChange = onChange
        // The sessions directory may be created after launch.
        rootWatcher = DirectoryWatcher(path: Self.directory, queue: queue) { [weak self] in
            self?.syncSessions()
        }
        syncSessions()
    }

    /// `{"terminalFor": <session name, "" for the default one>}` replies with the pids hosting
    /// that session's clients, nearest first, so the app can bring the terminal forward.
    func handle(_ request: Data, reply: @escaping (Data?) -> Void) {
        guard let object = try? JSONSerialization.jsonObject(with: request) as? [String: String],
              let session = object["terminalFor"]
        else { return reply(nil) }
        DispatchQueue.global().async {
            reply(try? JSONEncoder().encode(HerdrClientLocator.ancestors(ofClientFor: session)))
        }
    }

    private func syncSessions() {
        if sessionsWatcher == nil {
            sessionsWatcher = DirectoryWatcher(path: Self.sessionsDirectory, queue: queue) { [weak self] in
                self?.syncSessions()
            }
        }
        let named = (try? FileManager.default.contentsOfDirectory(atPath: Self.sessionsDirectory)) ?? []
        let names = Set(named.filter { !$0.hasPrefix(".") } + [""])

        for name in Set(monitors.keys).subtracting(names) {
            monitors[name] = nil
            snapshots[name] = nil
        }
        for name in names.subtracting(monitors.keys) {
            let directory = name.isEmpty ? Self.directory : Self.sessionsDirectory + "/" + name
            monitors[name] = HerdrSessionMonitor(directory: directory, queue: queue) { [weak self] data in
                self?.snapshots[name] = data
                self?.publish()
            }
        }
        publish()
    }

    private func publish() {
        guard !snapshots.isEmpty else {
            onChange(nil)
            return
        }
        // Responses are already JSON; they are embedded as-is instead of being re-encoded.
        var data = Data("[".utf8)
        for (index, (name, snapshot)) in snapshots.sorted(by: { $0.key < $1.key }).enumerated() {
            let session = name.isEmpty ? nil : try? JSONEncoder().encode(name)
            if index > 0 { data.append(Data(",".utf8)) }
            data.append(Data("{\"session\":".utf8))
            data.append(session ?? Data("null".utf8))
            data.append(Data(",\"response\":".utf8))
            data.append(snapshot)
            data.append(Data("}".utf8))
        }
        data.append(Data("]".utf8))
        onChange(data)
    }
}

/// Subscribes to one Herdr server's socket events and reads a fresh snapshot after each one.
/// See https://herdr.dev/docs/socket-api
private final class HerdrSessionMonitor {
    private static let lifecycleEvents = [
        "pane.created", "pane.closed", "pane.agent_detected",
        "workspace.created", "workspace.renamed", "workspace.closed",
    ]

    private let socketPath: String
    private let queue: DispatchQueue
    private let onChange: (Data?) -> Void
    private var directoryWatcher: DirectoryWatcher?
    private var subscription: LineSocket?
    private var subscribedPanes: [String] = []
    private var pendingRefresh: DispatchWorkItem?

    init(directory: String, queue: DispatchQueue, onChange: @escaping (Data?) -> Void) {
        socketPath = directory + "/herdr.sock"
        self.queue = queue
        self.onChange = onChange
        // The socket is created and removed with the server, which changes the directory.
        directoryWatcher = DirectoryWatcher(path: directory, queue: queue) { [weak self] in
            self?.scheduleRefresh()
        }
        refresh()
    }

    deinit {
        pendingRefresh?.cancel()
        closeSubscription()
    }

    private func scheduleRefresh() {
        pendingRefresh?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh() }
        pendingRefresh = work
        queue.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    private func refresh() {
        LineSocket.request(path: socketPath, ["id": "snapshot", "method": "session.snapshot", "params": [:]], queue: queue) { [weak self] data in
            guard let self else { return }
            guard let data, let panes = Self.paneIDs(in: data) else {
                closeSubscription()
                onChange(nil)
                return
            }
            if subscription == nil || panes != subscribedPanes {
                subscribe(to: panes)
            }
            onChange(data)
        }
    }

    /// Status events are scoped to a pane, so the subscription is renewed when panes change.
    private func subscribe(to panes: [String]) {
        closeSubscription()
        guard let socket = LineSocket(path: socketPath, queue: queue) else { return }

        let subscriptions = Self.lifecycleEvents.map { ["type": $0] }
            + panes.map { ["type": "pane.agent_status_changed", "pane_id": $0] }
        socket.onLine = { [weak self] _ in self?.scheduleRefresh() }
        socket.onClose = { [weak self] in
            self?.subscription = nil
            self?.scheduleRefresh()
        }
        socket.send(["id": "events", "method": "events.subscribe", "params": ["subscriptions": subscriptions]])
        subscription = socket
        subscribedPanes = panes
    }

    private func closeSubscription() {
        subscription?.onClose = nil
        subscription?.close()
        subscription = nil
        subscribedPanes = []
    }

    private static func paneIDs(in data: Data) -> [String]? {
        guard let response = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = response["result"] as? [String: Any],
              let snapshot = result["snapshot"] as? [String: Any],
              let panes = snapshot["panes"] as? [[String: Any]]
        else { return nil }
        return panes.compactMap { $0["pane_id"] as? String }.sorted()
    }
}

// MARK: - Terminal lookup

/// Finds the processes hosting a Herdr client, so the app can bring its terminal to the front.
private enum HerdrClientLocator {
    /// Ancestors of every client attached to `session` ("" for the default session), nearest first.
    static func ancestors(ofClientFor session: String) -> [Int] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,ppid=,args="]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        var parents: [Int: Int] = [:]
        var clients: [Int] = []
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let fields = line.split(separator: " ", maxSplits: 2)
            guard fields.count == 3, let pid = Int(fields[0]), let parent = Int(fields[1]) else { continue }
            parents[pid] = parent
            if clientSession(fields[2]) == session { clients.append(pid) }
        }

        return clients.flatMap { client in
            var chain: [Int] = []
            var current = parents[client]
            while let pid = current, pid > 1, chain.count < 32 {
                chain.append(pid)
                current = parents[pid]
            }
            return chain
        }
    }

    /// The session a Herdr command line attaches to, or nil when it is not an interactive client.
    private static func clientSession(_ commandLine: Substring) -> String? {
        var words = commandLine.split(separator: " ").map(String.init)
        guard let tool = words.first, URL(fileURLWithPath: tool).lastPathComponent == "herdr" else { return nil }
        words.removeFirst()
        var session = ""
        if let index = words.firstIndex(of: "--session"), index + 1 < words.count {
            session = words[index + 1]
            words.removeSubrange(index ... index + 1)
        }
        if words.count == 3, words[0] == "session", words[1] == "attach" { return words[2] }
        return words.isEmpty ? session : nil
    }
}
