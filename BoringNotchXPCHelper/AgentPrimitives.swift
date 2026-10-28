//
//  AgentPrimitives.swift
//  BoringNotchXPCHelper
//
//  Building blocks for agent monitors: kqueue directory watching and NDJSON Unix sockets.
//

import Foundation

/// Calls the handler when entries are added, removed or renamed in a directory.
final class DirectoryWatcher {
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
final class LineSocket {
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
