import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import CodexPortShared

public protocol RelayP2PSignalingHTTPClient: Sendable {
    func getPresence(hostID: UUID, deviceID: UUID, at url: URL) async throws -> RelayP2PPresenceResponse
    func openSession(_ request: RelayP2POpenSessionRequest, at url: URL) async throws -> RelayP2POpenSessionResponse
    func getICEConfiguration(
        _ request: RelayP2PICEConfigurationRequest,
        at url: URL
    ) async throws -> RelayP2PICEConfigurationResponse
    func sendMessage(_ request: RelayP2PSendMessageRequest, at url: URL) async throws
    func drainMessages(at url: URL) async throws -> RelayP2PDrainMessagesResponse
}

public struct RelayP2PSignalingClient: Sendable {
    public var relayBaseURL: URL
    private let httpClient: RelayP2PSignalingHTTPClient

    public init(
        relayBaseURL: URL,
        httpClient: RelayP2PSignalingHTTPClient = URLSessionRelayP2PSignalingHTTPClient()
    ) {
        self.relayBaseURL = relayBaseURL
        self.httpClient = httpClient
    }

    public func presence(hostID: UUID, deviceID: UUID) async throws -> RelayP2PPresenceResponse {
        try await httpClient.getPresence(
            hostID: hostID,
            deviceID: deviceID,
            at: p2pURL(pathComponents: ["hosts", hostID.uuidString, "presence"], queryItems: [
                URLQueryItem(name: "deviceID", value: deviceID.uuidString),
            ])
        )
    }

    public func openSession(
        hostID: UUID,
        deviceID: UUID,
        pairingRecordID: String,
        supportedVersions: [RelayProtocolVersion] = [.v0_2_0]
    ) async throws -> RelayP2POpenSessionResponse {
        try await httpClient.openSession(
            RelayP2POpenSessionRequest(
                hostID: hostID,
                deviceID: deviceID,
                pairingRecordID: pairingRecordID,
                supportedVersions: supportedVersions
            ),
            at: p2pURL(pathComponents: ["sessions", "open"])
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

    public func drainMessages(
        sessionID: UUID,
        endpoint: RelayP2PSignalingEndpointRole
    ) async throws -> [RelayP2PSignalingMessageDTO] {
        try await httpClient.drainMessages(
            at: p2pURL(pathComponents: ["sessions", sessionID.uuidString, "messages"], queryItems: [
                URLQueryItem(name: "endpoint", value: endpoint.rawValue),
            ])
        ).messages
    }

    private func p2pURL(pathComponents: [String], queryItems: [URLQueryItem] = []) -> URL {
        var url = relayBaseURL.appending(path: "v0").appending(path: "p2p")
        for component in pathComponents {
            url.append(path: component)
        }
        guard !queryItems.isEmpty else {
            return url
        }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = queryItems
        return components.url!
    }
}

public struct URLSessionRelayP2PSignalingHTTPClient: RelayP2PSignalingHTTPClient {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func getPresence(hostID: UUID, deviceID: UUID, at url: URL) async throws -> RelayP2PPresenceResponse {
        try await get(url, decode: RelayP2PPresenceResponse.self)
    }

    public func openSession(
        _ request: RelayP2POpenSessionRequest,
        at url: URL
    ) async throws -> RelayP2POpenSessionResponse {
        try await post(request, to: url, decode: RelayP2POpenSessionResponse.self)
    }

    public func getICEConfiguration(
        _ request: RelayP2PICEConfigurationRequest,
        at url: URL
    ) async throws -> RelayP2PICEConfigurationResponse {
        try await post(request, to: url, decode: RelayP2PICEConfigurationResponse.self)
    }

    public func sendMessage(_ request: RelayP2PSendMessageRequest, at url: URL) async throws {
        _ = try await post(request, to: url)
    }

    public func drainMessages(at url: URL) async throws -> RelayP2PDrainMessagesResponse {
        try await get(url, decode: RelayP2PDrainMessagesResponse.self)
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

    private func post<T: Encodable, U: Decodable>(_ value: T, to url: URL, decode type: U.Type) async throws -> U {
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(value)
        return try await response(for: request, decode: type)
    }

    private func response<T: Decodable>(for request: URLRequest, decode type: T.Type) async throws -> T {
        let response = try await response(for: request)
        do {
            return try JSONDecoder().decode(T.self, from: response.data)
        } catch {
            throw RelayP2PSignalingClientError.invalidResponsePayload
        }
    }

    private func response(for request: URLRequest) async throws -> (status: Int, data: Data) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else {
                throw RelayP2PSignalingClientError.invalidResponse
            }
            guard (200..<300).contains(response.statusCode) else {
                throw RelayP2PSignalingClientError.httpStatus(response.statusCode)
            }
            return (response.statusCode, data)
        } catch let error as RelayP2PSignalingClientError {
            throw error
        } catch {
            throw Self.clientError(for: error)
        }
    }

    private static func clientError(for error: Error) -> RelayP2PSignalingClientError {
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

public enum RelayP2PSignalingClientError: Error, Equatable, Sendable {
    case httpStatus(Int)
    case requestTimedOut
    case appTransportSecurityBlocked
    case transport(String)
    case invalidResponse
    case invalidResponsePayload
}
