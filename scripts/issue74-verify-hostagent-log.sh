#!/usr/bin/env zsh
set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
Usage:
  zsh scripts/issue74-verify-hostagent-log.sh <idle-thread-id> [log-file] [--run-id <run-id>] [--sender-client <client-id>] [--observer-client <client-id>] [--forbid-text <text>] [client-id ...]

Verifies no-payload HostAgent stdout metadata for the #74 idle TUI gate.
Default log-file:
  .scratch/logs/hostagent-p2p-launchd.out

Checks:
  - at least two distinct clients attached to the target thread
  - optional expected client ids all attached to the target thread
  - optional sender client issued the prompt command
  - optional observer client did not issue the prompt command
  - a prompt command targeted the thread and produced one shared write id
  - both clients received handled status for the same write id
  - both clients received userMessage for the same turn id
  - both clients received assistantTextDelta for the same turn id
  - both clients received turnCompleted for the same turn id
  - optional forbidden text does not appear in the run-scoped HostAgent log

This script only reads metadata fields emitted by HostAgent diagnostics. It
does not inspect prompt, assistant, command, or diff payloads.

Set CODEXPORT_ISSUE74_RUN_ID or pass --run-id to scope evidence to one
HostAgent run and avoid stale log lines from earlier rehearsals.
USAGE
}

if [[ $# -lt 1 ]]; then
  usage
  exit 64
fi

THREAD_ID="$1"
shift

DEFAULT_LOG=".scratch/logs/hostagent-p2p-launchd.out"
LOG_FILE="$DEFAULT_LOG"

if [[ $# -gt 0 && -f "$1" ]]; then
  LOG_FILE="$1"
  shift
fi

RUN_ID="${CODEXPORT_ISSUE74_RUN_ID:-}"
SENDER_CLIENT=""
OBSERVER_CLIENT=""
EXPECTED_CLIENTS=()
FORBIDDEN_TEXTS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --run-id)
      if [[ $# -lt 2 ]]; then
        echo "Missing value for --run-id" >&2
        exit 64
      fi
      RUN_ID="$2"
      shift 2
      ;;
    --sender-client)
      if [[ $# -lt 2 ]]; then
        echo "Missing value for --sender-client" >&2
        exit 64
      fi
      SENDER_CLIENT="$2"
      EXPECTED_CLIENTS+=("$2")
      shift 2
      ;;
    --observer-client)
      if [[ $# -lt 2 ]]; then
        echo "Missing value for --observer-client" >&2
        exit 64
      fi
      OBSERVER_CLIENT="$2"
      EXPECTED_CLIENTS+=("$2")
      shift 2
      ;;
    --forbid-text)
      if [[ $# -lt 2 ]]; then
        echo "Missing value for --forbid-text" >&2
        exit 64
      fi
      FORBIDDEN_TEXTS+=("$2")
      shift 2
      ;;
    --*)
      echo "Unknown option: $1" >&2
      usage
      exit 64
      ;;
    *)
      EXPECTED_CLIENTS+=("$1")
      shift
      ;;
  esac
done

if [[ ! -f "$LOG_FILE" ]]; then
  echo "Missing log file: $LOG_FILE" >&2
  exit 66
fi

if [[ ! -s "$LOG_FILE" ]]; then
  echo "Log file is empty: $LOG_FILE" >&2
  exit 65
fi

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/codexport-issue74-log.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

THREAD_LOG="$TMP_DIR/thread.log"
SESSION_IDS_FILE="$TMP_DIR/p2p-sessions.txt"
SCOPED_LOG="$TMP_DIR/scoped.log"
RUN_LOG="$TMP_DIR/run.log"
PROMPT_WRITES_FILE="$TMP_DIR/prompt-writes.txt"
PROMPT_CLIENT_WRITES_FILE="$TMP_DIR/prompt-client-writes.txt"
HANDLED_WRITES_FILE="$TMP_DIR/handled-writes.txt"
USER_MESSAGE_TURNS_FILE="$TMP_DIR/user-message-turns.txt"
DELTA_TURNS_FILE="$TMP_DIR/delta-turns.txt"
COMPLETED_TURNS_FILE="$TMP_DIR/completed-turns.txt"
SHARED_WRITES_FILE="$TMP_DIR/shared-writes.txt"
SHARED_TURNS_FILE="$TMP_DIR/shared-turns.txt"

if [[ -n "$RUN_ID" ]]; then
  grep -F "run=${RUN_ID}" "$LOG_FILE" > "$RUN_LOG" || true
else
  cp "$LOG_FILE" "$RUN_LOG"
fi

grep -F "thread=${THREAD_ID}" "$RUN_LOG" > "$THREAD_LOG" || true
grep -F "thread=${THREAD_ID}" "$RUN_LOG" \
  | grep -F "type=attach" \
  | sed -nE 's/.*p2pSession=([^ ]+).*/\1/p' \
  | sort -u > "$SESSION_IDS_FILE" || true

: > "$SCOPED_LOG"
while IFS= read -r session_id; do
  [[ -n "$session_id" ]] || continue
  grep -F "p2pSession=${session_id}" "$RUN_LOG" >> "$SCOPED_LOG" || true
done < "$SESSION_IDS_FILE"

failures=()

require_match() {
  local description="$1"
  local pattern="$2"
  local file="${3:-$LOG_FILE}"
  if ! grep -F "$pattern" "$file" >/dev/null; then
    failures+=("$description")
  fi
}

require_thread_match() {
  local description="$1"
  local pattern="$2"
  require_match "$description" "$pattern" "$THREAD_LOG"
}

require_match "missing prompt command in target p2p sessions" "type=prompt" "$SCOPED_LOG"
require_match "missing target thread metadata in target p2p sessions" "thread=${THREAD_ID}" "$SCOPED_LOG"
require_match "missing handled write status in target p2p sessions" "event=writeStatusChanged" "$SCOPED_LOG"
require_match "missing handled status value in target p2p sessions" "status=handled" "$SCOPED_LOG"
require_match "missing userMessage event in target p2p sessions" "event=userMessage" "$SCOPED_LOG"
require_match "missing turnCompleted event in target p2p sessions" "event=turnCompleted" "$SCOPED_LOG"
require_match "missing assistantTextDelta event in target p2p sessions" "event=assistantTextDelta" "$SCOPED_LOG"

CLIENTS_FILE="$TMP_DIR/clients.txt"
grep -F "type=attach" "$THREAD_LOG" | sed -nE 's/.*client=([^ ]+).*/\1/p' | sort -u > "$CLIENTS_FILE"
CLIENT_COUNT="$(wc -l < "$CLIENTS_FILE" | tr -d ' ')"

if [[ "$CLIENT_COUNT" -lt 2 ]]; then
  failures+=("expected at least two distinct clients attached to thread=${THREAD_ID}, got ${CLIENT_COUNT}")
fi

for client in "${EXPECTED_CLIENTS[@]}"; do
  if ! grep -Fx "$client" "$CLIENTS_FILE" >/dev/null; then
    failures+=("expected client not attached to thread=${THREAD_ID}: ${client}")
  fi
done

while IFS= read -r client; do
  [[ -n "$client" ]] || continue
  if ! grep -F "client=${client}" "$SCOPED_LOG" | grep -F "event=assistantTextDelta" >/dev/null; then
    failures+=("client missing assistantTextDelta: ${client}")
  fi
  if ! grep -F "client=${client}" "$SCOPED_LOG" | grep -F "event=userMessage" >/dev/null; then
    failures+=("client missing userMessage: ${client}")
  fi
  if ! grep -F "client=${client}" "$SCOPED_LOG" | grep -F "event=turnCompleted" >/dev/null; then
    failures+=("client missing turnCompleted: ${client}")
  fi
  if ! grep -F "client=${client}" "$SCOPED_LOG" | grep -F "event=writeStatusChanged" | grep -F "status=handled" >/dev/null; then
    failures+=("client missing handled writeStatusChanged: ${client}")
  fi
done < "$CLIENTS_FILE"

grep -F "type=prompt" "$SCOPED_LOG" \
  | sed -nE 's/.*write=([^ ]+).*/\1/p' \
  | sort -u > "$PROMPT_WRITES_FILE" || true

grep -F "type=prompt" "$SCOPED_LOG" \
  | sed -nE 's/.*client=([^ ]+).*write=([^ ]+).*/\1 \2/p' \
  | sort -u > "$PROMPT_CLIENT_WRITES_FILE" || true

: > "$HANDLED_WRITES_FILE"
: > "$USER_MESSAGE_TURNS_FILE"
: > "$DELTA_TURNS_FILE"
: > "$COMPLETED_TURNS_FILE"

while IFS= read -r client; do
  [[ -n "$client" ]] || continue
  grep -F "client=${client}" "$SCOPED_LOG" \
    | grep -F "event=writeStatusChanged" \
    | grep -F "status=handled" \
    | sed -nE "s/.*write=([^ ]+).*/\1 ${client}/p" >> "$HANDLED_WRITES_FILE" || true
  grep -F "client=${client}" "$SCOPED_LOG" \
    | grep -F "event=userMessage" \
    | sed -nE "s/.*turn=([^ ]+).*/\1 ${client}/p" >> "$USER_MESSAGE_TURNS_FILE" || true
  grep -F "client=${client}" "$SCOPED_LOG" \
    | grep -F "event=assistantTextDelta" \
    | sed -nE "s/.*turn=([^ ]+).*/\1 ${client}/p" >> "$DELTA_TURNS_FILE" || true
  grep -F "client=${client}" "$SCOPED_LOG" \
    | grep -F "event=turnCompleted" \
    | sed -nE "s/.*turn=([^ ]+).*/\1 ${client}/p" >> "$COMPLETED_TURNS_FILE" || true
done < "$CLIENTS_FILE"

prompt_write_count="$(wc -l < "$PROMPT_WRITES_FILE" | tr -d ' ')"
if [[ "$prompt_write_count" -lt 1 ]]; then
  failures+=("missing write id on prompt command")
fi

if [[ -n "$SENDER_CLIENT" ]]; then
  if ! awk -v client="$SENDER_CLIENT" '$1 == client { found = 1 } END { exit found ? 0 : 1 }' "$PROMPT_CLIENT_WRITES_FILE"; then
    failures+=("sender client did not issue prompt: ${SENDER_CLIENT}")
  fi
fi

if [[ -n "$OBSERVER_CLIENT" ]]; then
  if awk -v client="$OBSERVER_CLIENT" '$1 == client { found = 1 } END { exit found ? 0 : 1 }' "$PROMPT_CLIENT_WRITES_FILE"; then
    failures+=("observer client unexpectedly issued prompt: ${OBSERVER_CLIENT}")
  fi
fi

: > "$SHARED_WRITES_FILE"
while IFS= read -r write_id; do
  [[ -n "$write_id" ]] || continue
  shared=1
  while IFS= read -r client; do
    [[ -n "$client" ]] || continue
    if ! grep -Fx "${write_id} ${client}" "$HANDLED_WRITES_FILE" >/dev/null; then
      shared=0
      break
    fi
  done < "$CLIENTS_FILE"
  if [[ "$shared" -eq 1 ]]; then
    echo "$write_id" >> "$SHARED_WRITES_FILE"
  fi
done < "$PROMPT_WRITES_FILE"

if [[ ! -s "$SHARED_WRITES_FILE" ]]; then
  failures+=("missing one prompt write id handled by every attached client")
fi

candidate_turns_file="$TMP_DIR/candidate-turns.txt"
{
  awk '{print $1}' "$USER_MESSAGE_TURNS_FILE"
  awk '{print $1}' "$DELTA_TURNS_FILE"
  awk '{print $1}' "$COMPLETED_TURNS_FILE"
} | sort -u > "$candidate_turns_file"

: > "$SHARED_TURNS_FILE"
while IFS= read -r turn_id; do
  [[ -n "$turn_id" ]] || continue
  shared=1
  while IFS= read -r client; do
    [[ -n "$client" ]] || continue
    if ! grep -Fx "${turn_id} ${client}" "$USER_MESSAGE_TURNS_FILE" >/dev/null; then
      shared=0
      break
    fi
    if ! grep -Fx "${turn_id} ${client}" "$DELTA_TURNS_FILE" >/dev/null; then
      shared=0
      break
    fi
    if ! grep -Fx "${turn_id} ${client}" "$COMPLETED_TURNS_FILE" >/dev/null; then
      shared=0
      break
    fi
  done < "$CLIENTS_FILE"
  if [[ "$shared" -eq 1 ]]; then
    echo "$turn_id" >> "$SHARED_TURNS_FILE"
  fi
done < "$candidate_turns_file"

if [[ ! -s "$SHARED_TURNS_FILE" ]]; then
  failures+=("missing one turn id with userMessage, assistantTextDelta, and turnCompleted for every attached client")
fi

for forbidden_text in "${FORBIDDEN_TEXTS[@]}"; do
  [[ -n "$forbidden_text" ]] || continue
  if grep -F "$forbidden_text" "$RUN_LOG" >/dev/null; then
    failures+=("forbidden text appeared in HostAgent log")
  fi
done

if [[ "${#failures[@]}" -gt 0 ]]; then
  echo "Issue #74 HostAgent log verification FAILED"
  echo "Thread: $THREAD_ID"
  echo "Log: $LOG_FILE"
  if [[ -n "$RUN_ID" ]]; then
    echo "Run: $RUN_ID"
  fi
  if [[ "${#FORBIDDEN_TEXTS[@]}" -gt 0 ]]; then
    echo "Forbidden text checks: ${#FORBIDDEN_TEXTS[@]}"
  fi
  echo
  echo "Observed clients attached to thread:"
  if [[ -s "$CLIENTS_FILE" ]]; then
    sed 's/^/  - /' "$CLIENTS_FILE"
  else
    echo "  none"
  fi
  echo
  echo "Observed P2P sessions for thread:"
  if [[ -s "$SESSION_IDS_FILE" ]]; then
    sed 's/^/  - /' "$SESSION_IDS_FILE"
  else
    echo "  none"
  fi
  echo
  echo "Observed prompt write ids:"
  if [[ -s "$PROMPT_WRITES_FILE" ]]; then
    sed 's/^/  - /' "$PROMPT_WRITES_FILE"
  else
    echo "  none"
  fi
  echo
  echo "Observed prompt client/write pairs:"
  if [[ -s "$PROMPT_CLIENT_WRITES_FILE" ]]; then
    sed 's/^/  - /' "$PROMPT_CLIENT_WRITES_FILE"
  else
    echo "  none"
  fi
  echo
  echo "Observed shared handled write ids:"
  if [[ -s "$SHARED_WRITES_FILE" ]]; then
    sed 's/^/  - /' "$SHARED_WRITES_FILE"
  else
    echo "  none"
  fi
  echo
  echo "Observed shared completed live turn ids:"
  if [[ -s "$SHARED_TURNS_FILE" ]]; then
    sed 's/^/  - /' "$SHARED_TURNS_FILE"
  else
    echo "  none"
  fi
  echo
  echo "Missing evidence:"
  for failure in "${failures[@]}"; do
    echo "  - $failure"
  done
  echo
  echo "Relevant lines:"
  grep -E "thread=${THREAD_ID}|event=writeStatusChanged|status=handled|event=userMessage|event=turnCompleted|event=assistantTextDelta" "$SCOPED_LOG" | tail -n 80 || true
  exit 1
fi

echo "Issue #74 HostAgent log verification passed"
echo "Thread: $THREAD_ID"
echo "Log: $LOG_FILE"
if [[ -n "$RUN_ID" ]]; then
  echo "Run: $RUN_ID"
fi
if [[ "${#FORBIDDEN_TEXTS[@]}" -gt 0 ]]; then
  echo "Forbidden text checks: ${#FORBIDDEN_TEXTS[@]}"
fi
echo "P2P sessions for thread:"
sed 's/^/  - /' "$SESSION_IDS_FILE"
echo "Clients attached to thread:"
sed 's/^/  - /' "$CLIENTS_FILE"
if [[ -n "$SENDER_CLIENT" ]]; then
  echo "Sender client:"
  echo "  - $SENDER_CLIENT"
fi
if [[ -n "$OBSERVER_CLIENT" ]]; then
  echo "Observer client:"
  echo "  - $OBSERVER_CLIENT"
fi
echo "Shared handled write ids:"
sed 's/^/  - /' "$SHARED_WRITES_FILE"
echo "Shared completed live turn ids:"
sed 's/^/  - /' "$SHARED_TURNS_FILE"
