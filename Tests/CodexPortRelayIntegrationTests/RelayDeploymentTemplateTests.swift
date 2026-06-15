import Foundation
import Testing

@Test func relayDeploymentTemplatesDocumentDockerSystemdAndNoSecretOperatorConfig() throws {
    let root = URL(filePath: FileManager.default.currentDirectoryPath)
    let dockerfile = try String(contentsOf: root.appending(path: "deploy/codexport-relay/Dockerfile"), encoding: .utf8)
    let compose = try String(contentsOf: root.appending(path: "deploy/codexport-relay/docker-compose.yml"), encoding: .utf8)
    let env = try String(contentsOf: root.appending(path: "deploy/codexport-relay/.env.example"), encoding: .utf8)
    let service = try String(contentsOf: root.appending(path: "deploy/codexport-relay/codexport-relay.service"), encoding: .utf8)
    let nginx = try String(contentsOf: root.appending(path: "deploy/codexport-relay/nginx.conf.example"), encoding: .utf8)
    let guide = try String(contentsOf: root.appending(path: "docs/deployment/codexport-relay-vps.md"), encoding: .utf8)

    #expect(dockerfile.contains("swift build -c release --product codexport-relay"))
    #expect(dockerfile.contains("USER codexport"))
    #expect(dockerfile.contains("COPY Tests ./Tests"))
    #expect(dockerfile.contains("libcurl4"))
    #expect(compose.contains("container_name: codexport-relay"))
    #expect(compose.contains("codexport-relay-data:/var/lib/codexport-relay"))
    #expect(compose.contains("network: host"))
    #expect(env.contains("CODEXPORT_RELAY_PUBLIC_BASE_URL=https://codexport.smarteffi.net"))
    #expect(env.contains("CODEXPORT_RELAY_TLS_MODE=reverse-proxy"))
    #expect(service.contains("docker compose up -d --build"))
    #expect(service.contains("WorkingDirectory=/opt/codexport-relay/source/deploy/codexport-relay"))
    #expect(nginx.contains("proxy_pass http://127.0.0.1:8080"))
    #expect(nginx.contains("proxy_set_header Upgrade $http_upgrade"))
    #expect(nginx.contains("proxy_set_header Connection $codexport_relay_connection_upgrade"))
    #expect(guide.contains("sudo rsync -a --delete --exclude 'deploy/codexport-relay/.env' Package.swift Package.resolved Sources Tests deploy /opt/codexport-relay/source/"))
    #expect(guide.contains("Docker Compose plugin"))
    #expect(guide.contains("docker compose version"))
    #expect(!guide.contains("docker-run.sh"))
    #expect(guide.contains("nginx.conf.example"))
    #expect(guide.contains("/v0/host/connect"))
    #expect(guide.contains("/v0/streams"))
    #expect(guide.contains("/v0/pairing/consume"))

    let combined = [dockerfile, compose, env, service, nginx, guide].joined(separator: "\n")
    for forbidden in ["sk-", "BEGIN OPENSSH PRIVATE KEY", "pairing-token-secret", "ssh-rsa "] {
        #expect(!combined.contains(forbidden))
    }
}
