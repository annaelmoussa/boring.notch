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
/// The descriptor stays open for writing after the peer finishes sending, until `close()`.
final class LineSocket {
    var onLine: ((Data) -> Void)?
    /// Called once the peer has finished sending or disconnected.
    var onClose: (() -> Void)?

    /// Closes the descriptor only once the read source no longer uses it.
    private final class Descriptor {
        let value: Int32
        var wantsClose = false
        var isReleased = false
        private var isClosed = false

        init(_ value: Int32) { self.value = value }

        func close() {
            guard !isClosed else { return }
            isClosed = true
            Darwin.close(value)
        }
    }

    private let descriptor: Descriptor
    private let source: DispatchSourceRead
    private var buffer = Data()

    /// Wraps a connected socket.
    init(descriptor value: Int32, queue: DispatchQueue) {
        var noSigPipe: Int32 = 1
        setsockopt(value, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        let descriptor = Descriptor(value)
        self.descriptor = descriptor
        source = DispatchSource.makeReadSource(fileDescriptor: value, queue: queue)
        source.setCancelHandler {
            descriptor.isReleased = true
            if descriptor.wantsClose { descriptor.close() }
        }
        source.setEventHandler { [weak self] in self?.readAvailable() }
        source.resume()
    }

    /// Connects to the socket at `path`.
    convenience init?(path: String, queue: DispatchQueue) {
        guard var address = LineSocket.address(path) else { return nil }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            Darwin.close(descriptor)
            return nil
        }
        self.init(descriptor: descriptor, queue: queue)
    }

    deinit {
        close()
    }

    static func address(_ path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: pathBytes) }
        return address
    }

    func send(_ message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }
        send(line: data)
    }

    func send(line: Data) {
        var data = line
        data.append(0x0A)
        data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = write(descriptor.value, bytes.baseAddress! + offset, bytes.count - offset)
                guard written > 0 else { return }
                offset += written
            }
        }
    }

    func close() {
        descriptor.wantsClose = true
        if descriptor.isReleased {
            descriptor.close()
        } else {
            source.cancel()
        }
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
        let count = read(descriptor.value, &chunk, chunk.count)
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

/// Accepts connections on a Unix domain socket owned by the current user.
final class LineSocketListener {
    private let descriptor: Int32
    private let source: DispatchSourceRead

    init?(path: String, queue: DispatchQueue, onAccept: @escaping (LineSocket) -> Void) {
        guard var address = LineSocket.address(path) else { return nil }
        unlink(path)
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, chmod(path, 0o600) == 0, listen(descriptor, 16) == 0 else {
            Darwin.close(descriptor)
            return nil
        }
        fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)

        self.descriptor = descriptor
        source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setCancelHandler { Darwin.close(descriptor) }
        source.setEventHandler {
            while case let client = accept(descriptor, nil, nil), client >= 0 {
                onAccept(LineSocket(descriptor: client, queue: queue))
            }
        }
        source.resume()
    }

    deinit {
        source.cancel()
    }
}

/// Short-lived command line tools, used for user actions only.
enum Command {
    /// Runs a short command and returns its output, or nil if it failed or took over 5 seconds.
    static func run(_ executable: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: timeout)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeout.cancel()
        return process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }
}
