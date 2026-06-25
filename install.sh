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

need_cmd node
need_cmd codex
need_cmd swift
need_cmd make

if ! xcode-select -p >/dev/null 2>&1; then
  echo "Xcode Command Line Tools are required. Run: xcode-select --install" >&2
  exit 1
fi

echo "Installing ${APP_NAME}..."
make -C "$ROOT" stop >/dev/null 2>&1 || true
make -C "$ROOT" install-user

echo "Installing Codex plugin..."
node "$ROOT/scripts/install_plugin.js"

echo
echo "Done."
echo "Status bar app: $HOME/Applications/${APP_NAME}.app"
echo "Plugin: codex-usage-monitor@personal"
