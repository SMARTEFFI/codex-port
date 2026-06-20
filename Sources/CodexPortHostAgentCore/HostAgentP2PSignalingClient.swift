import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import CodexPortShared

public protocol HostAgentP2PSignalingHTTPClient: Sendable {
    func publishHostPresence(
        _ request: RelayP2PHostPresencePublishRequest,
        at url: URL
    ) async throws -> RelayP2PHostPresencePublishResponse
    func getICEConfiguration(
        _ request: RelayP2PICEConfigurationRequest,
        at url: URL
    ) async throws -> RelayP2PICEConfigurationResponse
    func drainHostMessages(at url: URL) async throws -> RelayP2PDrainHostMessagesResponse
    func sendMessage(_ request: RelayP2PSendMessageRequest, at url: URL) async throws
}

public struct HostAgentP2PSignalingClient: Sendable {
    public var relayBaseURL: URL
    private let httpClient: HostAgentP2PSignalingHTTPClient

    public init(
        relayBaseURL: URL,
        httpClient: HostAgentP2PSignalingHTTPClient = URLSessionHostAgentP2PSignalingHTTPClient()
    ) {
        self.relayBaseURL = relayBaseURL
        self.httpClient = httpClient
    }

    public func drainHostMessages(hostID: UUID) async throws -> [RelayP2PHostDrainedMessageDTO] {
        try await httpClient.drainHostMessages(
            at: p2pURL(pathComponents: ["hosts", hostID.uuidString, "messages"])
        ).messages
    }

    public func publishHostPresence(_ host: RelayHostIdentity) async throws -> RelayP2PHostPresencePublishResponse {
        try await httpClient.publishHostPresence(
            RelayP2PHostPresencePublishRequest(
                hostID: host.id,
                hostDisplayName: host.displayName,
                hostUserName: host.userName,
                hostPublicKeyBase64: host.publicKey.rawValue.base64EncodedString()
            ),
            at: p2pURL(pathComponents: ["hosts", host.id.uuidString, "presence"])
        )
    }

    public func iceConfiguration(
        hostID: UUID,
        deviceID: UUID,
        pairingRecordID: String,
        supportedVersions: [RelayProtocolVersion] = [.v0_2_0]
    ) async throws -> RelayP2PICEConfigurationResponse {
        try await httpClient.getICEConfiguration(
            RelayP2PICEConfigurationRequest(
                hostID: hostID,
                deviceID: deviceID,
                pairingRecordID: pairingRecordID,
                supportedVersions: supportedVersions
            ),
            at: p2pURL(pathComponents: ["ice-config"])
        )
    }

    public func send(
        _ message: RelayP2PSignalingMessageDTO,
        sessionID: UUID
    ) async throws {
        try await httpClient.sendMessage(
            RelayP2PSendMessageRequest(message: message),
            at: p2pURL(pathComponents: ["sessions", sessionID.uuidString, "messages", "send"])
        )
    }

    private func p2pURL(pathComponents: [String]) -> URL {
        var url = relayBaseURL.appending(path: "v0").appending(path: "p2p")
        for component in pathComponents {
            url.append(path: component)
        }
        return url
    }
}

public struct URLSessionHostAgentP2PSignalingHTTPClient: HostAgentP2PSignalingHTTPClient {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func publishHostPresence(
        _ request: RelayP2PHostPresencePublishRequest,
        at url: URL
    ) async throws -> RelayP2PHostPresencePublishResponse {
        let response = try await post(request, to: url)
        do {
            return try JSONDecoder().decode(RelayP2PHostPresencePublishResponse.self, from: response.data)
        } catch {
            throw HostAgentP2PSignalingClientError.invalidResponsePayload
        }
    }

    public func getICEConfiguration(
        _ request: RelayP2PICEConfigurationRequest,
        at url: URL
    ) async throws -> RelayP2PICEConfigurationResponse {
        let response = try await post(request, to: url)
        do {
            return try JSONDecoder().decode(RelayP2PICEConfigurationResponse.self, from: response.data)
        } catch {
            throw HostAgentP2PSignalingClientError.invalidResponsePayload
        }
    }

    public func drainHostMessages(at url: URL) async throws -> RelayP2PDrainHostMessagesResponse {
        try await get(url, decode: RelayP2PDrainHostMessagesResponse.self)
    }

    public func sendMessage(_ request: RelayP2PSendMessageRequest, at url: URL) async throws {
        _ = try await post(request, to: url)
    }

    private func get<T: Decodable>(_ url: URL, decode type: T.Type) async throws -> T {
        let request = Self.makeRequest(url: url, method: "GET")
        return try await response(for: request, decode: type)
    }

    private func post<T: Encodable>(_ value: T, to url: URL) async throws -> (status: Int, data: Data) {
        var request = Self.makeRequest(url: url, method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(value)
        return try await response(for: request)
    }

    static func makeRequest(url: URL, method: String) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        return request
    }

    private func response<T: Decodable>(for request: URLRequest, decode type: T.Type) async throws -> T {
        let response = try await response(for: request)
        do {
            return try JSONDecoder().decode(T.self, from: response.data)
        } catch {
            throw HostAgentP2PSignalingClientError.invalidResponsePayload
        }
    }

    private func response(for request: URLRequest) async throws -> (status: Int, data: Data) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else {
                throw HostAgentP2PSignalingClientError.invalidResponse
            }
            guard (200..<300).contains(response.statusCode) else {
                throw HostAgentP2PSignalingClientError.httpStatus(response.statusCode)
            }
            return (response.statusCode, data)
        } catch let error as HostAgentP2PSignalingClientError {
            throw error
        } catch {
            throw Self.clientError(for: error)
        }
    }

    private static func clientError(for error: Error) -> HostAgentP2PSignalingClientError {
        guard let error = error as? URLError else {
            return .transport(String(describing: error))
        }
        switch error.code {
        case .timedOut:
            return .requestTimedOut
        case .appTransportSecurityRequiresSecureConnection:
            return .appTransportSecurityBlocked
        default:
            return .transport(error.localizedDescription)
        }
    }
}

public enum HostAgentP2PSignalingClientError: Error, Equatable, Sendable {
    case httpStatus(Int)
    case requestTimedOut
    case appTransportSecurityBlocked
    case transport(String)
    case invalidResponse
    case invalidResponsePayload
}
