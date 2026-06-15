#!/usr/bin/env bash

resolve_codexport_codesign_identity() {
  if [[ -n "${CODEXPORT_CODESIGN_IDENTITY:-}" ]]; then
    printf '%s\n' "${CODEXPORT_CODESIGN_IDENTITY}"
    return
  fi
  local identity
  identity="$(security find-identity -v -p codesigning 2>/dev/null | awk -F '"' '/Apple Development:/{ print $2; exit }')"
  if [[ -z "${identity}" ]]; then
    identity="$(security find-identity -v -p codesigning 2>/dev/null | awk -F '"' '/Developer ID Application:/{ print $2; exit }')"
  fi
  if [[ -z "${identity}" ]]; then
    identity="$(security find-identity -v -p codesigning 2>/dev/null | awk -F '"' '/Apple Distribution:/{ print $2; exit }')"
  fi
  printf '%s\n' "${identity}"
}
