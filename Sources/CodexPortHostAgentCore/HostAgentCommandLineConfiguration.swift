import Foundation
import CodexPortShared

public enum HostAgentCommandLineMode: Equatable, Sendable {
    case manifest
    case listIdleThreadsJSON(limit: Int)
    case localRelayJSONL
    case localRelayWebSocket(port: Int)
    case relayConnect
    case p2pListen
}

public enum HostAgentCommandLineConfigurationError: Error, Equatable, Sendable {
    case invalidArgumentsJSON
    case missingRelaySeed(String)
    case invalidRelaySeedUUID(String)
    case invalidPort(String)
    case invalidLimit(String)
    case invalidRelayDevicesJSON
    case invalidBackend(String)
    case invalidTimeout(String)
    case missingRelayBaseURL
}

public struct HostAgentLocalRelaySeed: Equatable, Sendable {
    public var host: RelayHostIdentity
    public var devices: [DeviceIdentity]

    public init(host: RelayHostIdentity, device: DeviceIdentity) {
        self.init(host: host, devices: [device])
    }

    public init(host: RelayHostIdentity, devices: [DeviceIdentity]) {
        self.host = host
        self.devices = devices
    }

    public var device: DeviceIdentity {
        devices[0]
    }
}

public struct HostAgentCommandLineConfiguration: Sendable {
    public var mode: HostAgentCommandLineMode
    public var commandFactory: HostAgentLocalRelayRuntime.CommandFactory
    public var adapterFactory: HostAgentLocalRelayRuntime.AdapterFactory
    public var localRelaySeed: HostAgentLocalRelaySeed?
    public var relayConfiguration: HostAgentRelayConfiguration?
    public var backend: HostAgentRuntimeBackend
    public var codexExecTimeout: Duration
    public var codexControlSocketPath: String
    public var webRTCSidecarCommand: HostAgentProcessCommand?

    public init(
        arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws {
        let backend = try Self.parseBackend(environment["CODEXPORT_HOST_AGENT_BACKEND"])
        let codexExecTimeout = try Self.parseCodexExecTimeout(environment["CODEXPORT_CODEX_EXEC_TIMEOUT_SECONDS"])
        let codexControlSocketPath = Self.parseCodexControlSocketPath(environment["CODEXPORT_CODEX_CONTROL_SOCKET_PATH"])
        let webRTCSidecarCommand = try Self.parseWebRTCSidecarCommand(environment)
        self.backend = backend
        self.codexExecTimeout = codexExecTimeout
        self.codexControlSocketPath = codexControlSocketPath
        self.webRTCSidecarCommand = webRTCSidecarCommand
        if arguments.contains("--list-idle-threads-json") {
            self.mode = .listIdleThreadsJSON(limit: try Self.parseLimit(arguments, defaultValue: 20))
            self.localRelaySeed = nil
            self.relayConfiguration = nil
        } else if arguments.contains("--local-relay-jsonl") {
            self.mode = .localRelayJSONL
            self.localRelaySeed = nil
            self.relayConfiguration = nil
        } else if arguments.contains("--local-relay-websocket") {
            self.mode = .localRelayWebSocket(port: try Self.parsePort(arguments))
            self.localRelaySeed = try Self.parseLocalRelaySeed(environment)
            self.relayConfiguration = nil
        } else if arguments.contains("--relay-connect") {
            self.mode = .relayConnect
            self.localRelaySeed = nil
            self.relayConfiguration = try Self.parseRelayConfiguration(environment)
        } else if arguments.contains("--p2p-listen") {
            self.mode = .p2pListen
            self.localRelaySeed = nil
            self.relayConfiguration = try Self.parseRelayConfiguration(environment)
        } else {
            self.mode = .manifest
            self.localRelaySeed = nil
            self.relayConfiguration = nil
        }
        let executablePath = HostAgentCodexCommandResolver.executablePath(
            explicitCommand: environment["CODEXPORT_HOST_AGENT_COMMAND"],
            environment: environment
        )
        let parsedArguments = try Self.parseArgumentsJSON(environment["CODEXPORT_HOST_AGENT_ARGUMENTS_JSON"])
        let codexExecBaseArguments = try Self.parseArgumentsJSON(environment["CODEXPORT_CODEX_EXEC_ARGUMENTS_JSON"])
        let codexExecResumeArguments = try Self.parseArgumentsJSON(environment["CODEXPORT_CODEX_EXEC_RESUME_ARGUMENTS_JSON"])
        self.commandFactory = { request in
            HostAgentProcessCommand(executablePath: executablePath, arguments: parsedArguments, workingDirectory: request.cwd)
        }
        self.adapterFactory = HostAgentRuntimeAdapterFactory.make(configuration: HostAgentRuntimeAdapterFactoryConfiguration(
            backend: backend,
            executablePath: executablePath,
            processArguments: parsedArguments,
            codexExecBaseArguments: codexExecBaseArguments,
            codexExecResumeArguments: codexExecResumeArguments,
            codexExecTimeout: codexExecTimeout,
            codexControlSocketPath: codexControlSocketPath
        ))
    }

    private static func parseRelayConfiguration(_ environment: [String: String]) throws -> HostAgentRelayConfiguration {
        let relayBaseURL: URL
        if let rawBaseURL = environment["CODEXPORT_RELAY_BASE_URL"], !rawBaseURL.isEmpty {
            guard let overrideURL = URL(string: rawBaseURL) else {
                throw HostAgentCommandLineConfigurationError.missingRelayBaseURL
            }
            relayBaseURL = overrideURL
        } else {
            relayBaseURL = HostAgentRelayConfiguration.productionRelayBaseURL
        }
        let host = RelayHostIdentity(
            id: try uuid("CODEXPORT_RELAY_HOST_ID", environment: environment),
            displayName: try hostDisplayName("CODEXPORT_RELAY_HOST_NAME", environment: environment),
            userName: try string("CODEXPORT_RELAY_HOST_USER", environment: environment),
            publicKey: EndpointPublicKey(rawValue: Data("host-agent-public-key".utf8))
        )
        return try HostAgentRelayConfiguration(relayBaseURL: relayBaseURL, host: host)
    }

    private static func parseBackend(_ rawValue: String?) throws -> HostAgentRuntimeBackend {
        do {
            return try HostAgentRuntimeBackend.parse(rawValue)
        } catch let HostAgentRuntimeBackendError.invalidBackend(rawValue) {
            throw HostAgentCommandLineConfigurationError.invalidBackend(rawValue)
        } catch {
            throw error
        }
    }

    private static func parseCodexControlSocketPath(_ rawValue: String?) -> String {
        if let rawValue, !rawValue.isEmpty {
            return rawValue
        }
        return "\(FileManager.default.homeDirectoryForCurrentUser.path)/.codex/app-server-control/app-server-control.sock"
    }

    private static func parseWebRTCSidecarCommand(_ environment: [String: String]) throws -> HostAgentProcessCommand? {
        guard let executablePath = environment["CODEXPORT_WEBRTC_SIDECAR_PATH"], !executablePath.isEmpty else {
            return nil
        }
        return HostAgentProcessCommand(
            executablePath: executablePath,
            arguments: try parseArgumentsJSON(environment["CODEXPORT_WEBRTC_SIDECAR_ARGUMENTS_JSON"])
        )
    }

    private static func parseArgumentsJSON(_ rawValue: String?) throws -> [String] {
        guard let rawValue, !rawValue.isEmpty else {
            return []
        }
        guard let data = rawValue.data(using: .utf8),
              let arguments = try JSONSerialization.jsonObject(with: data) as? [String] else {
            throw HostAgentCommandLineConfigurationError.invalidArgumentsJSON
        }
        return arguments
    }

    private static func parseCodexExecTimeout(_ rawValue: String?) throws -> Duration {
        guard let rawValue, !rawValue.isEmpty else {
            return .seconds(120)
        }
        guard let seconds = Double(rawValue), seconds > 0 else {
            throw HostAgentCommandLineConfigurationError.invalidTimeout(rawValue)
        }
        return .milliseconds(Int64(seconds * 1_000))
    }

    private static func parsePort(_ arguments: [String]) throws -> Int {
        guard let index = arguments.firstIndex(of: "--port"),
              arguments.indices.contains(arguments.index(after: index))
        else {
            return 0
        }
        let rawValue = arguments[arguments.index(after: index)]
        guard let port = Int(rawValue), port >= 0, port <= 65_535 else {
            throw HostAgentCommandLineConfigurationError.invalidPort(rawValue)
        }
        return port
    }

    private static func parseLimit(_ arguments: [String], defaultValue: Int) throws -> Int {
        guard let index = arguments.firstIndex(of: "--limit"),
              arguments.indices.contains(arguments.index(after: index))
        else {
            return defaultValue
        }
        let rawValue = arguments[arguments.index(after: index)]
        guard let limit = Int(rawValue), limit > 0 else {
            throw HostAgentCommandLineConfigurationError.invalidLimit(rawValue)
        }
        return limit
    }

    private static func parseLocalRelaySeed(_ environment: [String: String]) throws -> HostAgentLocalRelaySeed {
        let hostID = try uuid("CODEXPORT_RELAY_HOST_ID", environment: environment)
        let host = RelayHostIdentity(
            id: hostID,
            displayName: try hostDisplayName("CODEXPORT_RELAY_HOST_NAME", environment: environment),
            userName: try string("CODEXPORT_RELAY_HOST_USER", environment: environment),
            publicKey: EndpointPublicKey(rawValue: Data("local-relay-host-public-key".utf8))
        )
        return HostAgentLocalRelaySeed(host: host, devices: try parseLocalRelayDevices(environment))
    }

    private static func parseLocalRelayDevices(_ environment: [String: String]) throws -> [DeviceIdentity] {
        if let rawDevices = environment["CODEXPORT_RELAY_DEVICES_JSON"], !rawDevices.isEmpty {
            return try parseDevicesJSON(rawDevices)
        }
        let deviceID = try uuid("CODEXPORT_RELAY_DEVICE_ID", environment: environment)
        return [
            localRelayDevice(
                id: deviceID,
                displayName: try string("CODEXPORT_RELAY_DEVICE_NAME", environment: environment)
            ),
        ]
    }

    private static func parseDevicesJSON(_ rawValue: String) throws -> [DeviceIdentity] {
        guard let data = rawValue.data(using: .utf8),
              let objects = try JSONSerialization.jsonObject(with: data) as? [[String: String]]
        else {
            throw HostAgentCommandLineConfigurationError.invalidRelayDevicesJSON
        }
        let devices = try objects.map { object in
            guard let rawID = object["id"], let id = UUID(uuidString: rawID) else {
                throw HostAgentCommandLineConfigurationError.invalidRelaySeedUUID("CODEXPORT_RELAY_DEVICES_JSON.id")
            }
            guard let name = object["name"], !name.isEmpty else {
                throw HostAgentCommandLineConfigurationError.missingRelaySeed("CODEXPORT_RELAY_DEVICES_JSON.name")
            }
            return localRelayDevice(id: id, displayName: name)
        }
        guard !devices.isEmpty else {
            throw HostAgentCommandLineConfigurationError.missingRelaySeed("CODEXPORT_RELAY_DEVICES_JSON")
        }
        return devices
    }

    private static func localRelayDevice(id: UUID, displayName: String) -> DeviceIdentity {
        DeviceIdentity(
            id: id,
            displayName: displayName,
            kind: .iOSClient,
            publicKey: EndpointPublicKey(rawValue: Data("local-relay-device-\(id.uuidString)-public-key".utf8))
        )
    }

    private static func string(_ key: String, environment: [String: String]) throws -> String {
        guard let value = environment[key], !value.isEmpty else {
            throw HostAgentCommandLineConfigurationError.missingRelaySeed(key)
        }
        return value
    }

    private static func hostDisplayName(_ key: String, environment: [String: String]) throws -> String {
        guard let value = HostAgentHostDisplayName.nonSynthetic(environment[key]) else {
            throw HostAgentCommandLineConfigurationError.missingRelaySeed(key)
        }
        return value
    }

    private static func uuid(_ key: String, environment: [String: String]) throws -> UUID {
        let value = try string(key, environment: environment)
        guard let uuid = UUID(uuidString: value) else {
            throw HostAgentCommandLineConfigurationError.invalidRelaySeedUUID(key)
        }
        return uuid
    }
}
