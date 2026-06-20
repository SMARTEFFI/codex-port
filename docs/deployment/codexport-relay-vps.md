# CodexPort Relay VPS Deployment

## Scope

This guide deploys the `codexport-relay` service component for `Relay Connection`.
It is not a third user-facing app project. iOS and macOS Host Agent both connect
outbound to this service.

## VPS Requirements

- Linux VPS with Docker and the Docker Compose plugin (`docker compose`).
- Open TCP port `80`/`443` when using a reverse proxy. Direct `8080` smoke tests
  are optional and only work if the VPS network/security policy exposes it.
- Install path: `/opt/codexport-relay/source`.
- Runtime user inside the container: `codexport`.
- Persistent data volume: `codexport-relay-data`, mounted at `/var/lib/codexport-relay`.

If `docker compose version` is unavailable, install the Compose plugin before
deployment. On Debian/Ubuntu hosts where `docker-compose-plugin` is not present
in apt, install the Docker CLI plugin binary:

```bash
sudo mkdir -p /usr/local/lib/docker/cli-plugins
COMPOSE_VERSION="$(curl -fsSL https://api.github.com/repos/docker/compose/releases/latest | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1)"
sudo curl -fL "https://github.com/docker/compose/releases/download/${COMPOSE_VERSION}/docker-compose-linux-x86_64" -o /usr/local/lib/docker/cli-plugins/docker-compose
sudo chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
docker compose version
```

## Install With Docker

```bash
sudo mkdir -p /opt/codexport-relay/source
sudo rsync -a --delete --exclude 'deploy/codexport-relay/.env' Package.swift Package.resolved Sources Tests deploy /opt/codexport-relay/source/
cd /opt/codexport-relay/source/deploy/codexport-relay
sudo cp .env.example .env
sudo docker compose up -d --build
```

For production with the CodexPort Relay domain and TLS termination, set:

```env
CODEXPORT_RELAY_PUBLIC_BASE_URL=https://codexport.smarteffi.net
CODEXPORT_RELAY_TLS_MODE=reverse-proxy
```

For P2P `TURN relay fallback`, the Relay service must also be able to issue
short-lived TURN credentials. Set `CODEXPORT_RELAY_TURN_SHARED_SECRET` in the
Relay `.env` to the same value as coturn `static-auth-secret`. Do not commit or
print the production value.

```env
CODEXPORT_RELAY_TURN_SHARED_SECRET=<same value as coturn static-auth-secret>
```

When this value is missing, `/v0/p2p/ice-config` intentionally returns an empty
ICE server list; iOS/HostAgent then only have their local STUN fallback and TURN
cannot work.

## systemd Template

Install `deploy/codexport-relay/codexport-relay.service` at:

```bash
sudo cp codexport-relay.service /etc/systemd/system/codexport-relay.service
sudo systemctl daemon-reload
sudo systemctl enable --now codexport-relay
```

The service runs `docker compose up -d --build` in
`/opt/codexport-relay/source/deploy/codexport-relay` and `docker compose down`
on stop. The compose build context intentionally points back to the repository
root so the Swift package sources are available to the Docker build.

## Reverse Proxy

If this VPS already has nginx on port `80`/`443`, use
`deploy/codexport-relay/nginx.conf.example` as the reverse-proxy shape. It
includes WebSocket upgrade headers required by `/v0/host/connect` and
`/v0/streams`. The same proxy also forwards normal HTTP endpoints such as
pairing and P2P signaling under `/v0/pairing/...` and `/v0/p2p/...`.

```bash
sudo cp nginx.conf.example /etc/nginx/conf.d/codexport-relay.conf
sudo nginx -t
sudo systemctl reload nginx
```

For TLS automation on a clean host, Caddy is also suitable:

```bash
sudo apt-get install -y caddy
sudo cp Caddyfile.example /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

`Caddyfile.example` proxies `codexport.smarteffi.net` to `127.0.0.1:8080` and lets
Caddy manage certificate issuance/renewal.

## Endpoint Configuration

- Host Agent Relay base URL: `https://codexport.smarteffi.net`.
- Host Agent outbound WebSocket endpoint derived from base URL:
  `/v0/host/connect`.
- iOS Relay stream endpoint derived from base URL:
  `/v0/streams`.
- iOS pairing consume endpoint derived from base URL:
  `/v0/pairing/consume`.
- P2P signaling endpoints derived from base URL:
  `/v0/p2p/hosts/{hostID}/presence`,
  `/v0/p2p/hosts/{hostID}/messages`,
  `/v0/p2p/sessions/open`,
  `/v0/p2p/sessions/{sessionID}/messages/send`, and
  `/v0/p2p/sessions/{sessionID}/messages?endpoint=host|device`.

The P2P signaling surface only carries presence, authorization, WebRTC
offer/answer, and ICE candidate exchange. It does not carry `Client-Host Session
Protocol` payload. Real WebRTC DataChannel runtime wiring in iOS and HostAgent
is still required before #74 can be closed.

The `CODEXPORT_IOS_RELAY_*` launch seed remains AFK/local verification only.
It must not be treated as production pairing authority.

## Smoke Checklist

```bash
curl -i https://codexport.smarteffi.net/healthz
sudo docker compose ps
sudo docker logs codexport-relay --tail=100
```

Expected:

- Reverse-proxied `/healthz` returns `HTTP/1.1 200 OK` when nginx/Caddy fronts
  the service on `80`/`443`.
- `codexport-relay` container is running.
- Logs show listen/public endpoints only.
- Logs do not contain prompt plaintext, assistant output, command output,
  pairing secret, API key, SSH key, Codex token, or ChatGPT token.

## Clean Uninstall

```bash
cd /opt/codexport-relay/source/deploy/codexport-relay
sudo docker compose down -v --rmi local
sudo systemctl disable --now codexport-relay 2>/dev/null || true
sudo rm -f /etc/systemd/system/codexport-relay.service
sudo systemctl daemon-reload
sudo rm -rf /opt/codexport-relay
```
