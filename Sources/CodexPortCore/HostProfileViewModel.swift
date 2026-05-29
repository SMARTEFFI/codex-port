import Foundation

public enum HostProfileFormError: Error, Equatable {
    case requiredField(String)
    case invalidPort(String)
}

public enum HostProfileAuthMethod: Equatable, Sendable {
    case password
    case key
}

public struct HostProfileFormModel: Equatable, Sendable {
    public var name: String
    public var host: String
    public var port: String
    public var username: String
    public var authMethod: HostProfileAuthMethod
    public var password: String
    public var privateKeyLabel: String
    public var privateKey: String
    public var existingCredentialID: String?
    public var codexPath: String
    public var defaultDirectory: String

    public init(
        name: String = "",
        host: String = "",
        port: String = "22",
        username: String = "",
        authMethod: HostProfileAuthMethod = .password,
        password: String = "",
        privateKeyLabel: String = "",
        privateKey: String = "",
        existingCredentialID: String? = nil,
        codexPath: String = "codex",
        defaultDirectory: String = "~"
    ) {
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.authMethod = authMethod
        self.password = password
        self.privateKeyLabel = privateKeyLabel
        self.privateKey = privateKey
        self.existingCredentialID = existingCredentialID
        self.codexPath = codexPath
        self.defaultDirectory = defaultDirectory
    }

    public init(profile: HostProfile) {
        let authMethod: HostProfileAuthMethod
        let privateKeyLabel: String
        let existingCredentialID: String?
        switch profile.auth {
        case let .password(credentialID):
            authMethod = .password
            privateKeyLabel = ""
            existingCredentialID = credentialID
        case let .key(label, credentialID):
            authMethod = .key
            privateKeyLabel = label
            existingCredentialID = credentialID
        }

        self.init(
            name: profile.name,
            host: profile.host,
            port: String(profile.port),
            username: profile.username,
            authMethod: authMethod,
            password: "",
            privateKeyLabel: privateKeyLabel,
            privateKey: "",
            existingCredentialID: existingCredentialID,
            codexPath: profile.codexPath,
            defaultDirectory: profile.defaultDirectory
        )
    }

    public var startupCommand: String {
        AppServerStartupCommand(codexPath: trimmed(codexPath)).shellCommand
    }

    public func makeDraft() throws -> HostProfileDraft {
        let name = try required(self.name, field: "name")
        let host = try required(self.host, field: "host")
        let username = try required(self.username, field: "username")
        let codexPath = try required(self.codexPath, field: "codexPath")
        let defaultDirectory = try required(self.defaultDirectory, field: "defaultDirectory")
        let port = try parsedPort()
        let auth: HostProfileDraftAuth
        switch authMethod {
        case .password:
            if trimmed(password).isEmpty, let existingCredentialID {
                auth = .existingPassword(credentialID: existingCredentialID)
            } else {
                auth = .password(
                    try required(self.password, field: "password"),
                    protection: .localEncrypted
                )
            }
        case .key:
            let label = try required(self.privateKeyLabel, field: "privateKeyLabel")
            if trimmed(privateKey).isEmpty, let existingCredentialID {
                auth = .existingKey(label: label, credentialID: existingCredentialID)
            } else {
                auth = .key(
                    label: label,
                    privateKey: try required(self.privateKey, field: "privateKey"),
                    protection: .localEncrypted
                )
            }
        }

        return HostProfileDraft(
            name: name,
            host: host,
            port: port,
            username: username,
            auth: auth,
            codexPath: codexPath,
            startupCommand: AppServerStartupCommand(codexPath: codexPath).shellCommand,
            defaultDirectory: defaultDirectory
        )
    }

    private func parsedPort() throws -> Int {
        let value = trimmed(port)
        guard let port = Int(value), (1...65535).contains(port) else {
            throw HostProfileFormError.invalidPort(value)
        }
        return port
    }

    private func required(_ value: String, field: String) throws -> String {
        let value = trimmed(value)
        guard !value.isEmpty else {
            throw HostProfileFormError.requiredField(field)
        }
        return value
    }

    private func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
