# Issue #92 TURN Smoke Runbook

本文档记录 VPS 上 `coturn` 的基础 smoke 验证步骤。命令只输出状态和连接计数，不打印 TURN shared secret、短期 username 或 credential。

## Service And Listener

```bash
ssh -p 35870 root@47.86.9.177 '
set -eu
systemctl is-enabled coturn
systemctl is-active coturn
ss -lntup | awk "/:3478/ {print \$1,\$5,\$7}"
grep -E "^(listening-port|external-ip|realm|server-name|use-auth-secret|lt-cred-mech|fingerprint|no-multicast-peers|min-port|max-port)" /etc/turnserver.conf
'
```

Expected:

- `coturn` is `enabled` and `active`.
- UDP and TCP listeners exist on `0.0.0.0:3478`.
- `min-port=49152` and `max-port=49252` are configured.

## Relay Health

```bash
curl -fsS --max-time 10 -D - https://codexport.smarteffi.net/healthz
```

Expected: `HTTP/1.1 200 OK`.

## STUN Binding

```bash
ssh -p 35870 root@47.86.9.177 '
set -eu
turnutils_stunclient -p 3478 127.0.0.1 >/tmp/codexport-stun.out
echo STUN_BINDING=PASS
'
```

## TURN Allocation And Connectivity

```bash
ssh -p 35870 root@47.86.9.177 '
set -eu
secret=$(cat /etc/codexport/turnserver.secret)
peer_addr=172.23.54.175
peer_log=/tmp/codexport-turn-peer.log
rm -f "$peer_log"
timeout 20s turnutils_peer -L "$peer_addr" -p 3480 >"$peer_log" 2>&1 &
peer_pid=$!
sleep 1
set +e
output=$(timeout 15s turnutils_uclient -n 2 -m 1 -p 3478 -W "$secret" -e "$peer_addr" -r 3480 "$peer_addr" 2>&1)
status=$?
set -e
kill "$peer_pid" >/dev/null 2>&1 || true
printf "TURN_PRIVATE_PEER_TIMEOUT_STATUS=%s\n" "$status"
printf "%s\n" "$output" | sed -n "1,60p"
'
```

Expected:

- `TURN_PRIVATE_PEER_TIMEOUT_STATUS=0`.
- `tot_send_msgs` equals `tot_recv_msgs`.
- `Total lost packets 0`.

## Log Redaction Check

```bash
ssh -p 35870 root@47.86.9.177 '
tail -n 50 /var/log/turnserver/turnserver.log
'
```

Expected: connection and service metadata only. Logs must not contain prompt text, assistant output, command output, diffs, approval payloads, `Client-Host Session Protocol` JSONL, the long-term TURN shared secret, or full short-lived TURN credentials.

Note: `turnserver.conf` currently declares `tls-listening-port=5349`, but TLS/DTLS listeners are not active because coturn has no certificate/private key configured. The production WebRTC config uses UDP/TCP TURN on `3478`.
