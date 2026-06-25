#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="Codex Rate Limits Bar"

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

need_cmd swift
need_cmd make

if ! command -v codex >/dev/null 2>&1 && [[ ! -x /Applications/Codex.app/Contents/Resources/codex ]]; then
  echo "Missing required command: codex. Install Codex CLI or Codex.app first." >&2
  exit 1
fi

if ! xcode-select -p >/dev/null 2>&1; then
  echo "Xcode Command Line Tools are required. Run: xcode-select --install" >&2
  exit 1
fi

echo "Installing ${APP_NAME}..."
make -C "$ROOT" stop >/dev/null 2>&1 || true
make -C "$ROOT" install-user

echo "Installing Codex plugin..."
"$HOME/Applications/${APP_NAME}.app/Contents/MacOS/CodexRateLimitsBar" install-plugin --source "$ROOT/plugins/codex-usage-monitor"

echo
echo "Done."
echo "Status bar app: $HOME/Applications/${APP_NAME}.app"
echo "Plugin: codex-usage-monitor@personal"
