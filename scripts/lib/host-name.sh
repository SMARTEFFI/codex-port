codexport_trim() {
  printf '%s' "$1" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

codexport_default_host_name() {
  local value

  if command -v scutil >/dev/null 2>&1; then
    value="$(scutil --get LocalHostName 2>/dev/null || true)"
    value="$(codexport_trim "$value")"
    if [[ -n "$value" ]]; then
      printf '%s\n' "$value"
      return 0
    fi
  fi

  value="$(hostname -s 2>/dev/null || hostname 2>/dev/null || true)"
  value="$(codexport_trim "$value")"
  if [[ -n "$value" ]]; then
    printf '%s\n' "$value"
    return 0
  fi

  if command -v scutil >/dev/null 2>&1; then
    value="$(scutil --get ComputerName 2>/dev/null || true)"
    value="$(codexport_trim "$value")"
    if [[ -n "$value" ]]; then
      printf '%s\n' "$value"
      return 0
    fi
  fi

  printf 'Mac\n'
}
