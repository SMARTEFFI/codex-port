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
    public var connectionMethod: HostConnectionMethodDraft
    public var name: String
    public var host: String
    public var port: String
    public var username: String
    public var authMethod: HostProfileAuthMethod
    public var password: String
    public var privateKeyLabel: String
    public var privateKey: String
    public var existingCredentialID: String?
    public var relayServerEndpoint: String
    public var pairingMaterial: String
    public var deviceDisplayName: String
    public var codexPath: String
    public var defaultDirectory: String

    public init(
        connectionMethod: HostConnectionMethodDraft = HostProfileFormModel.defaultRelayConnectionMethod,
        name: String = "",
        host: String = "",
        port: String = "",
        username: String = "",
        authMethod: HostProfileAuthMethod = .password,
        password: String = "",
        privateKeyLabel: String = "",
        privateKey: String = "",
        existingCredentialID: String? = nil,
        relayServerEndpoint: String = "",
        pairingMaterial: String = "",
        deviceDisplayName: String = "",
        codexPath: String = "codex",
        defaultDirectory: String = "~"
    ) {
        self.connectionMethod = connectionMethod
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.authMethod = authMethod
        self.password = password
        self.privateKeyLabel = privateKeyLabel
        self.privateKey = privateKey
        self.existingCredentialID = existingCredentialID
        self.relayServerEndpoint = relayServerEndpoint
        self.pairingMaterial = pairingMaterial
        self.deviceDisplayName = deviceDisplayName
        self.codexPath = codexPath
        self.defaultDirectory = defaultDirectory
    }

    public static var defaultRelayConnectionMethod: HostConnectionMethodDraft {
        .relay(
            RelayHostDraft(
                hostAgentID: UUID(),
                displayName: "Mac HostAgent",
                userName: "",
                pairingRecordID: "pending-pairing",
                presence: .offline(),
                diagnosticsSummary: "Pairing pending"
            )
        )
    }

    public init(profile: HostProfile) {
        let authMethod: HostProfileAuthMethod
        let privateKeyLabel: String
        let existingCredentialID: String?
        switch profile.auth {
        case .none:
            authMethod = .password
            privateKeyLabel = ""
            existingCredentialID = nil
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
            connectionMethod: HostConnectionMethodDraft(profile.connectionMethod),
            name: profile.name,
            host: profile.host,
            port: String(profile.port),
            username: profile.username,
            authMethod: authMethod,
            password: "",
            privateKeyLabel: privateKeyLabel,
            privateKey: "",
            existingCredentialID: existingCredentialID,
            relayServerEndpoint: profile.connectionMethod.relayHost?.relayEndpointURL.flatMap(Self.relayBaseURLString(from:)) ?? "",
            pairingMaterial: "",
            deviceDisplayName: "",
            codexPath: profile.codexPath,
            defaultDirectory: profile.defaultDirectory
        )
    }

    public var startupCommand: String {
        AppServerStartupCommand(codexPath: trimmed(codexPath)).shellCommand
    }

    public mutating func selectRelayConnection(defaultRelayEndpoint: String = "") {
        let endpoint = trimmed(relayServerEndpoint).isEmpty ? defaultRelayEndpoint : relayServerEndpoint
        relayServerEndpoint = endpoint
        connectionMethod = .relay(
            RelayHostDraft(
                hostAgentID: UUID(),
                displayName: trimmed(name).isEmpty ? "Mac HostAgent" : trimmed(name),
                userName: trimmed(username),
                pairingRecordID: "pending-pairing",
                presence: .offline(),
                diagnosticsSummary: "Pairing pending"
            )
        )
        authMethod = .password
        password = ""
        privateKey = ""
        privateKeyLabel = ""
        existingCredentialID = nil
        if port == "22" {
            port = ""
        }
    }

    public mutating func selectDirectSSHConnection() {
        connectionMethod = .directSSH
        relayServerEndpoint = ""
        pairingMaterial = ""
        deviceDisplayName = ""
        if trimmed(port).isEmpty {
            port = "22"
        }
    }

    @discardableResult
    public mutating func applyScannedPairingMaterial(_ material: String) -> Bool {
        let material = trimmed(material)
        guard !material.isEmpty else { return false }
        if material.contains("://") {
            guard material.hasPrefix("codexport://pair?") else { return false }
        }
        guard let scannedMaterial = try? RelayPairingScannedMaterial.parse(material) else {
            return false
        }
        pairingMaterial = scannedMaterial.pairingCode
        if trimmed(name).isEmpty, let hostDisplayName = scannedMaterial.hostDisplayName {
            name = hostDisplayName
        }
        return true
    }

    public func makeRelayPairingInput(defaultDeviceDisplayName: String) throws -> RelayHostProductionPairingInput {
        try RelayHostProductionPairingInput(
            pairingMaterial: pairingMaterial,
            deviceDisplayName: trimmed(deviceDisplayName).isEmpty ? defaultDeviceDisplayName : deviceDisplayName
        )
    }

    public func makeDraft() throws -> HostProfileDraft {
        let name = try required(self.name, field: "name")
        let codexPath = try required(self.codexPath, field: "codexPath")
        let defaultDirectory = try required(self.defaultDirectory, field: "defaultDirectory")
        let auth: HostProfileDraftAuth
        switch connectionMethod {
        case let .relay(relayHost):
            auth = .none
            let username = trimmed(self.username).isEmpty ? relayHost.userName : trimmed(self.username)
            return HostProfileDraft(
                connectionMethod: .relay(relayHost),
                name: name,
                host: relayHost.hostAgentID.uuidString.lowercased(),
                port: 443,
                username: username,
                auth: auth,
                codexPath: codexPath,
                startupCommand: "",
                defaultDirectory: defaultDirectory
            )
        case .directSSH:
            let host = try required(self.host, field: "host")
            let username = try required(self.username, field: "username")
            let port = try parsedPort()
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
                connectionMethod: connectionMethod,
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

    private static func relayBaseURLString(from relayEndpointURL: URL) -> String? {
        var components = URLComponents(url: relayEndpointURL, resolvingAgainstBaseURL: false)
        switch components?.scheme {
        case "wss":
            components?.scheme = "https"
        case "ws":
            components?.scheme = "http"
        default:
            break
        }
        components?.path = ""
        components?.query = nil
        components?.fragment = nil
        return components?.url?.absoluteString
    }
}

private extension HostConnectionMethodDraft {
    init(_ method: HostConnectionMethod) {
        switch method {
        case .directSSH:
            self = .directSSH
        case let .relay(host):
            self = .relay(
                RelayHostDraft(
                    hostAgentID: host.hostAgentID,
                    displayName: host.displayName,
                    userName: host.userName,
                    pairingRecordID: host.pairingRecordID,
                    deviceID: host.deviceID,
                    relayEndpointURL: host.relayEndpointURL,
                    presence: host.presence,
                    readiness: host.readiness,
                    diagnosticsSummary: host.diagnosticsSummary
                )
            )
        }
    }
}
