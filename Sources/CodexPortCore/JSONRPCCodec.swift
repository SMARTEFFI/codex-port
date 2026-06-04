import Foundation

public enum JSONRPCCodecError: Error, Equatable {
    case invalidMessage(String)
}

public struct JSONRPCCodec: Sendable {
    public init() {}

    public func encodeRequest(_ request: JSONRPCOutboundRequest) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "id": request.id.foundationValue,
            "method": request.method,
            "params": request.params.foundationValue
        ], options: [.withoutEscapingSlashes])
    }

    public func encodeNotification(_ notification: JSONRPCNotification) throws -> Data {
        var object: [String: Any] = [
            "method": notification.method
        ]
        if notification.params != .object([:]) {
            object["params"] = notification.params.foundationValue
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])
    }

    public func encodeResponse(_ response: JSONRPCOutboundResponse) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "id": response.id.foundationValue,
            "result": response.result.foundationValue
        ], options: [.withoutEscapingSlashes])
    }

    public func decode(_ data: Data) throws -> JSONRPCInboundMessage {
        let rawMessage = String(data: data, encoding: .utf8) ?? data.base64EncodedString()
        let jsonObject: Any
        do {
            jsonObject = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw JSONRPCCodecError.invalidMessage(rawMessage)
        }
        guard let object = jsonObject as? [String: Any] else {
            throw JSONRPCCodecError.invalidMessage(rawMessage)
        }

        if let method = object["method"] as? String {
            let params = JSONValue(any: object["params"] ?? NSNull())
            if let id = JSONRPCID(any: object["id"] ?? NSNull()) {
                return .request(id: id, method: method, params: params)
            }
            return .notification(method: method, params: params)
        }

        guard let id = JSONRPCID(any: object["id"] ?? NSNull()) else {
            throw JSONRPCCodecError.invalidMessage(rawMessage)
        }

        if let error = object["error"] as? [String: Any] {
            return .error(
                id: id,
                code: error["code"] as? Int ?? -32000,
                message: error["message"] as? String ?? "Unknown JSON-RPC error"
            )
        }

        return .response(id: id, result: JSONValue(any: object["result"] ?? NSNull()))
    }
}

public struct JSONRPCFramer: Sendable {
    private let codec: JSONRPCCodec
    private var buffer = Data()

    public init(codec: JSONRPCCodec = JSONRPCCodec()) {
        self.codec = codec
    }

    public mutating func receive(_ data: Data) throws -> [JSONRPCInboundMessage] {
        buffer.append(data)
        var messages: [JSONRPCInboundMessage] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[..<newline]
            buffer.removeSubrange(...newline)
            guard !line.isEmpty else { continue }
            messages.append(try codec.decode(Data(line)))
        }
        return messages
    }
}

public struct AppServerStartupCommand: Equatable, Sendable {
    public var codexPath: String

    public init(codexPath: String) {
        self.codexPath = codexPath
    }

    public var shellCommand: String {
        AppServerShellCommand(codexPath: codexPath).appServerCommand
    }
}

public struct AppServerShellCommand: Equatable, Sendable {
    public var codexPath: String

    public init(codexPath: String) {
        self.codexPath = codexPath
    }

    public var versionCommand: String {
        command("\(quotedCodexPath) --version")
    }

    public var proxyHelpCommand: String {
        command("\(quotedCodexPath) app-server proxy --help")
    }

    public var appServerHelpCommand: String {
        command("\(quotedCodexPath) app-server --help")
    }

    public var daemonStartCommand: String {
        command(daemonStartBody)
    }

    public var proxyCommand: String {
        command(proxyBody)
    }

    public var appServerCommand: String {
        command("\(quotedCodexPath) app-server --listen stdio://")
    }

    private func command(_ body: String) -> String {
        "\(Self.pathExport); \(body)"
    }

    private var daemonStartBody: String {
        "\(quotedCodexPath) app-server daemon start"
    }

    private var proxyBody: String {
        "\(quotedCodexPath) app-server proxy"
    }

    private static let pathExport = #"export PATH="$HOME/.codex/bin:$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH""#

    private var quotedCodexPath: String {
        Self.singleQuoted(codexPath)
    }

    private static func singleQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

extension JSONRPCID {
    init?(any: Any) {
        switch any {
        case let value as Int:
            self = .number(value)
        case let value as NSNumber:
            self = .number(value.intValue)
        case let value as String:
            self = .string(value)
        default:
            return nil
        }
    }

    var foundationValue: Any {
        switch self {
        case let .number(value):
            return value
        case let .string(value):
            return value
        }
    }
}

extension JSONValue {
    init(any: Any) {
        switch any {
        case let value as [String: Any]:
            self = .object(value.mapValues(JSONValue.init(any:)))
        case let value as [Any]:
            self = .array(value.map(JSONValue.init(any:)))
        case let value as String:
            self = .string(value)
        case let value as Bool:
            self = .bool(value)
        case let value as NSNumber:
            self = .number(value.doubleValue)
        default:
            self = .null
        }
    }

    var foundationValue: Any {
        switch self {
        case let .object(value):
            return value.mapValues(\.foundationValue)
        case let .array(value):
            return value.map(\.foundationValue)
        case let .string(value):
            return value
        case let .number(value):
            return value
        case let .bool(value):
            return value
        case .null:
            return NSNull()
        }
    }
}
