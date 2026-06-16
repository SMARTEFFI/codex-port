import Foundation
import CodexPortShared

public enum ApprovalAction: Equatable, Sendable {
    case accept
    case acceptForSession
    case decline
    case cancel
}

public struct ApprovalResponse: Equatable, Sendable {
    public var id: JSONRPCID
    public var result: JSONValue
}

public enum ApprovalRequest: Equatable, Sendable {
    case command(id: JSONRPCID, command: [String], cwd: String, reason: String?)
    case fileChange(id: JSONRPCID, path: String, diff: String)
    case permissions(id: JSONRPCID, permissions: JSONValue)

    public func response(for action: ApprovalAction) -> ApprovalResponse {
        let id: JSONRPCID
        switch self {
        case let .command(requestID, _, _, _), let .fileChange(requestID, _, _), let .permissions(requestID, _):
            id = requestID
        }

        if case let .permissions(_, permissions) = self {
            let scope: JSONValue = action == .acceptForSession ? .string("session") : .string("turn")
            if action == .decline || action == .cancel {
                return ApprovalResponse(id: id, result: .object(["decision": .string(action.decisionValue)]))
            }
            return ApprovalResponse(id: id, result: .object(["permissions": permissions, "scope": scope]))
        }

        return ApprovalResponse(id: id, result: .object(["decision": .string(action.decisionValue)]))
    }
}

public enum ApprovalResponderError: Error, Equatable {
    case unsupportedRequest(method: String)
}

public final class ApprovalResponder {
    private let jsonRPCClient: JSONRPCClient

    public init(jsonRPCClient: JSONRPCClient) {
        self.jsonRPCClient = jsonRPCClient
    }

    public func nextApprovalRequest() async throws -> ApprovalRequest {
        while let request = await jsonRPCClient.nextServerRequest() {
            if let approval = ApprovalRequest(serverRequest: request) {
                return approval
            }
            throw ApprovalResponderError.unsupportedRequest(method: request.method)
        }
        throw JSONRPCError.connectionClosed
    }

    public func respond(to request: ApprovalRequest, action: ApprovalAction) async throws {
        let response = request.response(for: action)
        try await jsonRPCClient.respond(to: response.id, result: response.result)
    }
}

extension ApprovalRequest {
    public init?(serverRequest: JSONRPCServerRequest) {
        switch serverRequest.method {
        case "item/commandExecution/requestApproval":
            guard let object = serverRequest.params.object else { return nil }
            let command = object["command"]?.array?.compactMap(\.string) ?? []
            self = .command(
                id: serverRequest.id,
                command: command,
                cwd: object["cwd"]?.string ?? "",
                reason: object["reason"]?.string
            )
        case "item/fileChange/requestApproval":
            guard let object = serverRequest.params.object else { return nil }
            self = .fileChange(
                id: serverRequest.id,
                path: object["path"]?.string ?? "",
                diff: object["diff"]?.string ?? ""
            )
        case "item/permissions/requestApproval":
            guard let object = serverRequest.params.object else { return nil }
            self = .permissions(id: serverRequest.id, permissions: object["permissions"] ?? serverRequest.params)
        default:
            return nil
        }
    }
}

extension ApprovalAction {
    var decisionValue: String {
        switch self {
        case .accept: "approved"
        case .acceptForSession: "approved_for_session"
        case .decline: "denied"
        case .cancel: "abort"
        }
    }
}

public enum InputPrimaryAction: Equatable, Sendable {
    case send
    case stop
    case disabled
}

public struct InputComposer: Equatable, Sendable {
    public var message = StructuredUserMessage(body: "")
    public var text: String {
        get { message.body }
        set { message.body = newValue }
    }
    public var attachments: [TurnAttachment] = []
    public var modelDisplay: String
    public var model: CodexModel = .gpt55
    public var reasoningEffort: ReasoningEffort = .xhigh
    public var permissionMode: PermissionMode = .remoteDefault
    public var collaborationMode: CollaborationMode = .default
    public var capabilities: ComposerCapabilities = .supported
    public var isRunning = false

    public init(modelDisplay: String, capabilities: ComposerCapabilities = .supported) {
        self.modelDisplay = modelDisplay
        self.capabilities = capabilities
    }

    public var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !attachments.isEmpty
            || !message.attachments.isEmpty
            || !message.mentions.isEmpty
    }

    public var primaryAction: InputPrimaryAction {
        if isRunning {
            return .stop
        }
        return canSend ? .send : .disabled
    }

    public mutating func togglePlanMode() {
        guard capabilities.planMode.isSupported else { return }
        collaborationMode = collaborationMode == .plan ? .default : .plan
    }

    public mutating func setPermissionMode(_ mode: PermissionMode) {
        guard capabilities.permissionModes[mode]?.isSupported ?? false else { return }
        permissionMode = mode
    }

    public var modelMenu: ModelMenuState {
        ModelMenuState(
            primaryTitle: modelDisplay,
            modelOptions: CodexModel.allCases.map { option in
                ModelOptionState(
                    model: option,
                    id: option.id,
                    title: option.displayName,
                    isSelected: option == model,
                    isEnabled: capabilities.modelSelection.isSupported,
                    disabledReason: capabilities.modelSelection.reason
                )
            },
            reasoningOptions: ReasoningEffort.allCases.map { option in
                ReasoningOptionState(
                    effort: option,
                    title: option.displayName,
                    isSelected: option == reasoningEffort,
                    isEnabled: capabilities.reasoningEffort.isSupported,
                    disabledReason: capabilities.reasoningEffort.reason
                )
            }
        )
    }

    public mutating func setModel(_ model: CodexModel) {
        guard capabilities.modelSelection.isSupported else { return }
        self.model = model
        updateModelDisplay()
    }

    public func skillSuggestions(in catalog: SkillCatalog) -> [SkillMention] {
        guard let query = currentSkillQuery else { return [] }
        return catalog.skills.filter { skill in
            skill.identifier.localizedCaseInsensitiveContains(query)
                || skill.displayName.localizedCaseInsensitiveContains(query)
        }
    }

    public mutating func selectSkillMention(_ mention: SkillMention) {
        message.mentions.removeAll { $0.identifier == mention.identifier }
        message.mentions.append(mention)
        if let range = currentSkillQueryRange {
            text.removeSubrange(range)
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    public mutating func removeSkillMention(id: String) {
        message.mentions.removeAll { $0.identifier == id }
    }

    public mutating func setReasoningEffort(_ effort: ReasoningEffort) {
        guard capabilities.reasoningEffort.isSupported else { return }
        self.reasoningEffort = effort
        updateModelDisplay()
    }

    private mutating func updateModelDisplay() {
        modelDisplay = "\(model.shortDisplayName) \(reasoningEffort.shortDisplayName)"
    }

    private var currentSkillQuery: String? {
        guard let range = currentSkillQueryRange else { return nil }
        let queryStart = text.index(after: range.lowerBound)
        let query = String(text[queryStart..<range.upperBound])
        return query.isEmpty ? nil : query
    }

    private var currentSkillQueryRange: Range<String.Index>? {
        var ranges: [Range<String.Index>] = []
        var searchStart = text.startIndex
        while searchStart < text.endIndex,
              let dollar = text[searchStart...].firstIndex(of: "$")
        {
            let previous = dollar == text.startIndex ? nil : text[text.index(before: dollar)]
            let isBoundary = previous == nil || previous?.isWhitespace == true || previous?.isNewline == true
            var end = text.index(after: dollar)
            while end < text.endIndex {
                let character = text[end]
                guard character.isLetter || character.isNumber || character == "-" || character == "_" else {
                    break
                }
                end = text.index(after: end)
            }
            if isBoundary, end > text.index(after: dollar) {
                ranges.append(dollar..<end)
            }
            searchStart = end
        }
        return ranges.last
    }
}

public struct ComposerCapabilities: Equatable, Sendable {
    public var planMode: FeatureAvailability
    public var permissionModes: [PermissionMode: FeatureAvailability]
    public var modelSelection: FeatureAvailability
    public var reasoningEffort: FeatureAvailability

    public static let supported = ComposerCapabilities(
        planMode: .supported,
        permissionModes: Dictionary(uniqueKeysWithValues: PermissionMode.allCases.map { ($0, .supported) }),
        modelSelection: .supported,
        reasoningEffort: .supported
    )

    public static let appDefault = ComposerCapabilities(
        planMode: .supported,
        permissionModes: Dictionary(uniqueKeysWithValues: PermissionMode.allCases.map { ($0, .supported) }),
        modelSelection: .unsupported(reason: "当前远端 Codex app-server 暂不支持从 iOS 切换模型。"),
        reasoningEffort: .unsupported(reason: "当前远端 Codex app-server 暂不支持从 iOS 切换推理强度。")
    )

    public init(
        planMode: FeatureAvailability,
        permissionModes: [PermissionMode: FeatureAvailability],
        modelSelection: FeatureAvailability = .supported,
        reasoningEffort: FeatureAvailability = .supported
    ) {
        self.planMode = planMode
        self.permissionModes = permissionModes
        self.modelSelection = modelSelection
        self.reasoningEffort = reasoningEffort
    }
}

public enum FeatureAvailability: Equatable, Sendable {
    case supported
    case unsupported(reason: String)

    public var isSupported: Bool {
        if case .supported = self {
            return true
        }
        return false
    }

    public var reason: String? {
        if case let .unsupported(reason) = self {
            return reason
        }
        return nil
    }
}

public enum CodexModel: String, CaseIterable, Equatable, Sendable {
    case gpt55 = "gpt-5.5"
    case gpt5 = "gpt-5"
    case gpt41 = "gpt-4.1"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .gpt55: "GPT-5.5"
        case .gpt5: "GPT-5"
        case .gpt41: "GPT-4.1"
        }
    }

    public var shortDisplayName: String {
        switch self {
        case .gpt55: "5.5"
        case .gpt5: "5"
        case .gpt41: "4.1"
        }
    }
}

public enum ReasoningEffort: String, CaseIterable, Equatable, Sendable {
    case low
    case medium
    case high
    case xhigh

    public var displayName: String {
        switch self {
        case .low: "低"
        case .medium: "中"
        case .high: "高"
        case .xhigh: "超高"
        }
    }

    public var shortDisplayName: String { displayName }
}

public struct ModelMenuState: Equatable, Sendable {
    public var primaryTitle: String
    public var modelOptions: [ModelOptionState]
    public var reasoningOptions: [ReasoningOptionState]
}

public struct ModelOptionState: Equatable, Sendable {
    public var model: CodexModel
    public var id: String
    public var title: String
    public var isSelected: Bool
    public var isEnabled: Bool
    public var disabledReason: String?
}

public struct ReasoningOptionState: Equatable, Sendable {
    public var effort: ReasoningEffort
    public var title: String
    public var isSelected: Bool
    public var isEnabled: Bool
    public var disabledReason: String?
}
