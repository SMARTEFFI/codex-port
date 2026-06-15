import Foundation
import CodexPortShared

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

    @discardableResult
    public func seedRelayHostIfNeeded(_ seed: RelayHostLaunchSeed) throws -> HostProfile? {
        if profiles.contains(where: { profile in
            guard let relayHost = profile.connectionMethod.relayHost else { return false }
            return relayHost.hostAgentID == seed.hostAgentID
                && relayHost.deviceID == seed.deviceID
                && relayHost.pairingRecordID == seed.pairingRecordID
        }) {
            return nil
        }
        return try create(seed.hostProfileDraft())
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

    public func updateRelayReadiness(id: UUID, readiness: RelayHostReadiness) throws -> HostProfile {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else {
            throw HostProfileStoreError.notFound
        }
        guard case var .relay(relayHost) = profiles[index].connectionMethod else {
            throw HostProfileStoreError.notRelayHost
        }
        relayHost.readiness = readiness
        profiles[index].connectionMethod = .relay(relayHost)
        try repository.save(profiles)
        return profiles[index]
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
    var connectionMethod: StoredHostConnectionMethod?
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
        connectionMethod = StoredHostConnectionMethod(hostProfile.connectionMethod)
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
            connectionMethod: connectionMethod?.hostConnectionMethod ?? .directSSH,
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
    case none
    case password(credentialID: String)
    case key(label: String, credentialID: String)

    init(_ auth: HostProfileAuth) {
        switch auth {
        case .none:
            self = .none
        case let .password(credentialID):
            self = .password(credentialID: credentialID)
        case let .key(label, credentialID):
            self = .key(label: label, credentialID: credentialID)
        }
    }

    var hostProfileAuth: HostProfileAuth {
        switch self {
        case .none:
            return .none
        case let .password(credentialID):
            return .password(credentialID: credentialID)
        case let .key(label, credentialID):
            return .key(label: label, credentialID: credentialID)
        }
    }
}

private enum StoredHostConnectionMethod: Codable {
    case directSSH
    case relay(StoredRelayHost)

    init(_ method: HostConnectionMethod) {
        switch method {
        case .directSSH:
            self = .directSSH
        case let .relay(host):
            self = .relay(StoredRelayHost(host))
        }
    }

    var hostConnectionMethod: HostConnectionMethod {
        switch self {
        case .directSSH:
            return .directSSH
        case let .relay(host):
            return .relay(host.relayHost)
        }
    }
}

private struct StoredRelayHost: Codable {
    var hostAgentID: UUID
    var displayName: String
    var userName: String
    var pairingRecordID: String
    var deviceID: UUID?
    var relayEndpointURL: URL?
    var presence: StoredRelayHostPresence
    var readiness: StoredRelayHostReadiness?
    var diagnosticsSummary: String

    init(_ host: RelayHost) {
        hostAgentID = host.hostAgentID
        displayName = host.displayName
        userName = host.userName
        pairingRecordID = host.pairingRecordID
        deviceID = host.deviceID
        relayEndpointURL = host.relayEndpointURL
        presence = StoredRelayHostPresence(host.presence)
        readiness = StoredRelayHostReadiness(host.readiness)
        diagnosticsSummary = host.diagnosticsSummary
    }

    var relayHost: RelayHost {
        RelayHost(
            hostAgentID: hostAgentID,
            displayName: displayName,
            userName: userName,
            pairingRecordID: pairingRecordID,
            deviceID: deviceID,
            relayEndpointURL: relayEndpointURL,
            presence: presence.relayHostPresence,
            readiness: readiness?.relayHostReadiness ?? RelayHostReadiness.default(for: presence.relayHostPresence),
            diagnosticsSummary: diagnosticsSummary
        )
    }
}

private enum StoredRelayHostPresence: Codable {
    case offline(lastSeenAt: Date?)
    case online(activeConnectionCount: Int)

    init(_ presence: RelayHostPresence) {
        switch presence {
        case let .offline(lastSeenAt):
            self = .offline(lastSeenAt: lastSeenAt)
        case let .online(activeConnectionCount):
            self = .online(activeConnectionCount: activeConnectionCount)
        }
    }

    var relayHostPresence: RelayHostPresence {
        switch self {
        case let .offline(lastSeenAt):
            return .offline(lastSeenAt: lastSeenAt)
        case let .online(activeConnectionCount):
            return .online(activeConnectionCount: activeConnectionCount)
        }
    }
}

private enum StoredRelayHostReadiness: Codable {
    case offline(lastSeenAt: Date?)
    case loading(stage: RelayHostReadinessStage)
    case ready(loadedThreadCount: Int)
    case failed(reason: RelayHostReadinessFailureReason, message: String)

    init(_ readiness: RelayHostReadiness) {
        switch readiness {
        case let .offline(lastSeenAt):
            self = .offline(lastSeenAt: lastSeenAt)
        case let .loading(stage):
            self = .loading(stage: stage)
        case let .ready(loadedThreadCount):
            self = .ready(loadedThreadCount: loadedThreadCount)
        case let .failed(reason, message):
            self = .failed(reason: reason, message: message)
        }
    }

    var relayHostReadiness: RelayHostReadiness {
        switch self {
        case let .offline(lastSeenAt):
            return .offline(lastSeenAt: lastSeenAt)
        case .loading:
            return .failed(
                reason: .threadListTimeout,
                message: "上次读取会话未完成，点按重试"
            )
        case let .ready(loadedThreadCount):
            return .ready(loadedThreadCount: loadedThreadCount)
        case let .failed(reason, message):
            return .failed(reason: reason, message: message)
        }
    }
}
