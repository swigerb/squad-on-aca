#!/usr/bin/env bash
set -Eeuo pipefail

if command -v pwsh >/dev/null 2>&1; then
  command -v pwsh
  exit 0
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TOOLS_DIR="$ROOT_DIR/worker/tests/.tools/powershell"
BIN_PATH="$TOOLS_DIR/pwsh"
if [[ -x "$BIN_PATH" ]]; then
  printf '%s\n' "$BIN_PATH"
  exit 0
fi

mkdir -p "$TOOLS_DIR"
urls=(
  "https://github.com/PowerShell/PowerShell/releases/download/v7.4.6/powershell-7.4.6-linux-x64.tar.gz"
  "https://github.com/PowerShell/PowerShell/releases/download/v7.4.7/powershell-7.4.7-linux-x64.tar.gz"
  "https://github.com/PowerShell/PowerShell/releases/download/v7.5.1/powershell-7.5.1-linux-x64.tar.gz"
)
for url in "${urls[@]}"; do
  if curl -fsSL "$url" | tar -xz -C "$TOOLS_DIR"; then
    chmod +x "$BIN_PATH"
    printf '%s\n' "$BIN_PATH"
    exit 0
  fi
done

printf 'failed to acquire PowerShell runtime\n' >&2
exit 1
