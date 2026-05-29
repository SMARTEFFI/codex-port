import Foundation

public enum JSONValue: Equatable, Sendable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    public var object: [String: JSONValue]? {
        if case let .object(value) = self { value } else { nil }
    }

    public var array: [JSONValue]? {
        if case let .array(value) = self { value } else { nil }
    }

    public var string: String? {
        if case let .string(value) = self { value } else { nil }
    }

    public var number: Double? {
        if case let .number(value) = self { value } else { nil }
    }

    public var boolValue: Bool? {
        if case let .bool(value) = self { value } else { nil }
    }
}

public enum JSONRPCID: Equatable, Hashable, Sendable {
    case number(Int)
    case string(String)
}
