import Crypto
import Foundation

public final class LocalEncryptedCredentialVault: CredentialVault {
    private let directory: URL
    private let credentialsURL: URL
    private let keyURL: URL
    private let fileManager: FileManager
    private let lock = NSLock()

    public init(directory: URL, fileManager: FileManager = .default) throws {
        self.directory = directory
        self.credentialsURL = directory.appending(path: "credentials.json")
        self.keyURL = directory.appending(path: "credentials.key")
        self.fileManager = fileManager

        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public static func defaultDirectory(fileManager: FileManager = .default) throws -> URL {
        let base = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let bundleID = Bundle.main.bundleIdentifier ?? "CodexPort"
        return base.appending(path: bundleID).appending(path: "Credentials")
    }

    public func saveSecret(_ secret: String, protection: CredentialProtection) throws -> String {
        lock.lock()
        defer { lock.unlock() }

        let id = UUID().uuidString
        var file = try loadCredentials()
        let key = try loadOrCreateKey()
        let sealed = try AES.GCM.seal(Data(secret.utf8), using: key)
        guard let combined = sealed.combined else {
            throw LocalEncryptedCredentialVaultError.encryptionFailed
        }
        file.credentials[id] = StoredLocalCredential(
            protection: protection,
            sealedBox: combined.base64EncodedString()
        )
        try saveCredentials(file)
        return id
    }

    public func readSecret(id: String, authorization: CredentialAuthorization) throws -> String {
        lock.lock()
        defer { lock.unlock() }

        let file = try loadCredentials()
        guard let stored = file.credentials[id] else {
            throw CredentialVaultError.notFound
        }
        guard let combined = Data(base64Encoded: stored.sealedBox) else {
            throw LocalEncryptedCredentialVaultError.invalidCiphertext
        }
        let key = try loadOrCreateKey()
        let sealedBox = try AES.GCM.SealedBox(combined: combined)
        let plaintext = try AES.GCM.open(sealedBox, using: key)
        guard let secret = String(data: plaintext, encoding: .utf8) else {
            throw LocalEncryptedCredentialVaultError.invalidPlaintext
        }
        return secret
    }

    public func deleteSecret(id: String) throws {
        lock.lock()
        defer { lock.unlock() }

        var file = try loadCredentials()
        file.credentials[id] = nil
        try saveCredentials(file)
    }

    private func loadOrCreateKey() throws -> SymmetricKey {
        if fileManager.fileExists(atPath: keyURL.path) {
            let encoded = try String(contentsOf: keyURL, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let data = Data(base64Encoded: encoded) else {
                throw LocalEncryptedCredentialVaultError.invalidKey
            }
            return SymmetricKey(data: data)
        }

        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        try data.base64EncodedString().write(to: keyURL, atomically: true, encoding: .utf8)
        return key
    }

    private func loadCredentials() throws -> StoredLocalCredentialFile {
        guard fileManager.fileExists(atPath: credentialsURL.path) else {
            return StoredLocalCredentialFile()
        }
        let data = try Data(contentsOf: credentialsURL)
        return try JSONDecoder().decode(StoredLocalCredentialFile.self, from: data)
    }

    private func saveCredentials(_ file: StoredLocalCredentialFile) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(file).write(to: credentialsURL, options: [.atomic])
    }
}

public enum LocalEncryptedCredentialVaultError: Error, Equatable {
    case encryptionFailed
    case invalidCiphertext
    case invalidKey
    case invalidPlaintext
}

private struct StoredLocalCredentialFile: Codable {
    var version = 1
    var credentials: [String: StoredLocalCredential] = [:]
}

private struct StoredLocalCredential: Codable {
    var protection: CredentialProtection
    var sealedBox: String
}
