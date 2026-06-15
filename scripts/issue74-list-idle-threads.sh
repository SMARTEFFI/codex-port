#!/usr/bin/env zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

LIMIT="${1:-20}"

if [[ ! "$LIMIT" =~ '^[0-9]+$' || "$LIMIT" -le 0 ]]; then
  echo "Usage: zsh scripts/issue74-list-idle-threads.sh [limit]" >&2
  exit 64
fi

if [[ ! -S "$HOME/.codex/app-server-control/app-server-control.sock" ]]; then
  echo "Missing Codex control socket: $HOME/.codex/app-server-control/app-server-control.sock" >&2
  echo "Open Codex TUI before listing candidate idle threads." >&2
  exit 69
fi

swift build --product codexport-host-agent >/dev/null
.build/debug/codexport-host-agent --list-idle-threads-json --limit "$LIMIT"
