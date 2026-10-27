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
    private var herdrSnapshot: Data?
    private var orcaWorktrees: Data?
    private var waiters: [(Int, Data?, Data?) -> Void] = []

    /// Replies as soon as the state differs from the given generation.
    func waitForUpdate(after knownGeneration: Int, reply: @escaping (Int, Data?, Data?) -> Void) {
        queue.async { [self] in
            startIfNeeded()
            if knownGeneration != generation {
                reply(generation, herdrSnapshot, orcaWorktrees)
            } else {
                waiters.append(reply)
            }
        }
    }

    private func startIfNeeded() {
        guard herdr == nil else { return }
        herdr = HerdrMonitor(queue: queue) { [weak self] data in
            guard let self, data != herdrSnapshot else { return }
            herdrSnapshot = data
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
        pending.forEach { $0(generation, herdrSnapshot, orcaWorktrees) }
    }
}

// MARK: - Herdr

/// Subscribes to Herdr's socket events and reads a fresh session snapshot after each one.
/// See https://herdr.dev/docs/socket-api
private final class HerdrMonitor {
    private static let directory = NSHomeDirectory() + "/.config/herdr"
    private static let socketPath = directory + "/herdr.sock"
    private static let lifecycleEvents = [
        "pane.created", "pane.closed", "pane.agent_detected",
        "workspace.created", "workspace.renamed", "workspace.closed",
    ]

    private let queue: DispatchQueue
    private let onChange: (Data?) -> Void
    private var directoryWatcher: DirectoryWatcher?
    private var subscription: LineSocket?
    private var subscribedPanes: [String] = []
    private var pendingRefresh: DispatchWorkItem?

    init(queue: DispatchQueue, onChange: @escaping (Data?) -> Void) {
        self.queue = queue
        self.onChange = onChange
        // The socket is created and removed with the server, which changes the directory.
        directoryWatcher = DirectoryWatcher(path: Self.directory, queue: queue) { [weak self] in
            self?.scheduleRefresh()
        }
        refresh()
    }

    private func scheduleRefresh() {
        pendingRefresh?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh() }
        pendingRefresh = work
        queue.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    private func refresh() {
        LineSocket.request(path: Self.socketPath, ["id": "snapshot", "method": "session.snapshot", "params": [:]], queue: queue) { [weak self] data in
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
        guard let socket = LineSocket(path: Self.socketPath, queue: queue) else { return }

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
