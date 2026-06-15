import Foundation
import CodexPortShared

public enum P2PICEPlan: Equatable, Sendable {
    case directSucceeds
    case directFailsThenTurnSucceeds(reason: String)
    case directFailsThenTurnFails(directReason: String, turnReason: String)
}

public final class P2PWebRTCDataChannelTransportPair: @unchecked Sendable {
    public let client: P2PWebRTCDataChannelTransportEndpoint
    public let host: P2PWebRTCDataChannelTransportEndpoint

    private let signalingService: P2PSignalingService
    private let session: P2PSignalingSession
    private let icePlan: P2PICEPlan

    public init(
        signalingService: P2PSignalingService,
        session: P2PSignalingSession,
        icePlan: P2PICEPlan = .directSucceeds
    ) {
        self.signalingService = signalingService
        self.session = session
        self.icePlan = icePlan
        self.client = P2PWebRTCDataChannelTransportEndpoint(role: .client)
        self.host = P2PWebRTCDataChannelTransportEndpoint(role: .host)
        client.connect(to: host)
        host.connect(to: client)
    }

    public func open() async throws {
        client.emit(.iceGathering)
        host.emit(.iceGathering)

        do {
            try await signalingService.send(P2PSignalingMessage(
                sessionID: session.id,
                from: .device(session.deviceID),
                to: .host(session.hostID),
                kind: .offer,
                payload: "webrtc-offer"
            ))
        } catch P2PSignalingError.deviceNotAuthorized {
            throw WebRTCDataChannelTransportError.signalingFailed("device not authorized")
        }
        let offers = await signalingService.drainMessages(for: .host(session.hostID), sessionID: session.id)
        guard offers.map(\.kind).contains(.offer) else {
            throw WebRTCDataChannelTransportError.signalingFailed("missing offer")
        }

        try await signalingService.send(P2PSignalingMessage(
            sessionID: session.id,
            from: .host(session.hostID),
            to: .device(session.deviceID),
            kind: .answer,
            payload: "webrtc-answer"
        ))
        try await signalingService.send(P2PSignalingMessage(
            sessionID: session.id,
            from: .host(session.hostID),
            to: .device(session.deviceID),
            kind: .iceCandidate,
            payload: "candidate:1 udp direct"
        ))
        let answers = await signalingService.drainMessages(for: .device(session.deviceID), sessionID: session.id)
        guard answers.map(\.kind).contains(.answer),
              answers.map(\.kind).contains(.iceCandidate)
        else {
            throw WebRTCDataChannelTransportError.signalingFailed("missing answer or ICE candidate")
        }

        try applyICEPlan()
        client.open()
        host.open()
    }

    private func applyICEPlan() throws {
        switch icePlan {
        case .directSucceeds:
            client.emit(.directConnected)
            host.emit(.directConnected)
        case let .directFailsThenTurnSucceeds(reason):
            client.emit(.directFailed(reason: reason))
            host.emit(.directFailed(reason: reason))
            client.emit(.turnRelayedConnected)
            host.emit(.turnRelayedConnected)
        case let .directFailsThenTurnFails(directReason, turnReason):
            client.emit(.directFailed(reason: directReason))
            host.emit(.directFailed(reason: directReason))
            client.emit(.turnFailed(reason: turnReason))
            host.emit(.turnFailed(reason: turnReason))
            throw WebRTCDataChannelTransportError.iceFailed(reason: turnReason)
        }
    }
}

public final class P2PWebRTCDataChannelTransportEndpoint: WebRTCDataChannelTransport, @unchecked Sendable {
    fileprivate enum Role: Sendable {
        case client
        case host
    }

    public let configuration: WebRTCDataChannelConfiguration = .reliableOrdered
    public let incomingMessages: AsyncStream<Data>
    public let stateUpdates: AsyncStream<WebRTCDataChannelConnectionState>

    private let role: Role
    private let lock = NSLock()
    private let incomingContinuation: AsyncStream<Data>.Continuation
    private let stateContinuation: AsyncStream<WebRTCDataChannelConnectionState>.Continuation
    private var peer: P2PWebRTCDataChannelTransportEndpoint?
    private var isOpen = false
    private var isClosed = false

    fileprivate init(role: Role) {
        self.role = role
        var incomingContinuation: AsyncStream<Data>.Continuation?
        self.incomingMessages = AsyncStream<Data> { continuation in
            incomingContinuation = continuation
        }
        var stateContinuation: AsyncStream<WebRTCDataChannelConnectionState>.Continuation?
        self.stateUpdates = AsyncStream<WebRTCDataChannelConnectionState> { continuation in
            stateContinuation = continuation
        }
        self.incomingContinuation = incomingContinuation!
        self.stateContinuation = stateContinuation!
    }

    public func send(_ message: Data) async throws {
        let state = lock.withLock { (isOpen, isClosed) }
        guard !state.1 else {
            throw WebRTCDataChannelTransportError.dataChannelClosed
        }
        guard state.0 else {
            throw WebRTCDataChannelTransportError.dataChannelNotOpen
        }
        try peer?.receive(message)
    }

    public func close() {
        close(propagateToPeer: true)
    }

    fileprivate func connect(to peer: P2PWebRTCDataChannelTransportEndpoint) {
        lock.withLock {
            self.peer = peer
        }
    }

    fileprivate func open() {
        lock.withLock {
            isOpen = true
            isClosed = false
        }
        emit(.dataChannelOpen)
    }

    private func close(propagateToPeer: Bool) {
        let connectedPeer = lock.withLock { () -> P2PWebRTCDataChannelTransportEndpoint? in
            guard isOpen || !isClosed else {
                return nil
            }
            isOpen = false
            isClosed = true
            return peer
        }
        emit(.dataChannelClosed)
        if propagateToPeer {
            connectedPeer?.close(propagateToPeer: false)
        }
    }

    fileprivate func emit(_ state: WebRTCDataChannelConnectionState) {
        stateContinuation.yield(state)
    }

    private func receive(_ message: Data) throws {
        let state = lock.withLock { (isOpen, isClosed) }
        guard !state.1 else {
            throw WebRTCDataChannelTransportError.dataChannelClosed
        }
        guard state.0 else {
            throw WebRTCDataChannelTransportError.dataChannelNotOpen
        }
        incomingContinuation.yield(message)
    }
}
