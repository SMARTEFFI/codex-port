import Foundation

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
    public var name: String
    public var host: String
    public var port: Int
    public var username: String
    public var auth: HostProfileDraftAuth
    public var codexPath: String
    public var startupCommand: String
    public var defaultDirectory: String

    public init(
        name: String,
        host: String,
        port: Int,
        username: String,
        auth: HostProfileDraftAuth,
        codexPath: String,
        startupCommand: String,
        defaultDirectory: String
    ) {
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
    case password(String, protection: CredentialProtection)
    case key(label: String, privateKey: String, protection: CredentialProtection)
    case existingPassword(credentialID: String)
    case existingKey(label: String, credentialID: String)
}

public struct HostProfile: Equatable, Identifiable, Sendable {
    public var id: UUID
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
    case password(credentialID: String)
    case key(label: String, credentialID: String)

    public var credentialID: String? {
        switch self {
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
            name: draft.name,
            host: draft.host,
            port: draft.port,
            username: draft.username,
            auth: auth,
            codexPath: draft.codexPath,
            startupCommand: draft.startupCommand,
            defaultDirectory: draft.defaultDirectory,
            knownHostFingerprint: knownHostFingerprint
        )
    }
}

public enum HostProfileStoreError: Error, Equatable {
    case notFound
}

extension HostProfileDraftAuth {
    var replacesStoredCredential: Bool {
        switch self {
        case .password, .key:
            return true
        case .existingPassword, .existingKey:
            return false
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
