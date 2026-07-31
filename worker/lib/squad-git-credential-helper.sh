#!/bin/sh
# squad-git-credential-helper.sh
#
# The git credential helper the worker installs for github.com. It exists for
# ONE reason: it re-reads the token FILE on EVERY git operation, so a token that
# is refreshed mid-session is picked up with no re-clone, no `git config`
# rewrite, and no restart of the process that is holding the repository.
#
# WHAT IT REPLACES, AND WHY. Until issue #32 the worker baked the token into the
# repository URL once, at session start:
#
#     git config --global url."https://x-access-token:${GH_TOKEN}@github.com/".insteadOf ...
#
# With a long-lived PAT that is harmless. With a GitHub App installation token,
# whose TTL is a hard 1 hour, it is a live failure mode, and a maximally LATE
# one. Measured, not assumed:
#
#     clone with an EXPIRED token, public repo -> exit 0, succeeds (no warning)
#     push  with an EXPIRED token              -> exit 128, "Invalid username or token"
#
# The agent run sits between those two, so the whole session's wall-clock and AI
# credits are spent and then thrown away with nothing pushed. Re-reading a file
# is what makes a mid-session refresh POSSIBLE; whether a refresh can actually be
# delivered depends on the substrate (see docs/sandboxes.md, "Refresh channel
# matrix"), and this helper is correct either way.
#
# WHY A FILE AND NOT AN ENVIRONMENT VARIABLE. An exported variable in a shell
# that has already started is frozen for the life of that shell. A file can be
# rewritten from outside the process. The token therefore lives in ONE place,
# mode 0600, and is never an argument to anything: not in argv, not in
# `git config` output, not in `ps`, not in a log line.
#
# PROTOCOL. git invokes a credential helper as `<helper> <operation>` with the
# request on stdin, terminated by a blank line:
#
#     get    -> print `username=` / `password=` on stdout, exit 0
#     store  -> git offers a credential for caching. We do nothing and exit 0,
#               so no token is ever written to ~/.git-credentials.
#     erase  -> git asks us to forget a credential. We do nothing and exit 0;
#               forgetting is the control plane's job, not git's.
#
# An unknown operation is also exit 0 with no output: a helper that errors makes
# git fail the whole operation, and a future git that adds a verb must not take
# a session down.
#
# SHELL. `#!/bin/sh` and strict POSIX. This file is not one of the strings
# screened by scripts/lib/squad-shell-portability.ps1 (it is not sent into a
# sandbox), but it is executed by git on a Debian image where /bin/sh is dash,
# so the same rules apply. `printf` is a dash and bash BUILTIN, which is why the
# token can be printed without ever becoming another process's argv.
#
# Environment:
#   SQUAD_GIT_TOKEN_FILE        path to the token file (mode 0600). Default
#                               $HOME/.squad-on-aca/git-token.
#   SQUAD_GIT_CREDENTIAL_HOST   the ONLY host this helper answers for.
#                               Default github.com.
#   SQUAD_GIT_CREDENTIAL_USERNAME  username paired with the token.
#                               Default x-access-token, which is what GitHub
#                               App installation tokens and PATs both accept.
#
# Exit codes: always 0. A credential helper that cannot answer must say nothing
# and let git move on to the next helper or fail on its own terms.

set -u

op="${1:-}"

case "$op" in
    get) ;;
    store|erase) exit 0 ;;
    *) exit 0 ;;
esac

# Read the request. git writes `key=value` lines then a blank line. Anything we
# do not recognise is ignored rather than rejected.
req_protocol=""
req_host=""
while IFS= read -r line; do
    [ -n "$line" ] || break
    case "$line" in
        protocol=*) req_protocol=${line#protocol=} ;;
        host=*)     req_host=${line#host=} ;;
    esac
done

# Answer for exactly one protocol and one host. The helper is ALSO configured
# scoped to that host in git config, so this is a second, independent gate: a
# future `credential.helper` (unscoped) that picked this script up must not hand
# a GitHub token to some other server.
[ "$req_protocol" = "https" ] || exit 0
[ "$req_host" = "${SQUAD_GIT_CREDENTIAL_HOST:-github.com}" ] || exit 0

token_file="${SQUAD_GIT_TOKEN_FILE:-${HOME:-/home/squad}/.squad-on-aca/git-token}"
[ -f "$token_file" ] || exit 0
[ -r "$token_file" ] || exit 0

# 2>/dev/null is placed BEFORE the input redirection deliberately: redirections
# are applied left to right, so a file that vanishes between the test above and
# this read is silenced rather than printing a shell error into git's stderr.
token=""
IFS= read -r token 2>/dev/null < "$token_file" || token=""

# A CR would become part of the password. Built without putting the token in any
# argv: `printf '\r'` carries no secret.
CR=$(printf '\r')
token=${token%"$CR"}

[ -n "$token" ] || exit 0

printf 'username=%s\n' "${SQUAD_GIT_CREDENTIAL_USERNAME:-x-access-token}"
printf 'password=%s\n' "$token"
exit 0
