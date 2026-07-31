import Foundation
import Darwin

struct CodexLiveThreadStatus: Sendable, Equatable {
    let state: CodexTaskState
    let activeFlags: [String]
    let statusType: String

    var reportsSystemError: Bool { statusType == "systemError" }
}

/// Reads the live thread status already maintained by Codex Desktop.
///
/// Codex Desktop exposes a user-owned Unix socket at `~/.codex/ipc/ipc.sock`.
/// Messages use a four-byte little-endian length followed by JSON. Subscribing
/// through this channel avoids inferring approval state from incomplete JSONL
/// tool events (notably approvals nested inside a yielded `functions.exec`).
final class CodexIPCStatusMonitor: @unchecked Sendable {
    typealias UpdateHandler = @Sendable (_ connected: Bool, _ statuses: [String: CodexLiveThreadStatus]) -> Void

    private let socketPath = NSHomeDirectory() + "/.codex/ipc/ipc.sock"
    private let worker = DispatchQueue(label: "com.local.codex-pet-monitor.ipc", qos: .utility)
    private let lock = NSLock()
    private let writeLock = NSLock()
    private let updateHandler: UpdateHandler

    private var running = false
    private var socketFD: Int32 = -1
    private var clientID: String?
    private var desiredThreadIDs = Set<String>()
    private var subscribedThreadIDs = Set<String>()
    private var statuses: [String: CodexLiveThreadStatus] = [:]

    init(updateHandler: @escaping UpdateHandler) {
        self.updateHandler = updateHandler
    }

    deinit { stop() }

    func start() {
        lock.lock()
        guard !running else {
            lock.unlock()
            return
        }
        running = true
        lock.unlock()
        worker.async { [weak self] in self?.connectionLoop() }
    }

    func stop() {
        lock.lock()
        running = false
        let fd = socketFD
        socketFD = -1
        lock.unlock()
        if fd >= 0 {
            Darwin.shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
        }
    }

    func updateSubscriptions(_ threadIDs: [String]) {
        let desired = Set(threadIDs)
        lock.lock()
        desiredThreadIDs = desired
        let currentClientID = clientID
        let additions = desired.subtracting(subscribedThreadIDs)
        let removals = subscribedThreadIDs.subtracting(desired)
        subscribedThreadIDs.formUnion(additions)
        subscribedThreadIDs.subtract(removals)
        for id in removals { statuses.removeValue(forKey: id) }
        let snapshot = statuses
        lock.unlock()

        guard let currentClientID else { return }
        for id in removals { sendFollowing(threadID: id, following: false, clientID: currentClientID) }
        for id in additions { sendFollowing(threadID: id, following: true, clientID: currentClientID) }
        if !removals.isEmpty { updateHandler(true, snapshot) }
    }

    private func connectionLoop() {
        while isRunning {
            guard let fd = connectSocket() else {
                Thread.sleep(forTimeInterval: 1)
                continue
            }
            setConnectedSocket(fd)
            sendInitialize()
            while isRunning, let frame = readFrame(from: fd) {
                process(frame)
            }
            disconnect(fd)
            if isRunning { Thread.sleep(forTimeInterval: 1) }
        }
    }

    private var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    private func connectSocket() -> Int32? {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8CString)
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            Darwin.close(fd)
            return nil
        }
        let pathCapacity = MemoryLayout.size(ofValue: address.sun_path)
        socketPath.withCString { source in
            withUnsafeMutablePointer(to: &address.sun_path.0) { destination in
                _ = Darwin.strlcpy(destination, source, pathCapacity)
            }
        }
        let addressLength = socklen_t(MemoryLayout<sa_family_t>.size + pathBytes.count)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, addressLength)
            }
        }
        guard result == 0 else {
            Darwin.close(fd)
            return nil
        }
        return fd
    }

    private func setConnectedSocket(_ fd: Int32) {
        lock.lock()
        socketFD = fd
        clientID = nil
        subscribedThreadIDs.removeAll()
        statuses.removeAll()
        lock.unlock()
        updateHandler(true, [:])
    }

    private func disconnect(_ fd: Int32) {
        lock.lock()
        if socketFD == fd { socketFD = -1 }
        clientID = nil
        subscribedThreadIDs.removeAll()
        statuses.removeAll()
        lock.unlock()
        Darwin.close(fd)
        updateHandler(false, [:])
    }

    private func sendInitialize() {
        send([
            "type": "request",
            "requestId": "codex-pet-initialize",
            "sourceClientId": "initializing-client",
            "version": 1,
            "method": "initialize",
            "params": ["clientType": "codex-pet-monitor"],
            "timeoutMs": 5_000
        ])
    }

    private func finishInitialization(clientID: String) {
        lock.lock()
        self.clientID = clientID
        let desired = desiredThreadIDs
        subscribedThreadIDs = desired
        lock.unlock()

        send([
            "type": "broadcast",
            "method": "thread-stream-following-status-requested",
            "sourceClientId": clientID,
            "version": 1,
            "params": [:]
        ])
        for id in desired { sendFollowing(threadID: id, following: true, clientID: clientID) }
    }

    private func sendFollowing(threadID: String, following: Bool, clientID: String) {
        send([
            "type": "broadcast",
            "method": "thread-stream-following-changed",
            "sourceClientId": clientID,
            "version": 1,
            "params": [
                "conversationId": threadID,
                "hostId": "local",
                "following": following
            ]
        ])
    }

    private func send(_ object: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        var length = UInt32(data.count).littleEndian
        var frame = Data(bytes: &length, count: MemoryLayout<UInt32>.size)
        frame.append(data)

        lock.lock()
        let fd = socketFD
        lock.unlock()
        guard fd >= 0 else { return }

        writeLock.lock()
        defer { writeLock.unlock() }
        frame.withUnsafeBytes { rawBuffer in
            guard var pointer = rawBuffer.baseAddress else { return }
            var remaining = rawBuffer.count
            while remaining > 0 {
                let written = Darwin.write(fd, pointer, remaining)
                if written <= 0 { return }
                pointer = pointer.advanced(by: written)
                remaining -= written
            }
        }
    }

    private func readFrame(from fd: Int32) -> Data? {
        guard let lengthData = readExactly(4, from: fd) else { return nil }
        let length = lengthData.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) }
        guard length > 0, length <= 268_435_456 else { return nil }
        return readExactly(Int(length), from: fd)
    }

    private func readExactly(_ count: Int, from fd: Int32) -> Data? {
        var data = Data(count: count)
        let success = data.withUnsafeMutableBytes { rawBuffer -> Bool in
            guard var pointer = rawBuffer.baseAddress else { return false }
            var remaining = count
            while remaining > 0 {
                let amount = Darwin.read(fd, pointer, remaining)
                if amount <= 0 { return false }
                pointer = pointer.advanced(by: amount)
                remaining -= amount
            }
            return true
        }
        return success ? data : nil
    }

    private func process(_ data: Data) {
        // Initialization responses are small and can be decoded normally.
        if data.count < 64_000,
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           object["type"] as? String == "response",
           object["method"] as? String == "initialize",
           let result = object["result"] as? [String: Any],
           let id = result["clientId"] as? String {
            finishInitialization(clientID: id)
            return
        }

        // Snapshot frames may contain megabytes of task history. Look only at
        // the small status field instead of decoding the complete conversation.
        guard let text = String(data: data, encoding: .utf8),
              text.contains("\"method\":\"thread-stream-state-changed\""),
              text.contains("\"threadRuntimeStatus\"") else { return }
        guard let threadID = extractJSONString(named: "conversationId", from: text) else { return }
        if text.contains("\"type\":\"snapshot\""),
           let statusObject = extractJSONObject(named: "threadRuntimeStatus", from: text) {
            update(threadID: threadID, statusObject: statusObject)
            return
        }
        processStatusPatches(data, threadID: threadID)
    }

    private func processStatusPatches(_ data: Data, threadID: String) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let params = object["params"] as? [String: Any],
              let change = params["change"] as? [String: Any],
              let patches = change["patches"] as? [[String: Any]] else { return }

        for patch in patches {
            guard let path = patch["path"] as? [String], path.first == "threadRuntimeStatus" else { continue }
            if path.count == 1, let value = patch["value"] as? [String: Any] {
                update(threadID: threadID, statusObject: value)
            } else if path.count == 2, path[1] == "activeFlags" {
                let flags = patch["value"] as? [String] ?? []
                updateFlags(threadID: threadID, flags: flags)
            } else if path.count == 2, path[1] == "type", let type = patch["value"] as? String {
                updateType(threadID: threadID, type: type)
            }
        }
    }

    private func updateFlags(threadID: String, flags: [String]) {
        lock.lock()
        let current = statuses[threadID]
        lock.unlock()
        let type = current?.statusType ?? "notLoaded"
        update(threadID: threadID, statusObject: ["type": type, "activeFlags": flags])
    }

    private func updateType(threadID: String, type: String) {
        lock.lock()
        let flags = statuses[threadID]?.activeFlags ?? []
        lock.unlock()
        update(threadID: threadID, statusObject: ["type": type, "activeFlags": flags])
    }

    private func update(threadID: String, statusObject: [String: Any]) {
        let type = statusObject["type"] as? String ?? "notLoaded"
        let flags = statusObject["activeFlags"] as? [String] ?? []
        let state: CodexTaskState
        if flags.contains("waitingOnApproval") || flags.contains("waitingOnUserInput") {
            state = .waitingApproval
        } else {
            switch type {
            case "active": state = .working
            case "systemError": state = .failed
            default: state = .idle
            }
        }

        lock.lock()
        guard desiredThreadIDs.contains(threadID) else {
            lock.unlock()
            return
        }
        statuses[threadID] = CodexLiveThreadStatus(
            state: state,
            activeFlags: flags,
            statusType: type
        )
        let snapshot = statuses
        lock.unlock()
        updateHandler(true, snapshot)
    }

    private func extractJSONString(named name: String, from text: String) -> String? {
        let marker = "\"\(name)\":\""
        guard let markerRange = text.range(of: marker) else { return nil }
        var index = markerRange.upperBound
        var value = ""
        var escaped = false
        while index < text.endIndex {
            let character = text[index]
            index = text.index(after: index)
            if escaped {
                value.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "\"" {
                return value
            } else {
                value.append(character)
            }
        }
        return nil
    }

    private func extractJSONObject(named name: String, from text: String) -> [String: Any]? {
        let marker = "\"\(name)\":"
        guard let markerRange = text.range(of: marker),
              let opening = text[markerRange.upperBound...].firstIndex(of: "{") else { return nil }
        var index = opening
        var depth = 0
        var inString = false
        var escaped = false
        while index < text.endIndex {
            let character = text[index]
            if inString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
            } else if character == "\"" {
                inString = true
            } else if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 {
                    let end = text.index(after: index)
                    let fragment = Data(text[opening..<end].utf8)
                    return try? JSONSerialization.jsonObject(with: fragment) as? [String: Any]
                }
            }
            index = text.index(after: index)
        }
        return nil
    }
}
