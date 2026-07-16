#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

export DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1
PWSH_BIN="$(worker/tests/lib/get-pwsh.sh)"
"$PWSH_BIN" -NoLogo -NoProfile -File worker/tests/provider-contract-tests.ps1
