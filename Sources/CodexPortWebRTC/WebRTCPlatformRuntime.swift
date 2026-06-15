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

    public func acceptDataChannel(
        offer: WebRTCSessionDescriptionPayload,
        session: RelayP2POpenSessionResponse,
        configuration: WebRTCRuntimeConfiguration
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
