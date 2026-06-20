import Foundation
import CodexPortShared
import Crypto

public struct RelayP2PICEConfigurationContext: Equatable, Sendable {
    public var hostID: UUID
    public var deviceID: UUID
    public var pairingRecordID: String
    public var issuedAt: Date

    public init(hostID: UUID, deviceID: UUID, pairingRecordID: String, issuedAt: Date) {
        self.hostID = hostID
        self.deviceID = deviceID
        self.pairingRecordID = pairingRecordID
        self.issuedAt = issuedAt
    }
}

public protocol RelayP2PICEConfigurationProviding: Sendable {
    func issueICEConfiguration(
        for context: RelayP2PICEConfigurationContext
    ) throws -> RelayP2PICEConfigurationResponse
}

public struct StaticRelayP2PICEConfigurationProvider: RelayP2PICEConfigurationProviding {
    public var configuration: WebRTCRuntimeConfiguration
    public var ttl: Duration

    public init(configuration: WebRTCRuntimeConfiguration, ttl: Duration) {
        self.configuration = configuration
        self.ttl = ttl
    }

    public func issueICEConfiguration(
        for context: RelayP2PICEConfigurationContext
    ) throws -> RelayP2PICEConfigurationResponse {
        RelayP2PICEConfigurationResponse(
            configuration: configuration,
            expiresAtUnixTime: context.issuedAt.addingTimeInterval(ttl.timeInterval).timeIntervalSince1970
        )
    }
}

public struct CoturnRESTICEConfigurationProvider: CustomStringConvertible, RelayP2PICEConfigurationProviding {
    public var stunURLs: [String]
    public var turnURLs: [String]
    public var sharedSecret: String
    public var ttl: Duration
    public var dataChannelLabel: String

    public init(
        stunURLs: [String],
        turnURLs: [String],
        sharedSecret: String,
        ttl: Duration,
        dataChannelLabel: String = "codexport-client-host"
    ) {
        self.stunURLs = stunURLs
        self.turnURLs = turnURLs
        self.sharedSecret = sharedSecret
        self.ttl = ttl
        self.dataChannelLabel = dataChannelLabel
    }

    public func issueICEConfiguration(
        for context: RelayP2PICEConfigurationContext
    ) throws -> RelayP2PICEConfigurationResponse {
        let expiresAt = context.issuedAt.addingTimeInterval(ttl.timeInterval)
        let expiresAtUnixTime = floor(expiresAt.timeIntervalSince1970)
        let username = "\(Int(expiresAtUnixTime)):\(context.pairingRecordID)"
        let credential = Self.credential(username: username, sharedSecret: sharedSecret)
        var iceServers = stunURLs.isEmpty ? [] : [
            WebRTCICEServerConfiguration(urls: stunURLs),
        ]
        iceServers.append(WebRTCICEServerConfiguration(
            urls: turnURLs,
            username: username,
            credential: credential
        ))
        return RelayP2PICEConfigurationResponse(
            configuration: WebRTCRuntimeConfiguration(
                iceServers: iceServers,
                dataChannelLabel: dataChannelLabel
            ),
            expiresAtUnixTime: expiresAtUnixTime
        )
    }

    public var description: String {
        "CoturnRESTICEConfigurationProvider(stunURLs: \(stunURLs), turnURLs: \(turnURLs), sharedSecret: <redacted>, ttl: \(ttl), dataChannelLabel: \(dataChannelLabel))"
    }

    private static func credential(username: String, sharedSecret: String) -> String {
        let key = SymmetricKey(data: Data(sharedSecret.utf8))
        let authenticationCode = HMAC<Insecure.SHA1>.authenticationCode(
            for: Data(username.utf8),
            using: key
        )
        return Data(authenticationCode).base64EncodedString()
    }
}

public enum RelayP2PICEConfigurationProvider {
    public static let empty = StaticRelayP2PICEConfigurationProvider(
        configuration: WebRTCRuntimeConfiguration(iceServers: []),
        ttl: .seconds(600)
    )
}

private extension Duration {
    var timeInterval: TimeInterval {
        let components = self.components
        return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
    }
}
