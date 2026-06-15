import Foundation

public enum ControlJSONValue: Equatable, Sendable {
    case object([String: ControlJSONValue])
    case array([ControlJSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    public var object: [String: ControlJSONValue]? {
        if case let .object(value) = self { value } else { nil }
    }

    public var array: [ControlJSONValue]? {
        if case let .array(value) = self { value } else { nil }
    }

    public var string: String? {
        if case let .string(value) = self { value } else { nil }
    }

    public var bool: Bool? {
        if case let .bool(value) = self { value } else { nil }
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

    init(any: Any) {
        switch any {
        case let value as [String: Any]:
            self = .object(value.mapValues(ControlJSONValue.init(any:)))
        case let value as [Any]:
            self = .array(value.map(ControlJSONValue.init(any:)))
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
}

public enum ControlJSONRPCID: Equatable, Hashable, Sendable {
    case number(Int)
    case string(String)

    var foundationValue: Any {
        switch self {
        case let .number(value):
            return value
        case let .string(value):
            return value
        }
    }

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
}

public struct ControlJSONRPCNotification: Equatable, Sendable {
    public var method: String
    public var params: ControlJSONValue

    public init(method: String, params: ControlJSONValue) {
        self.method = method
        self.params = params
    }
}

enum ControlJSONRPCInboundMessage: Equatable, Sendable {
    case response(id: ControlJSONRPCID, result: ControlJSONValue)
    case error(id: ControlJSONRPCID, code: Int, message: String)
    case notification(method: String, params: ControlJSONValue)
    case request(id: ControlJSONRPCID, method: String, params: ControlJSONValue)
}

enum ControlJSONRPCCodecError: Error, Equatable, Sendable {
    case invalidMessage(String)
}

struct ControlJSONRPCCodec: Sendable {
    func encodeRequest(id: ControlJSONRPCID, method: String, params: ControlJSONValue) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "id": id.foundationValue,
            "method": method,
            "params": params.foundationValue,
        ], options: [.withoutEscapingSlashes])
    }

    func decode(_ data: Data) throws -> ControlJSONRPCInboundMessage {
        let rawMessage = String(data: data, encoding: .utf8) ?? data.base64EncodedString()
        let jsonObject: Any
        do {
            jsonObject = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ControlJSONRPCCodecError.invalidMessage(rawMessage)
        }
        guard let object = jsonObject as? [String: Any] else {
            throw ControlJSONRPCCodecError.invalidMessage(rawMessage)
        }
        if let method = object["method"] as? String {
            let params = ControlJSONValue(any: object["params"] ?? NSNull())
            if let id = ControlJSONRPCID(any: object["id"] ?? NSNull()) {
                return .request(id: id, method: method, params: params)
            }
            return .notification(method: method, params: params)
        }
        guard let id = ControlJSONRPCID(any: object["id"] ?? NSNull()) else {
            throw ControlJSONRPCCodecError.invalidMessage(rawMessage)
        }
        if let error = object["error"] as? [String: Any] {
            return .error(
                id: id,
                code: error["code"] as? Int ?? -32000,
                message: error["message"] as? String ?? "Unknown JSON-RPC error"
            )
        }
        return .response(id: id, result: ControlJSONValue(any: object["result"] ?? NSNull()))
    }
}
