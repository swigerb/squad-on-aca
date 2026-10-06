#!/usr/bin/env bash
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKER_DIR="$(cd "${TEST_DIR}/.." && pwd)"
TMP_DIR="${TEST_DIR}/.tmp-aca-job-rest"

source "${TEST_DIR}/lib/assert.sh"
source "${TEST_DIR}/lib/deps.sh"
require_deps node

# shellcheck source=worker/lib/aca-job-rest.sh
source "${WORKER_DIR}/lib/aca-job-rest.sh"

echo "== aca-job-rest =="
rm -rf "$TMP_DIR"
mkdir -p "$TMP_DIR"
trap 'rm -rf "$TMP_DIR"' EXIT

job_file="${TMP_DIR}/job.json"
env_file="${TMP_DIR}/env.bin"
body_file="${TMP_DIR}/body.json"

cat > "$job_file" <<'JSON'
{
  "properties": {
    "configuration": {
      "manualTriggerConfig": {
        "parallelism": 1,
        "replicaCompletionCount": 1
      }
    },
    "template": {
      "containers": [
        {
          "name": "squad-worker",
          "image": "ghcr.io/example/squad-worker:latest",
          "resources": {
            "cpu": 1,
            "memory": "2.0Gi"
          },
          "env": [
            { "name": "ASPIRE_OTLP_GRPC_ENDPOINT", "value": "http://ca-squad-aspire:18889" },
            { "name": "OTEL_EXPORTER_OTLP_HEADERS", "secretRef": "otlp-headers" }
          ]
        }
      ]
    }
  }
}
JSON

prompt=$'Quotes " and '\'' plus CRLF\r\nLF\n%PATH% %GITHUB_TOKEN% & | ^ ! < > \\\\ $HOME `backticks` café 😀'
{
  printf 'ASPIRE_OTLP_GRPC_ENDPOINT=http://ca-squad-aspire:18889\0'
  printf 'OTEL_EXPORTER_OTLP_HEADERS=secretref:otlp-headers\0'
  printf 'SESSION_NAME=session-123\0'
  printf 'SQUAD_POD_ID=session-123\0'
  printf 'OTEL_SERVICE_NAME=squad-session-123\0'
  printf 'SQUAD_PROMPT=%s\0' "$prompt"
} > "$env_file"

squad_build_job_start_body "$job_file" "$env_file" > "$body_file"
summary="$(node - "$body_file" "$prompt" <<'NODE'
const fs = require('fs');
const [bodyPath, prompt] = process.argv.slice(2);
const body = JSON.parse(fs.readFileSync(bodyPath, 'utf8'));
const env = body.containers?.[0]?.env || [];
const find = (name) => env.find((entry) => entry && entry.name === name) || {};
const actualPrompt = String(find('SQUAD_PROMPT').value || '');
const actualBytes = Buffer.from(actualPrompt, 'utf8').toString('base64');
const expectedBytes = Buffer.from(prompt, 'utf8').toString('base64');
process.stdout.write(JSON.stringify({
  api: Object.keys(body).sort().join('+'),
  session: find('SESSION_NAME').value || '',
  podId: find('SQUAD_POD_ID').value || '',
  otel: find('OTEL_SERVICE_NAME').value || '',
  secretRef: find('OTEL_EXPORTER_OTLP_HEADERS').secretRef || '',
  exact: actualBytes === expectedBytes,
  actualBytes,
  expectedBytes
}));
NODE
)"
assert_contains "$summary" '"api":"containers"' "body build: only StartJobExecutionTemplate properties are sent (no manualTriggerConfig)"
assert_contains "$summary" '"session":"session-123"' "body build: session name carried"
assert_contains "$summary" '"podId":"session-123"' "body build: SQUAD_POD_ID carried"
assert_contains "$summary" '"otel":"squad-session-123"' "body build: OTEL_SERVICE_NAME carried"
assert_contains "$summary" '"secretRef":"otlp-headers"' "body build: secretRef entries are preserved"
assert_contains "$summary" '"exact":true' "body build: prompt bytes survive JSON construction exactly"

printf 'SQUAD_PROMPT=secretref:github-token\0' > "$env_file"
squad_build_job_start_body "$job_file" "$env_file" > "$body_file"
literal_prompt_summary="$(node - "$body_file" <<'NODE'
const fs = require('fs');
const body = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const prompt = (body.containers?.[0]?.env || []).find((entry) => entry && entry.name === 'SQUAD_PROMPT') || {};
process.stdout.write(JSON.stringify(prompt));
NODE
)"
assert_contains "$literal_prompt_summary" '"value":"secretref:github-token"' "body build: SQUAD_PROMPT stays literal even when it starts with secretref:"
assert_not_contains "$literal_prompt_summary" '"secretRef"' "body build: SQUAD_PROMPT is never upgraded into a secretRef"

cap_ok="$(node -e 'process.stdout.write("a".repeat(100000))')"
if squad_assert_prompt_byte_cap "$cap_ok" "SQUAD_PROMPT" >/dev/null 2>&1; then
  cap_ok_rc=0
else
  cap_ok_rc=1
fi
assert_eq "0" "$cap_ok_rc" "prompt cap helper: accepts 100000 bytes"

cap_bad="$(node -e 'process.stdout.write("a".repeat(100001))')"
if cap_err="$(squad_assert_prompt_byte_cap "$cap_bad" "SQUAD_PROMPT" 2>&1 >/dev/null)"; then
  cap_bad_rc=0
else
  cap_bad_rc=1
fi
assert_eq "1" "$cap_bad_rc" "prompt cap helper: rejects 100001 bytes"
assert_contains "$cap_err" '100000 UTF-8 bytes' "prompt cap helper: reports cap"
assert_contains "$cap_err" '100001' "prompt cap helper: reports actual size"
assert_contains "$(squad_arm_job_url sub rg job)" 'https://management.azure.com/subscriptions/sub/resourceGroups/rg/providers/Microsoft.App/jobs/job' "url helper: builds ARM job URL"

test_summary
