# Issue #74 P2P E2E gated verification record

日期：2026-06-14 08:05:59Z

## 结论

Blocked for true HITL close.

AFK prerequisites for the P2P-first path pass, but #74 explicitly requires real
Mac HostAgent + real iPhoneA + real iPhoneB + Codex live source verification.
During this run the Mac was visible, but all physical iPhones reported by
`xcrun xctrace list devices` were Offline. Available iOS targets were simulators
only. Because of that, this record does not claim the real-device acceptance
criteria are passed.

Update after #75/#80 triage: persisted transcript visibility is not sufficient.
The HITL close condition now requires proof that an already-open Codex TUI
session updates without leaving and reopening the thread. Codex Desktop is not
part of the live-sync gate because it only showed the new turn after
exit/reopen in #80. The iOS side must also show prompt progress immediately after write acceptance
(`正在思考...` / working state) and must stream intermediate command/file/tool
events before the final assistant response where the Codex live source emits
those events.

Update after production signaling slice: `codexport-relay` now exposes a first
production P2P signaling HTTP surface for presence, session open, and WebRTC
offer/answer/ICE candidate mailbox exchange. The shared Core client builds the
matching URLs and payloads. This removes the earlier in-memory-only signaling
gap, but does not close #74: real WebRTC runtime integration, iOS/HostAgent
route selection, and TUI + iPhoneA + iPhoneB HITL evidence remain pending.

Update after P2P route seam slice: Core now has `RelayP2PSessionTransportFactory`
and `RelayDeferredJSONLTransport`. This proves production signaling can be
wrapped as the existing `RelayJSONLTransport` abstraction and can pass through
`RelaySessionRouteBuilder` / `RelayJSONLSessionClient` session attach. This is
the intended iOS route seam for future real WebRTC runtime wiring. It still does
not provide a real WebRTC implementation or physical-device HITL evidence.

Update after route-selection guard slice: Core now has
`RelayConnectionTransportFactory`. The default route remains legacy WebSocket
JSONL; explicit `p2pWebRTCDataChannel` route selection returns the deferred P2P
transport and requires an injected production `RelayP2PDataChannelFactory`.
`UnavailableRelayP2PDataChannelFactory` fails with a diagnostic row when no real
WebRTC runtime is linked. This prevents fake/in-memory DataChannel transports
from becoming the product path.

Update after HostAgent DataChannel endpoint seam slice: HostAgentCore now has
`HostAgentP2PDataChannelEndpoint`. It receives newline-delimited JSONL frames
from a shared `WebRTCDataChannelTransport`, routes them through
`HostAgentLocalRelayService`, and writes thread list/history/write status/live
event responses back over the same DataChannel. This proves the HostAgent
application protocol seam can sit behind a real DataChannel without depending on
iOS/Core targets. It still does not provide a real HostAgent WebRTC runtime,
signaling listener, TURN/STUN configuration, or physical-device HITL evidence.

Update after HostAgent P2P signaling listener seam slice: Relay now exposes
host-wide P2P message draining at `/v0/p2p/hosts/{hostID}/messages`, returning
session metadata with each offer so a HostAgent can discover newly opened P2P
sessions. HostAgentCore now has `HostAgentP2PSignalingClient`,
`HostAgentP2PSignalingListener`, `HostAgentP2PDataChannelAccepting`, and an
explicit `--p2p-listen` executable mode. The listener can drain offers, send
answer/ICE, and start `HostAgentP2PDataChannelEndpoint`. The current product
guard is `UnavailableHostAgentP2PDataChannelAcceptor`, which reports that the
real HostAgent WebRTC runtime is not linked. This still does not close #74:
real WebRTC acceptor/runtime, TURN/STUN configuration, iOS route enablement, and
physical-device HITL evidence remain pending.

Update after explicit route/listener enablement slice: iOS can now select the
P2P route through `CODEXPORT_IOS_RELAY_TRANSPORT_MODE=p2p-webrtc-datachannel`;
the default remains legacy WebSocket JSONL. HostAgent menu can enable the P2P
listener path through `CODEXPORT_HOST_AGENT_P2P_LISTEN=1`; the default remains
the legacy relay bridge connector. Both explicit paths still hit
unavailable-runtime guards until real WebRTC DataChannel implementations are
linked.

Update after WebRTC runtime adapter seam slice: `CodexPortWebRTC` now defines
the platform WebRTC runtime contract, STUN/TURN ICE server configuration, and
JSON signaling payload codec for SDP offer/answer plus ICE candidates.
`RelayWebRTCDataChannelFactory` is now the default explicit iOS P2P route
opener and performs offer/local-ICE send plus answer/remote-ICE drain before
returning the DataChannel. `HostAgentWebRTCDataChannelAcceptor` is now the
HostAgent listener acceptor used by the CLI/menu P2P listener path. The default
platform runtime is still unavailable until a real WebRTC SDK adapter is linked;
continuous trickle ICE, TURN credential provisioning, and physical-device HITL
remain pending.

Update after conditional WebRTC SDK adapter slice: `WebRTCSDKRuntime` now exists
behind `(os(iOS) || targetEnvironment(macCatalyst)) && canImport(WebRTC)` and
implements the platform adapter shape for `RTCPeerConnection`, reliable ordered
`RTCDataChannel`, SDP conversion, ICE candidate conversion, incoming DataChannel
messages, and basic state updates. `DefaultWebRTCPlatformDataChannelRuntime`
will use `WebRTCSDKRuntime` on iOS/Catalyst when the `WebRTC` module is linked,
and otherwise keeps the unavailable-runtime guard. This still does not close
#74.

Update after ICE configuration and trickle signaling slice: iOS/Core and
HostAgent P2P paths now read `WebRTCRuntimeConfiguration` from
`CODEXPORT_WEBRTC_ICE_SERVERS_JSON` or the split variables
`CODEXPORT_WEBRTC_STUN_URLS`, `CODEXPORT_WEBRTC_TURN_URLS`,
`CODEXPORT_WEBRTC_TURN_USERNAME`, and `CODEXPORT_WEBRTC_TURN_CREDENTIAL`.
`String(describing:)` redacts TURN credentials. `RelayWebRTCDataChannelFactory`
and `HostAgentP2PSignalingListener` now forward post-offer/post-answer local ICE
candidates through the Relay signaling mailbox and apply remote follow-up ICE to
the active DataChannel runtime. Focused regression for this slice passed 81
tests. This still does not close #74 because the real WebRTC SDK package is not
available for native macOS HostAgent and physical iPhoneA + iPhoneB + open TUI
HITL evidence is still pending.

Update after WebRTC SDK package verification: `Package.swift` now pins
`stasel/WebRTC` `148.0.0` for iOS/Catalyst and keeps `WebRTCSDKRuntime` behind
`(os(iOS) || targetEnvironment(macCatalyst)) && canImport(WebRTC)`. The
`149.0.0` release asset downloaded from GitHub has checksum
`79c5a3e49a68de30a99baabaf5b4c0067dd7a0b66fdd4b8afb8ec337e746abba`, which does
not match the upstream manifest checksum; `148.0.0` and `147.0.0` match their
upstream manifests. Local verification of the `148.0.0` artifact showed its
native macOS slice exposes only the umbrella `WebRTC.h` public header while that
header imports additional headers such as `WebRTC/RTCAudioSource.h`, so the same
SDK package cannot currently be treated as a native macOS HostAgent runtime.
HostAgent still needs a macOS-compatible WebRTC adapter or sidecar.
`Package.resolved` now pins `webrtc` `148.0.0` at revision
`7b7272aa4c2ebb597eaf0bf4f81ec19b6a0a44a3`; `swift build --target
CodexPortWebRTC`, `swift build --product codexport-host-agent-menu`, and the
focused 81-test regression pass with this pin.

Update after iOS compile/run verification: after fixing the public default
factory access level and explicit `CheckedContinuation<Void, Error>` typing in
`WebRTCSDKRuntime`, Xcode simulator build/install/launch passed for scheme
`CodexPort` on `iPhone 17`; launched bundle id `com.smarteffi.codexport`, process
`77325`. The app opened to the Host list empty state.

Update after HostAgent menu restart diagnosis: launching
`.scratch/apps/CodexPort Host Agent.app` originally exited immediately because
the generated app bundle had an incomplete ad-hoc signature: `Info.plist` was
not bound and `codesign --verify --deep --strict` reported a resource sealing
failure. `scripts/build-host-agent-app.sh` now signs the completed `.app` bundle
after writing `Info.plist`. Verification now passes `codesign --verify --deep
--strict`, and `open -n ".scratch/apps/CodexPort Host Agent.app"` leaves
`codexport-host-agent-menu` resident; observed PID `21228` during this run.

Update after native macOS WebRTC probe: a scratch package copied the `148.0.0`
xcframework, patched the native macOS slice with the complete Mac Catalyst
headers, and temporarily compiled `WebRTCSDKRuntime` for macOS. The compile still
failed because the imported umbrella headers reference iOS-only APIs such as
`AVAudioSession`, `AVAudioSessionRouteDescription`, `UIView`, and
`UIKit/UIKit.h`, which are unavailable on native macOS. This proves the selected
`stasel/WebRTC` package is not merely missing macOS headers; it is not a viable
direct native HostAgent runtime without a custom module surface or different
SDK. The next implementation decision is therefore a macOS-compatible WebRTC
runtime/sidecar, not simply enabling `WebRTCSDKRuntime` on macOS.

Update after HostAgent WebRTC sidecar packaging slice: HostAgentCore now has a
production-side `HostAgentWebRTCSidecarAcceptor` and JSONL IPC contract for a
Mac Catalyst WebRTC helper. The HostAgent sends `accept`, `remoteICE`, and
`dataChannelSend` messages to the sidecar; the sidecar returns `accepted`,
`localICE`, `dataChannelMessage`, `dataChannelState`, and `error` messages.
`CODEXPORT_WEBRTC_SIDECAR_PATH` and `CODEXPORT_WEBRTC_SIDECAR_ARGUMENTS_JSON`
select this sidecar acceptor for both `codexport-host-agent --p2p-listen` and
the menu app listener. `scripts/build-webrtc-sidecar.sh` builds
`.scratch/webrtc-sidecar/codexport-webrtc-sidecar`, copies `WebRTC.framework`,
rewrites the helper rpath to `@executable_path/PackageFrameworks`, and ad-hoc
signs it for local HITL. Without the sidecar path, HostAgent keeps the existing
platform SDK acceptor/unavailable guard.

Production Relay smoke with a deliberately invalid SDP offer now proves the
HostAgent receives host-wide P2P offers and delegates accept to the sidecar:
the failure is `org.webrtc.RTCPeerConnection` `SessionDescription is NULL`, not
the old `runtimeUnavailable` guard. This still does not close #74: TURN/STUN
provisioning, real iPhoneA/iPhoneB SDP/ICE, DataChannel open, and already-open
TUI HITL remain pending.

Update after production HostAgent producer selection: the default HostAgent
runtime backend is now `codex-cli-live`, not `codex-exec-json`. Manual runs can
still set `CODEXPORT_HOST_AGENT_BACKEND=codex-cli-live` for auditability, but no
override is required for the TUI live-sync gate. The old `codex-exec-json` and
`process-stdio` backends are explicit fallback/fixture paths only.

Update after full build verification on 2026-06-15: `swift test --no-parallel`
passed 363 tests. Focused P2P/HostAgent sidecar/live regression passed 52 tests.
`swift build --product codexport-host-agent-menu`, `swift build --product
codexport-host-agent`, and `swift build --build-tests` passed. Xcode simulator
build/install/launch also passed for `CodexPort.app` on iPhone 17, bundle id
`com.smarteffi.codexport`, process `19297`. The temporary `.scratch/apps`
HostAgent wrapper remains a packaging/signing convenience only; until a signed
macOS app target exists, use the SwiftPM CLI product as the authoritative
HostAgent start path for HITL.

Update after production simulator P2P smoke on 2026-06-15:

- iPhoneA simulator (`CCCCCCCC-DDDD-EEEE-FFFF-000000000001`) connected to the
  production Relay using `CODEXPORT_IOS_RELAY_TRANSPORT_MODE=p2p-webrtc-datachannel`.
  HostAgent logs showed `offerReceived`, `dataChannelAccepted`, `attach`, a
  prompt write, and `queued` / `running` write status for
  `afk-autoprompt-4B6B78DA-CC85-4A1C-818B-62E98CE3B5F2`.
- The `SIM-P2P-LIVE-060405` marker arrived in the currently running Codex
  session as a user message. This proves the simulator P2P path can inject a
  prompt through production Relay signaling, real WebRTC DataChannel,
  HostAgent, and the Codex app-server control-socket producer into an active
  Codex session. Prompt plaintext is intentionally absent from HostAgent
  diagnostics; the structured log evidence remains command/write/status
  metadata only.
- iPhoneB simulator (`DDDDDDDD-EEEE-FFFF-0000-000000000002`) was paired through
  the production `/v0/pairing/publish` + `/v0/pairing/consume` HTTP contract.
  Production presence returned `authorizedToSignal` with pairing record
  `pairing-11111111-2222-3333-4444-555555555555-DDDDDDDD-EEEE-FFFF-0000-000000000002`.
- iPhoneB then connected through the same production Relay and HostAgent sidecar
  path. HostAgent logs showed `offerReceived`, `dataChannelAccepted`,
  repeated `listThreads`, `attach` to thread
  `019ec4d2-43bc-7150-bd0f-b28161539d66`, `threadHistoryPage`, and streamed
  live `event` output back to the iPhoneB client id.
- This is a simulator two-client P2P connectivity pass, not a #74 close. It
  proves production Relay pairing/signaling + real WebRTC DataChannel +
  HostAgent DataChannel endpoint can support two iOS clients. The final gate
  still requires physical iPhoneA + iPhoneB and an idle already-open Codex TUI
  thread where a prompt reaches `handled` / final assistant response without
  reopening the TUI session.

Update after simulator live marker `SIM-P2P-LIVE-060405`: this marker is the
current simulator-side proof that production Relay signaling + WebRTC
DataChannel + HostAgent sidecar + `codex-cli-live` control-socket producer can
inject a prompt into an active Codex session. It remains partial evidence only:
the final close condition still requires the same path against a user-selected
idle thread already open in Codex TUI, with two iPhone clients attached and log
metadata proving `handled` / `turnCompleted` / assistant live events for both
clients.

Update after simulator idle-thread live completion gate on 2026-06-15:

- A direct app-server control-socket probe showed that real
  `turn/completed` notifications carry the terminal turn id as nested
  `turn.id`, not as a top-level `turnId`. `CodexAppServerControlSocketLiveProducer`
  now accepts both top-level and nested turn id shapes for completion, failure,
  assistant delta, and completed-item mapping.
- The previous simulator verifier miss was also caused by buffered HostAgent
  stdout in LaunchAgent logs. The `--p2p-listen` metadata diagnostics now write
  complete lines with `FileHandle.standardOutput.write`, so the verifier does
  not depend on Swift `print` flushing behavior.
- Re-running
  `zsh scripts/issue74-idle-tui-sim-smoke.sh 019ea4d7-6c12-7132-8fad-4cd2028309ba SIM-P2P-LIVE-075304`
  passed the metadata gate. HostAgent evidence was scoped to two simulator P2P
  sessions attached to the same thread:
  `14A57763-301A-4EDC-B7F5-AC687CD3DA4E` and
  `8AC8BB88-E258-42A0-8060-03EB8A78CC00`.
- Both attached simulator clients received `writeStatusChanged status=handled`,
  `assistantTextDelta`, and `turnCompleted` for the same turn
  `019ec88e-3a23-7431-acb3-9892d2577e90`.
- This upgrades simulator evidence from ingress-only to two-client live
  completion metadata pass. It still does not close #74 because physical
  iPhoneA + iPhoneB and human observation of the already-open TUI session remain
  pending.

For repeatable simulator rehearsal before physical iPhone HITL, first list
metadata-only candidate idle threads:

```sh
zsh scripts/issue74-list-idle-threads.sh 20
```

Choose a thread id from the JSON output, open that same thread in Codex TUI
without starting a new turn, then run:

```sh
zsh scripts/issue74-idle-tui-sim-smoke.sh "<idle-thread-id>" "SIM-P2P-LIVE-060405"
```

The helper intentionally omits prompt/assistant preview text from thread-list
output and verifies HostAgent logs using command/write/live-event metadata only.

Update after physical-device helper hardening: `zsh scripts/issue74-idle-tui-device-smoke.sh`
now mirrors the simulator smoke for locally connected real iPhones. It refuses
simulator UDIDs, refuses physical devices listed under `Devices Offline`, checks
that `devicectl` is usable before building/installing, launches iPhoneB first
as observer and iPhoneA second with `CODEXPORT_IOS_RELAY_AUTOPROMPT`, then runs
the same metadata-only HostAgent log verifier. On this machine at the time of
writing, all physical iPhones are still reported Offline by `xcrun xctrace list
devices`, and `xcrun devicectl list devices` exits 137, so no physical HITL pass
is claimed.

Update after TestFlight/manual verification deeplink slice: the iOS app now
registers the `codexport` URL scheme and handles `codexport://verify?...`.
Opening this URL seeds a Relay Host profile, selects the explicit P2P WebRTC
route through launch automation, connects to the target thread, and optionally
sends the marker prompt. `zsh scripts/issue74-list-pairing-records.sh` lists
metadata-only active production Pairing Records for the target HostAgent.
`zsh scripts/issue74-export-real-pairing-env.sh` filters that list down to active
non-synthetic records and prints the four real-device Relay identity exports used
by the TestFlight/manual gate. `zsh scripts/issue74-make-verify-deeplinks.sh`
then requires those two real iPhone device IDs and Pairing Record IDs before it
prints the iPhoneB observer URL and iPhoneA sender URL. Synthetic simulator IDs
are available only with `CODEXPORT_ALLOW_SYNTHETIC_PAIRING_IDS=1` and are not
product/TestFlight evidence. The generated URLs contain host/device/pairing-record
IDs and the target thread id, not Pairing Token material, Codex tokens, prompt
history, assistant output, command output, or diffs.

Update after physical/simulator smoke hardening: the idle TUI smoke helpers now
generate a fresh LaunchAgent plist under `.scratch/launchagents/` for each run
instead of depending on a pre-existing user LaunchAgent plist. This forces the
latest built `codexport-host-agent`, current WebRTC sidecar path, current control
socket path, and a per-run `CODEXPORT_ISSUE74_RUN_ID` into the HostAgent
environment before bootstrap/kickstart. HostAgent `--p2p-listen` metadata lines
include `run=<id>`, and `zsh scripts/issue74-verify-hostagent-log.sh --run-id <id>`
scopes evidence to that run. This prevents stale log lines from an earlier
simulator rehearsal on the same thread/client ids from satisfying a later
physical-device gate. The physical-device helper also now requires explicit real
`CODEXPORT_IOS_RELAY_DEVICE_ID` / `CODEXPORT_IOS_RELAY_PAIRING_RECORD_ID` values
for both iPhones by default; synthetic Relay identities are allowed only with
`CODEXPORT_ALLOW_SYNTHETIC_PAIRING_IDS=1` and are not #74 close evidence.

Run-id scoped simulator regression on 2026-06-15:

- Command:
  `zsh scripts/issue74-idle-tui-sim-smoke.sh 019ea4d7-6c12-7132-8fad-4cd2028309ba SIM-P2P-LIVE-080927`.
- HostAgent run id: `issue74-sim-20260615080927-91896`.
- The script rebuilt `codexport-host-agent`, rebuilt the WebRTC sidecar, wrote a
  fresh `.scratch/launchagents/com.smarteffi.codexport.hostagent.p2p.plist`,
  restarted LaunchAgent, rebuilt the simulator app, launched iPhoneB observer
  and iPhoneA sender, then ran the verifier with `--run-id`.
- Result: PASS. The run-id scoped verifier saw two P2P sessions
  `1E87EF08-1AC5-465E-BF30-E9E4532A4766` and
  `25A1AC61-729E-415C-A3C7-4492389D8A30`, plus both simulator clients attached
  to the target thread and receiving `writeStatusChanged status=handled`,
  `assistantTextDelta`, and `turnCompleted`.
- This proves the new LaunchAgent generation and run-id verifier hardening do
  not break the simulator P2P live path. It still does not close #74 because it
  is not physical iPhoneA + iPhoneB evidence.

Update after shared write/turn verifier hardening: the metadata verifier no
longer accepts "client A received some completion and client B received some
completion" as sufficient evidence. It now requires:

- one prompt `write=<id>` targeted at the selected thread;
- every attached/expected client receives `writeStatusChanged status=handled`
  for that same `write=<id>`;
- one live `turn=<id>` has both `assistantTextDelta` and `turnCompleted` for
  every attached/expected client.

Fixture coverage proves mismatched per-client turn ids fail and mismatched
handled write ids fail. Re-running the stronger verifier against the
`SIM-P2P-LIVE-080927` HostAgent log still passes, with shared handled write id
`afk-autoprompt-0D51B1CD-E872-48C3-9D42-25674930B4C2` and shared completed live
turn id `019ec89d-9721-7dc2-99d1-524a21acc9a4`.

Update after sender/observer role-aware verifier hardening: the verifier now
accepts `--sender-client <client-id>` and `--observer-client <client-id>`.
When provided, it requires the sender client to be the one that emitted the
prompt command and requires the observer client not to emit a prompt command.
The simulator and physical-device smoke helpers now pass iPhoneA as
`--sender-client` and iPhoneB as `--observer-client`. Fixture coverage proves an
observer-issued prompt fails even when both clients receive the same handled
write and completed turn. Re-running against `SIM-P2P-LIVE-080927` still passes,
now additionally proving the iPhoneA simulator identity was the prompt sender and
the iPhoneB simulator identity was an observer for the shared write/turn.

Update after HostAgent P2P start helper extraction: `zsh scripts/issue74-start-hostagent-p2p.sh`
is now the single repeatable start path for this gate. It builds the current
`codexport-host-agent`, builds the WebRTC sidecar unless explicitly skipped,
writes a fresh run-id-scoped LaunchAgent plist under `.scratch/launchagents/`,
restarts `codexport-host-agent --p2p-listen`, checks the production Relay P2P
host drain, and prints eval-able shell assignments for
`CODEXPORT_ISSUE74_RUN_ID`, `CODEXPORT_HOSTAGENT_STDOUT`,
`CODEXPORT_HOSTAGENT_STDERR`, and `CODEXPORT_HOSTAGENT_LAUNCHD_PLIST`. The
simulator and physical-device smoke helpers both call this helper, so simulator,
local physical-device, and TestFlight/manual verification use the same HostAgent
start semantics and the same run-id-scoped stdout verifier.

Helper-backed simulator regression on 2026-06-15:

- Command:
  `zsh scripts/issue74-idle-tui-sim-smoke.sh 019ea4d7-6c12-7132-8fad-4cd2028309ba SIM-P2P-LIVE-082655`.
- HostAgent run id: `issue74-sim-20260615082655-5129`.
- Result: PASS. The role-aware verifier saw iPhoneA simulator client
  `pairing-11111111-2222-3333-4444-555555555555-CCCCCCCC-DDDD-EEEE-FFFF-000000000001`
  emit the prompt command and iPhoneB simulator client
  `pairing-11111111-2222-3333-4444-555555555555-DDDDDDDD-EEEE-FFFF-0000-000000000002`
  remain observer-only.
- Both clients attached to the same target thread and received
  `writeStatusChanged status=handled` for shared write id
  `afk-autoprompt-06787439-46C2-4FCE-A605-2E90563E229C`, plus
  `assistantTextDelta` and `turnCompleted` for shared live turn id
  `019ec8ad-45a2-7ae2-b5ee-066d92a8960b`.
- This is the strongest simulator rehearsal so far because it covers helper
  start, run-id scoping, sender/observer roles, shared write id, and shared live
turn id in one run. It still does not close #74 because it is not physical
iPhoneA + iPhoneB evidence and still needs human observation that the
already-open Codex TUI updates without leaving/reopening the thread.

Update after TUI-to-iOS sync diagnosis: screenshot evidence showed the opposite
direction was still under-specified. iOS-originated prompts appeared in the
already-open TUI, but a prompt typed directly in Codex TUI produced only the
assistant response on iOS, not the user prompt bubble. The cause was that the
Client-Host live protocol had no `userMessage` live event; HostAgent mapped
assistant deltas and terminal events from the app-server control socket, but
dropped `item/started` / `item/completed` `userMessage` items. The protocol now
has `RelayLiveSessionEvent.userMessage(turnID:itemID:text:)`, the control-socket
producer maps Codex `userMessage` items with `content: [{type: "input_text"}]`,
and iOS `SessionStore.receive(relayEvent:)` renders them through the same
deduplicating item path used by optimistic local sends. The verifier now requires
`event=userMessage` for every attached client and a shared turn id that has
`userMessage`, `assistantTextDelta`, and `turnCompleted`; earlier simulator
passes remain valid ingress rehearsals but do not satisfy the stronger
TUI-to-iOS gate until rerun with the new HostAgent.

## Device discovery

Command:

```sh
xcrun xctrace list devices
xcrun simctl list devices available
```

Observed:

- Mac host visible: `Ben's MacBook Air`.
- Physical iPhones visible but Offline:
  - `Pie的iPhone (26.3.1)`
  - `min (26.2.1)`
  - `min (26.5)`
  - `派 (18.5)`
- Available iOS targets are simulators, including `iPhone 17`, `iPhone 17 Pro`,
  `iPhone 17 Pro Max`, `iPhone 16e`, and `iPhone Air`.

## AFK prerequisite verification

Command:

```sh
swift test --filter 'P2PSignalingServiceTests|P2PWebRTCDataChannelTransportTests|ClientHostSessionDataChannelTests|ConnectionDiagnosticsTests|HostAgentNoSecretLogTests'
```

Result:

```text
34 tests passed
```

Covered behavior:

- Authorized, unknown, revoked, and version-mismatch signaling paths.
- Revoked device cannot keep using an existing signaling session for new WebRTC
  negotiation.
- Reliable ordered fake `WebRTC DataChannel Transport` open/close/send/receive.
- Direct success, direct failure with `TURN relayed connected`, and TURN failure
  diagnostics.
- `Client-Host Session Protocol` over DataChannel for session list, history,
  prompt write status, assistant streaming, command output, file change,
  approval, interrupt, split/coalesced JSONL frames, and multi-device fan-out.
- iOS transcript projection shows a thinking/working row after relay prompt
  write status reaches `queued` before assistant output arrives.
- `codex exec --json` streaming stdout maps command execution and file change
  items to live relay events before the exec process exits.
- Foreground recovery, network change recovery, HostAgent wake stale replacement,
  failed recovery UI, and preservation of already loaded history.
- Support export redaction for Pairing Token, Codex token, SSH secret, API key,
  prompt, assistant output, command output, diff, and approval payload sentinels.
- Public Relay P2P signaling HTTP endpoints backed by production Pairing Record,
  presence, revoke, and protocol-version gates.
- Core `RelayP2PSignalingClient` URL and payload contract for iOS/HostAgent
  callers.
- Core `RelayP2PSessionTransportFactory` + `RelayDeferredJSONLTransport` route
  seam from production signaling to existing `Client-Host Session Protocol`
  JSONL clients.
- Core `RelayConnectionTransportFactory` route selection and
  `UnavailableRelayP2PDataChannelFactory` runtime guard.
- HostAgent `HostAgentP2PDataChannelEndpoint` DataChannel-to-local-relay seam
  for split JSONL frames, thread list responses, live prompt write status, live
  assistant deltas, and sanitized command errors.
- Relay host-wide P2P message drain and HostAgent
  `HostAgentP2PSignalingListener` seam for offer discovery, answer/ICE send, and
  unavailable-runtime diagnostics.
- Explicit iOS P2P route selection via `CODEXPORT_IOS_RELAY_TRANSPORT_MODE` and
  explicit HostAgent menu listener selection via `CODEXPORT_HOST_AGENT_P2P_LISTEN`.
- Platform WebRTC runtime adapter seam for SDP offer/answer, ICE candidate
  payloads, iOS opener, HostAgent acceptor, and unavailable-SDK diagnostics.
- Conditional `WebRTCSDKRuntime` source for real `RTCPeerConnection` /
  `RTCDataChannel` integration when an iOS/Catalyst `WebRTC` module is linked.
- STUN/TURN ICE configuration parsing from environment, TURN credential
  redaction, and bidirectional trickle ICE forwarding/application across iOS
  opener and HostAgent listener seams.
- `stasel/WebRTC` package selection narrowed to `148.0.0` for iOS/Catalyst
  because `149.0.0` checksum verification fails. Native macOS HostAgent runtime
  remains unavailable with this package because the macOS framework headers are
  incomplete and the complete iOS/Catalyst headers pull in APIs unavailable on
  native macOS.
- HostAgent WebRTC sidecar for native macOS: `CODEXPORT_WEBRTC_SIDECAR_PATH`
  enables a JSONL IPC acceptor that bridges offer/answer/ICE/DataChannel bytes
  between HostAgent and a Mac Catalyst helper built by
  `scripts/build-webrtc-sidecar.sh`.

## Acceptance criteria status

| Criteria | Status | Evidence |
| --- | --- | --- |
| Real iPhoneA connects to real Mac HostAgent through P2P direct or TURN-relayed DataChannel | Pending HITL | iOS/Catalyst WebRTC SDK dependency is pinned in `Package.swift` and `Package.resolved`. Native macOS HostAgent now delegates WebRTC to the Mac Catalyst sidecar at `.scratch/webrtc-sidecar/codexport-webrtc-sidecar`; JSONL smoke reaches real WebRTC runtime and fails only on deliberately invalid SDP. Real iPhone offer/answer remains pending. |
| Real iPhoneB connects to same HostAgent session and sees iPhoneA live events | Pending HITL | AFK `ClientHostSessionDataChannelTests` covers two-device fan-out over DataChannel; `HostAgentP2PDataChannelEndpointTests` covers HostAgent DataChannel routing into the local relay service. No physical iPhoneB run was possible. |
| Foreground recovery restores session list/detail without stale #61 online state | AFK pass, HITL pending | `ConnectionDiagnosticsTests` covers foreground, network change, HostAgent wake, stale replacement, failed recovery UI, and history retention. Real app foreground/background on physical iPhone remains pending. |
| iOS shows write progress and intermediate events before final assistant response | AFK pass, HITL pending | `RelayJSONLSessionClientTests` covers `queued` -> `正在思考...`; `ClientHostSessionDataChannelTests` and `HostAgentP2PDataChannelEndpointTests` cover write status and assistant deltas over DataChannel before completion. Physical iPhone UI capture remains pending. |
| Codex TUI, iPhoneA, and iPhoneB sync evidence is recorded with live source limits | Simulator metadata pass, HITL pending | `SIM-P2P-LIVE-060405` proved active-session prompt ingress. `SIM-P2P-LIVE-075304` then passed the two-simulator idle-thread metadata verifier. `SIM-P2P-LIVE-082655` repeated the gate through the shared HostAgent start helper and proved sender/observer roles, shared handled write id, `assistantTextDelta`, and `turnCompleted` for the same live turn. This is not a full close because it did not use two physical iPhones and still needs human observation that the already-open TUI updates without reopening. |
| Verification record includes direct/TURN path state, signaling, failure diagnostics, and no-secret log check | AFK partial, HITL pending | Public Relay P2P signaling endpoint tests, Core route seam tests, route guard tests, HostAgent DataChannel endpoint tests, and HostAgent sidecar IPC contract tests compile. Direct/TURN path remains incomplete until the sidecar helper is exercised with real iPhone SDP/ICE. |

## HITL runbook

Use this checklist when two physical iPhones are online.

1. Build current app and HostAgent from this workspace.
2. Start real Mac HostAgent with P2P signaling configured against the intended
   Relay/TURN environment. The default HostAgent producer is the
   TUI-compatible `codex-cli-live`; set it explicitly only to make the run log
   self-documenting:

   ```sh
   CODEXPORT_HOST_AGENT_BACKEND=codex-cli-live
   CODEXPORT_CODEX_CONTROL_SOCKET_PATH="$HOME/.codex/app-server-control/app-server-control.sock"
   ```

   Configure ICE using one of:

   ```sh
   CODEXPORT_WEBRTC_ICE_SERVERS_JSON='[{"urls":["stun:stun.example.test:3478"]},{"urls":["turn:turn.example.test:3478?transport=udp"],"username":"...","credential":"..."}]'
   ```

   or:

   ```sh
   CODEXPORT_WEBRTC_STUN_URLS="stun:stun.example.test:3478"
   CODEXPORT_WEBRTC_TURN_URLS="turn:turn.example.test:3478?transport=udp turn:turn.example.test:3478?transport=tcp"
   CODEXPORT_WEBRTC_TURN_USERNAME="..."
   CODEXPORT_WEBRTC_TURN_CREDENTIAL="..."
   ```

   On native macOS HostAgent, build and set the WebRTC sidecar helper:

   ```sh
   scripts/build-webrtc-sidecar.sh
   CODEXPORT_WEBRTC_SIDECAR_PATH="$PWD/.scratch/webrtc-sidecar/codexport-webrtc-sidecar"
   CODEXPORT_WEBRTC_SIDECAR_ARGUMENTS_JSON='["--stdio-jsonl"]'
   ```

   This backend uses `CodexAppServerControlSocketLiveProducer` over the official
   app-server control socket. Do not use `codex-exec-json` for this gate because
   it only proves persisted history / one-shot JSONL behavior.

   Until a signed HostAgent macOS app target exists, prefer the SwiftPM CLI
   product for HITL. The repeatable run-id-scoped helper is the preferred start
   path for #74:

   ```sh
   eval "$(zsh scripts/issue74-start-hostagent-p2p.sh "ISSUE74-PHYSICAL-IDLE-TUI-<timestamp>")"
   ```

   It builds the HostAgent, builds the WebRTC sidecar, writes a fresh
   `.scratch/launchagents/` plist, restarts `--p2p-listen`, checks the Relay P2P
   host drain, and exports `CODEXPORT_ISSUE74_RUN_ID` plus
   `CODEXPORT_HOSTAGENT_STDOUT` for the metadata verifier. If you need to start
   the CLI manually for diagnosis, use the equivalent command:

   ```sh
   swift build --product codexport-host-agent

   CODEXPORT_RELAY_BASE_URL=https://codexport.smarteffi.net \
   CODEXPORT_RELAY_HOST_ID=11111111-2222-3333-4444-555555555555 \
   CODEXPORT_RELAY_HOST_NAME="CodexPort Dev Mac" \
   CODEXPORT_RELAY_HOST_USER="$USER" \
   CODEXPORT_CODEX_CONTROL_SOCKET_PATH="$HOME/.codex/app-server-control/app-server-control.sock" \
   CODEXPORT_WEBRTC_SIDECAR_PATH="$PWD/.scratch/webrtc-sidecar/codexport-webrtc-sidecar" \
   CODEXPORT_WEBRTC_SIDECAR_ARGUMENTS_JSON='["--stdio-jsonl"]' \
   .build/debug/codexport-host-agent --p2p-listen
   ```
3. Pair iPhoneA and iPhoneB as separate device identities. Confirm both records
   are active and independently revocable.
4. Confirm the production Relay exposes the P2P signaling HTTP surface:
   `/v0/p2p/hosts/{hostID}/presence`, `/v0/p2p/sessions/open`,
   `/v0/p2p/sessions/{sessionID}/messages/send`, and
   `/v0/p2p/sessions/{sessionID}/messages?endpoint=...`.
5. On iPhoneA, connect to the paired Relay Host. Capture path state:
   `signaling`, `ICE`, `direct connected` or `TURN relayed connected`,
   `DataChannel open`, `host protocol ready`, and `Codex live source ready`.
6. On iPhoneB, connect to the same HostAgent session. Confirm active connection
   count and path state on HostAgent menu/diagnostics.
7. Open the same thread in Codex TUI and keep it open before sending from
   iPhoneA. Send a redacted prompt from iPhoneA. Confirm the open TUI view
   updates live without exiting/reopening the thread. If it only appears after
   reopening, mark Mac live sync failed and do not close.
   First list metadata-only idle/completed thread candidates:

   ```sh
   zsh scripts/issue74-list-idle-threads.sh 20
   ```

   Prefer explicitly targeting the already-open
   idle TUI thread instead of relying on the first thread in the list:

   ```sh
   CODEXPORT_IOS_RELAY_THREAD_ID="<idle-thread-id>"
   CODEXPORT_IOS_RELAY_AUTOPROMPT="ISSUE74-IDLE-TUI-<timestamp>"
   ```

   Do not use the current active Codex agent thread as the final gate; it can
   remain `queued` / `running` behind the active turn and only proves the write
   reached HostAgent/control-socket, not that an idle TUI session completed the
   live update.

   The repeatable simulator smoke helper for this step is:

   ```sh
   zsh scripts/issue74-idle-tui-sim-smoke.sh \
     "<idle-thread-id>" \
     "ISSUE74-IDLE-TUI-<timestamp>"
   ```

   The script builds the current HostAgent and WebRTC sidecar, writes a fresh
   `.scratch/launchagents/` P2P LaunchAgent plist containing
   `CODEXPORT_ISSUE74_RUN_ID`, restarts the LaunchAgent, rebuilds/reinstalls
   the simulator app, launches iPhoneB first as an observer on
   `CODEXPORT_IOS_RELAY_THREAD_ID`, then launches iPhoneA with
   `CODEXPORT_IOS_RELAY_THREAD_ID` plus
   `CODEXPORT_IOS_RELAY_AUTOPROMPT`. Set
   `CODEXPORT_SKIP_IPHONE_B_OBSERVER=1` only when intentionally running the
   single-simulator ingress smoke. By default it waits up to 180 seconds and
   runs the metadata verifier below every 5 seconds; set
   `CODEXPORT_SKIP_ISSUE74_VERIFY=1` only when intentionally launching without
   waiting for the gate. It still requires the target idle thread to be open in
   Codex TUI before running. HostAgent logs intentionally omit the prompt text;
   verify by metadata such as `type=prompt thread=<idle-thread-id>`, two
   distinct `client=pairing-*` values attached to the same thread,
   `event=writeStatusChanged status=handled`, `event=userMessage`,
   `event=turnCompleted`, and `event=assistantTextDelta`.

   The repeatable local physical-device helper for this step is:

   ```sh
   zsh scripts/issue74-readiness-check.sh \
     --mode local-device \
     "<iphone-a-physical-device-udid>" \
     "<iphone-b-physical-device-udid>"

   zsh scripts/issue74-idle-tui-device-smoke.sh \
     "<idle-thread-id>" \
     "<iphone-a-physical-device-udid>" \
     "<iphone-b-physical-device-udid>" \
     "ISSUE74-PHYSICAL-IDLE-TUI-<timestamp>"
   ```

   This helper requires both UDIDs to appear under `== Devices ==`, not
   `== Devices Offline ==` or `== Simulators ==`, in `xcrun xctrace list
   devices`. It builds for `iphoneos`, installs through `xcrun devicectl device
   install app`, launches through `xcrun devicectl device process launch
   --environment-variables`, and uses the same run-id-scoped HostAgent log
   verifier. By default this helper refuses to use synthetic Relay device or
   Pairing Record IDs; export the two real-device values with
   `zsh scripts/issue74-export-real-pairing-env.sh` before running. If
   `devicectl` is unavailable or killed before listing devices, do not treat the
   run as product evidence; use TestFlight/manual pairing and then run the
   metadata verifier against HostAgent stdout after both real iPhones connect.

   For TestFlight/manual real-device verification, generate deeplinks after both
   devices have active Pairing Records and after starting HostAgent through the
   shared helper above. The repeatable wrapper for this flow is:

   Before starting the wrapper, run the read-only readiness check in manual
   mode:

   ```sh
   zsh scripts/issue74-readiness-check.sh \
     --mode manual \
     "<iphone-a-physical-device-udid>" \
     "<iphone-b-physical-device-udid>"
   ```

   It checks local tools, Codex control socket, HostAgent/sidecar artifacts,
   `xctrace`/`devicectl` physical-device state, active non-synthetic Relay
   Pairing Records, and the four real-device deeplink environment variables. It
   does not start HostAgent, install apps, open URLs, or print credential
   values. In `manual` mode, local `xctrace`/`devicectl` device availability is
   diagnostic-only because TestFlight/manual verification can be performed when
   the phones are not locally controllable; in `local-device` mode, two locally
   available devices are required.

   ```sh
   zsh scripts/issue74-manual-testflight-smoke.sh \
     "<idle-thread-id>" \
     "ISSUE74-PHYSICAL-IDLE-TUI-<timestamp>"
   ```

   The wrapper validates the two real-device Relay identities, prints the
   iPhoneB observer and iPhoneA sender deeplinks, starts HostAgent through
   `zsh scripts/issue74-start-hostagent-p2p.sh`, and waits on the same run-id-scoped
   sender/observer verifier. The marker is also passed to the verifier as
   `--forbid-text`, so the gate fails if HostAgent stdout includes the prompt
   marker. It does not use `devicectl`; it is the intended path when the app is
   installed through TestFlight or opened manually on the two real iPhones.

   To run the steps manually, first list the active real-device pairing metadata:

   ```sh
   zsh scripts/issue74-export-real-pairing-env.sh --list
   ```

   Export the two real iPhone identities from that output. Prefer explicit
   selectors so iPhoneA remains the sender and iPhoneB remains the observer:

   ```sh
   eval "$(zsh scripts/issue74-export-real-pairing-env.sh \
     --iphone-a "<iphone-a-device-id-or-name>" \
     --iphone-b "<iphone-b-device-id-or-name>")"
   ```

   If exactly two active non-synthetic Pairing Records exist and the role order is
   obvious from the printed comments, this shorter command is also available:

   ```sh
   eval "$(zsh scripts/issue74-export-real-pairing-env.sh --auto-two)"
   ```

   Then generate the URLs:

   ```sh
   zsh scripts/issue74-make-verify-deeplinks.sh \
     "<idle-thread-id>" \
     "ISSUE74-PHYSICAL-IDLE-TUI-<timestamp>"
   ```

   The deeplink generator fails fast if these four real-device values are
   missing. `CODEXPORT_ALLOW_SYNTHETIC_PAIRING_IDS=1` is allowed only for
   simulator/dev rehearsal and must not be used as TestFlight or #74 close
   evidence.

   Open the iPhoneB observer URL first, wait for it to attach to the target
   thread, then open the iPhoneA sender URL. This exercises the same P2P route
   selection and launch automation without relying on simulator or devicectl
   process environment injection. The close condition is still the HostAgent
   metadata verifier plus human observation that the already-open Codex TUI
   updates without leaving/reopening the thread.

   The metadata-only verifier for HostAgent stdout is:

   ```sh
   zsh scripts/issue74-verify-hostagent-log.sh \
     "<idle-thread-id>" \
     "$CODEXPORT_HOSTAGENT_STDOUT" \
     --run-id "$CODEXPORT_ISSUE74_RUN_ID" \
     --sender-client "$CODEXPORT_IOS_RELAY_PAIRING_RECORD_ID" \
     --observer-client "$CODEXPORT_IOS_RELAY_PAIRING_RECORD_ID_B" \
     --forbid-text "ISSUE74-PHYSICAL-IDLE-TUI-<timestamp>"
   ```

   The verifier first scopes evidence to `run=<issue74-run-id>` when provided,
   then scopes to P2P sessions that attached to the target thread, then
   requires the sender client to issue the prompt, the observer client not to
   issue the prompt, one prompt write id to be handled by every attached client,
   and one live turn id to have `userMessage`, `assistantTextDelta`, and
   `turnCompleted` for every attached client. If `--forbid-text` is provided, it also fails when
   that exact text appears in the run-scoped HostAgent stdout; failure output
   reports only the check count, not the forbidden text. It does not read prompt,
   assistant, command, file
   diff, or approval payloads.
8. Confirm iPhoneA shows working/thinking state immediately after write
   acceptance, then streams command/file/tool progress events before the final
   assistant message when the prompt triggers such events.
9. Confirm iPhoneB receives write status, intermediate events, and live assistant
   events from the same session.
10. Send a redacted prompt or interrupt from iPhoneB. Confirm iPhoneA and the
   already-open Codex TUI view receive the same live status/event stream.
11. Background iPhoneA long enough to force recovery, then foreground it. Confirm
   session list/detail returns without clearing loaded history and without
   showing process-online as host-protocol-ready.
12. Trigger a network switch on one iPhone, then confirm renegotiation or stale
   DataChannel replacement with path-state evidence.
13. Revoke iPhoneB, then confirm it cannot complete new signaling or create a
    new session protocol connection.
14. Export support diagnostics and scan for sentinels:
    Pairing Token, Codex/ChatGPT token, SSH secret, API key, prompt, assistant
    output, command output, diff, approval payload.

## No-secret handling

This record does not include credential values, Pairing Token values, prompt
plaintext, assistant plaintext, command output, diffs, approval payloads, API
keys, SSH secrets, Codex tokens, or ChatGPT tokens. The AFK redaction tests use
synthetic sentinel strings only.

## Closure guidance

Do not close #74 until a HITL run updates this file, or a follow-up record, with
real iPhoneA + real iPhoneB + real Mac HostAgent evidence and final pass/fail
status. The Mac evidence must be live evidence from an already-open Codex TUI
session, not only persisted history visible after reopening.
