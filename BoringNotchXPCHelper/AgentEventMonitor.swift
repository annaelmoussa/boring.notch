//
//  AgentEventMonitor.swift
//  BoringNotchXPCHelper
//
//  Event-driven agent state for Herdr and Orca. Nothing runs while agents are idle:
//  Herdr pushes events over its socket, Orca changes are observed with kqueue, and
//  each change triggers a single request to the tool's local socket.
//

import Foundation

/// Merges both sources and answers long-poll requests from the app.
final class AgentEventMonitor {
    static let shared = AgentEventMonitor()

    private let queue = DispatchQueue(label: "theboringteam.boringnotch.agents")
    private var herdr: HerdrMonitor?
    private var orca: OrcaMonitor?
    private var generation = 0
    private var herdrSessions: Data?
    private var orcaWorktrees: Data?
    private var waiters: [(Int, Data?, Data?) -> Void] = []

    /// Replies as soon as the state differs from the given generation.
    func waitForUpdate(after knownGeneration: Int, reply: @escaping (Int, Data?, Data?) -> Void) {
        queue.async { [self] in
            startIfNeeded()
            if knownGeneration != generation {
                reply(generation, herdrSessions, orcaWorktrees)
            } else {
                waiters.append(reply)
            }
        }
    }

    private func startIfNeeded() {
        guard herdr == nil else { return }
        herdr = HerdrMonitor(queue: queue) { [weak self] data in
            guard let self, data != herdrSessions else { return }
            herdrSessions = data
            publish()
        }
        orca = OrcaMonitor(queue: queue) { [weak self] data in
            guard let self, data != orcaWorktrees else { return }
            orcaWorktrees = data
            publish()
        }
    }

    private func publish() {
        generation += 1
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0(generation, herdrSessions, orcaWorktrees) }
    }
}

// MARK: - Herdr

/// Follows the default Herdr session and every named session (`herdr --session <name>`).
/// Publishes `[{"session": <name or null>, "response": <session.snapshot response>}]`.
private final class HerdrMonitor {
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

// MARK: - Orca

/// Orca has no public event stream. It rewrites `agent-hooks/last-status.json` whenever an
/// agent reports a new state, so that directory is watched and each change triggers one
/// `worktree.ps` request on Orca's local runtime socket, the same call its CLI makes.
private final class OrcaMonitor {
    private static let directory = NSHomeDirectory() + "/Library/Application Support/orca"
    private static let metadataPath = directory + "/orca-runtime.json"
    private static let hooksDirectory = directory + "/agent-hooks"

    private let queue: DispatchQueue
    private let onChange: (Data?) -> Void
    private var directoryWatcher: DirectoryWatcher?
    private var hooksWatcher: DirectoryWatcher?
    private var processWatcher: DispatchSourceProcess?
    private var metadataStamp: Date?
    private var pendingRefresh: DispatchWorkItem?

    init(queue: DispatchQueue, onChange: @escaping (Data?) -> Void) {
        self.queue = queue
        self.onChange = onChange
        // Orca rewrites its runtime metadata on launch; other files in this directory are ignored.
        directoryWatcher = DirectoryWatcher(path: Self.directory, queue: queue) { [weak self] in
            self?.metadataMayHaveChanged()
        }
        metadataStamp = Self.metadataModificationDate()
        refresh()
    }

    private func metadataMayHaveChanged() {
        let stamp = Self.metadataModificationDate()
        guard stamp != metadataStamp else { return }
        metadataStamp = stamp
        scheduleRefresh()
    }

    private static func metadataModificationDate() -> Date? {
        try? FileManager.default.attributesOfItem(atPath: metadataPath)[.modificationDate] as? Date
    }

    private func scheduleRefresh() {
        pendingRefresh?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh() }
        pendingRefresh = work
        queue.asyncAfter(deadline: .now() + 0.1, execute: work)
    }

    private func refresh() {
        if hooksWatcher == nil {
            hooksWatcher = DirectoryWatcher(path: Self.hooksDirectory, queue: queue) { [weak self] in
                self?.scheduleRefresh()
            }
        }

        guard let runtime = Self.readRuntime() else {
            onChange(nil)
            return
        }
        watchExit(of: runtime.pid)

        let request: [String: Any] = ["id": "agents", "authToken": runtime.token, "method": "worktree.ps", "params": [:]]
        LineSocket.request(path: runtime.socketPath, request, queue: queue) { [weak self] data in
            self?.onChange(data)
        }
    }

    /// Clears the agents as soon as Orca quits.
    private func watchExit(of pid: pid_t) {
        guard processWatcher?.handle != pid else { return }
        processWatcher?.cancel()
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        source.setEventHandler { [weak self] in
            self?.processWatcher?.cancel()
            self?.processWatcher = nil
            self?.onChange(nil)
        }
        source.resume()
        processWatcher = source
    }

    private static func readRuntime() -> (socketPath: String, token: String, pid: pid_t)? {
        guard let data = FileManager.default.contents(atPath: metadataPath),
              let metadata = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = metadata["authToken"] as? String,
              let pid = metadata["pid"] as? Int,
              kill(pid_t(pid), 0) == 0,
              let transports = metadata["transports"] as? [[String: Any]],
              let socketPath = transports.first(where: { $0["kind"] as? String == "unix" })?["endpoint"] as? String
        else { return nil }
        return (socketPath, token, pid_t(pid))
    }
}

// MARK: - Terminal lookup

/// Finds the processes hosting a Herdr client, so the app can bring its terminal to the front.
enum HerdrClientLocator {
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

// MARK: - Primitives

/// Calls the handler when entries are added, removed or renamed in a directory.
private final class DirectoryWatcher {
    private let source: DispatchSourceFileSystemObject

    init?(path: String, queue: DispatchQueue, handler: @escaping () -> Void) {
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: queue)
        source.setEventHandler(handler: handler)
        source.setCancelHandler { close(descriptor) }
        source.resume()
    }

    deinit {
        source.cancel()
    }
}

/// Newline-delimited JSON over a Unix domain socket, read only when data arrives.
private final class LineSocket {
    var onLine: ((Data) -> Void)?
    var onClose: (() -> Void)?

    private let descriptor: Int32
    private let source: DispatchSourceRead
    private var buffer = Data()

    init?(path: String, queue: DispatchQueue) {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            Darwin.close(descriptor)
            return nil
        }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: pathBytes) }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            Darwin.close(descriptor)
            return nil
        }
        var noSigPipe: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        self.descriptor = descriptor
        source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setCancelHandler { Darwin.close(descriptor) }
        source.setEventHandler { [weak self] in self?.readAvailable() }
        source.resume()
    }

    deinit {
        source.cancel()
    }

    func send(_ message: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: message) else { return }
        data.append(0x0A)
        data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = write(descriptor, bytes.baseAddress! + offset, bytes.count - offset)
                guard written > 0 else { return }
                offset += written
            }
        }
    }

    func close() {
        source.cancel()
    }

    /// Sends one request and delivers the first response line, or nil on failure or timeout.
    static func request(path: String, _ message: [String: Any], queue: DispatchQueue, timeout: TimeInterval = 3, completion: @escaping (Data?) -> Void) {
        guard let socket = LineSocket(path: path, queue: queue) else {
            completion(nil)
            return
        }
        var finished = false
        let finish = { (data: Data?) in
            guard !finished else { return }
            finished = true
            socket.onLine = nil
            socket.onClose = nil
            socket.close()
            completion(data)
        }
        socket.onLine = { finish($0) }
        socket.onClose = { finish(nil) }
        socket.send(message)
        queue.asyncAfter(deadline: .now() + timeout) { finish(nil) }
    }

    private func readAvailable() {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        let count = read(descriptor, &chunk, chunk.count)
        guard count > 0 else {
            source.cancel()
            onClose?()
            return
        }
        buffer.append(contentsOf: chunk[0 ..< count])
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex ..< newline]
            buffer.removeSubrange(buffer.startIndex ... newline)
            if !line.isEmpty { onLine?(Data(line)) }
        }
    }
}
