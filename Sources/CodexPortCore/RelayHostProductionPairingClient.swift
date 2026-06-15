import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import CodexPortShared

public protocol RelayHostProductionPairingHTTPClient: Sendable {
    func consume(_ request: RelayPairingConsumeRequest, at url: URL) async throws -> RelayPairingConsumeResponse
}

public struct RelayHostProductionPairingClient: Sendable {
    public var deviceID: UUID
    public var devicePublicKey: EndpointPublicKey
    private let httpClient: RelayHostProductionPairingHTTPClient

    public init(
        deviceID: UUID = UUID(),
        devicePublicKey: EndpointPublicKey,
        httpClient: RelayHostProductionPairingHTTPClient = URLSessionRelayHostProductionPairingHTTPClient()
    ) {
        self.deviceID = deviceID
        self.devicePublicKey = devicePublicKey
        self.httpClient = httpClient
    }

    public func pair(
        _ input: RelayHostProductionPairingInput,
        codexPath: String,
        defaultDirectory: String,
        profileName: String? = nil
    ) async throws -> HostProfileDraft {
        let response = try await httpClient.consume(
            RelayPairingConsumeRequest(
                tokenID: input.pairingTokenID,
                deviceID: deviceID,
                deviceDisplayName: input.deviceDisplayName,
                devicePublicKeyBase64: devicePublicKey.rawValue.base64EncodedString(),
                supportedVersions: [.v0_2_0]
            ),
            at: input.pairingConsumeURL
        )
        let result = RelayPairingResult(
            tokenID: response.tokenID,
            host: RelayHostIdentity(
                id: response.hostID,
                displayName: response.hostDisplayName,
                userName: response.hostUserName,
                publicKey: EndpointPublicKey(rawValue: Data(base64Encoded: response.hostPublicKeyBase64) ?? Data())
            ),
            device: DeviceIdentity(
                id: response.deviceID,
                displayName: input.deviceDisplayName,
                kind: .iOSClient,
                publicKey: devicePublicKey
            ),
            record: PairingRecord(
                id: response.pairingRecordID,
                hostID: response.hostID,
                deviceID: response.deviceID,
                deviceDisplayName: input.deviceDisplayName,
                pairedAt: Date(),
                revokedAt: nil
            ),
            negotiatedVersion: response.selectedVersion,
            presence: .online(activeConnectionCount: response.activeConnectionCount)
        )
        return input.makeHostProfileDraft(
            from: result,
            codexPath: codexPath,
            defaultDirectory: defaultDirectory,
            profileName: profileName
        )
    }
}

public struct URLSessionRelayHostProductionPairingHTTPClient: RelayHostProductionPairingHTTPClient {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func consume(_ request: RelayPairingConsumeRequest, at url: URL) async throws -> RelayPairingConsumeResponse {
        var urlRequest = URLRequest(url: url, timeoutInterval: 8)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONEncoder().encode(request)
        do {
            let (data, response) = try await session.data(for: urlRequest)
            guard let response = response as? HTTPURLResponse else {
                throw RelayHostProductionPairingClientError.invalidResponse
            }
            guard (200..<300).contains(response.statusCode) else {
                throw RelayHostProductionPairingClientError.httpStatus(response.statusCode)
            }
            do {
                return try JSONDecoder().decode(RelayPairingConsumeResponse.self, from: data)
            } catch {
                throw RelayHostProductionPairingClientError.invalidResponsePayload
            }
        } catch let error as RelayHostProductionPairingClientError {
            throw error
        } catch {
            throw Self.clientError(for: error)
        }
    }

    private static func clientError(for error: Error) -> RelayHostProductionPairingClientError {
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

public enum RelayHostProductionPairingClientError: Error, Equatable, Sendable {
    case httpStatus(Int)
    case requestTimedOut
    case appTransportSecurityBlocked
    case transport(String)
    case invalidResponse
    case invalidResponsePayload
}
