#!/usr/bin/env bash
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="${TEST_DIR}/../lib/session-env-transport.sh"

# shellcheck source=lib/assert.sh
source "${TEST_DIR}/lib/assert.sh"
# shellcheck source=lib/deps.sh
source "${TEST_DIR}/lib/deps.sh"
require_deps node

echo "== session-env transport =="

original=$'He said "ship it"\n%GITHUB_TOKEN% &|^!<> \\\\ café 東京\n'
expected_b64="$(ORIGINAL_VALUE="$original" node -e 'process.stdout.write(Buffer.from(process.env.ORIGINAL_VALUE || "", "utf8").toString("base64"))')"
export SQUAD_PROMPT_B64="$expected_b64"

# shellcheck source=lib/session-env-transport.sh
source "$LIB"
if squad_decode_b64_env SQUAD_PROMPT_B64 SQUAD_PROMPT; then
  decode_rc=0
else
  decode_rc=1
fi

assert_eq "0" "$decode_rc" "worker transport: base64 prompt decodes successfully"
roundtrip_b64="$(ROUNDTRIP_VALUE="${SQUAD_PROMPT:-}" node -e 'process.stdout.write(Buffer.from(process.env.ROUNDTRIP_VALUE || "", "utf8").toString("base64"))')"
assert_eq "$expected_b64" "$roundtrip_b64" "worker transport: decoded prompt matches the original UTF-8 bytes exactly"
assert_contains "${SQUAD_PROMPT:-}" '%GITHUB_TOKEN%' "worker transport: percent tokens survive literally"
assert_contains "${SQUAD_PROMPT:-}" 'café 東京' "worker transport: non-ASCII survives literally"

test_summary
