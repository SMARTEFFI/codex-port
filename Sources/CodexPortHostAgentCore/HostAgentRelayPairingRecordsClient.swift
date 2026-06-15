import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import CodexPortShared

public protocol HostAgentRelayPairingRecordsHTTPClient: Sendable {
    func fetchPairingRecords(at url: URL) async throws -> RelayHostPairingRecordsResponse
    func revokePairingRecord(at url: URL) async throws
}

public struct HostAgentRelayPairingRecordsClient: Sendable {
    public var configuration: HostAgentRelayConfiguration
    private let httpClient: HostAgentRelayPairingRecordsHTTPClient

    public init(
        configuration: HostAgentRelayConfiguration,
        httpClient: HostAgentRelayPairingRecordsHTTPClient = URLSessionHostAgentRelayPairingRecordsHTTPClient()
    ) {
        self.configuration = configuration
        self.httpClient = httpClient
    }

    public func pairedDevices() async throws -> [HostAgentMenuPairedDevice] {
        let response = try await httpClient.fetchPairingRecords(at: configuration.pairingRecordsURL)
        return response.devices.compactMap { summary in
            guard summary.revokedAtUnixTime == nil else { return nil }
            let status: HostAgentMenuPairedDeviceStatus
            if summary.activeConnectionCount > 0 {
                status = .connected(activeConnectionCount: summary.activeConnectionCount)
            } else {
                status = .paired
            }
            return HostAgentMenuPairedDevice(
                id: summary.pairingRecordID,
                displayName: summary.deviceDisplayName,
                status: status,
                pairedAt: Date(timeIntervalSince1970: summary.pairedAtUnixTime),
                lastActiveAt: nil,
                management: .revoke(pairingRecordID: summary.pairingRecordID)
            )
        }
    }

    public func revokePairing(recordID: String) async throws {
        try await httpClient.revokePairingRecord(at: configuration.pairingRecordRevokeURL(recordID: recordID))
    }
}

public enum HostAgentRelayPairingRecordsClientError: Error, Equatable, Sendable {
    case httpStatus(Int)
}

public struct URLSessionHostAgentRelayPairingRecordsHTTPClient: HostAgentRelayPairingRecordsHTTPClient {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func fetchPairingRecords(at url: URL) async throws -> RelayHostPairingRecordsResponse {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let (data, response) = try await session.data(for: request)
        if let response = response as? HTTPURLResponse,
           !(200..<300).contains(response.statusCode) {
            throw HostAgentRelayPairingRecordsClientError.httpStatus(response.statusCode)
        }
        return try JSONDecoder().decode(RelayHostPairingRecordsResponse.self, from: data)
    }

    public func revokePairingRecord(at url: URL) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        let (_, response) = try await session.data(for: request)
        if let response = response as? HTTPURLResponse,
           !(200..<300).contains(response.statusCode) {
            throw HostAgentRelayPairingRecordsClientError.httpStatus(response.statusCode)
        }
    }
}
