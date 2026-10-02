# Security re-review — fixes for `security-review-112-113.md`

**Reviewer:** Security (appsec specialist)
**Date:** 2026-10-01
**Branch:** `feat/squad-0.13-alignment` @ `24b7143`
**Scope:** `8285886`, `24b7143` (fix commits) + `1a496bb`, `b268d80` (regression check)
**Mode:** read-only. No repo file modified. All scratch artefacts deleted.

Method: for every original finding that had a *working attack string*, I re-ran that exact attack
against the current tree and recorded whether it still works — **before** looking at the author's new
tests. Where the attack now fails, I then confirmed the author's test actually exercises the real
code path rather than a stand-in. Where the attack still works, I built a minimal repro and recorded
the observed output verbatim.

---

## 1. Per-finding closure table

| # | Sev (orig) | Verdict | Confidence |
|---|---|---|---|
| F1 | CRITICAL | **CLOSED** | 9/10 |
| F2 | HIGH | **CLOSED** | 10/10 |
| F3 | HIGH | **CLOSED** | 9/10 |
| F4 | HIGH | **PARTIALLY CLOSED** (2 proven bypasses) | 9/10 |
| F5 | MEDIUM | **CLOSED** for the original repro; new opposite-direction leak (→ N4) | 9/10 |
| F6 | MEDIUM | **PARTIALLY CLOSED** (1 proven bypass) | 9/10 |
| F7 | MEDIUM | **PARTIALLY CLOSED** | 8/10 |
| F8 | MEDIUM | **PARTIALLY CLOSED** (2 proven bypasses) | 10/10 |
| F9 | MEDIUM | **CLOSED** | 9/10 |
| F10 | LOW | **CLOSED** | 10/10 |
| F11 | LOW | not re-reviewed (original verdict: not worth a fix) | — |
| S1 | suspected | **NOT CLOSED — the commit's stated justification is factually false** | 10/10 |

### F1 — CRITICAL — `squad-agent` wrapper writable by the `squad` user — **CLOSED**

Evidence (reading the FINAL layer ordering, which is where this gets subtly wrong):

```
worker/Dockerfile:187  COPY --chown=root:root worker/entrypoint.sh /usr/local/bin/squad-on-aca
worker/Dockerfile:188  COPY --chown=root:root worker/squad-agent ... /usr/local/lib/squad-on-aca/
worker/Dockerfile:189  RUN sed -i 's/\r$//' ...        <- root, before the a-w
worker/Dockerfile:190      && chmod +x ...              <- root, before the a-w
worker/Dockerfile:201      && chmod -R a-w /usr/local/lib/squad-on-aca /usr/local/bin/squad-on-aca
worker/Dockerfile:213  ENTRYPOINT ["/usr/local/bin/squad-on-aca"]
```

* `chmod -R a-w` (201) is the **last** step of that RUN. Lines 202–212 are comments + `WORKDIR` +
  `ENTRYPOINT`; **nothing after 201 re-COPYs, re-chmods or re-chowns either destination.** The
  "a later step undoes an earlier one" failure mode does not occur.
* `squad` is neither `root` nor in group `root`, so it falls to the `other` class — `a-w` strips its
  write bit. Ownership root + no write bit = the wrapper cannot be rewritten by the agent.
* **Does `a-w` break a legitimate runtime function?** I grepped every runtime reference to
  `/usr/local/lib/squad-on-aca` across the repo (entrypoint.sh, ralph-dispatch.sh, squad-agent,
  deploy.ps1, both Dockerfiles, all tests). Every one is `source` / `node` / `exec` / `test -x` /
  `test -f` — i.e. read or execute. **There is no runtime writer.** Confirmed the derived image
  `worker/images/python/Dockerfile` only writes `/usr/local/lib/python3.12` and
  `libpython3.12.so.1.0`, and its `USER squad` build-time smoke test (lines 96–101) only does
  `test -x` / `test -f` against the squad-on-aca dir. `a-w` is safe.
* `worker/tests/test_image_layout.sh` extracts the real `chmod -R a-w` command from the Dockerfile
  text and runs it against a materialised layout (not a hard-coded copy), so deleting the line from
  the Dockerfile breaks the test. Good test design. Ran it: `25 assertions run, 1 failed` — the one
  failure is T9/CRLF, which is **pre-existing** (T9 is present at `1a496bb`, before the fix commits)
  and is a Windows-checkout harness artefact; the real Dockerfile names `proc-isolation-probe.sh`
  explicitly in its sed list at line 189. Not a regression, not security-relevant (→ N7).

Residual 1/10: I cannot build the image (prohibited), so this is layer-arithmetic + a materialised
simulation rather than an `ls -l` inside the real image.

### F2 — HIGH — `SQUAD_COPILOT_FLAGS` injects `--allow-all-urls` — **CLOSED**

**Original attack, re-run verbatim:**

```
$ SQUAD_COPILOT_FLAGS='--allow-all-urls --allow-tool shell' \
    node worker/lib/agent-policy.js watch-agent-argv-json
... refusal message ...
rc = 78
```

Previously this landed verbatim in the resolved argv. It now aborts. I then walked the full matrix
through the three independent gates (resolver env-scrub, wrapper `POLICY_ARGV_FORBIDDEN`, wrapper
`TRAILING_ARGV_FORBIDDEN`) plus `squad_policy_resolve`:

| injected | resolver | policy-argv gate | trailing-argv gate |
|---|---|---|---|
| `--allow-all-urls` | 78 | 78 | 78 |
| `--allow-all-urls=1` (`=`-form) | 78 | 78 | 78 |
| `--allow-all-paths` | 78 | 78 | 78 |
| `--allow-all` | 78 | 78 | 78 |
| `--yolo` | 78 | 78 | 78 |
| `--add-dir` / `--add-dir=/etc` | 78 | 78 | 78 |
| `--allow-all-tools` | ok (legitimate, required) | ok | **78** (correct) |

`worker/tests/test_squad_agent_wrapper.sh`: `79 assertions run, 0 failed`.

*Residual, not a reopen:* `--allow-tool <x>` is still accepted from the environment (my original text
said only "consider"). It cannot re-grant anything `--allow-all-tools` has not already granted, and
it cannot defeat a `--deny-tool`, so it is not an escalation — see §5.

### F3 — HIGH — PARITY mode silently drops the undeliverable set — **CLOSED**

`worker/entrypoint.sh:443-452` `squad_watch_policy_announce_undelivered()` restores the loud line:

```
NOT enforced on this path: <list>   +  reason  +  "set SQUAD_WATCH_STRICT_POLICY=true to refuse ..."
```

and in strict mode prints an explicit "nothing is undeliverable" line (so silence is never ambiguous).
Called at `:985` (loop) and `:1124` (watch|triage), immediately after the argv log line — i.e. on
every path that previously went quiet.

Verified the set is non-empty in reality (an announcement of an empty list would be decorative):
`SQUAD_POLICY_UNDELIVERABLE` resolves to **9** entries —
`shell(git config) shell(gh auth) shell(gh secret) shell(gh variable) shell(gh api)
shell(gh repo delete) shell(gh release delete) shell(git push) shell(gh pr)`.

`worker/tests/test_security_f3_parity_announce.sh`: `18 assertions run, 0 failed`.

### F4 — HIGH — append-only check defeated by truncate-to-exact-baseline — **PARTIALLY CLOSED**

**Positive control (the fix genuinely works when it gets to observe):** grew
`.squad/memory/audit.jsonl` 35 → 51 bytes, forced one high-water sample, truncated back to the exact
baseline length *and* baseline hash, then ran verify:

```
VERIFY_RC=1
  ".squad/memory/audit.jsonl grew to 51 bytes ... then TRUNCATED BACK to its exact
   baseline length and hash (35 bytes / 6fa9faf3...)"
```

The original attack string is caught. **But two bypasses survive, both proven:**

**A1 (PROVEN) — the sampling window.** Same attack with **no sample tick between grow and truncate**
(the production default is `SQUAD_POLICY_HIGHWATER_INTERVAL_SECONDS=5`, and
`squad_policy_highwater_sampler_start` is a plain `sleep` loop):

```
VERIFY_RC=0
HWM_STATE: append-only .squad/memory/audit.jsonl 35
```

Appending and truncating inside one 5-second window is entirely invisible. This is not a corner
case: `printf ... >> audit.jsonl; truncate -s 35 audit.jsonl` takes microseconds. The enforcement is
**sample-rate-limited, not an invariant.** The author's own F4 regression test in
`worker/tests/test_governance_guard.sh` calls `squad_policy_highwater_scan` **manually** "to stand in
for the sampler ticking" — so the suite never exercises the real timing and structurally cannot
catch A1.

**A2 (PROVEN) — delete the state.** Tick normally, then `rm -f "$SQUAD_POLICY_STATE_DIR/highwater.state"`:

```
VERIFY_RC=0
```

The loader falls back to `${...:-$blen}`, i.e. "high-water == baseline", i.e. nothing ever grew.
A3 (rewriting the state to ≤ baseline) is equivalent; rewriting to > baseline still trips the check,
so the agent simply deletes rather than forges.

A2 is an instance of **N1** below — the state directory is writable by the same uid as the agent.

### F5 — MEDIUM — classifier answered `locked` for files that are not locked — **CLOSED** (original repro) + new leak

Original repro re-run via `node worker/lib/agent-policy.js classify-governance-path <p>` over ~40
real and crafted paths:

| path | before | now |
|---|---|---|
| `.mcp.json` | `locked` | `not-governance` ✅ |
| `.squad/team.md` | `locked` | `not-governance` ✅ |
| `.squad/decisions.md` | `locked` | `not-governance` ✅ |
| `.squad/ralph-instructions.md` | `locked` | `not-governance` ✅ |
| `.squad/casting-registry.json` | `locked` | `not-governance` ✅ |

**The opposite leak you asked me to hunt — does a genuinely governed path now get coaxed into
`not-governance`?** I re-ran every traversal/crafted case from the original review:

```
.squad/identity/now.md/../mission.md   -> locked   (fails safe)
.squad/identity/./now.md               -> locked
.squad/identity/now.md/.               -> locked
.squad//identity//now.md               -> locked
../etc/passwd                          -> locked
/etc/passwd                            -> locked
C:\...\.squad\identity\now.md          -> locked
```

All still fail safe. **One real leak found, case:** the classifier is purely lexical and
case-sensitive, so `.SQUAD/identity/mission.md`, `.Squad/agents/security/charter.md`,
`.squad/IDENTITY/mission.md`, `.squad/Agents/security/charter.md`, `.SQUAD/memory/audit.jsonl`,
`.squad/memory/AUDIT.JSONL` all now answer `not-governance`. Also bare `.squad` → `not-governance`
while `.squad/` → `locked`. On Linux (case-sensitive fs) this is harmless; on a Windows/macOS host
running `scripts/validate.ps1` it under-reports a genuinely governed file. Tracked as **N4 (LOW)** —
the classifier is advisory/diagnostic, real enforcement is chmod + manifest on real paths, so this is
a reporting inaccuracy, not a bypass.

### F6 — MEDIUM — modify-then-revert invisible — **PARTIALLY CLOSED**

The sticky `everdiffered` flag works **when a sample lands between the modify and the revert**.

**A4 (PROVEN bypass):** modify `.squad/identity/now.md` → tick →
`rm -f "$SQUAD_POLICY_STATE_DIR/highwater.state"` → revert:

```
VERIFY_RC=0
now.md mentioned in output? 0
```

Completely silent again, exactly as before the fix. F6 also inherits A1's sampling-window gap
verbatim. Same root cause: **N1**.

### F7 — MEDIUM — governance report not durable — **PARTIALLY CLOSED**

`worker/entrypoint.sh:534-556` `squad_watch_governance_report_if_any()` appends to
`${SQUAD_POLICY_STATE_DIR}/reported-changes.md`; wired at `:1000` (loop) and `:1171` (watch), after
`squad_policy_checkpoint`. `worker/tests/test_security_f7_watch_loop_governance_report.sh`:
`16 assertions run, 0 failed`.

Why only partial:

1. The file lives in the **agent-writable** state dir (N1) — the agent can delete or rewrite its own
   incident report.
2. It lives in an ephemeral ACA container's `$HOME` and **nothing ships it out**. The original ask
   was for an artefact a human reviewer actually sees. "Durable" overstates what was built: it
   survives the loop iteration, not the container.
3. `squad_policy_checkpoint` can `exit 78` on a violation and the report call is *after* it — so on
   the most interesting path (an actual violation) the durable report is never written.

(3) is the one I would call a real defect rather than a scope question.

### F8 — MEDIUM — `.mcp.json` TOCTOU — **PARTIALLY CLOSED**

**Is the TOCTOU itself closed? Yes.** The wrapper reads the file **once** and hashes that same read,
so there is no re-read between check and use.

```
A5a: baseline intact + tampered .mcp.json
  -> rc 78, "It may have been rewritten to point at an attacker-controlled MCP server;
             refusing to load it."
```

**Can the stored hash be defeated? Yes — two proven fail-open bypasses:**

```
A5b (PROVEN): rm -f "$SQUAD_POLICY_STATE_DIR/mcp-config.sha256"; tamper .mcp.json
  -> RC=0 ; "copilot got mcp config? 1"   (tampered config loaded)

A5c (PROVEN): rewrite mcp-config.sha256 to the hash of the tampered file
  -> RC=0 ; tampered config loaded
```

A5b is not an oversight — the code comment designs it that way ("A MISSING baseline ... is not itself
a violation"). That is the wrong default: after `squad_policy_harden` has *recorded* a baseline, its
subsequent absence is evidence of tampering, not of a fresh start. Tracked as **N3**.

(A5d: unsetting `SQUAD_POLICY_STATE_DIR` in the child env also skips the check, but the agent cannot
alter the parent's exported env, so I am not counting it.)

### F9 — MEDIUM — harden log claimed protection it did not provide — **CLOSED**

`worker/lib/squad-policy.sh:528-537` `squad_policy_parent_dir_is_locked()` prefix-matches the file's
parent against `SQUAD_POLICY_GOVERNANCE_PATHS`, and the log now branches. Real observed harden output:

```
Their containing directories do NOT stay locked (not a GOVERNANCE_PATHS directory entry):
  .squad/memory/audit.jsonl
Their containing directories stay locked, so no file can be created or deleted beside them:
  .squad/identity/now.md
```

Both halves are true: `.squad/identity` *is* a `GOVERNANCE_PATHS` entry and is `chmod a-w`'d;
`.squad/memory` is not. **The log no longer lies.** The underlying gap (those directories are still
not locked) remains and is now documented rather than hidden — which is what I asked for.

Cross-platform check: the 7 failures in `test_governance_guard.sh` on this Windows host are all
directory-permission-bit assertions (`a new file cannot be created inside a protected directory`,
`... cannot be deleted`, the `.squad/agents/` create/delete set, the unlink-needs-parent-write case).
Those are the known Windows ACL limitation, not F9 regressions — and they are exactly the assertions
that cannot be meaningful on NTFS via MSYS.

### F10 — LOW — argv transport could mangle multi-word elements — **CLOSED**

```
["--deny-tool","","shell(x)"]            -> rc 78, 0 argv elements dumped
["--deny-tool","shell(a)\nshell(b)"]     -> rc 78, 0 argv elements dumped
["--allow-all-tools","--deny-tool","shell(git push)"] -> rc 0, 5 elements,
                                            "shell(git push)" intact as ONE element
```

Empty and newline-bearing elements are now rejected at the node parser. Multi-word patterns survive.

### S1 — suspected — symlinked governance directory — **NOT CLOSED; the commit's justification is false**

`24b7143`'s message concludes S1 is "already handled", on this claim:

> find descends into a directory named directly as a command-line operand even when that operand is
> itself a symlink (this is not governed by -P/-H/-L)

**That is wrong for GNU find's default `-P`.** Run on real Linux (WSL2, GNU findutils 4.8.0 — the
same generation as the Debian base image), reproducing `worker/lib/squad-policy.sh:881` exactly:

```
operand symlink: yes
--- find DIR -type f (default -P, exactly squad-policy.sh:881) ---
rc=0            <- ZERO files printed
--- find -L ---
/home/.../repo/.squad/agents/security/charter.md
--- chmod -R a-w on the symlink operand ---
rc=0
-r--r--r-- 1 ... /home/.../real/security/charter.md
```

Also reproduced with GNU findutils 4.11.0 on the Windows host using
`MSYS=winsymlinks:nativestrict`, and end-to-end: a real `squad_policy_harden` against a repo whose
`.squad/agents` is a genuine symlink produced a manifest containing **only `dir .squad/agents` and
zero `file` lines**.

So the true position is split, and the commit got half of it right by accident:

* **Prevention HOLDS.** `chmod -R a-w` on the symlink operand *does* follow through to the real
  target (`-r--r--r--` above), and a write through the symlink was refused.
* **Detection is LOST.** The manifest captures no per-file hashes behind the symlink, so every
  modify / revert / truncate detector (F4, F6, and the manifest diff itself) is blind there.

**Why the author's new test passes anyway:** `worker/tests/test_governance_guard.sh` does `ln -s`
under MSYS, where the default `winsymlinks` behaviour is to **copy the directory**, not create a
symlink. The test therefore never constructs the shape it claims to test, and is green on Windows for
a reason that has nothing to do with the code. This is precisely the "artifact of how the test was
written" you asked me to check for — **S1's "already handled" conclusion is an artefact.**

---

## 2. Per-commit verdicts

| commit | scope | verdict |
|---|---|---|
| `8285886` | F1, F3, F7 | **APPROVED WITH FINDINGS** |
| `24b7143` | F2, F4, F5, F6, F8, F9, F10, S1 | **REJECTED** |
| `1a496bb` | perf refactor of policy bundle transport | **APPROVED** |
| `b268d80` | #115 signal forwarding | **APPROVED WITH FINDINGS** |

**`8285886` — APPROVED WITH FINDINGS.** F1 and F3 are properly closed with ordering-correct,
mutation-resistant tests. F7 is partial: the report is written to an agent-writable, container-local
path and is skipped on the violation path (`checkpoint` exits 78 first). Not blocking.

**`24b7143` — REJECTED.** F2, F5, F9, F10 are genuinely closed and well done. But:

* F4, F6, F7 and F8 all rest on a trust boundary that **does not exist** (N1). Four proven bypasses
  (A2, A4, A5b, A5c) all reduce to "the agent can `rm` the state file".
* F4/F6 are additionally sample-rate-limited (A1) and the regression test cannot catch it, because it
  calls the scanner manually instead of letting the sampler run.
* S1 is marked resolved on a **factually false** claim about GNU `find`, backed by a test that does
  not construct a symlink on the platform it was run on.

A fix commit that closes four findings by writing state the attacker can delete has not closed them.

**`1a496bb` — APPROVED.** I treated this with the suspicion requested. The bundle transport does not
drop, reorder or mangle anything:

```
ARGV<->FLAGSTRING ROUND-TRIP: IDENTICAL (48 elements, no drop/reorder/mangle)
deny-tool flags: 21 / shell(...) patterns: 21     (perfectly paired)
GOVPATHS IDENTICAL (15 entries)   MUTABLE IDENTICAL (2)   REPORTED IDENTICAL (4)
```

i.e. the single `bundle` call produces byte-identical output to the individual CLI verbs it replaced,
and the bash-side array joins back to the canonical flag string exactly. The parser is count-prefixed
and uses `IFS= read -r`, so spaces, order and empties are preserved. Failure direction is correct:
unrecognised lines are ignored → empty arrays → "nothing excluded, everything stays locked"
(fail-closed). No repeat of the correctness bug this file shipped before.

**`b268d80` — APPROVED WITH FINDINGS.** Teardown is preserved on the normal path:
`squad_run_foreground_with_signal_forwarding` does the "wait twice" trap dance, returns the child's
real rc, and `squad_policy_checkpoint` + `squad_watch_governance_report_if_any` still run after it.
`test_signal_forwarding.sh`: `19 assertions run, 0 failed`. Backgrounding the child did **not** create
a window where the checkpoint is skipped on normal exit. One residual window (N5) and one inherited
behaviour: `set -Eeuo pipefail` means a non-zero return from the forwarding function aborts before
the checkpoint — same as pre-#115, so not a regression.

---

## 3. NEW findings

### N1 — HIGH (arguably CRITICAL) — PROVEN — the policy state directory is owned and writable by the agent

**This is the root cause behind A2, A3, A4, A5b and A5c.**

Attack path:

1. `squad_policy_state_dir()` (`worker/lib/squad-policy.sh:310`) resolves to
   `${HOME:-/tmp}/.squad-policy/${SESSION_NAME:-session}`, `mkdir -p` + `chmod 700`.
2. `worker/entrypoint.sh:50,61` re-execs the entire entrypoint as the **`squad`** user
   (`exec env -u HOME runuser -p -u "$SQUAD_RUNTIME_USER" -- "$0" "$@"`). So `HOME=/home/squad` and
   the state dir is owned by uid `squad`, mode 0700.
3. The copilot agent **also runs as `squad`**. `0700` protects it from nobody.
4. The resolved watch argv is `--allow-all-tools` with deny rules only for
   `shell(sudo|su|chmod|chown|chattr|setfacl|az|kubectl|terraform|docker|curl|wget)`. There is **no
   deny for `rm`, `sh`, `bash`, `node`, `printf`, `tee`, `truncate`, `mv`**.
5. Therefore `shell(rm -rf ~/.squad-policy/...)` is permitted, and so is
   `shell(sh -c 'sha256sum .mcp.json > ~/.squad-policy/*/mcp-config.sha256')`.

The code comments repeatedly justify this dir as "outside the agent's file-tool reach" because
`--allow-all-paths` is dropped. That is true for Copilot's *structured file tools* and **false for the
shell tool** — and it is self-inconsistent with F1, whose accepted attack was precisely a shell write
outside CWD (`printf ... > /usr/local/lib/squad-on-aca/squad-agent`). The same threat model that made
F1 CRITICAL makes N1 at least HIGH.

Effect: F4's high-water mark, F6's sticky flag, F7's durable report and F8's `.mcp.json` baseline are
all attacker-controlled. Four of the eight findings in `24b7143` are undone by one `rm`.

**Fix (pick one, in preference order):**

1. Write the state dir as a **different uid** than the agent — create it root-owned `0711` with
   `0600` files before the `runuser` drop, or reuse the existing `squad-identity` user from PC-2. The
   policy subsystem runs in the entrypoint, not in the agent, so it does not need the agent's uid.
2. Make the state **tamper-evident**: HMAC each state file with a key the agent cannot read
   (root-owned, or held only in the entrypoint's process memory).
3. At minimum, make **absence a violation**: if `squad_policy_harden` recorded `highwater.state` /
   `mcp-config.sha256`, then `squad_policy_verify` finding them missing or newer-than-expected must
   `exit 78`, never fall back to a default. (This alone kills A2, A4 and A5b, though not A5c.)

Options 1 and 3 are complementary; do both.

**Confidence: 9/10** (the bypasses are proven; the 1 point is that I could not confirm the exact
production `--deny-tool` set inside the running container rather than from the resolver).

**Assign to:** a third agent (engineer authored #112/#113; reviewer authored both fix commits —
neither may fix their own). This spans `worker/entrypoint.sh` + `worker/lib/squad-policy.sh`.

### N2 — HIGH — PROVEN — F4/F6 enforcement is sampling-rate-limited, not an invariant

`squad_policy_highwater_sampler_start` (`squad-policy.sh:760`) polls every
`SQUAD_POLICY_HIGHWATER_INTERVAL_SECONDS` (default 5) in a bash `sleep` loop. A grow-then-truncate
completed inside one interval is never observed (repro A1 above: `VERIFY_RC=0`). There is also an
unguarded window **before the first sample** and **between the last sample and verify**.

The regression test cannot catch this: it invokes `squad_policy_highwater_scan` manually as a
stand-in for the sampler, so the real timing is never exercised.

**Fix:** polling cannot make this an invariant — any interval leaves a window. Either (a) accept it
explicitly and *document the window* (and shorten it, and sample once immediately before verify as
well as at harden), or (b) move to an inotify-based watch (`inotifywait -m` on the mutable set), or
(c) make the mutable files append-only at the kernel level (`chattr +a`) so truncation is impossible
rather than merely observed. (c) is the only true fix; it needs CAP_LINUX_IMMUTABLE at harden time,
which the entrypoint has before the drop.

**Assign to:** same third agent as N1 (same files, same subsystem).
**Confidence: 9/10.**

### N3 — MEDIUM — PROVEN — F8 fails OPEN on a missing baseline, by explicit design

Repro A5b. A baseline that `harden` wrote and that is now absent is evidence, not a clean slate.

**Fix:** record in the state dir (or in the exported env the agent cannot touch) the fact that a
baseline *was* taken; if it was, a missing `mcp-config.sha256` at use time must be a refusal
(`exit 78`), not a skip. Pairs with N1's option 3.
**Confidence: 10/10.**

### N4 — LOW — PROVEN — `classify-governance-path` under-reports case-variant governed paths

`.SQUAD/identity/mission.md`, `.squad/Agents/...`, `.squad/memory/AUDIT.JSONL` → `not-governance`
(previously `locked`). Bare `.squad` → `not-governance`, `.squad/` → `locked`. Lexical,
case-sensitive matching. Harmless on Linux; misleading on Windows/macOS hosts running
`scripts/validate.ps1`. Advisory output only — not a bypass.

**Fix:** case-fold the comparison when `process.platform` is `win32`/`darwin`, or always (governance
paths are a fixed lowercase set, so case-folding cannot cause a false `not-governance`), and
normalise a trailing-slash-less directory operand.

### N5 — LOW — SUSPECTED — the governance checkpoint is unprotected during shutdown

`squad_run_foreground_with_signal_forwarding` does `trap - TERM INT` (restoring default disposition)
**before** returning, and `squad_policy_checkpoint` runs after that return. A SIGTERM — or ACA's
grace-period SIGKILL — arriving while `squad_policy_checkpoint` is running kills the entrypoint
outright and the governance verify is skipped. Not a regression (no checkpoint ran on SIGTERM before
#115 either), but #115 is what made the shutdown path a real, exercised code path.

**Fix:** keep the TERM/INT traps installed (ignoring, or deferring) until after the checkpoint and the
governance report have completed, then restore.
**Confidence: 6/10** — I reasoned this from the trap ordering; I did not race a real signal against a
real checkpoint.

### N6 — informational — dead code

`squad_policy_highwater_dir()` (`squad-policy.sh:589`) returns `$1/highwater`, but the state file
actually lives at `$1/highwater.state` and the function appears unused. A future caller reaching for
the "obvious" helper would silently look in the wrong place.

### N7 — informational — `test_image_layout.sh` T9 fails on a Windows checkout

`T9 ... CRLF line endings normalised away ... (expected: '0', actual: '294')`. **Pre-existing** (T9 is
present at `1a496bb`, before the fix commits) and not security-relevant — the real Dockerfile names
`proc-isolation-probe.sh` explicitly in its sed list at line 189. A harness artefact of the
materialise-then-sed step on NTFS. Worth fixing so the suite is green and a real regression is
visible.

---

## 4. HIGH-and-above fix assignments

| finding | fix | assign to |
|---|---|---|
| N1 | move the state dir off the agent's uid **and** make missing state a violation | third agent (not engineer, not reviewer) |
| N2 | `chattr +a` at harden, or inotify; failing that, document the window + sample immediately before verify | same third agent |
| S1 | `realpath` the operand before `find`, or use `find -L`, **or** refuse a governance path that is a symlink; and **correct the `24b7143` commit-message claim about GNU find** | third agent for the code; `docs` for the claim correction |

Lockout honoured: engineer authored `63e61cc`/`b9bac08`; reviewer authored `8285886`/`24b7143`.
Neither may author the N1/N2/S1 fix.

---

## 5. Residual risk the team should consciously accept

1. **`--allow-tool <x>` is still accepted from `SQUAD_COPILOT_FLAGS`.** It cannot re-grant anything
   `--allow-all-tools` has not already granted and cannot defeat a `--deny-tool`, so it is not an
   escalation today. It becomes one the day the policy stops passing `--allow-all-tools`.
2. **Directory-level create/unlink in `.squad/memory` and `.squad/casting` remains open** — those are
   not `GOVERNANCE_PATHS` directory entries. F9 now says so out loud instead of claiming otherwise.
   Accepting this means accepting that a file can be created or unlinked beside the governed ones.
3. **PARITY as the watch/loop default** (deliberate, documented) — with F3, the 9 undeliverable rules
   are now announced on every run. The gap is real and visible; that is the accepted trade-off.
4. **`reported-changes.md` never leaves the container.** Until something ships it to the run artefacts
   or an issue comment, no human reviewer will ever read it.
5. **The checkpoint is best-effort under SIGKILL.** ACA can hard-kill during the grace period; the
   governance verify is not guaranteed to run on shutdown (N5).
6. **No in-image verification was possible** (docker build prohibited). F1 rests on Dockerfile layer
   arithmetic plus a materialised simulation, not on `ls -l` inside the shipped image. Someone should
   run `docker run --rm --entrypoint sh <image> -c 'ls -l /usr/local/lib/squad-on-aca'` once.
7. **F11 was not re-reviewed** (manifest IFS parsing; original verdict: not worth a fix).

---

## 6. Bottom line

`8285886` is good work. `24b7143` closes four findings cleanly (F2, F5, F9, F10) and *appears* to
close four more (F4, F6, F7, F8) by writing state into a directory the agent can delete with one
shell command — plus it closes S1 on a claim about GNU `find` that is demonstrably false on the
target platform. **Recommend `24b7143` be reworked before this branch merges.**

---

## Round 3 — final gate

**Reviewer:** Security  
**Date:** 2026-10-02T01:47:31.8766154-04:00  
**Branch:** `feat/squad-0.13-alignment` @ `3ee4fa4`  
**Scope:** final verification of prior findings F1-F10, S1, N1, N2, N3, N5 plus fresh review of `b268d80` (#115), `9fc29fb` (#116), `532920d` (#117).  
**Mode:** read-only source review plus probes. Scratch was confined to `worker/tests/.tmp-security-r3/` and removed after the review; no source edits were made.

### Verdict table

| finding | status | evidence |
|---|---|---|
| F1 wrapper writable by `squad` | VERIFIED CLOSED | `worker/Dockerfile:188` copies `worker/squad-agent` as `root:root`; `worker/Dockerfile:201` strips all write bits from `/usr/local/lib/squad-on-aca` and `/usr/local/bin/squad-on-aca`. `test_squad_agent_wrapper.sh`: `91 assertions run, 0 failed`. |
| F2 `SQUAD_COPILOT_FLAGS` could inject `--allow-all-urls` | VERIFIED CLOSED | `worker/lib/agent-policy.js:438-444` includes `--allow-all-urls` in `FORBIDDEN_EXTRA_FLAGS`; `worker/squad-agent:316` and `:326` reject it in resolved and trailing argv; `worker/lib/squad-policy.sh:260` rejects it in resolved flags. Wrapper test F2 cases: all `--allow-all-urls` smuggling attempts exit 78 and copilot is not exec'd. |
| F3 parity gap not announced | VERIFIED CLOSED | `worker/entrypoint.sh:494-507` logs the parity `NOT enforced on this path` set and strict-mode inverse; called in loop/watch at `worker/entrypoint.sh:1138` and `:1282`. `test_security_f3_parity_announce.sh`: `18 assertions run, 0 failed`. |
| F4 append-only truncate-to-baseline | VERIFIED CLOSED for the prior exploit | `worker/lib/squad-policy.sh:684-689` records inode/ctime fingerprints; `:1020-1058` sampler records high-water marks; `:1815-1823` fails exact-baseline restore even inside a sampling window. A1/A2 repros now fail: `test_security_n2_sampler_invariant.sh` A1 `VERIFY_RC=1`; `test_security_n1_state_tamper.sh` A2 `VERIFY_RC=1` / tamper aborts. |
| F5 classifier said `locked` for nongovernance paths | VERIFIED CLOSED | `worker/lib/agent-policy.js:685-706` only returns `locked` for actual governance membership or unsafe paths and folds case for membership. `test_security_n1_state_tamper.sh`: N4 classifier cases all pass, including `src/app.js -> not-governance` and case variants -> `locked`. |
| F6 modify-then-revert invisible | VERIFIED CLOSED | `worker/lib/squad-policy.sh:1820-1823` and `:1868-1874` use fingerprints to report append-only/reportable files restored to baseline. A4/F6 repros: `test_security_n1_state_tamper.sh` reports `.squad/identity/now.md (modified then reverted)`; `test_security_n2_sampler_invariant.sh` reports F6 inside one window. |
| F7 report not durable / skipped on violation | VERIFIED CLOSED in production root path | `worker/entrypoint.sh:584-601` writes report before exit 78; `:634-681` writes to root-sealed `reported-changes.md` when available; `worker/lib/squad-policy.sh:870-884` appends through the root sealer. WSL root/ext4 test: root-owned report written on both violation and tampered paths and dropped uid cannot delete it. |
| F8 `.mcp.json` TOCTOU / missing or forged baseline | VERIFIED CLOSED | `worker/squad-agent:256-286` uses env digest plus tripwire plus root-sealed digest; missing/mismatch exits 78. `worker/lib/squad-policy.sh:369-380` exports the harden-time digest. A5b/A5c repros in `test_security_n1_state_tamper.sh` and WSL root test now refuse with 78 and `COPILOT_RAN=0`. |
| F9 harden log overclaimed parent-dir locking | VERIFIED CLOSED | `worker/lib/squad-policy.sh:552-562` computes whether the parent dir is actually a governance path; `:1623-1649` logs locked vs open parent directories separately. Prior Windows ACL failures remain harness limitations, not a false claim. |
| F10 newline/empty argv mangling | VERIFIED CLOSED | `worker/squad-agent:156-188` rejects empty-string and newline-bearing JSON elements before newline transport. `test_squad_agent_wrapper.sh` F10 cases exit 78 for malformed values and preserve legitimate multi-word deny patterns. |
| S1 symlinked governance directory lost detection | VERIFIED CLOSED | `worker/lib/squad-policy.sh:1217-1271` emits `symlink` manifest lines for symlinked governance paths/components; `:1495-1504` aborts harden with 78 on any baseline symlink; `:1776-1782` treats mid-session symlinks as violations. WSL GNU find evidence: `find <symlink-dir> -type f` returns zero; `test_security_n3_s1_symlink.sh`: `11 assertions run, 0 failed`. |
| N1 state dir owned by agent uid | VERIFIED CLOSED | Authority moved to hardening-shell memory (`worker/lib/squad-policy.sh:568-651`) plus root-sealed store (`:789-867`). `squad_policy_exec_agent` closes seal/sampler fds at `:890-908`. WSL root/ext4 test: sealed dir `0 711`, sealed files `0 644`, ten dropped-uid write primitives refused, `50 assertions run, 0 failed`. |
| N2 sampling-rate limit | PARTIAL / ACCEPTED RESIDUAL | Original A1 exact-baseline exploit is closed by fingerprints (`test_security_n2_sampler_invariant.sh`: A1 now `VERIFY_RC=1`). The suite deliberately proves the residual remains: partial truncation that stays above baseline and completes inside one sampling interval still verifies (`DOCUMENTED RESIDUAL (N2)`). `chattr +a` was not added; this is accepted as a documented residual, not hidden. |
| N3 missing `.mcp.json` baseline failed open | VERIFIED CLOSED | `worker/squad-agent:256-274` treats missing malformed digest/tripwire as 78; `worker/lib/squad-policy.sh:1709-1766` treats missing/rewritten tripwires as tamper. A5b/A5c test cases now refuse and checkpoint aborts on rewritten tripwire. |
| N5 SIGTERM/INT during checkpoint | VERIFIED CLOSED for TERM; INT path same code but host-limited | `worker/entrypoint.sh:617-629` defers TERM/INT during checkpoint/report and exits 0 after release; `worker/lib/squad-policy.sh:1099-1106` retries sampler reads interrupted by signals. `test_security_n5_entrypoint_hardening.sh`: `53 assertions run, 0 failed`; `test_signal_forwarding.sh`: TERM scenarios pass, INT skipped because this host cannot deliver INT to bash traps. |

### Attack repros re-run

Commands were run from an LF-normalized scratch copy because this Windows checkout has CRLF; `TMPDIR` was set under `worker/tests/.tmp-security-r3` (not `/tmp`). Root-required checks ran in WSL as root on an ext4 loopback image stored under the same scratch directory so ownership/mode semantics were real.

- `test_squad_agent_wrapper.sh`: `91 assertions run, 0 failed`.
- `test_security_n1_state_tamper.sh`: `35 assertions run, 0 failed` — A2, A4, A5b, A5c closed.
- `test_security_n2_sampler_invariant.sh`: `18 assertions run, 0 failed` — A1/exact-baseline closed; residual partial truncation asserted.
- `test_security_n3_s1_symlink.sh`: `11 assertions run, 0 failed` on WSL2 / GNU findutils 4.8.0.
- `test_security_n5_entrypoint_hardening.sh`: `53 assertions run, 0 failed`.
- `test_security_n1b_root_sealed_state` (sanitized to avoid `/tmp`, run as WSL root on ext4 loopback): `50 assertions run, 0 failed`.
- `test_signal_forwarding.sh`: `19 assertions run, 0 failed`.
- `test_squad_health.sh`: `56 assertions run, 0 failed`.
- `test_external_state_refusal.sh`: `36 assertions run, 0 failed`.

### Fresh review of #115 / #116 / #117

| commit | finding | severity | confidence | evidence |
|---|---|---:|---:|---|
| `b268d80` #115 signal forwarding | No blocking finding. TERM forwarding drains child and preserves post-run checkpoint on zero exit. | — | 9/10 | `worker/lib/squad-signal-forwarding.sh:36-48` forwards and waits in the trap; `:56-77` returns the real child rc. `worker/entrypoint.sh:1149-1154` and `:1314-1327` run watch/loop through the wrapper then checkpoint/report. `test_signal_forwarding.sh`: `19 assertions run, 0 failed`. |
| `b268d80` #115 inherited behavior: non-zero watch/loop child exits before checkpoint under `set -e`. This pre-existed the signal-forwarding change and is not a regression, but remains a residual risk if Squad propagates an agent-caused non-zero. | LOW | 6/10 | Prior round already noted this inherited behavior. Current tests intentionally assert the same shape: non-zero child rc has `post-invocation checkpoint ... 0 time(s)`. |
| `9fc29fb` #116 health gate | No finding. Parsed `status: fail` fails closed with check ids; unreadable/old CLI is `UNAVAILABLE`, not a false pass. No repo-controlled shell interpolation. | — | 9/10 | `worker/entrypoint.sh:389-441`; local doctor mirror at `scripts/squad-aca.ps1:1545-1577`. `test_squad_health.sh`: `56 assertions run, 0 failed`. |
| `532920d` #117 external state refusal | No bypass finding. Worker gate runs after clone/checkout but before `squad init`, health, hardening, or agent; local CLI refuses before dispatch. | — | 9/10 | `worker/entrypoint.sh:271-310`, call ordering `clone :227 -> gate :310 -> init :362 -> health :441 -> harden :470`; `scripts/squad-aca.ps1:289-348` and `:1152-1155`. `test_external_state_refusal.sh`: `36 assertions run, 0 failed`. |
| `532920d` #117 log-forgery hardening gap: a hostile `teamRoot` string is placed directly in logs/errors, so control characters/newlines could forge adjacent log lines. It does not bypass the refusal or execute code. | LOW | 6/10 | `worker/entrypoint.sh:297-306` and `scripts/squad-aca.ps1:338-345` include raw `teamRoot` in diagnostic text. Recommended follow-up: sanitize control chars before logging. Non-blocking. |

### Entrypoint ordering / skippability

Verified ordering is still: clone (`worker/entrypoint.sh:227`) -> external-state gate (`:310`) -> bootstrap / optional `squad init` (`:362`) -> health gate (`:441`) -> root seal created before drop (`:27-85`) and hardening (`:470`) -> agent execution through `squad_policy_exec_agent` (`worker/lib/squad-policy.sh:890-908`). The root sealer is started before `exec env -u HOME runuser -p` (`worker/entrypoint.sh:80-85`), and `squad_policy_exec_agent` closes both sampler and seal fds before exec. I found no agent-uid env manipulation path that skips the gates after hardening.

### Residual risks accepted

1. N2 residual: a partial truncation above the baseline that starts and ends inside one sampler interval is still not detectable without kernel append-only/inotify. This is asserted by test and accepted because `chattr +a` is not available in the target default capability set.
2. Root seal pipe residual: a same-uid process that somehow reopens the inherited seal pipe via `/proc` can cause denial-of-service before seal or append report noise after seal, but cannot modify sealed baseline files.
3. PARITY remains the deliberate watch/loop default. The missing multi-word deny rules are announced; `SQUAD_WATCH_STRICT_POLICY=true` opts into strict mode.
4. `--allow-all-tools` in the resolved argv remains legitimate and required for non-interactive Copilot; I did not re-report it.
5. #115 inherited behavior: non-zero watch/loop child exit may skip checkpoint under `set -e`; not introduced by #115 and not re-opened as a blocking finding here.
6. #117 diagnostics should sanitize control characters in a later hardening pass, but this is log integrity only and does not bypass the refusal.

### Final verdict

**APPROVE** the branch as a whole.

All previously blocking findings are closed or reduced to explicitly documented residual risk. No CRITICAL/HIGH/MEDIUM new finding was found in #115/#116/#117. The only new issue is LOW log-forgery hardening for #117 diagnostics; it should be fixed opportunistically, not as a merge blocker.
