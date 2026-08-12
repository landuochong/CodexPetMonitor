import AppKit
import Combine
import SwiftUI

@main
struct CodexPetMonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("Codex Pet", systemImage: "pawprint.fill") {
            MonitorMenu(model: appDelegate.model)
        }
        .menuBarExtraStyle(.window)

        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = CodexStatusModel()
    private var petWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        model.start()
        let controller = NSHostingController(rootView: PetWindow(model: model))
        let window = NSPanel(contentViewController: controller)
        window.setContentSize(NSSize(width: 156, height: 174))
        window.styleMask = [.borderless, .nonactivatingPanel]
        window.level = .floating
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.canHide = false
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        if let screen = NSScreen.main {
            let frame = window.frame
            let visible = screen.visibleFrame
            window.setFrameOrigin(NSPoint(
                x: visible.maxX - frame.width - 24,
                y: visible.minY + 24
            ))
        }
        window.orderFrontRegardless()
        petWindow = window
    }
}

enum CodexTaskState: String, CaseIterable, Identifiable, Sendable {
    case idle, working, waitingApproval, failed
    var id: String { rawValue }

    var title: String {
        switch self {
        case .idle: "待机"
        case .working: "正在工作"
        case .waitingApproval: "等待你的批准"
        case .failed: "出现问题"
        }
    }

    var row: Int {
        switch self {
        case .idle: 0
        case .working: 7
        case .waitingApproval: 1
        case .failed: 5
        }
    }

    var frameCount: Int {
        switch self {
        case .idle: 6
        case .working: 6
        case .waitingApproval: 8
        case .failed: 8
        }
    }
}

private struct ThreadState: Sendable {
    let id: String
    let updatedAt: TimeInterval
    let state: CodexTaskState
    let evidence: String
    let lastEventAt: TimeInterval
    let lastStartedAt: TimeInterval
}

private struct StatusScanResult: Sendable {
    let results: [ThreadState]
    let error: String?
}

private final class CodexStatusScanner: @unchecked Sendable {
    private let databaseURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/state_5.sqlite")
    private let logsDatabaseURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/logs_2.sqlite")
    private let eventReader = LocalEventReader()

    func scan() -> StatusScanResult {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            return StatusScanResult(results: [], error: "未找到 Codex 本地状态库")
        }
        let threads = recentThreads()
        guard !threads.isEmpty else {
            return StatusScanResult(results: [], error: "尚无可读取的 Codex 任务")
        }
        let approvalTimes = latestApprovalTimes()
        let results = threads.map { thread in
            let result = eventReader.state(at: thread.path, approvedAt: approvalTimes[thread.id])
            return ThreadState(id: thread.id, updatedAt: thread.updatedAt, state: result.state,
                               evidence: result.evidence, lastEventAt: result.lastEventAt,
                               lastStartedAt: result.lastStartedAt)
        }
        return StatusScanResult(results: results, error: nil)
    }

    private func recentThreads() -> [(id: String, path: String, updatedAt: TimeInterval)] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [databaseURL.path, "select id||char(9)||rollout_path||char(9)||updated_at_ms from threads where archived=0 and preview<>'' order by updated_at_ms desc limit 20;"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return [] }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?
                .split(separator: "\n")
                .compactMap { line in
                    let fields = line.split(separator: "\t", maxSplits: 2).map(String.init)
                    guard fields.count == 3, let milliseconds = TimeInterval(fields[2]) else { return nil }
                    return (fields[0], fields[1], milliseconds / 1000)
                } ?? []
        } catch {
            return []
        }
    }

    private func latestApprovalTimes() -> [String: TimeInterval] {
        guard FileManager.default.fileExists(atPath: logsDatabaseURL.path) else { return [:] }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [logsDatabaseURL.path, "select thread_id||char(9)||max(ts) from logs where thread_id is not null and target='codex_core::session::handlers' and feedback_log_body like '%Approval %decision:%' group by thread_id;"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return [:] }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let lines = String(data: data, encoding: .utf8)?.split(separator: "\n") ?? []
            return Dictionary(uniqueKeysWithValues: lines.compactMap { line in
                let fields = line.split(separator: "\t", maxSplits: 1)
                guard fields.count == 2, let seconds = TimeInterval(fields[1]) else { return nil }
                return (String(fields[0]), seconds)
            })
        } catch {
            return [:]
        }
    }
}

@MainActor
final class CodexStatusModel: ObservableObject {
    @Published private(set) var detectedState: CodexTaskState = .idle
    @Published private(set) var runningTaskCount = 0
    @Published private(set) var waitingTaskCount = 0
    @Published var manualState: CodexTaskState?
    @Published private(set) var lastEvidence = "正在读取 Codex 本地任务事件"

    private var timer: AnyCancellable?
    private let diagnosticsURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex/codex-pet-monitor-status.json")
    private let selfTestPassed = LocalEventReader.selfTest()
    private let scanner = CodexStatusScanner()
    private let scanQueue = DispatchQueue(label: "com.local.codex-pet-monitor.status-scan", qos: .utility)
    private lazy var liveStatusMonitor = CodexIPCStatusMonitor { [weak self] connected, statuses in
        Task { @MainActor [weak self] in
            self?.applyLiveStatuses(connected: connected, statuses: statuses)
        }
    }
    private var pollInFlight = false
    private var liveStatusConnected = false
    private var liveStatuses: [String: CodexLiveThreadStatus] = [:]
    private var latestScanResults: [ThreadState] = []
    private var trackedThreadID: String?
    private var foregroundThreadID: String?
    private var failureCandidateSince: [String: Date] = [:]
    private let failureConfirmationDelay: TimeInterval = 3
    private var stateChangedAt = Date()
    private var stateHistory: [[String: String]] = []

    var state: CodexTaskState { manualState ?? detectedState }
    private var liveStatusUsable: Bool { liveStatusConnected && !liveStatuses.isEmpty }

    func start() {
        liveStatusMonitor.start()
        timer = Timer.publish(every: 1.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.poll() }
        poll()
    }

    private func poll() {
        guard !pollInFlight else { return }
        pollInFlight = true
        scanQueue.async { [scanner] in
            let scanResult = scanner.scan()
            Task { @MainActor [weak self] in
                self?.apply(scanResult)
            }
        }
    }

    private func apply(_ scanResult: StatusScanResult) {
        pollInFlight = false
        if let error = scanResult.error {
            detectedState = error.contains("未找到") ? .failed : .idle
            lastEvidence = error
            writeDiagnostics()
            return
        }

        let results = scanResult.results
        latestScanResults = results
        liveStatusMonitor.updateSubscriptions(results.map(\.id))
        recomputeState(results: results)
    }

    private func applyLiveStatuses(connected: Bool, statuses: [String: CodexLiveThreadStatus]) {
        liveStatusConnected = connected
        liveStatuses = statuses
        recomputeState(results: latestScanResults)
    }

    private func effectiveState(for result: ThreadState) -> CodexTaskState {
        guard let live = liveStatuses[result.id] else { return result.state }
        // Treat active signals as additive. A long-running IPC subscription can
        // retain an idle snapshot while a newer local lifecycle has already
        // started, so idle must never cancel local working/waiting evidence.
        if live.state == .waitingApproval || result.state == .waitingApproval { return .waitingApproval }
        if live.state == .working || result.state == .working { return .working }
        if live.reportsSystemError { return result.state == .failed ? .failed : result.state }
        return result.state
    }

    private func recomputeState(results: [ThreadState]) {
        let now = Date()
        // A connected socket is only a transport signal. New Codex versions
        // can accept the IPC connection without returning a snapshot to this
        // client. Merge per thread so missing live entries keep using the local
        // lifecycle instead of being incorrectly counted as idle.
        let effectiveStates = results.map { result in
            (id: result.id, state: effectiveState(for: result))
        }
        let failureCandidates: Set<String>
        failureCandidates = Set(results.compactMap { result in
            if let live = liveStatuses[result.id] {
                return live.reportsSystemError && result.state == .failed ? result.id : nil
            }
            return result.state == .failed ? result.id : nil
        })
        failureCandidateSince = failureCandidateSince.filter { failureCandidates.contains($0.key) }
        for id in failureCandidates where failureCandidateSince[id] == nil {
            failureCandidateSince[id] = now
        }
        let confirmedFailureIDs = Set(failureCandidates.filter {
            now.timeIntervalSince(failureCandidateSince[$0] ?? now) >= failureConfirmationDelay
        })

        runningTaskCount = effectiveStates.filter { $0.state == .working }.count
        waitingTaskCount = effectiveStates.filter { $0.state == .waitingApproval }.count

        if foregroundThreadID == nil || !results.contains(where: { $0.id == foregroundThreadID }) {
            foregroundThreadID = results.first?.id
        }
        if let newestStart = results.max(by: { $0.lastStartedAt < $1.lastStartedAt }),
           let foreground = results.first(where: { $0.id == foregroundThreadID }),
           newestStart.lastStartedAt > foreground.lastStartedAt {
            foregroundThreadID = newestStart.id
        }
        let liveWaitingIDs = liveStatuses.compactMap { id, status in
            status.state == .waitingApproval ? id : nil
        }
        let waiting = results.filter { $0.state == .waitingApproval }
        let working = results
            .filter { effectiveState(for: $0) == .working }
            .max(by: { $0.lastStartedAt < $1.lastStartedAt })
        let nextState: CodexTaskState
        let nextEvidence: String
        let nextTrackedThreadID: String?
        if !liveWaitingIDs.isEmpty {
            nextState = .waitingApproval
            nextTrackedThreadID = liveWaitingIDs.first
            nextEvidence = "Codex 实时状态：\(liveWaitingIDs.count) 个任务等待你的批准（持续显示）"
        } else if !waiting.isEmpty {
            nextState = .waitingApproval
            nextTrackedThreadID = waiting.max(by: { $0.lastEventAt < $1.lastEventAt })?.id
            nextEvidence = "本地事件：\(waiting.count) 个任务等待你的批准（持续显示）"
        } else if let failed = results
            .filter({ confirmedFailureIDs.contains($0.id) })
            .max(by: { $0.lastEventAt < $1.lastEventAt }) {
            nextState = .failed
            nextTrackedThreadID = failed.id
            nextEvidence = "已确认：任务持续报告真实错误"
        } else if let working {
            nextState = .working
            nextTrackedThreadID = working.id
            let prefix = liveStatuses[working.id] == nil ? "本地事件" : "Codex 实时状态"
            nextEvidence = "\(prefix)：\(runningTaskCount) 个任务正在运行"
        } else if let foreground = results.first(where: { $0.id == foregroundThreadID }) ?? results.first {
            // Keep following the selected task across database heartbeat updates.
            // A different task takes over only when it emits a genuinely newer
            // task_started event, not merely because a background timestamp moved.
            if liveStatuses[foreground.id]?.reportsSystemError == true {
                // Codex Desktop can retain a top-level systemError after a later
                // turn has completed. Until the local lifecycle also confirms a
                // task_failed event, follow the newer local state instead.
                nextState = foreground.state == .failed ? .idle : foreground.state
            } else {
                nextState = effectiveState(for: foreground)
            }
            nextTrackedThreadID = foreground.id
            let prefix = liveStatuses[foreground.id] == nil ? "本地事件" : "Codex 实时状态"
            switch nextState {
            case .idle: nextEvidence = "\(prefix)：当前任务已结束，进入待机"
            case .working: nextEvidence = "\(prefix)：当前任务正在运行"
            case .failed: nextEvidence = "\(prefix)：当前任务异常结束"
            case .waitingApproval: nextEvidence = "\(prefix)：当前任务等待你的批准"
            }
        } else {
            nextState = .idle
            nextTrackedThreadID = nil
            nextEvidence = "本地事件：没有任务等待"
        }

        if nextState != detectedState || nextTrackedThreadID != trackedThreadID {
            detectedState = nextState
            trackedThreadID = nextTrackedThreadID
            lastEvidence = nextEvidence
            stateChangedAt = .now
            stateHistory.append([
                "state": nextState.rawValue,
                "threadID": nextTrackedThreadID ?? "",
                "at": ISO8601DateFormatter().string(from: stateChangedAt)
            ])
            stateHistory = Array(stateHistory.suffix(20))
        } else {
            lastEvidence = nextEvidence
        }
        writeDiagnostics(results: results)
    }

    private func writeDiagnostics(results: [ThreadState] = []) {
        let payload: [String: Any] = [
            "dataSource": liveStatusUsable ? "codex-desktop-ipc+local-events" : "codex-local-events-fallback",
            "liveStatusConnected": liveStatusConnected,
            "liveStatusUsable": liveStatusUsable,
            "liveThreadStatuses": liveStatuses.mapValues {
                [
                    "state": $0.state.rawValue,
                    "activeFlags": $0.activeFlags,
                    "statusType": $0.statusType,
                    "reportsSystemError": $0.reportsSystemError
                ] as [String: Any]
            },
            "selfTestPassed": selfTestPassed,
            "detectedState": detectedState.rawValue,
            "runningTaskCount": runningTaskCount,
            "waitingTaskCount": waitingTaskCount,
            "lastEvidence": lastEvidence,
            "trackedThreadID": trackedThreadID ?? "",
            "stateChangedAt": ISO8601DateFormatter().string(from: stateChangedAt),
            "stateHistory": stateHistory,
            "threadStates": results.prefix(20).map {
                [
                    "threadID": $0.id,
                    "state": $0.state.rawValue,
                    "codexUpdatedAt": ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: $0.updatedAt)),
                    "lastEventAt": $0.lastEventAt > 0 ? ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: $0.lastEventAt)) : "",
                    "lastStartedAt": $0.lastStartedAt > 0 ? ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: $0.lastStartedAt)) : "",
                    "evidence": $0.evidence
                ]
            },
            "updatedAt": ISO8601DateFormatter().string(from: .now)
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]) else { return }
        try? data.write(to: diagnosticsURL, options: .atomic)
    }
}

final class LocalEventReader {
    private struct RememberedState {
        let state: CodexTaskState
        let lastEventAt: TimeInterval
        let lastStartedAt: TimeInterval
    }

    private struct ScanResult {
        let state: CodexTaskState
        let evidence: String
        let lastEventAt: TimeInterval
        let lastStartedAt: TimeInterval
        let foundLifecycle: Bool
        let fileSize: UInt64
    }

    private var remembered: [String: RememberedState] = [:]

    static func selfTest() -> Bool {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-pet-self-test-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: file) }
        let started = #"{"timestamp":"2026-07-30T03:00:00Z","type":"event_msg","payload":{"type":"task_started"}}"#
        let request = #"{"timestamp":"2026-07-30T03:00:01Z","type":"response_item","payload":{"type":"custom_tool_call","call_id":"call-1","name":"exec","input":"{\"sandbox_permissions\":\"require_escalated\"}"}}"#
        let aborted = #"{"timestamp":"2026-07-30T03:00:02Z","type":"event_msg","payload":{"type":"turn_aborted"}}"#
        let failed = #"{"timestamp":"2026-07-30T03:00:02Z","type":"event_msg","payload":{"type":"task_failed"}}"#
        let completed = #"{"timestamp":"2026-07-30T03:00:03Z","type":"event_msg","payload":{"type":"task_complete"}}"#
        let formatter = ISO8601DateFormatter()
        guard let before = formatter.date(from: "2026-07-30T03:00:00Z")?.timeIntervalSince1970,
              let after = formatter.date(from: "2026-07-30T03:00:02Z")?.timeIntervalSince1970 else { return false }
        do {
            try (started + "\n" + request + "\n").write(to: file, atomically: true, encoding: .utf8)
            guard scan(at: file.path, approvedAt: before, tailSize: .max, initial: nil).state == .waitingApproval,
                  scan(at: file.path, approvedAt: after, tailSize: .max, initial: nil).state == .working else { return false }
            try (started + "\n" + request + "\n" + completed + "\n").write(to: file, atomically: true, encoding: .utf8)
            guard scan(at: file.path, approvedAt: after, tailSize: .max, initial: nil).state == .idle else {
                return false
            }
            try (started + "\n" + aborted + "\n").write(to: file, atomically: true, encoding: .utf8)
            guard scan(at: file.path, approvedAt: nil, tailSize: .max, initial: nil).state == .idle else {
                return false
            }
            try (started + "\n" + failed + "\n").write(to: file, atomically: true, encoding: .utf8)
            guard scan(at: file.path, approvedAt: nil, tailSize: .max, initial: nil).state == .failed else {
                return false
            }
            try (started + "\n" + failed + "\n" + completed + "\n").write(
                to: file, atomically: true, encoding: .utf8
            )
            return scan(at: file.path, approvedAt: nil, tailSize: .max, initial: nil).state == .idle
        } catch {
            return false
        }
    }

    func state(at path: String, approvedAt: TimeInterval?) -> (state: CodexTaskState, evidence: String,
                                                               lastEventAt: TimeInterval, lastStartedAt: TimeInterval) {
        let result: ScanResult
        if let prior = remembered[path] {
            result = Self.scan(at: path, approvedAt: approvedAt, tailSize: 2_000_000, initial: prior)
        } else {
            var size: UInt64 = 2_000_000
            var bootstrap = Self.scan(at: path, approvedAt: approvedAt, tailSize: size, initial: nil)
            while !bootstrap.foundLifecycle && size < bootstrap.fileSize {
                size = min(size * 2, bootstrap.fileSize)
                bootstrap = Self.scan(at: path, approvedAt: approvedAt, tailSize: size, initial: nil)
            }
            result = bootstrap
        }
        remembered[path] = RememberedState(state: result.state, lastEventAt: result.lastEventAt,
                                           lastStartedAt: result.lastStartedAt)
        return (result.state, result.evidence, result.lastEventAt, result.lastStartedAt)
    }

    private static func scan(at path: String, approvedAt: TimeInterval?, tailSize: UInt64,
                             initial: RememberedState?) -> ScanResult {
        let url = URL(fileURLWithPath: path)
        guard let handle = try? FileHandle(forReadingFrom: url),
              let end = try? handle.seekToEnd() else {
            return ScanResult(state: .idle, evidence: "无法读取最新任务事件", lastEventAt: 0,
                              lastStartedAt: 0, foundLifecycle: false, fileSize: 0)
        }
        defer { try? handle.close() }
        let start = end > tailSize ? end - tailSize : 0
        guard (try? handle.seek(toOffset: start)) != nil,
              let data = try? handle.readToEnd(),
              let text = String(data: data, encoding: .utf8) else {
            return ScanResult(state: .idle, evidence: "无法读取最新任务事件", lastEventAt: 0,
                              lastStartedAt: 0, foundLifecycle: false, fileSize: end)
        }

        var active = initial?.state == .working || initial?.state == .waitingApproval
        var failed = initial?.state == .failed
        var lastEventAt: TimeInterval = initial?.lastEventAt ?? 0
        var lastStartedAt: TimeInterval = initial?.lastStartedAt ?? 0
        var foundLifecycle = false
        var pendingApprovals: [String: TimeInterval] = [:]
        for line in text.split(separator: "\n") {
            guard let lineData = line.data(using: .utf8),
                  let root = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let payload = root["payload"] as? [String: Any] else { continue }
            let type = payload["type"] as? String ?? ""
            let timestamp = (root["timestamp"] as? String).flatMap(Self.parseTimestamp) ?? 0

            if type == "task_started" {
                foundLifecycle = true
                lastEventAt = max(lastEventAt, timestamp)
                lastStartedAt = max(lastStartedAt, timestamp)
                active = true
                failed = false
                pendingApprovals.removeAll()
            } else if type == "task_complete" {
                foundLifecycle = true
                lastEventAt = max(lastEventAt, timestamp)
                active = false
                failed = false
                pendingApprovals.removeAll()
            } else if type == "turn_aborted" {
                foundLifecycle = true
                lastEventAt = max(lastEventAt, timestamp)
                active = false
                failed = false
                pendingApprovals.removeAll()
            } else if type == "task_failed" {
                foundLifecycle = true
                lastEventAt = max(lastEventAt, timestamp)
                active = false
                failed = true
                pendingApprovals.removeAll()
            } else if type == "custom_tool_call" || type == "function_call" {
                let callID = payload["call_id"] as? String ?? ""
                let name = payload["name"] as? String ?? ""
                let input = (payload["input"] as? String) ?? (payload["arguments"] as? String) ?? ""
                if !callID.isEmpty && (input.contains("require_escalated") || name == "request_user_input") {
                    lastEventAt = max(lastEventAt, timestamp)
                    pendingApprovals[callID] = timestamp
                }
            } else if type == "custom_tool_call_output" || type == "function_call_output" {
                if let callID = payload["call_id"] as? String, pendingApprovals.removeValue(forKey: callID) != nil {
                    lastEventAt = max(lastEventAt, timestamp)
                }
            }
        }

        if let approvedAt {
            let previousCount = pendingApprovals.count
            pendingApprovals = pendingApprovals.filter { $0.value > approvedAt }
            if pendingApprovals.count < previousCount { lastEventAt = max(lastEventAt, approvedAt) }
        }

        if !pendingApprovals.isEmpty {
            return ScanResult(state: .waitingApproval, evidence: "本地事件：等待你的批准（持续显示）",
                              lastEventAt: lastEventAt, lastStartedAt: lastStartedAt,
                              foundLifecycle: foundLifecycle, fileSize: end)
        }
        if failed {
            return ScanResult(state: .failed, evidence: "本地事件：任务异常结束", lastEventAt: lastEventAt,
                              lastStartedAt: lastStartedAt, foundLifecycle: foundLifecycle, fileSize: end)
        }
        if active {
            return ScanResult(state: .working, evidence: "本地事件：任务正在运行", lastEventAt: lastEventAt,
                              lastStartedAt: lastStartedAt, foundLifecycle: foundLifecycle, fileSize: end)
        }
        return ScanResult(state: .idle, evidence: "本地事件：没有任务等待", lastEventAt: lastEventAt,
                          lastStartedAt: lastStartedAt, foundLifecycle: foundLifecycle, fileSize: end)
    }

    private static func parseTimestamp(_ value: String) -> TimeInterval? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date.timeIntervalSince1970 }
        return ISO8601DateFormatter().date(from: value)?.timeIntervalSince1970
    }
}

struct MonitorMenu: View {
    @ObservedObject var model: CodexStatusModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.state.title).font(.headline)
            Text(model.lastEvidence).font(.caption).foregroundStyle(.secondary)
            Divider()
            Picker("手动预览", selection: Binding(
                get: { model.manualState }, set: { model.manualState = $0 }
            )) {
                Text("自动检测").tag(CodexTaskState?.none)
                ForEach(CodexTaskState.allCases) { state in
                    Text(state.title).tag(CodexTaskState?.some(state))
                }
            }
            .pickerStyle(.menu)
            Button("退出") { NSApplication.shared.terminate(nil) }
        }
        .padding()
        .frame(width: 260)
    }
}

struct PetWindow: View {
    @ObservedObject var model: CodexStatusModel

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            AnimatedPetSprite(state: model.state)
                .frame(width: 144, height: 156)
                .padding(6)

            VStack(alignment: .trailing, spacing: 3) {
                TaskCountBadge(
                    count: model.runningTaskCount,
                    systemImage: "play.fill",
                    color: .green,
                    accessibilityLabel: "正在执行"
                )
                TaskCountBadge(
                    count: model.waitingTaskCount,
                    systemImage: "hourglass",
                    color: .red,
                    accessibilityLabel: "等待处理"
                )
            }
            .padding(.trailing, 3)
            .padding(.bottom, 5)
            .allowsHitTesting(false)
        }
        .background(Color.clear)
    }
}

private struct TaskCountBadge: View {
    let count: Int
    let systemImage: String
    let color: Color
    let accessibilityLabel: String

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: systemImage)
                .font(.system(size: 8, weight: .black))
            Text("\(count)")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .monospacedDigit()
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 6)
        .frame(height: 18)
        .background(color.opacity(count > 0 ? 0.94 : 0.55), in: Capsule())
        .overlay {
            Capsule().stroke(.white.opacity(0.75), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.35), radius: 1.5, y: 1)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue("\(count)")
    }
}

struct AnimatedPetSprite: NSViewRepresentable {
    let state: CodexTaskState

    final class DraggableImageView: NSImageView {
        var onPointerEntered: (() -> Void)?
        var onPointerExited: (() -> Void)?
        var onPointerMoved: ((NSPoint) -> Void)?
        var onClicked: (() -> Void)?
        private var pointerTrackingArea: NSTrackingArea?

        override var mouseDownCanMoveWindow: Bool { true }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let pointerTrackingArea { removeTrackingArea(pointerTrackingArea) }
            let area = NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(area)
            pointerTrackingArea = area
        }

        override func mouseEntered(with event: NSEvent) {
            onPointerEntered?()
            onPointerMoved?(convert(event.locationInWindow, from: nil))
        }

        override func mouseExited(with event: NSEvent) { onPointerExited?() }

        override func mouseMoved(with event: NSEvent) {
            onPointerMoved?(convert(event.locationInWindow, from: nil))
        }

        override func mouseDown(with event: NSEvent) {
            onClicked?()
            super.mouseDown(with: event)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSImageView {
        let view = DraggableImageView()
        view.imageScaling = .scaleProportionallyDown
        view.imageAlignment = .alignCenter
        view.animates = false
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .vertical)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        context.coordinator.attach(view, state: state)
        return view
    }

    func updateNSView(_ view: NSImageView, context: Context) {
        context.coordinator.setState(state)
    }

    static func dismantleNSView(_ view: NSImageView, coordinator: Coordinator) {
        coordinator.stop()
    }

    @MainActor
    final class Coordinator: NSObject {
        private weak var imageView: NSImageView?
        private var timer: Timer?
        private var state: CodexTaskState = .idle
        private var frame = 0
        private var failedSequenceIndex = 0
        private var hovered = false
        private var clickJumpActive = false
        private var frameAccumulator: TimeInterval = 0
        private var lastTickAt = ProcessInfo.processInfo.systemUptime

        private enum Playback {
            case task(CodexTaskState)
            case jumping
        }

        func attach(_ view: NSImageView, state: CodexTaskState) {
            imageView = view
            if let interactiveView = view as? DraggableImageView {
                interactiveView.onPointerEntered = { [weak self] in self?.pointerEntered() }
                interactiveView.onPointerExited = { [weak self] in self?.pointerExited() }
                interactiveView.onClicked = { [weak self] in self?.clicked() }
            }
            self.state = state
            frame = 0
            failedSequenceIndex = 0
            frameAccumulator = 0
            lastTickAt = ProcessInfo.processInfo.systemUptime
            displayCurrentFrame()
            let timer = Timer(
                timeInterval: 1.0 / 60.0,
                target: self,
                selector: #selector(timerFired(_:)),
                userInfo: nil,
                repeats: true
            )
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }

        @objc private func timerFired(_ timer: Timer) {
            let now = ProcessInfo.processInfo.systemUptime
            let elapsed = min(now - lastTickAt, 0.1)
            lastTickAt = now

            frameAccumulator += elapsed
            let interval = currentFrameInterval
            guard frameAccumulator >= interval else { return }
            frameAccumulator.formTruncatingRemainder(dividingBy: interval)
            advance()
        }

        private var playback: Playback {
            if state == .waitingApproval || state == .failed { return .task(state) }
            if hovered || clickJumpActive { return .jumping }
            return .task(state)
        }

        private var currentFrameInterval: TimeInterval {
            switch playback {
            case .jumping:
                return frame == 4 ? 0.28 : 0.14
            case .task(.idle):
                return 3600
            case .task(.working):
                return 3600
            case .task(.waitingApproval):
                return 0.12
            case .task(.failed):
                if frame == 0 { return 0.48 }
                if frame == 5 { return 0.32 }
                return 0.18
            }
        }

        func setState(_ newState: CodexTaskState) {
            guard state != newState else { return }
            state = newState
            frame = 0
            failedSequenceIndex = 0
            frameAccumulator = 0
            lastTickAt = ProcessInfo.processInfo.systemUptime
            if newState == .waitingApproval || newState == .failed {
                clickJumpActive = false
            }
            displayCurrentFrame()
        }

        private func advance() {
            switch playback {
            case .jumping:
                if hovered {
                    frame = (frame + 1) % 5
                } else if frame == 4 {
                    clickJumpActive = false
                    frame = 0
                } else {
                    frame += 1
                }
            case .task(.idle):
                frame = 0
            case .task(.working):
                frame = 0
            case .task(.waitingApproval):
                // Frames 6 and 7 are gathered/tucked poses that read as a
                // mid-run pause. Keep the six continuous stride poses only.
                frame = (frame + 1) % 6
            case .task(.failed):
                // Descend into the crying pose and retrace the same frames.
                // This removes the visible snap from the old final frame back
                // to standing, while keeping a readable pause at both ends.
                let sequence = [0, 1, 2, 3, 4, 5, 4, 3, 2, 1]
                failedSequenceIndex = (failedSequenceIndex + 1) % sequence.count
                frame = sequence[failedSequenceIndex]
            }
            displayCurrentFrame()
        }

        private func displayCurrentFrame() {
            let position: (row: Int, column: Int)
            switch playback {
            case .jumping: position = (4, frame)
            case .task(let taskState): position = (taskState.row, frame)
            }
            guard let image = SpriteAtlas.shared.image(row: position.row, column: position.column) else { return }
            imageView?.image = image
        }

        private func pointerEntered() {
            guard state != .waitingApproval && state != .failed else { return }
            hovered = true
            frame = 0
            failedSequenceIndex = 0
            frameAccumulator = 0
            displayCurrentFrame()
        }

        private func pointerExited() {
            hovered = false
            clickJumpActive = false
            frame = 0
            failedSequenceIndex = 0
            frameAccumulator = 0
            displayCurrentFrame()
        }

        private func clicked() {
            guard state != .waitingApproval && state != .failed else { return }
            clickJumpActive = true
            frame = 0
            failedSequenceIndex = 0
            frameAccumulator = 0
            displayCurrentFrame()
        }

        func stop() {
            timer?.invalidate()
            timer = nil
            if let interactiveView = imageView as? DraggableImageView {
                interactiveView.onPointerEntered = nil
                interactiveView.onPointerExited = nil
                interactiveView.onPointerMoved = nil
                interactiveView.onClicked = nil
            }
            imageView = nil
        }
    }
}

@MainActor
final class SpriteAtlas {
    static let shared = SpriteAtlas()
    private let frames: [[NSImage?]]
    private let cellWidth = 192
    private let cellHeight = 208

    private init() {
        guard let url = Bundle.module.url(forResource: "chopper-spritesheet", withExtension: "png"),
              let source = NSImage(contentsOf: url),
              let cgImage = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            frames = Array(repeating: Array(repeating: nil, count: 8), count: 11)
            return
        }
        var loaded = Array(repeating: Array<NSImage?>(repeating: nil, count: 8), count: 11)
        for row in 0..<11 {
            for column in 0..<8 {
                let rect = CGRect(
                    x: column * cellWidth,
                    y: row * cellHeight,
                    width: cellWidth,
                    height: cellHeight
                )
                if let crop = cgImage.cropping(to: rect) {
                    loaded[row][column] = NSImage(
                        cgImage: crop,
                        size: NSSize(width: cellWidth, height: cellHeight)
                    )
                }
            }
        }
        frames = loaded
    }

    func image(row: Int, column: Int) -> NSImage? {
        guard frames.indices.contains(row), frames[row].indices.contains(column) else { return nil }
        return frames[row][column]
    }
}
