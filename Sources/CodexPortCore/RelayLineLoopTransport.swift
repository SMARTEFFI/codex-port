import Foundation

public final class RelayLineLoopTransport: RelayJSONLTransport, @unchecked Sendable {
    public typealias SendLine = @Sendable (String) async throws -> Void

    public let incomingLines: AsyncStream<String>
    private let sendLineHandler: SendLine

    public init(
        incomingLines: AsyncStream<String>,
        sendLine: @escaping SendLine
    ) {
        self.incomingLines = incomingLines
        self.sendLineHandler = sendLine
    }

    public func sendLine(_ line: String) async throws {
        try await sendLineHandler(line)
    }
}
