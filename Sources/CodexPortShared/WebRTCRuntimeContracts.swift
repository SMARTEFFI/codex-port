import Foundation

public enum WebRTCICECredentialType: String, Codable, Equatable, Sendable {
    case password
}

public struct WebRTCICEServerConfiguration: Codable, Equatable, Sendable, CustomStringConvertible {
    public var urls: [String]
    public var username: String?
    public var credential: String?
    public var credentialType: WebRTCICECredentialType

    public init(
        urls: [String],
        username: String? = nil,
        credential: String? = nil,
        credentialType: WebRTCICECredentialType = .password
    ) {
        self.urls = urls
        self.username = username
        self.credential = credential
        self.credentialType = credentialType
    }

    private enum CodingKeys: String, CodingKey {
        case urls
        case username
        case credential
        case credentialType
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        urls = try container.decode([String].self, forKey: .urls)
        username = try container.decodeIfPresent(String.self, forKey: .username)
        credential = try container.decodeIfPresent(String.self, forKey: .credential)
        credentialType = try container.decodeIfPresent(WebRTCICECredentialType.self, forKey: .credentialType) ?? .password
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(urls, forKey: .urls)
        try container.encodeIfPresent(username, forKey: .username)
        try container.encodeIfPresent(credential, forKey: .credential)
        try container.encode(credentialType, forKey: .credentialType)
    }

    public var description: String {
        let usernameDescription = username == nil ? "nil" : "<set>"
        let credentialDescription = credential == nil ? "nil" : "<redacted>"
        return "WebRTCICEServerConfiguration(urls: \(urls), username: \(usernameDescription), credential: \(credentialDescription), credentialType: \(credentialType.rawValue))"
    }
}

public struct WebRTCRuntimeConfiguration: Codable, Equatable, Sendable, CustomStringConvertible {
    public var iceServers: [WebRTCICEServerConfiguration]
    public var dataChannelLabel: String

    public init(
        iceServers: [WebRTCICEServerConfiguration],
        dataChannelLabel: String = "codexport-client-host"
    ) {
        self.iceServers = iceServers
        self.dataChannelLabel = dataChannelLabel
    }

    public var description: String {
        "WebRTCRuntimeConfiguration(iceServers: \(iceServers), dataChannelLabel: \(dataChannelLabel))"
    }
}

public enum WebRTCSDPType: String, Codable, Equatable, Sendable {
    case offer
    case answer
}

public struct WebRTCSessionDescriptionPayload: Codable, Equatable, Sendable {
    public var type: WebRTCSDPType
    public var sdp: String

    public init(type: WebRTCSDPType, sdp: String) {
        self.type = type
        self.sdp = sdp
    }
}

public struct WebRTCICECandidatePayload: Codable, Equatable, Sendable {
    public var sdp: String
    public var sdpMid: String?
    public var sdpMLineIndex: Int32

    public init(sdp: String, sdpMid: String?, sdpMLineIndex: Int32) {
        self.sdp = sdp
        self.sdpMid = sdpMid
        self.sdpMLineIndex = sdpMLineIndex
    }
}

public enum RelayP2PWebRTCSignalingPayloadCodec {
    public static func encode(_ payload: WebRTCSessionDescriptionPayload) throws -> String {
        String(data: try JSONEncoder().encode(payload), encoding: .utf8)!
    }

    public static func encode(_ payload: WebRTCICECandidatePayload) throws -> String {
        String(data: try JSONEncoder().encode(payload), encoding: .utf8)!
    }

    public static func decodeSessionDescription(_ payload: String) throws -> WebRTCSessionDescriptionPayload {
        guard let data = payload.data(using: .utf8) else {
            throw RelayP2PWebRTCSignalingPayloadCodecError.invalidUTF8Payload
        }
        return try JSONDecoder().decode(WebRTCSessionDescriptionPayload.self, from: data)
    }

    public static func decodeICECandidate(_ payload: String) throws -> WebRTCICECandidatePayload {
        guard let data = payload.data(using: .utf8) else {
            throw RelayP2PWebRTCSignalingPayloadCodecError.invalidUTF8Payload
        }
        return try JSONDecoder().decode(WebRTCICECandidatePayload.self, from: data)
    }
}

public enum RelayP2PWebRTCSignalingPayloadCodecError: Error, Equatable, Sendable {
    case invalidUTF8Payload
}
