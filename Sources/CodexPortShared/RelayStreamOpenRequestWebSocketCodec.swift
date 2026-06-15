import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum RelayStreamOpenRequestWebSocketCodec {
    public enum Error: Swift.Error, Equatable, Sendable {
        case missingHeader(String)
        case invalidUUIDHeader(String)
        case invalidVersionHeader(String)
    }

    private static let hostHeader = "X-CodexPort-Host-Agent-ID"
    private static let deviceHeader = "X-CodexPort-Device-ID"
    private static let pairingHeader = "X-CodexPort-Pairing-Record-ID"
    private static let versionsHeader = "X-CodexPort-Relay-Versions"
    private static let purposeHeader = "X-CodexPort-Stream-Purpose"

    public static func encode(_ request: RelayStreamOpenRequest, into urlRequest: inout URLRequest) {
        urlRequest.setValue(request.hostID.uuidString, forHTTPHeaderField: hostHeader)
        urlRequest.setValue(request.deviceID.uuidString, forHTTPHeaderField: deviceHeader)
        urlRequest.setValue(request.pairingRecordID, forHTTPHeaderField: pairingHeader)
        urlRequest.setValue(request.supportedVersions.map(\.description).joined(separator: ","), forHTTPHeaderField: versionsHeader)
        if let purpose = request.tags["purpose"] {
            urlRequest.setValue(purpose, forHTTPHeaderField: purposeHeader)
        }
    }

    public static func decode(from urlRequest: URLRequest) throws -> RelayStreamOpenRequest {
        let hostID = try uuidHeader(hostHeader, in: urlRequest)
        let deviceID = try uuidHeader(deviceHeader, in: urlRequest)
        let pairingRecordID = try stringHeader(pairingHeader, in: urlRequest)
        let versions = try versionHeader(versionsHeader, in: urlRequest)
        var tags: [String: String] = [:]
        if let purpose = urlRequest.value(forHTTPHeaderField: purposeHeader), !purpose.isEmpty {
            tags["purpose"] = purpose
        }
        return RelayStreamOpenRequest(
            hostID: hostID,
            deviceID: deviceID,
            pairingRecordID: pairingRecordID,
            supportedVersions: versions,
            tags: tags
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
