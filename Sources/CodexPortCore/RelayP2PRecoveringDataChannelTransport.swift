import Foundation
import CodexPortShared
import CodexPortWebRTC

public protocol RelayJSONLTransportRecovering: Sendable {
    func recoverAfterForeground() async throws
    func recoverAfterNetworkChange() async throws
    func retryDirectProbeNow() async
}

public final class RelayP2PRecoveringDataChannelTransport:
    RelayJSONLTransport,
    RelayJSONLTransportRecovering,
    @unchecked Sendable
{
    public let incomingLines: AsyncStream<String>

    private let relayHost: RelayHost
    private let session: RelayP2POpenSessionResponse
    private let runtime: P2PConnectionRecoveryRuntime
    private let directProbeInterval: Duration
    private let lineContinuation: AsyncStream<String>.Continuation
    private let lock = NSLock()
    private var currentDataChannel: WebRTCDataChannelTransport
    private var currentPath: P2PConnectionRecoveryPath
    private var currentThreadID: String?
    private var lastAttachLine: String?
    private var pendingBuffer = Data()
    private var pendingRecoveryReason: String?
    private var recoveryTask: Task<Void, Error>?
    private var receiveTask: Task<Void, Never>?
    private var stateTask: Task<Void, Never>?
    private var directProbeTask: Task<Void, Never>?
    private var monitorGeneration = 0
    private var isClosed = false

    public init(
        relayHost: RelayHost,
        session: RelayP2POpenSessionResponse,
        dataChannel: WebRTCDataChannelTransport,
        runtime: P2PConnectionRecoveryRuntime,
        initialPath: P2PConnectionRecoveryPath = .direct,
        directProbeInterval: Duration = .seconds(30)
    ) {
        self.relayHost = relayHost
        self.session = session
        self.currentDataChannel = dataChannel
        self.currentPath = initialPath
        self.runtime = runtime
        self.directProbeInterval = directProbeInterval
        var capturedContinuation: AsyncStream<String>.Continuation?
        self.incomingLines = AsyncStream<String> { continuation in
            capturedContinuation = continuation
        }
        self.lineContinuation = capturedContinuation!
        startMonitoring(dataChannel)
        if initialPath == .relay {
            scheduleDirectProbeLoopIfNeeded()
        }
    }

    deinit {
        close()
    }

    public func sendLine(_ line: String) async throws {
        captureSessionContextIfPresent(in: line)
        if let reason = consumePendingRecoveryReason() {
            try await recoverAfterDataChannelClose(reason: reason)
        }
        do {
            try await send(line, on: currentDataChannelSnapshot())
        } catch {
            guard Self.shouldRecover(after: error) else {
                throw error
            }
            try await recoverAfterDataChannelClose(reason: String(describing: error))
            try await send(line, on: currentDataChannelSnapshot())
        }
    }

    public func recoverAfterForeground() async throws {
        try await runSerializedRecovery(reason: "foregrounded") { coordinator in
            try await coordinator.recoverAfterForeground()
        }
    }

    public func recoverAfterNetworkChange() async throws {
        try await runSerializedRecovery(reason: "network changed") { coordinator in
            try await coordinator.recoverAfterNetworkChange()
        }
    }

    public func retryDirectProbeNow() async {
        await runDirectProbe()
    }

    private func recoverAfterDataChannelClose(reason: String) async throws {
        try await runSerializedRecovery(reason: reason) { coordinator in
            try await coordinator.recoverAfterDataChannelClose(reason: reason)
        }
    }

    private func runSerializedRecovery(
        reason: String,
        _ operation: @escaping @Sendable (P2PConnectionRecoveryCoordinator) async throws -> P2PConnectionRecoveryResult
    ) async throws {
        let task = lock.withLock {
            if let recoveryTask {
                return recoveryTask
            }
            let task = Task { [weak self] in
                guard let self else { return }
                try await self.performRecovery(reason: reason, operation)
            }
            recoveryTask = task
            return task
        }
        do {
            try await task.value
            clearRecoveryTask()
        } catch {
            clearRecoveryTask()
            throw error
        }
    }

    private func performRecovery(
        reason: String,
        _ operation: @Sendable (P2PConnectionRecoveryCoordinator) async throws -> P2PConnectionRecoveryResult
    ) async throws {
        guard let threadID = threadIDSnapshot() else {
            throw WebRTCDataChannelTransportError.dataChannelClosed
        }
        let coordinator = P2PConnectionRecoveryCoordinator(
            relayHost: relayHost,
            session: session,
            threadID: threadID,
            dataChannel: currentDataChannelSnapshot(),
            runtime: runtime,
            initialPath: currentPathSnapshot()
        )
        do {
            let result = try await operation(coordinator)
        replaceDataChannel(result.transport.dataChannel, path: result.transport.path)
        try await replayAttachIfNeeded(on: result.transport.dataChannel)
        } catch {
            markRecoveryNeeded(reason: reason)
            throw error
        }
    }

    private func runDirectProbe() async {
        guard let threadID = threadIDSnapshot() else { return }
        let coordinator = P2PConnectionRecoveryCoordinator(
            relayHost: relayHost,
            session: session,
            threadID: threadID,
            dataChannel: currentDataChannelSnapshot(),
            runtime: runtime,
            initialPath: currentPathSnapshot()
        )
        let result = await coordinator.retryDirectProbeNow()
        guard let transport = result.transport else {
            scheduleDirectProbeLoopIfNeeded()
            return
        }
        replaceDataChannel(transport.dataChannel, path: transport.path)
        try? await replayAttachIfNeeded(on: transport.dataChannel)
    }

    private func replaceDataChannel(
        _ dataChannel: WebRTCDataChannelTransport,
        path: P2PConnectionRecoveryPath
    ) {
        let tasksToCancel = lock.withLock {
            let tasks = (receiveTask, stateTask)
            receiveTask = nil
            stateTask = nil
            currentDataChannel = dataChannel
            currentPath = path
            pendingRecoveryReason = nil
            return tasks
        }
        tasksToCancel.0?.cancel()
        tasksToCancel.1?.cancel()
        startMonitoring(dataChannel)
        switch path {
        case .direct:
            cancelDirectProbeLoop()
        case .relay:
            scheduleDirectProbeLoopIfNeeded()
        }
    }

    private func startMonitoring(_ dataChannel: WebRTCDataChannelTransport) {
        let generation = nextMonitorGeneration()
        let receiveTask = Task { [weak self, dataChannel] in
            for await message in dataChannel.incomingMessages {
                guard self?.isCurrentMonitor(generation) == true else { return }
                self?.receive(message)
            }
        }
        let stateTask = Task { [weak self, dataChannel] in
            for await state in dataChannel.stateUpdates {
                guard let self else { return }
                guard self.isCurrentMonitor(generation) else { return }
                switch state {
                case .turnRelayedConnected:
                    self.setCurrentPath(.relay)
                    self.scheduleDirectProbeLoopIfNeeded()
                case .directConnected:
                    self.setCurrentPath(.direct)
                    self.cancelDirectProbeLoop()
                case let .directFailed(reason), let .turnFailed(reason):
                    await self.recoverOrClose(reason: reason)
                    return
                case .dataChannelClosed:
                    await self.recoverOrClose(reason: "data channel closed")
                    return
                case .iceGathering, .dataChannelOpen:
                    continue
                }
            }
        }
        lock.withLock {
            guard !isClosed, generation == monitorGeneration else {
                receiveTask.cancel()
                stateTask.cancel()
                return
            }
            self.receiveTask = receiveTask
            self.stateTask = stateTask
        }
    }

    private func recoverOrClose(reason: String) async {
        markRecoveryNeeded(reason: reason)
        do {
            try await recoverAfterDataChannelClose(reason: reason)
        } catch {
            close()
        }
    }

    private func scheduleDirectProbeLoopIfNeeded() {
        lock.withLock {
            guard !isClosed, directProbeTask == nil else { return }
            directProbeTask = Task { [weak self] in
                guard let self else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(for: self.directProbeInterval)
                    guard !Task.isCancelled else { return }
                    await self.runDirectProbe()
                }
            }
        }
    }

    private func cancelDirectProbeLoop() {
        lock.withLock {
            let task = directProbeTask
            directProbeTask = nil
            return task
        }?.cancel()
    }

    private func close() {
        let tasks = lock.withLock {
            guard !isClosed else {
                return [Task<Void, Never>]()
            }
            isClosed = true
            let tasks = [receiveTask, stateTask, directProbeTask].compactMap { $0 }
            receiveTask = nil
            stateTask = nil
            directProbeTask = nil
            recoveryTask?.cancel()
            recoveryTask = nil
            return tasks
        }
        for task in tasks {
            task.cancel()
        }
        lineContinuation.finish()
    }

    private func send(_ line: String, on dataChannel: WebRTCDataChannelTransport) async throws {
        guard !lock.withLock({ isClosed }) else {
            throw WebRTCDataChannelTransportError.dataChannelClosed
        }
        for frame in WebRTCDataChannelJSONLFraming.frames(forLine: line) {
            try await dataChannel.send(frame)
        }
    }

    private func receive(_ message: Data) {
        let lines = lock.withLock {
            pendingBuffer.append(message)
            return drainCompleteLines()
        }
        for line in lines {
            lineContinuation.yield(line)
        }
    }

    private func drainCompleteLines() -> [String] {
        var lines: [String] = []
        while let newlineIndex = pendingBuffer.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = pendingBuffer[..<newlineIndex]
            pendingBuffer.removeSubrange(...newlineIndex)
            lines.append(String(decoding: lineData, as: UTF8.self))
        }
        return lines
    }

    private func replayAttachIfNeeded(on dataChannel: WebRTCDataChannelTransport) async throws {
        guard let attachLine = lock.withLock({ lastAttachLine }) else {
            return
        }
        try await send(attachLine, on: dataChannel)
    }

    private func captureSessionContextIfPresent(in line: String) {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let threadID = object["threadID"] as? String,
              !threadID.isEmpty else {
            return
        }
        lock.withLock {
            if currentThreadID == nil {
                currentThreadID = threadID
            }
            if object["type"] as? String == "attach" {
                lastAttachLine = line
            }
        }
    }

    private func markRecoveryNeeded(reason: String) {
        lock.withLock {
            pendingRecoveryReason = reason
        }
    }

    private func consumePendingRecoveryReason() -> String? {
        lock.withLock {
            let reason = pendingRecoveryReason
            pendingRecoveryReason = nil
            return reason
        }
    }

    private func clearRecoveryTask() {
        lock.withLock {
            recoveryTask = nil
        }
    }

    private func setCurrentPath(_ path: P2PConnectionRecoveryPath) {
        lock.withLock {
            currentPath = path
        }
    }

    private func currentDataChannelSnapshot() -> WebRTCDataChannelTransport {
        lock.withLock { currentDataChannel }
    }

    private func currentPathSnapshot() -> P2PConnectionRecoveryPath {
        lock.withLock { currentPath }
    }

    private func threadIDSnapshot() -> String? {
        lock.withLock { currentThreadID }
    }

    private func nextMonitorGeneration() -> Int {
        lock.withLock {
            monitorGeneration += 1
            return monitorGeneration
        }
    }

    private func isCurrentMonitor(_ generation: Int) -> Bool {
        lock.withLock {
            !isClosed && generation == monitorGeneration
        }
    }

    private static func shouldRecover(after error: Error) -> Bool {
        guard let webRTCError = error as? WebRTCDataChannelTransportError else {
            return false
        }
        switch webRTCError {
        case .dataChannelNotOpen, .dataChannelClosed, .iceFailed:
            return true
        case .signalingFailed:
            return false
        }
    }
}
