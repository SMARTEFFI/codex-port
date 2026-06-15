import Foundation
import Testing
@testable import CodexPortCore

@Test func relayProcessJSONLTransportSendsLinesAndStreamsProcessOutput() async throws {
    let transport = IntegrationProcessJSONLTransport(
        executablePath: "/bin/sh",
        arguments: [
            "-c",
            "while IFS= read -r line; do printf 'out:%s\\n' \"$line\"; done",
        ]
    )

    try transport.start()
    try await transport.sendLine("hello process transport")
    let line = await transport.nextLine(timeout: .milliseconds(300))
    transport.stop()

    #expect(line == "out:hello process transport")
}

final class IntegrationProcessJSONLTransport: RelayJSONLTransport, @unchecked Sendable {
    private let executablePath: String
    private let arguments: [String]
    private let environment: [String: String]
    private let lock = NSLock()
    private let outputPipe = Pipe()
    private let inputPipe = Pipe()
    private let errorPipe = Pipe()
    private let continuation: AsyncStream<String>.Continuation
    private var process: Process?
    private var stdoutBuffer = ""

    let incomingLines: AsyncStream<String>

    init(executablePath: String, arguments: [String] = [], environment: [String: String] = [:]) {
        self.executablePath = executablePath
        self.arguments = arguments
        self.environment = environment
        var capturedContinuation: AsyncStream<String>.Continuation?
        self.incomingLines = AsyncStream { continuation in
            capturedContinuation = continuation
        }
        self.continuation = capturedContinuation!
    }

    deinit {
        stop()
    }

    func start() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        if !environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, override in
                override
            }
        }
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.receive(data)
        }
        process.terminationHandler = { [weak self] _ in
            self?.finish()
        }
        try process.run()
        lock.withLock {
            self.process = process
        }
    }

    func sendLine(_ line: String) async throws {
        try inputPipe.fileHandleForWriting.write(contentsOf: Data((line + "\n").utf8))
    }

    func stop() {
        let process = lock.withLock {
            let existing = self.process
            self.process = nil
            return existing
        }
        outputPipe.fileHandleForReading.readabilityHandler = nil
        try? inputPipe.fileHandleForWriting.close()
        if let process, process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        finish()
    }

    private func receive(_ data: Data) {
        let text = String(decoding: data, as: UTF8.self)
        let lines = lock.withLock {
            stdoutBuffer.append(text)
            var completed: [String] = []
            while let newlineIndex = stdoutBuffer.firstIndex(of: "\n") {
                completed.append(String(stdoutBuffer[..<newlineIndex]))
                stdoutBuffer.removeSubrange(...newlineIndex)
            }
            return completed
        }
        for line in lines {
            continuation.yield(line)
        }
    }

    private func finish() {
        let remaining = lock.withLock {
            guard !stdoutBuffer.isEmpty else { return nil as String? }
            let line = stdoutBuffer
            stdoutBuffer = ""
            return line
        }
        if let remaining {
            continuation.yield(remaining)
        }
        continuation.finish()
    }
}

private extension IntegrationProcessJSONLTransport {
    func nextLine(timeout: Duration) async -> String? {
        let task = Task<String?, Never> {
            var iterator = incomingLines.makeAsyncIterator()
            return await iterator.next()
        }
        let timeoutTask = Task<String?, Never> {
            try? await Task.sleep(for: timeout)
            return nil
        }
        return await withTaskGroup(of: String?.self) { group in
            group.addTask {
                await task.value
            }
            group.addTask {
                await timeoutTask.value
            }
            let result = await group.next() ?? nil
            task.cancel()
            timeoutTask.cancel()
            return result
        }
    }
}
