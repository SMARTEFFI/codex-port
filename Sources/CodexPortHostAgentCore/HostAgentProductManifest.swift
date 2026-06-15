import CodexPortShared

public struct HostAgentProductManifest: Equatable, Sendable {
    public enum Platform: Equatable, Sendable {
        case macOS
    }

    public enum Dependency: Equatable, Sendable {
        case sharedContracts
    }

    public var productName: String
    public var platform: Platform
    public var sharedContractVersion: RelayProtocolVersion
    public var dependencies: [Dependency]

    public init(
        productName: String,
        platform: Platform,
        sharedContractVersion: RelayProtocolVersion,
        dependencies: [Dependency]
    ) {
        self.productName = productName
        self.platform = platform
        self.sharedContractVersion = sharedContractVersion
        self.dependencies = dependencies
    }

    public static let `default` = HostAgentProductManifest(
        productName: "CodexPort Host Agent",
        platform: .macOS,
        sharedContractVersion: RelayProtocolVersion(major: 0, minor: 2, patch: 0),
        dependencies: [.sharedContracts]
    )
}
