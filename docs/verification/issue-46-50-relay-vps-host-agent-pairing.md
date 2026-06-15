# Issue #46-50 Relay/VPS/Host Agent Pairing Verification

## Scope

This record covers implementation and verification for:

- #46 `0.2.x: CodexPort Relay VPS service MVP`
- #47 `0.2.x: Relay VPS deployment template and operator config`
- #48 `0.2.x: Host Agent production Relay endpoint config and outbound connect`
- #49 `0.2.x: iOS Relay server configuration and production pairing entry`
- #50 `0.2.x: Host Agent 菜单栏新建配对入口和二维码/复制密钥`

## Implemented

- Added `codexport-relay` SwiftPM executable product and `CodexPortRelayService` target.
- Added `RelayServiceConfiguration` for non-secret operator config:
  listen host, listen port, public base URL, storage path, log level, TLS mode.
- Added `RelayPublicWebSocketService`:
  - `/v0/host/connect` for outbound Host Agent WebSocket registration.
  - `/v0/streams` for iOS/device Relay stream attach.
  - `/healthz` HTTP health check.
  - `/v0/pairing/publish` and `/v0/pairing/consume` HTTP pairing metadata endpoints.
- Added Host Agent outbound connector and Relay configuration state:
  `HostAgentRelayConnector`, `HostAgentRelayConfiguration`,
  `HostAgentRelayConnectionState`.
- Added iOS production pairing input:
  `RelayHostProductionPairingInput` parses Relay endpoint plus manual code or
  `codexport://pair?token=...` QR material and builds Relay Host drafts through
  the existing pairing builder.
- Added iOS production pairing client:
  `RelayHostProductionPairingClient` consumes Relay pairing tokens at
  `/v0/pairing/consume` and creates Relay Host drafts from the response.
- Added Host Agent menu pairing view-state:
  `HostAgentMenuPairingCoordinator`, `HostAgentMenuPairingSnapshot`,
  `New Pairing`, QR payload, copyable pairing key, expiry/cancel states.
- Added macOS menu UI for `New Pairing`, QR image generation, and
  `Copy Pairing Key`.
- Added Host Agent pairing publish client:
  `HostAgentRelayPairingPublisher` posts token metadata to
  `/v0/pairing/publish` when Relay configuration is present. The published
  payload contains token id, host id, and expiry metadata only; the copyable
  manual code is not sent as log/diagnostic payload.
- Added Docker/VPS deployment templates:
  `deploy/codexport-relay/Dockerfile`,
  `deploy/codexport-relay/docker-compose.yml`,
  `deploy/codexport-relay/.env.example`,
  `deploy/codexport-relay/codexport-relay.service`,
  `deploy/codexport-relay/Caddyfile.example`,
  `deploy/codexport-relay/nginx.conf.example`,
  `docs/deployment/codexport-relay-vps.md`.

## Local Verification

Commands run:

```bash
swift test
swift build --product codexport-relay
swift build --product codexport-host-agent
swift build --product codexport-host-agent-menu
swift test --filter RelayDeploymentTemplateTests
```

Results:

- `swift test` passed with 207 tests.
- `swift build --product codexport-relay` passed.
- `swift build --product codexport-host-agent` passed.
- `swift build --product codexport-host-agent-menu` passed.
- Xcode iOS simulator build for `CodexPort` passed through XcodeBuildMCP.
- Linux Docker release build passed on Debian VPS after adding
  `FoundationNetworking` imports for Linux `URLRequest`/`URLSession` APIs.

Key new test coverage:

- `RelayServiceConfigurationTests`
- `RelayPublicServiceBridgeTests`
- `RelayServiceExecutableTests`
- `RelayPairingHTTPTests`
- `RelayDeploymentTemplateTests`
- `HostAgentRelayConfigurationTests`
- `HostAgentRelayPairingPublisherTests`
- `HostAgentMenuPairingTests`
- `RelayHostProductionPairingInputTests`
- `RelayHostProductionPairingClientTests`

Host Agent menu pairing flow now covers:

```text
menu bar icon -> New Pairing -> QR payload + Copy Pairing Key
```

When `CODEXPORT_RELAY_BASE_URL`, `CODEXPORT_RELAY_HOST_ID`,
`CODEXPORT_RELAY_HOST_NAME`, and `CODEXPORT_RELAY_HOST_USER` are available,
the menu action also publishes the generated token metadata to the Relay
pairing endpoint.

## VPS Verification Status

Target VPS provided by maintainer:

```text
ssh -p 35870 root@47.86.9.177
```

Deployment commands used:

```bash
ssh -p 35870 root@47.86.9.177 'mkdir -p /opt/codexport-relay/source'
rsync -az --delete -e 'ssh -p 35870' Package.swift Package.resolved Sources Tests deploy root@47.86.9.177:/opt/codexport-relay/source/
ssh -p 35870 root@47.86.9.177 'docker compose version || install Docker Compose plugin'
ssh -p 35870 root@47.86.9.177 'cd /opt/codexport-relay/source/deploy/codexport-relay; cp .env.example .env; docker compose down --remove-orphans || true; docker rm -f codexport-relay 2>/dev/null || true; docker compose up -d --build'
```

The `docker rm -f codexport-relay` command was a one-time migration cleanup for
the previous non-Compose container. The deploy path now uses `docker compose`
only and the synced `deploy/` directory no longer contains `docker-run.sh`.

Remote Docker environment:

```text
Docker version 20.10.24+dfsg1
Docker Compose version v5.1.4
docker-run.sh absent on VPS after rsync --delete
```

Container result:

```text
codexport-relay Up ... 0.0.0.0:8080->8080/tcp, [::]:8080->8080/tcp
com.docker.compose.project=codexport-relay
RestartPolicy=unless-stopped
Image=codexport-relay:0.2.x
Mounts=codexport-relay_codexport-relay-data:/var/lib/codexport-relay
```

VPS-local health check:

```text
curl -i http://127.0.0.1:8080/healthz
HTTP/1.1 200 OK
```

Because nginx already fronts port `80`, `/etc/nginx/conf.d/codexport-relay.conf`
proxies `/healthz` and `/v0/*` to `127.0.0.1:8080` with WebSocket upgrade
headers. The active smoke endpoint is therefore `https://codexport.smarteffi.net`, matching
`CODEXPORT_RELAY_PUBLIC_BASE_URL` in `.env`.

Public nginx-fronted health check:

```text
curl -i https://codexport.smarteffi.net/healthz
HTTP/1.1 200 OK
Server: nginx/1.22.1
```

Log no-secret check:

```text
docker logs codexport-relay --tail=200
NO_SECRET_CHECK_PASSED
```

The log scan checked for prompt plaintext, assistant output, command output,
pairing secret, API key patterns, SSH key material, Codex token, and ChatGPT
token markers.

## Closure Result

#46-50 are closed. The follow-up Compose-only deployment also passes: local
tests/builds pass, Linux Docker build passes through `docker compose up -d
--build`, Relay container is running on the VPS with restart policy and
persistent Compose volume, and public nginx-fronted `/healthz` returns
`HTTP/1.1 200 OK`.
