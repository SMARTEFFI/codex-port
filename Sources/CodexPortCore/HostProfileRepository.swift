import Foundation

public protocol HostProfileRepository {
    func load() throws -> [HostProfile]
    func save(_ profiles: [HostProfile]) throws
}

public final class FileHostProfileRepository: HostProfileRepository {
    private let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func load() throws -> [HostProfile] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode([StoredHostProfile].self, from: data).map(\.hostProfile)
    }

    public func save(_ profiles: [HostProfile]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let stored = profiles.map(StoredHostProfile.init(hostProfile:))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(stored).write(to: fileURL, options: [.atomic])
    }
}

public final class PersistentHostProfileStore {
    private let repository: HostProfileRepository
    private let credentialVault: CredentialVault
    private var profiles: [HostProfile]

    public init(repository: HostProfileRepository, credentialVault: CredentialVault) throws {
        self.repository = repository
        self.credentialVault = credentialVault
        self.profiles = try repository.load()
    }

    public func list() -> [HostProfile] {
        profiles
    }

    public func create(_ draft: HostProfileDraft) throws -> HostProfile {
        let profile = try makeProfile(id: UUID(), draft: draft, knownHostFingerprint: nil)
        profiles.append(profile)
        try repository.save(profiles)
        return profile
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
        try repository.save(profiles)
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
        try repository.save(profiles)
    }

    public func markKnownHostTrusted(id: UUID, fingerprint: String) throws -> HostProfile {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else {
            throw HostProfileStoreError.notFound
        }
        profiles[index].knownHostFingerprint = fingerprint
        try repository.save(profiles)
        return profiles[index]
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
            startupCommand: AppServerStartupCommand(codexPath: draft.codexPath).shellCommand,
            defaultDirectory: draft.defaultDirectory,
            knownHostFingerprint: knownHostFingerprint
        )
    }
}

public protocol KnownHostStore {
    func load() throws -> [UUID: String]
    func save(_ fingerprints: [UUID: String]) throws
}

public final class FileKnownHostStore: KnownHostStore {
    private let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func load() throws -> [UUID: String] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return [:]
        }
        let data = try Data(contentsOf: fileURL)
        let stored = try JSONDecoder().decode([String: String].self, from: data)
        return Dictionary(uniqueKeysWithValues: stored.compactMap { key, value in
            guard let id = UUID(uuidString: key) else { return nil }
            return (id, value)
        })
    }

    public func save(_ fingerprints: [UUID: String]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let stored = Dictionary(uniqueKeysWithValues: fingerprints.map { ($0.key.uuidString, $0.value) })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(stored).write(to: fileURL, options: [.atomic])
    }
}

public final class PersistentKnownHostVerifier: KnownHostVerifying {
    private let store: KnownHostStore
    private var trustedFingerprints: [UUID: String]

    public init(store: KnownHostStore) throws {
        self.store = store
        self.trustedFingerprints = try store.load()
    }

    public func evaluate(profileID: UUID, presentedFingerprint: String) -> HostKeyEvaluation {
        guard let expected = trustedFingerprints[profileID] else {
            return .needsUserConfirmation(presentedFingerprint)
        }
        return expected == presentedFingerprint ? .trusted : .changed(expected: expected, presented: presentedFingerprint)
    }

    public func trust(profileID: UUID, fingerprint: String) throws {
        trustedFingerprints[profileID] = fingerprint
        try store.save(trustedFingerprints)
    }
}

private struct StoredHostProfile: Codable {
    var id: UUID
    var name: String
    var host: String
    var port: Int
    var username: String
    var auth: StoredHostProfileAuth
    var codexPath: String
    var startupCommand: String
    var defaultDirectory: String
    var knownHostFingerprint: String?

    init(hostProfile: HostProfile) {
        id = hostProfile.id
        name = hostProfile.name
        host = hostProfile.host
        port = hostProfile.port
        username = hostProfile.username
        auth = StoredHostProfileAuth(hostProfile.auth)
        codexPath = hostProfile.codexPath
        startupCommand = hostProfile.startupCommand
        defaultDirectory = hostProfile.defaultDirectory
        knownHostFingerprint = hostProfile.knownHostFingerprint
    }

    var hostProfile: HostProfile {
        HostProfile(
            id: id,
            name: name,
            host: host,
            port: port,
            username: username,
            auth: auth.hostProfileAuth,
            codexPath: codexPath,
            startupCommand: startupCommand,
            defaultDirectory: defaultDirectory,
            knownHostFingerprint: knownHostFingerprint
        )
    }
}

private enum StoredHostProfileAuth: Codable {
    case password(credentialID: String)
    case key(label: String, credentialID: String)

    init(_ auth: HostProfileAuth) {
        switch auth {
        case let .password(credentialID):
            self = .password(credentialID: credentialID)
        case let .key(label, credentialID):
            self = .key(label: label, credentialID: credentialID)
        }
    }

    var hostProfileAuth: HostProfileAuth {
        switch self {
        case let .password(credentialID):
            return .password(credentialID: credentialID)
        case let .key(label, credentialID):
            return .key(label: label, credentialID: credentialID)
        }
    }
}
