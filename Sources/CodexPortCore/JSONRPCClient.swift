import Foundation

public enum JSONRPCError: Error, Equatable {
    case remote(code: Int, message: String)
    case connectionClosed
    case requestTimedOut(method: String, seconds: Double)
}

public struct JSONRPCOutboundRequest: Equatable, Sendable {
    public var id: JSONRPCID
    public var method: String
    public var params: JSONValue

    public init(id: JSONRPCID, method: String, params: JSONValue) {
        self.id = id
        self.method = method
        self.params = params
    }
}

public struct JSONRPCOutboundResponse: Equatable, Sendable {
    public var id: JSONRPCID
    public var result: JSONValue

    public init(id: JSONRPCID, result: JSONValue) {
        self.id = id
        self.result = result
    }
}

public struct JSONRPCNotification: Equatable, Sendable {
    public var method: String
    public var params: JSONValue

    public init(method: String, params: JSONValue) {
        self.method = method
        self.params = params
    }
}

public struct JSONRPCServerRequest: Equatable, Sendable {
    public var id: JSONRPCID
    public var method: String
    public var params: JSONValue

    public init(id: JSONRPCID, method: String, params: JSONValue) {
        self.id = id
        self.method = method
        self.params = params
    }
}

public enum JSONRPCInboundMessage: Equatable, Sendable {
    case response(id: JSONRPCID, result: JSONValue)
    case error(id: JSONRPCID, code: Int, message: String)
    case notification(method: String, params: JSONValue)
    case request(id: JSONRPCID, method: String, params: JSONValue)
}

public protocol JSONRPCTransport: AnyObject, Sendable {
    func sendRequest(_ request: JSONRPCOutboundRequest) async throws
    func sendNotification(_ notification: JSONRPCNotification) async throws
    func sendResponse(_ response: JSONRPCOutboundResponse) async throws
    func receive() async throws -> JSONRPCInboundMessage
}

public actor JSONRPCClient {
    private let transport: JSONRPCTransport
    private var nextID = 1
    private var pending: Set<JSONRPCID> = []
    private var completed: [JSONRPCID: Result<JSONValue, Error>] = [:]
    private var notifications: [JSONRPCNotification] = []
    private var serverRequests: [JSONRPCServerRequest] = []
    private var pumpStarted = false

    public init(transport: JSONRPCTransport) {
        self.transport = transport
    }

    public func request(method: String, params: JSONValue, timeoutSeconds: Double? = nil) async throws -> JSONValue {
        let id = JSONRPCID.number(nextID)
        nextID += 1
        pending.insert(id)

        do {
            try await transport.sendRequest(JSONRPCOutboundRequest(id: id, method: method, params: params))
        } catch {
            pending.remove(id)
            throw error
        }

        startPumpIfNeeded()
        let didComplete = await waitUntil(timeoutSeconds: timeoutSeconds) {
            self.completed[id] != nil
        }
        pending.remove(id)
        if !didComplete, let timeoutSeconds {
            completed.removeValue(forKey: id)
            throw JSONRPCError.requestTimedOut(method: method, seconds: timeoutSeconds)
        }
        guard let result = completed.removeValue(forKey: id) else {
            throw JSONRPCError.connectionClosed
        }
        switch result {
        case let .success(value):
            return value
        case let .failure(error):
            throw error
        }
    }

    public func respond(to id: JSONRPCID, result: JSONValue) async throws {
        try await transport.sendResponse(JSONRPCOutboundResponse(id: id, result: result))
    }

    public func sendNotification(method: String, params: JSONValue = .object([:])) async throws {
        try await transport.sendNotification(JSONRPCNotification(method: method, params: params))
    }

    public func nextNotification() async -> JSONRPCNotification? {
        startPumpIfNeeded()
        _ = await waitUntil { !self.notifications.isEmpty }
        guard !Task.isCancelled else { return nil }
        return notifications.isEmpty ? nil : notifications.removeFirst()
    }

    public func nextServerRequest() async -> JSONRPCServerRequest? {
        startPumpIfNeeded()
        _ = await waitUntil { !self.serverRequests.isEmpty }
        guard !Task.isCancelled else { return nil }
        return serverRequests.isEmpty ? nil : serverRequests.removeFirst()
    }

    private func startPumpIfNeeded() {
        guard !pumpStarted else { return }
        pumpStarted = true
        Task {
            while true {
                do {
                    let message = try await self.transport.receive()
                    self.handle(message)
                } catch {
                    self.failAll(error)
                    break
                }
            }
        }
    }

    private func handle(_ message: JSONRPCInboundMessage) {
        switch message {
        case let .response(id, result):
            guard pending.contains(id) else { return }
            completed[id] = .success(result)
        case let .error(id, code, message):
            guard pending.contains(id) else { return }
            completed[id] = .failure(JSONRPCError.remote(code: code, message: message))
        case let .notification(method, params):
            notifications.append(JSONRPCNotification(method: method, params: params))
        case let .request(id, method, params):
            serverRequests.append(JSONRPCServerRequest(id: id, method: method, params: params))
        }
    }

    private func failPending(id: JSONRPCID, error: Error) {
        guard pending.contains(id) else { return }
        guard completed[id] == nil else { return }
        completed[id] = .failure(error)
    }

    private func failAll(_ error: Error) {
        for id in pending {
            guard completed[id] == nil else { continue }
            completed[id] = .failure(error)
        }
    }

    private func waitUntil(
        timeoutSeconds: Double? = nil,
        _ predicate: @escaping () -> Bool
    ) async -> Bool {
        let deadline = timeoutSeconds.map { Date().addingTimeInterval($0) }
        while !predicate(), !Task.isCancelled {
            if let deadline, Date() >= deadline {
                return false
            }
            do {
                try await Task.sleep(for: .milliseconds(5))
            } catch {
                return false
            }
        }
        return predicate()
    }
}

extension JSONRPCClient: AppServerEventSource {}
