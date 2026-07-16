#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"
. worker/tests/lib/assert.sh

PWSH_BIN="$(worker/tests/lib/get-pwsh.sh)"
export DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1
WORK_DIR="worker/tests/.work/cli"
BIN_DIR="$WORK_DIR/bin"
HOME_DIR="$WORK_DIR/home"
STATE_PATH="$WORK_DIR/fake-state.json"
AZ_LOG_FILE="$WORK_DIR/az.log"
rm -rf "$WORK_DIR"
mkdir -p "$BIN_DIR" "$HOME_DIR/.squad-on-aca"
cat > "$HOME_DIR/.squad-on-aca/config.json" <<'JSON'
{
  "resourceGroup": "rg-test",
  "sessionJob": "job-test",
  "ralphJob": "ralph-test",
  "watchApp": "watch-test",
  "aspireApp": "aspire-test"
}
JSON

cat > "$BIN_DIR/az" <<'EOF_AZ'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >> "$AZ_LOG_FILE"
case "$*" in
  containerapp\ job\ show*)
    echo "/subscriptions/mock/resourceGroups/rg-test/providers/Microsoft.App/containerApps/job-test"
    ;;
  containerapp\ job\ start*)
    echo '{"name":"aca-exec-0001","id":"/subscriptions/mock/executions/aca-exec-0001"}'
    ;;
  containerapp\ job\ update*)
    echo '{}'
    ;;
  containerapp\ job\ execution\ list*)
    echo '[{"name":"aca-exec-0001","properties":{"status":"Running","startTime":"2026-07-16T00:00:00Z","endTime":null}}]'
    ;;
  containerapp\ job\ execution\ show*)
    cat <<'JSON'
{"properties":{"status":"Running","startTime":"2026-07-16T00:00:00Z","endTime":null,"template":{"containers":[{"env":[{"name":"SESSION_NAME","value":"aca-session"},{"name":"SQUAD_MODE","value":"prompt"},{"name":"GITHUB_REPOSITORY","value":"owner/repo"},{"name":"GITHUB_REF","value":"main"}]}]}}}
JSON
    ;;
  containerapp\ job\ logs\ show*)
    echo 'aca mock logs'
    ;;
  containerapp\ job\ stop*)
    if [[ -n "${AZ_STOP_STDERR:-}" ]]; then
      printf '%s\n' "$AZ_STOP_STDERR" >&2
    fi
    echo "${AZ_STOP_STDOUT:-native stop output}"
    exit "${AZ_STOP_EXIT_CODE:-0}"
    ;;
  containerapp\ list*)
    echo 'NAME  STATE'
    ;;
  containerapp\ show*)
    echo 'aspire.example.test'
    ;;
  containerapp\ logs\ show*)
    echo 'watcher logs'
    ;;
  *)
    echo '{}'
    ;;
esac
EOF_AZ
chmod +x "$BIN_DIR/az"

export AZ_LOG_FILE
FAKE_ENV=(HOME="$HOME_DIR" SQUAD_ACA_PROVIDER="fake" SQUAD_ACA_FAKE_STATE_PATH="$STATE_PATH")
ACA_ENV=(HOME="$HOME_DIR" PATH="$BIN_DIR:$PATH")

fake_start_output="$(env "${FAKE_ENV[@]}" "$PWSH_BIN" -NoLogo -NoProfile -File scripts/start-session.ps1 -ResourceGroupName rg-test -JobName job-test -Repository owner/repo -Ref main -Mode prompt -SessionName fake-session -Prompt 'build feature' -OutputBranch squad/fake-session)"
printf '%s\n' "$fake_start_output" > "$WORK_DIR/fake-start.json"
fake_id="$(node -e "const fs=require('fs');const data=JSON.parse(fs.readFileSync(process.argv[1],'utf8'));process.stdout.write(data.id);" "$WORK_DIR/fake-start.json")"

sessions_output="$(env "${FAKE_ENV[@]}" "$PWSH_BIN" -NoLogo -NoProfile -File scripts/squad-aca.ps1 sessions)"
assert_contains "$sessions_output" 'fake-session' 'sessions command should show fake session'
logs_output="$(env "${FAKE_ENV[@]}" "$PWSH_BIN" -NoLogo -NoProfile -File scripts/squad-aca.ps1 logs "$fake_id")"
assert_contains "$logs_output" '[fake-provider] created execution' 'logs command should read fake provider logs'
stop_output="$(env "${FAKE_ENV[@]}" "$PWSH_BIN" -NoLogo -NoProfile -File scripts/squad-aca.ps1 stop "$fake_id")"
assert_contains "$stop_output" 'Stopped fake-exec-0001' 'stop command should preserve execution-oriented output'

resolve_output="$(env HOME="$HOME_DIR" "$PWSH_BIN" -NoLogo -NoProfile -File scripts/squad-aca.ps1 resolve --manifest worker/tests/fixtures/satisfied.yml)"
printf '%s\n' "$resolve_output" > "$WORK_DIR/resolve.json"
assert_json_file_equals "$WORK_DIR/resolve.json" "worker/tests/fixtures/expected/satisfied.json"

: > "$AZ_LOG_FILE"
aca_start_output="$(env "${ACA_ENV[@]}" "$PWSH_BIN" -NoLogo -NoProfile -File scripts/start-session.ps1 -ResourceGroupName rg-test -JobName job-test -Repository owner/repo -Ref main -Mode prompt -SessionName aca-session -Prompt 'ship it' -OutputBranch squad/aca-session)"
assert_contains "$aca_start_output" 'aca-exec-0001' 'ACA provider start should surface execution metadata'
az_log_contents="$(cat "$AZ_LOG_FILE")"
assert_contains "$az_log_contents" 'containerapp job start --name job-test --resource-group rg-test --env-vars' 'start-session should use per-execution env vars'
assert_contains "$az_log_contents" 'SQUAD_PROMPT=ship it' 'prompt override should flow through provider contract'
assert_contains "$az_log_contents" 'OUTPUT_BRANCH=squad/aca-session' 'output branch override should flow through provider contract'
assert_not_contains "$az_log_contents" 'containerapp job update' 'start-session must not mutate the ACA job template'

status_output="$(env "${ACA_ENV[@]}" "$PWSH_BIN" -NoLogo -NoProfile -File scripts/squad-aca.ps1 status)"
assert_contains "$status_output" 'Container Apps:' 'status command should preserve heading'
assert_contains "$status_output" 'Recent job executions:' 'status command should include executions section'
assert_contains "$status_output" 'Aspire dashboard: https://aspire.example.test' 'status command should preserve dashboard output'

: > "$AZ_LOG_FILE"
aca_stop_output="$(env "${ACA_ENV[@]}" "$PWSH_BIN" -NoLogo -NoProfile -File scripts/squad-aca.ps1 stop aca-session)"
assert_contains "$aca_stop_output" 'native stop output' 'ACA stop should pass through native az output'
assert_not_contains "$aca_stop_output" 'Stopped aca-exec-0001' 'ACA stop should not add wrapper output'
aca_stop_log="$(cat "$AZ_LOG_FILE")"
assert_contains "$aca_stop_log" 'containerapp job stop --name job-test --resource-group rg-test --job-execution-name' 'ACA stop should invoke native az stop'

set +e
aca_stop_fail_output="$(env AZ_STOP_EXIT_CODE=17 AZ_STOP_STDOUT='' AZ_STOP_STDERR='native stop failure' "${ACA_ENV[@]}" "$PWSH_BIN" -NoLogo -NoProfile -File scripts/squad-aca.ps1 stop aca-session 2>&1)"
aca_stop_fail_status=$?
set -e
assert_eq '17' "$aca_stop_fail_status" 'ACA stop should preserve native exit code'
assert_contains "$aca_stop_fail_output" 'native stop failure' 'ACA stop should preserve native stderr'

: > "$AZ_LOG_FILE"
ralph_output="$(env "${ACA_ENV[@]}" "$PWSH_BIN" -NoLogo -NoProfile -File scripts/squad-aca.ps1 ralph run --repo owner/repo)"
ralph_log="$(cat "$AZ_LOG_FILE")"
assert_contains "$ralph_log" 'containerapp job update --name ralph-test --resource-group rg-test --set-env-vars GITHUB_REPOSITORY=owner/repo' 'ralph run should still update the Ralph job repo target'
assert_contains "$ralph_log" 'containerapp job start --name ralph-test --resource-group rg-test' 'ralph run should still start the Ralph job'
assert_contains "$ralph_output" 'aca-exec-0001' 'ralph run should still surface start output'

entrypoint_watch_line="$(grep -nF -- '--max-concurrent "${WATCH_MAX_CONCURRENT:-1}"' worker/entrypoint.sh)"
assert_contains "$entrypoint_watch_line" '--max-concurrent "${WATCH_MAX_CONCURRENT:-1}"' 'watch concurrency default must remain unchanged'

printf 'cli/provider regression tests passed\n'
