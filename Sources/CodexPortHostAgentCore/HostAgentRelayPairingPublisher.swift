import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import CodexPortShared

public protocol HostAgentRelayPairingPublishHTTPClient: Sendable {
    func publish(_ request: RelayPairingPublishRequest, at url: URL) async throws
}

public struct HostAgentRelayPairingPublisher: Sendable {
    public var configuration: HostAgentRelayConfiguration
    private let httpClient: HostAgentRelayPairingPublishHTTPClient

    public init(
        configuration: HostAgentRelayConfiguration,
        httpClient: HostAgentRelayPairingPublishHTTPClient = URLSessionHostAgentRelayPairingPublishHTTPClient()
    ) {
        self.configuration = configuration
        self.httpClient = httpClient
    }

    public func publish(_ snapshot: HostAgentMenuPairingSnapshot) async throws {
        guard var request = snapshot.publishRequest else {
            throw HostAgentRelayPairingPublisherError.noPairingToken
        }
        request.hostDisplayName = configuration.host.displayName
        request.hostUserName = configuration.host.userName
        request.hostPublicKeyBase64 = configuration.host.publicKey.rawValue.base64EncodedString()
        try await httpClient.publish(request, at: configuration.pairingPublishURL)
    }
}

public enum HostAgentRelayPairingPublisherError: Error, Equatable, Sendable {
    case noPairingToken
    case httpStatus(Int)
}

public struct URLSessionHostAgentRelayPairingPublishHTTPClient: HostAgentRelayPairingPublishHTTPClient {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func publish(_ request: RelayPairingPublishRequest, at url: URL) async throws {
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONEncoder().encode(request)
        let (_, response) = try await session.data(for: urlRequest)
        if let response = response as? HTTPURLResponse,
           !(200..<300).contains(response.statusCode) {
            throw HostAgentRelayPairingPublisherError.httpStatus(response.statusCode)
        }
    }
}
