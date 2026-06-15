import Foundation
import CodexPortShared

public enum CredentialProtection: String, Codable, Equatable, Sendable {
    case localEncrypted
}

public enum CredentialAuthorization: Equatable, Sendable {
    case granted
    case denied
}

public enum CredentialVaultError: Error, Equatable {
    case authorizationRequired
    case notFound
}

public struct HostProfileDraft: Equatable, Sendable {
    public var connectionMethod: HostConnectionMethodDraft
    public var name: String
    public var host: String
    public var port: Int
    public var username: String
    public var auth: HostProfileDraftAuth
    public var codexPath: String
    public var startupCommand: String
    public var defaultDirectory: String

    public init(
        connectionMethod: HostConnectionMethodDraft = .directSSH,
        name: String,
        host: String,
        port: Int,
        username: String,
        auth: HostProfileDraftAuth,
        codexPath: String,
        startupCommand: String,
        defaultDirectory: String
    ) {
        self.connectionMethod = connectionMethod
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.auth = auth
        self.codexPath = codexPath
        self.startupCommand = startupCommand
        self.defaultDirectory = defaultDirectory
    }
}

public enum HostProfileDraftAuth: Equatable, Sendable {
    case none
    case password(String, protection: CredentialProtection)
    case key(label: String, privateKey: String, protection: CredentialProtection)
    case existingPassword(credentialID: String)
    case existingKey(label: String, credentialID: String)
}

public enum HostConnectionMethodDraft: Equatable, Sendable {
    case directSSH
    case relay(RelayHostDraft)
}

public struct RelayHostDraft: Equatable, Sendable {
    public var hostAgentID: UUID
    public var displayName: String
    public var userName: String
    public var pairingRecordID: String
    public var deviceID: UUID?
    public var relayEndpointURL: URL?
    public var presence: RelayHostPresence
    public var diagnosticsSummary: String

    public init(
        hostAgentID: UUID,
        displayName: String,
        userName: String,
        pairingRecordID: String,
        deviceID: UUID? = nil,
        relayEndpointURL: URL? = nil,
        presence: RelayHostPresence,
        diagnosticsSummary: String
    ) {
        self.hostAgentID = hostAgentID
        self.displayName = displayName
        self.userName = userName
        self.pairingRecordID = pairingRecordID
        self.deviceID = deviceID
        self.relayEndpointURL = relayEndpointURL
        self.presence = presence
        self.diagnosticsSummary = diagnosticsSummary
    }
}

public enum HostConnectionMethod: Equatable, Sendable {
    case directSSH
    case relay(RelayHost)

    public var relayHost: RelayHost? {
        switch self {
        case .directSSH:
            nil
        case let .relay(host):
            host
        }
    }

    public var isRelay: Bool {
        relayHost != nil
    }
}

public struct RelayHost: Equatable, Sendable {
    public var hostAgentID: UUID
    public var displayName: String
    public var userName: String
    public var pairingRecordID: String
    public var deviceID: UUID?
    public var relayEndpointURL: URL?
    public var presence: RelayHostPresence
    public var diagnosticsSummary: String

    public init(
        hostAgentID: UUID,
        displayName: String,
        userName: String,
        pairingRecordID: String,
        deviceID: UUID? = nil,
        relayEndpointURL: URL? = nil,
        presence: RelayHostPresence,
        diagnosticsSummary: String
    ) {
        self.hostAgentID = hostAgentID
        self.displayName = displayName
        self.userName = userName
        self.pairingRecordID = pairingRecordID
        self.deviceID = deviceID
        self.relayEndpointURL = relayEndpointURL
        self.presence = presence
        self.diagnosticsSummary = diagnosticsSummary
    }
}

public struct HostProfile: Equatable, Identifiable, Sendable {
    public var id: UUID
    public var connectionMethod: HostConnectionMethod
    public var name: String
    public var host: String
    public var port: Int
    public var username: String
    public var auth: HostProfileAuth
    public var codexPath: String
    public var startupCommand: String
    public var defaultDirectory: String
    public var knownHostFingerprint: String?

    public init(
        id: UUID,
        connectionMethod: HostConnectionMethod = .directSSH,
        name: String,
        host: String,
        port: Int,
        username: String,
        auth: HostProfileAuth,
        codexPath: String,
        startupCommand: String,
        defaultDirectory: String,
        knownHostFingerprint: String?
    ) {
        self.id = id
        self.connectionMethod = connectionMethod
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.auth = auth
        self.codexPath = codexPath
        self.startupCommand = startupCommand
        self.defaultDirectory = defaultDirectory
        self.knownHostFingerprint = knownHostFingerprint
    }
}

public enum HostProfileAuth: Equatable, Sendable {
    case none
    case password(credentialID: String)
    case key(label: String, credentialID: String)

    public var credentialID: String? {
        switch self {
        case .none:
            return nil
        case let .password(credentialID):
            return credentialID
        case let .key(_, credentialID):
            return credentialID
        }
    }
}

public protocol CredentialVault: AnyObject {
    func saveSecret(_ secret: String, protection: CredentialProtection) throws -> String
    func readSecret(id: String, authorization: CredentialAuthorization) throws -> String
    func deleteSecret(id: String) throws
}

public final class HostProfileStore {
    private let credentialVault: CredentialVault
    private var profiles: [HostProfile] = []

    public init(credentialVault: CredentialVault) {
        self.credentialVault = credentialVault
    }

    public func create(_ draft: HostProfileDraft) throws -> HostProfile {
        let profile = try makeProfile(id: UUID(), draft: draft, knownHostFingerprint: nil)
        profiles.append(profile)
        return profile
    }

    public func list() -> [HostProfile] {
        profiles
    }

    public func update(_ id: UUID, with draft: HostProfileDraft) throws -> HostProfile {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else {
            throw HostProfileStoreError.notFound
        }
        if draft.auth.replacesStoredCredential, let oldCredential = profiles[index].auth.credentialID {
            try credentialVault.deleteSecret(id: oldCredential)
        }
        let updated = try makeProfile(id: id, draft: draft, knownHostFingerprint: profiles[index].knownHostFingerprint)
        profiles[index] = updated
        return updated
    }

    public func delete(_ id: UUID) throws {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else {
            throw HostProfileStoreError.notFound
        }
        if let credentialID = profiles[index].auth.credentialID {
            try credentialVault.deleteSecret(id: credentialID)
        }
        profiles.remove(at: index)
    }

    private func makeProfile(id: UUID, draft: HostProfileDraft, knownHostFingerprint: String?) throws -> HostProfile {
        let auth: HostProfileAuth
        switch draft.auth {
        case .none:
            auth = .none
        case let .password(secret, protection):
            auth = .password(credentialID: try credentialVault.saveSecret(secret, protection: protection))
        case let .key(label, privateKey, protection):
            auth = .key(label: label, credentialID: try credentialVault.saveSecret(privateKey, protection: protection))
        case let .existingPassword(credentialID):
            auth = .password(credentialID: credentialID)
        case let .existingKey(label, credentialID):
            auth = .key(label: label, credentialID: credentialID)
        }
        return HostProfile(
            id: id,
            connectionMethod: HostConnectionMethod(draft.connectionMethod),
            name: draft.name,
            host: draft.host,
            port: draft.port,
            username: draft.username,
            auth: auth,
            codexPath: draft.codexPath,
            startupCommand: draft.normalizedStartupCommand,
            defaultDirectory: draft.defaultDirectory,
            knownHostFingerprint: knownHostFingerprint
        )
    }

    public func trustKnownHost(profileID: UUID, fingerprint: String) throws {
        guard let index = profiles.firstIndex(where: { $0.id == profileID }) else {
            throw HostProfileStoreError.notFound
        }
        profiles[index].knownHostFingerprint = fingerprint
    }
}

public enum HostProfileStoreError: Error, Equatable {
    case notFound
}

extension HostProfileDraftAuth {
    var replacesStoredCredential: Bool {
        switch self {
        case .none:
            return false
        case .password, .key:
            return true
        case .existingPassword, .existingKey:
            return false
        }
    }
}

extension HostConnectionMethod {
    init(_ draft: HostConnectionMethodDraft) {
        switch draft {
        case .directSSH:
            self = .directSSH
        case let .relay(relay):
            self = .relay(RelayHost(relay))
        }
    }
}

extension RelayHost {
    init(_ draft: RelayHostDraft) {
        self.init(
            hostAgentID: draft.hostAgentID,
            displayName: draft.displayName,
            userName: draft.userName,
            pairingRecordID: draft.pairingRecordID,
            deviceID: draft.deviceID,
            relayEndpointURL: draft.relayEndpointURL,
            presence: draft.presence,
            diagnosticsSummary: draft.diagnosticsSummary
        )
    }
}

extension HostProfileDraft {
    var normalizedStartupCommand: String {
        switch connectionMethod {
        case .directSSH:
            AppServerStartupCommand(codexPath: codexPath).shellCommand
        case .relay:
            startupCommand
        }
    }
}

public enum HostKeyEvaluation: Equatable, Sendable {
    case needsUserConfirmation(String)
    case trusted
    case changed(expected: String, presented: String)
}

public protocol KnownHostVerifying: AnyObject {
    func evaluate(profileID: UUID, presentedFingerprint: String) -> HostKeyEvaluation
    func trust(profileID: UUID, fingerprint: String) throws
}

public final class KnownHostVerifier: KnownHostVerifying {
    private var trustedFingerprints: [UUID: String] = [:]

    public init() {}

    public func evaluate(profileID: UUID, presentedFingerprint: String) -> HostKeyEvaluation {
        guard let expected = trustedFingerprints[profileID] else {
            return .needsUserConfirmation(presentedFingerprint)
        }
        return expected == presentedFingerprint ? .trusted : .changed(expected: expected, presented: presentedFingerprint)
    }

    public func trust(profileID: UUID, fingerprint: String) {
        trustedFingerprints[profileID] = fingerprint
    }
}
