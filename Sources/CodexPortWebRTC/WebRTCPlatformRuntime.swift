import Foundation
import CodexPortShared

public struct WebRTCPlatformDataChannelOpenResult: Sendable {
    public var offer: WebRTCSessionDescriptionPayload
    public var localICECandidates: [WebRTCICECandidatePayload]
    public var localICECandidateUpdates: AsyncStream<WebRTCICECandidatePayload>
    public var dataChannel: WebRTCDataChannelTransport

    public init(
        offer: WebRTCSessionDescriptionPayload,
        localICECandidates: [WebRTCICECandidatePayload],
        localICECandidateUpdates: AsyncStream<WebRTCICECandidatePayload> = AsyncStream { $0.finish() },
        dataChannel: WebRTCDataChannelTransport
    ) {
        self.offer = offer
        self.localICECandidates = localICECandidates
        self.localICECandidateUpdates = localICECandidateUpdates
        self.dataChannel = dataChannel
    }
}

public struct WebRTCPlatformDataChannelAcceptResult: Sendable {
    public var answer: WebRTCSessionDescriptionPayload
    public var localICECandidates: [WebRTCICECandidatePayload]
    public var localICECandidateUpdates: AsyncStream<WebRTCICECandidatePayload>
    public var dataChannel: WebRTCDataChannelTransport

    public init(
        answer: WebRTCSessionDescriptionPayload,
        localICECandidates: [WebRTCICECandidatePayload],
        localICECandidateUpdates: AsyncStream<WebRTCICECandidatePayload> = AsyncStream { $0.finish() },
        dataChannel: WebRTCDataChannelTransport
    ) {
        self.answer = answer
        self.localICECandidates = localICECandidates
        self.localICECandidateUpdates = localICECandidateUpdates
        self.dataChannel = dataChannel
    }
}

public enum WebRTCCandidatePairPath: Equatable, Sendable {
    case direct
    case relay
    case unknown
}

public struct WebRTCDataChannelHealthCheckResult: Equatable, Sendable {
    public var selectedCandidatePairPath: WebRTCCandidatePairPath
    public var pingPongSucceeded: Bool

    public init(
        selectedCandidatePairPath: WebRTCCandidatePairPath,
        pingPongSucceeded: Bool
    ) {
        self.selectedCandidatePairPath = selectedCandidatePairPath
        self.pingPongSucceeded = pingPongSucceeded
    }
}

public protocol WebRTCPlatformDataChannelOpening: Sendable {
    func openDataChannel(
        session: RelayP2POpenSessionResponse,
        configuration: WebRTCRuntimeConfiguration
    ) async throws -> WebRTCPlatformDataChannelOpenResult

    func applyRemoteAnswer(
        _ answer: WebRTCSessionDescriptionPayload,
        to dataChannel: WebRTCDataChannelTransport
    ) async throws

    func addRemoteICECandidate(
        _ candidate: WebRTCICECandidatePayload,
        to dataChannel: WebRTCDataChannelTransport
    ) async throws

    func restartICE(
        on dataChannel: WebRTCDataChannelTransport,
        configuration: WebRTCRuntimeConfiguration
    ) async throws -> WebRTCPlatformDataChannelOpenResult

    func checkDirectPath(
        on dataChannel: WebRTCDataChannelTransport,
        requiredPingPongCount: Int
    ) async throws -> WebRTCDataChannelHealthCheckResult
}

public extension WebRTCPlatformDataChannelOpening {
    func restartICE(
        on dataChannel: WebRTCDataChannelTransport,
        configuration: WebRTCRuntimeConfiguration
    ) async throws -> WebRTCPlatformDataChannelOpenResult {
        throw WebRTCPlatformRuntimeError.runtimeUnavailable("WebRTC runtime does not support ICE restart.")
    }

    func checkDirectPath(
        on dataChannel: WebRTCDataChannelTransport,
        requiredPingPongCount: Int
    ) async throws -> WebRTCDataChannelHealthCheckResult {
        WebRTCDataChannelHealthCheckResult(
            selectedCandidatePairPath: .unknown,
            pingPongSucceeded: false
        )
    }
}

public protocol WebRTCPlatformDataChannelAccepting: Sendable {
    func acceptDataChannel(
        offer: WebRTCSessionDescriptionPayload,
        session: RelayP2POpenSessionResponse,
        configuration: WebRTCRuntimeConfiguration
    ) async throws -> WebRTCPlatformDataChannelAcceptResult

    func addRemoteICECandidate(
        _ candidate: WebRTCICECandidatePayload,
        to dataChannel: WebRTCDataChannelTransport
    ) async throws

    func restartICE(
        offer: WebRTCSessionDescriptionPayload,
        session: RelayP2POpenSessionResponse,
        configuration: WebRTCRuntimeConfiguration,
        dataChannel: WebRTCDataChannelTransport
    ) async throws -> WebRTCPlatformDataChannelAcceptResult
}

public extension WebRTCPlatformDataChannelAccepting {
    func restartICE(
        offer: WebRTCSessionDescriptionPayload,
        session: RelayP2POpenSessionResponse,
        configuration: WebRTCRuntimeConfiguration,
        dataChannel: WebRTCDataChannelTransport
    ) async throws -> WebRTCPlatformDataChannelAcceptResult {
        throw WebRTCPlatformRuntimeError.runtimeUnavailable("WebRTC runtime does not support ICE restart.")
    }
}

public struct UnavailableWebRTCPlatformDataChannelRuntime:
    WebRTCPlatformDataChannelOpening,
    WebRTCPlatformDataChannelAccepting
{
    public init() {}

    public func openDataChannel(
        session: RelayP2POpenSessionResponse,
        configuration: WebRTCRuntimeConfiguration
    ) async throws -> WebRTCPlatformDataChannelOpenResult {
        throw WebRTCPlatformRuntimeError.runtimeUnavailable(Self.unavailableMessage)
    }

    public func applyRemoteAnswer(
        _ answer: WebRTCSessionDescriptionPayload,
        to dataChannel: WebRTCDataChannelTransport
    ) async throws {
        throw WebRTCPlatformRuntimeError.runtimeUnavailable(Self.unavailableMessage)
    }

    public func addRemoteICECandidate(
        _ candidate: WebRTCICECandidatePayload,
        to dataChannel: WebRTCDataChannelTransport
    ) async throws {
        throw WebRTCPlatformRuntimeError.runtimeUnavailable(Self.unavailableMessage)
    }

    public func restartICE(
        on dataChannel: WebRTCDataChannelTransport,
        configuration: WebRTCRuntimeConfiguration
    ) async throws -> WebRTCPlatformDataChannelOpenResult {
        throw WebRTCPlatformRuntimeError.runtimeUnavailable(Self.unavailableMessage)
    }

    public func checkDirectPath(
        on dataChannel: WebRTCDataChannelTransport,
        requiredPingPongCount: Int
    ) async throws -> WebRTCDataChannelHealthCheckResult {
        throw WebRTCPlatformRuntimeError.runtimeUnavailable(Self.unavailableMessage)
    }

    public func acceptDataChannel(
        offer: WebRTCSessionDescriptionPayload,
        session: RelayP2POpenSessionResponse,
        configuration: WebRTCRuntimeConfiguration
    ) async throws -> WebRTCPlatformDataChannelAcceptResult {
        throw WebRTCPlatformRuntimeError.runtimeUnavailable(Self.unavailableMessage)
    }

    public func restartICE(
        offer: WebRTCSessionDescriptionPayload,
        session: RelayP2POpenSessionResponse,
        configuration: WebRTCRuntimeConfiguration,
        dataChannel: WebRTCDataChannelTransport
    ) async throws -> WebRTCPlatformDataChannelAcceptResult {
        throw WebRTCPlatformRuntimeError.runtimeUnavailable(Self.unavailableMessage)
    }

    private static let unavailableMessage =
        "Real WebRTC SDK runtime is not linked. Link a platform WebRTC implementation before enabling P2P route selection."
}

public enum WebRTCPlatformRuntimeError: Error, Equatable, Sendable {
    case runtimeUnavailable(String)
    case invalidOfferPayload
    case invalidAnswerPayload
    case invalidICECandidatePayload
    case answerTimedOut
}

public enum DefaultWebRTCPlatformDataChannelRuntime {
    public static func makeOpeningRuntime() -> any WebRTCPlatformDataChannelOpening {
        #if (os(iOS) || targetEnvironment(macCatalyst)) && canImport(WebRTC)
        return WebRTCSDKRuntime()
        #else
        return UnavailableWebRTCPlatformDataChannelRuntime()
        #endif
    }

    public static func makeAcceptingRuntime() -> any WebRTCPlatformDataChannelAccepting {
        #if (os(iOS) || targetEnvironment(macCatalyst)) && canImport(WebRTC)
        return WebRTCSDKRuntime()
        #else
        return UnavailableWebRTCPlatformDataChannelRuntime()
        #endif
    }
}
