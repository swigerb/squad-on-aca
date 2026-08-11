#!/usr/bin/env bash
# The test fixture's own HTTPS git server must never hang its client.
#
# `worker/tests/lib/fake-git-https-server.js` builds its whole response inside
# `child.on('close')`, so the client receives nothing at all until
# `git-http-backend` exits AND every one of its pipes closes. Nothing bounded
# that, and `git` applies no timeout of its own -- so a backend that blocks
# meant `git clone` waited forever.
#
# That is issue #96. A clone against this fixture was observed stuck for over
# seven minutes with the backend still running, which is what made
# test_credential_withholding.sh hang intermittently and, before the per-suite
# timeout existed, hung the CI job itself.
#
# This drives the failure DELIBERATELY rather than waiting for the race: the
# fixture is pointed at a backend that never exits, which is the condition the
# real hang produced by accident. A control that only fires under a race
# cannot be shown to work.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pass=0
fail=0

ok()   { pass=$((pass + 1)); printf 'ok - %s\n' "$1"; }
bad()  { fail=$((fail + 1)); printf 'FAIL: %s\n' "$1"; }

need() {
  command -v "$1" >/dev/null 2>&1 || { printf 'SKIP: %s — missing %s\n' "$(basename "$0")" "$1"; exit 0; }
}
need node
need openssl
need git

echo "== fixture git server: a stuck backend must not hang the client (issue #96) =="

WORK="$(mktemp -d -t squad-fixture-timeout.XXXXXXXXXXXX)"
cleanup() {
  [[ -n "${SERVER_PID:-}" ]] && kill "$SERVER_PID" 2>/dev/null
  # Clean up after ourselves. This suite deliberately starts a backend that
  # never exits, and leaving it running for the remainder of the job is
  # antisocial whatever else it does -- a test that hunts leaked processes
  # must not leak its own.
  for f in "$WORK/backend.pid" "$WORK/backend-child.pid"; do
    p="$(cat "$f" 2>/dev/null)"
    [[ -n "$p" ]] && kill -9 "$p" 2>/dev/null
  done
  rm -rf "$WORK"
}
trap cleanup EXIT

mkdir -p "$WORK/srv" "$WORK/tls"
git init --bare --quiet "$WORK/srv/repo.git"
printf 'a-token\n' > "$WORK/srv/accepted-token"
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$WORK/tls/key.pem" \
  -out "$WORK/tls/cert.pem" -days 1 -subj '/CN=localhost' >/dev/null 2>&1

# A "backend" that reads nothing and never exits -- the shape a genuinely
# stuck git-http-backend presents to the fixture. It records its own pid and
# its child's, so survival is checked by PID rather than by a name match:
# `pgrep -f blocking-backend.sh` also matches the shell running the pgrep,
# which would report a survivor that does not exist.
cat > "$WORK/blocking-backend.sh" <<BACKEND
#!/usr/bin/env bash
echo \$\$ > "$WORK/backend.pid"
sleep 3600 &
echo \$! > "$WORK/backend-child.pid"
wait
BACKEND
chmod +x "$WORK/blocking-backend.sh"

TIMEOUT_MS=3000
node "$HERE/lib/fake-git-https-server.js" \
  --root "$WORK/srv" --cert "$WORK/tls/cert.pem" --key "$WORK/tls/key.pem" \
  --token-file "$WORK/srv/accepted-token" --auth-log "$WORK/srv/auth.log" \
  --request-log "$WORK/srv/request.log" --port-file "$WORK/srv/port" \
  --backend "$WORK/blocking-backend.sh" \
  --backend-timeout-ms "$TIMEOUT_MS" >"$WORK/server.out" 2>&1 &
SERVER_PID=$!

for _ in $(seq 1 100); do
  [[ -s "$WORK/srv/port" ]] && break
  sleep 0.1
done
PORT="$(cat "$WORK/srv/port" 2>/dev/null)"
if [[ -z "$PORT" ]]; then
  bad "the fixture server never reported a port; nothing below was exercised"
  printf '\n%s assertions run, %s failed.\n' "$((pass + fail))" "$fail"
  exit 1
fi
ok "CONTROL: the fixture server started and is listening"

# The property: a client gets an ANSWER, in bounded time, rather than waiting.
started=$(date +%s)
code="$(curl -k -s -o /dev/null -w '%{http_code}' --max-time 30 \
  -u "x:a-token" "https://localhost:${PORT}/repo.git/info/refs?service=git-upload-pack" 2>/dev/null)"
elapsed=$(( $(date +%s) - started ))

if [[ "$code" == "504" ]]; then
  ok "a backend that never exits produces a 504 -- the client is answered, not left waiting"
else
  bad "a stuck backend returned '$code'; before the timeout existed the client hung forever (expected 504)"
fi

# Bounded BOTH ways. An upper bound alone passes if the request failed
# instantly for some unrelated reason, which would mean the hang was never
# exercised at all.
if (( elapsed <= 20 )); then
  ok "the answer arrived in ${elapsed}s, bounded by the fixture's own timeout"
else
  bad "the answer took ${elapsed}s; the timeout is not bounding anything"
fi
if (( elapsed * 1000 >= TIMEOUT_MS / 2 )); then
  ok "it waited for the timeout rather than failing instantly -- the stuck backend was really reached"
else
  bad "the request failed in ${elapsed}s, faster than the ${TIMEOUT_MS}ms timeout: the hang was never exercised"
fi

# The direct backend must be gone. Its grandchild is deliberately NOT this
# fixture's job: the backend stays in the suite's process group, so
# run-tests.sh's own group sweep reaches every descendant. Detaching to signal
# a group here would take the backend OUT of that group and let it outlive the
# suite -- the very leak being fixed.
sleep 1
backend_pid="$(cat "$WORK/backend.pid" 2>/dev/null)"
if [[ -n "$(cat "$WORK/backend-child.pid" 2>/dev/null)" ]]; then
  ok "CONTROL: the stuck backend really did fork a grandchild, so this checks something"
else
  bad "the backend never recorded a grandchild; the survival check below proves nothing"
fi
if [[ -n "$backend_pid" ]] && kill -0 "$backend_pid" 2>/dev/null; then
  bad "the stuck backend ($backend_pid) survived its own timeout"
else
  ok "the stuck backend was killed when its timeout expired"
fi

printf '\n%s assertions run, %s failed.\n' "$((pass + fail))" "$fail"
[[ "$fail" -eq 0 ]]
