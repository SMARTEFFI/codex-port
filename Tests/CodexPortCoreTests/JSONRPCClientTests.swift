import Foundation
import Testing
@testable import CodexPortCore

@Test func jsonRPCClientMatchesResponsesAndDispatchesNotificationsAndServerRequests() async throws {
    let transport = InMemoryJSONRPCTransport()
    let client = JSONRPCClient(transport: transport)

    async let response: JSONValue = client.request(method: "thread/list", params: .object(["limit": .number(50)]))

    let outbound = try await transport.nextOutbound()
    #expect(outbound.method == "thread/list")
    #expect(outbound.params == .object(["limit": .number(50)]))

    try await transport.deliver(.response(id: outbound.id, result: .object(["threads": .array([])])))
    #expect(try await response == .object(["threads": .array([])]))

    try await transport.deliver(.notification(method: "turn/started", params: .object(["turnId": .string("t1")])))
    #expect(await client.nextNotification()?.method == "turn/started")

    try await transport.deliver(.request(id: .string("approval-1"), method: "item/commandExecution/requestApproval", params: .object(["command": .array([.string("ls")])])))
    let serverRequest = await client.nextServerRequest()
    #expect(serverRequest?.method == "item/commandExecution/requestApproval")

    try await client.respond(to: .string("approval-1"), result: .object(["action": .string("accept")]))
    let approvalResponse = try await transport.nextOutboundResponse()
    #expect(approvalResponse.id == .string("approval-1"))
    #expect(approvalResponse.result == .object(["action": .string("accept")]))
}

@Test func jsonRPCClientSurfacesProtocolErrors() async throws {
    let transport = InMemoryJSONRPCTransport()
    let client = JSONRPCClient(transport: transport)

    let responseTask = Task {
        try await client.request(method: "turn/start", params: .object([:]))
    }
    let outbound = try await transport.nextOutbound()
    try await transport.deliver(.error(id: outbound.id, code: -32602, message: "Invalid params"))

    await #expect(throws: JSONRPCError.remote(code: -32602, message: "Invalid params")) {
        try await responseTask.value
    }
}

@Test func jsonRPCClientEventWaitersReturnNilWhenCancelled() async throws {
    let transport = InMemoryJSONRPCTransport()
    let client = JSONRPCClient(transport: transport)

    let notificationTask = Task {
        await client.nextNotification()
    }
    notificationTask.cancel()
    let notification = await notificationTask.value
    #expect(notification == nil)

    let serverRequestTask = Task {
        await client.nextServerRequest()
    }
    serverRequestTask.cancel()
    let serverRequest = await serverRequestTask.value
    #expect(serverRequest == nil)
}

@Test func jsonRPCClientEventWaitersStartPumpWithoutAnOutstandingRequest() async throws {
    let transport = InMemoryJSONRPCTransport()
    let client = JSONRPCClient(transport: transport)

    let notificationTask = Task {
        await client.nextNotification()
    }
    try await transport.deliver(.notification(
        method: "turn/started",
        params: .object(["turn": .object(["id": .string("turn-1")])])
    ))

    let notification = await value(of: notificationTask, timeoutMilliseconds: 100)
    #expect(notification?.method == "turn/started")
}

private func value<T: Sendable>(
    of task: Task<T?, Never>,
    timeoutMilliseconds: Int
) async -> T? {
    await withTaskGroup(of: T?.self) { group -> T? in
        group.addTask {
            await task.value
        }
        group.addTask {
            try? await Task.sleep(for: .milliseconds(timeoutMilliseconds))
            task.cancel()
            return nil
        }
        let result = await group.next()
        group.cancelAll()
        return result ?? nil
    }
}
