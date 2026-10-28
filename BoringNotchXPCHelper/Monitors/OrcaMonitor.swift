//
//  OrcaMonitor.swift
//  BoringNotchXPCHelper
//

import Foundation

/// Orca has no public event stream. It rewrites `agent-hooks/last-status.json` whenever an
/// agent reports a new state, so that directory is watched and each change triggers one
/// `worktree.ps` request on Orca's local runtime socket, the same call its CLI makes.
final class OrcaMonitor: AgentMonitor {
    static let id = "orca"
    static let tools = ["orca"]

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
