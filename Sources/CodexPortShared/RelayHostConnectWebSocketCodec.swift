import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum RelayHostConnectWebSocketCodec {
    public enum Error: Swift.Error, Equatable, Sendable {
        case missingHeader(String)
        case invalidUUIDHeader(String)
        case invalidPublicKey(String)
        case invalidVersionHeader(String)
    }

    private static let hostHeader = "X-CodexPort-Host-Agent-ID"
    private static let displayNameHeader = "X-CodexPort-Host-Display-Name"
    private static let userNameHeader = "X-CodexPort-Host-User"
    private static let publicKeyHeader = "X-CodexPort-Host-Public-Key"
    private static let versionsHeader = "X-CodexPort-Relay-Versions"

    public static func encode(
        host: RelayHostIdentity,
        supportedVersions: [RelayProtocolVersion],
        into urlRequest: inout URLRequest
    ) {
        urlRequest.setValue(host.id.uuidString, forHTTPHeaderField: hostHeader)
        urlRequest.setValue(host.displayName, forHTTPHeaderField: displayNameHeader)
        urlRequest.setValue(host.userName, forHTTPHeaderField: userNameHeader)
        urlRequest.setValue(host.publicKey.rawValue.base64EncodedString(), forHTTPHeaderField: publicKeyHeader)
        urlRequest.setValue(supportedVersions.map(\.description).joined(separator: ","), forHTTPHeaderField: versionsHeader)
    }

    public static func decode(from urlRequest: URLRequest) throws -> (host: RelayHostIdentity, supportedVersions: [RelayProtocolVersion]) {
        let publicKeyBase64 = try stringHeader(publicKeyHeader, in: urlRequest)
        guard let publicKeyData = Data(base64Encoded: publicKeyBase64) else {
            throw Error.invalidPublicKey(publicKeyHeader)
        }
        return (
            RelayHostIdentity(
                id: try uuidHeader(hostHeader, in: urlRequest),
                displayName: try stringHeader(displayNameHeader, in: urlRequest),
                userName: try stringHeader(userNameHeader, in: urlRequest),
                publicKey: EndpointPublicKey(rawValue: publicKeyData)
            ),
            try versionHeader(versionsHeader, in: urlRequest)
        )
    }

    private static func stringHeader(_ name: String, in request: URLRequest) throws -> String {
        guard let value = request.value(forHTTPHeaderField: name), !value.isEmpty else {
            throw Error.missingHeader(name)
        }
        return value
    }

    private static func uuidHeader(_ name: String, in request: URLRequest) throws -> UUID {
        let value = try stringHeader(name, in: request)
        guard let uuid = UUID(uuidString: value) else {
            throw Error.invalidUUIDHeader(name)
        }
        return uuid
    }

    private static func versionHeader(_ name: String, in request: URLRequest) throws -> [RelayProtocolVersion] {
        let value = try stringHeader(name, in: request)
        let versions = value.split(separator: ",").map(String.init).compactMap(Self.parseVersion)
        guard !versions.isEmpty else {
            throw Error.invalidVersionHeader(name)
        }
        return versions
    }

    private static func parseVersion(_ value: String) -> RelayProtocolVersion? {
        let parts = value.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return RelayProtocolVersion(major: parts[0], minor: parts[1], patch: parts[2])
    }
}

public struct RelayHostBridgeEnvelope: Codable, Equatable, Sendable {
    public var streamID: UUID
    public var clientID: String
    public var line: String

    public init(streamID: UUID, clientID: String, line: String) {
        self.streamID = streamID
        self.clientID = clientID
        self.line = line
    }

    public static func encode(_ envelope: RelayHostBridgeEnvelope) throws -> String {
        let data = try JSONEncoder().encode(envelope)
        return String(decoding: data, as: UTF8.self)
    }

    public static func decode(_ line: String) throws -> RelayHostBridgeEnvelope {
        try JSONDecoder().decode(RelayHostBridgeEnvelope.self, from: Data(line.utf8))
    }
}
