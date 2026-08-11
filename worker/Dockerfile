FROM node:24-bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive \
    CI=true \
    COPILOT_AUTO_UPDATE=false \
    SQUAD_MODE=smoke \
    WORKDIR=/workspace

# COPILOT_ALLOW_ALL is deliberately NOT set (issue #26, PRD #6). It is the
# environment form of `--allow-all-tools`, and baking it into the image meant
# blanket tool approval applied even to a session whose flags said otherwise --
# a control that could not be turned off from the outside. Tool permissions are
# now resolved per session by worker/lib/agent-policy.js and passed explicitly,
# so what a session is allowed to do is decided in one reviewable place.

# Which squad-hub to install, or whether to install it at all.
#
# THE INTEGRATION IS OPTIONAL AND MUST STAY OPTIONAL. A worker that never
# attaches to a hub is the normal case, and it must keep building and running
# when squad-hub is unavailable, unpublished, or simply unwanted. So:
#
#   SQUAD_HUB_SPEC=squad-hub@0.3.0  (default) install the pinned npm version
#   SQUAD_HUB_SPEC=none                       do not install it at all
#   SQUAD_HUB_SPEC=github:owner/repo#<sha>    install from an immutable git ref
#
# The default installs it because it costs one small dependency and means an
# operator can turn supervision on with two environment variables instead of a
# rebuild. `none` exists so that convenience never becomes a requirement: it
# builds a worker with no squad-hub in it, which behaves exactly as this image
# did before the integration existed.
#
# The git-ref form exists so integration work is not blocked on a publish --
# the hub and this worker change together, and requiring a trip through
# registry.npmjs.org to test a two-file change turns a ten-minute loop into a
# release. It is not a hole to smuggle a package through: whoever passes a
# build arg already controls the Dockerfile. Anything other than the default
# should be a SHA, never a branch, or the image is not reproducible.
ARG SQUAD_HUB_SPEC=squad-hub@0.3.0

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl git gnupg openssh-client \
    && mkdir -p /etc/apt/keyrings \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | gpg --dearmor -o /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends gh \
    && curl -sL https://aka.ms/InstallAzureCLIDeb | bash \
    && npm config set fetch-retries 5 \
    && npm config set fetch-retry-maxtimeout 120000 \
    && npm install -g @github/copilot@1.0.69-2 @bradygaster/squad-cli@0.11.0 \
    # Record what was asked for, so a running container can be ASKED which
    # squad-hub it has rather than guessed at -- including "none".
    && printf '%s\n' "$SQUAD_HUB_SPEC" > /etc/squad-hub-spec \
    && if [ "$SQUAD_HUB_SPEC" = "none" ] || [ -z "$SQUAD_HUB_SPEC" ]; then \
         echo "squad-hub not installed (SQUAD_HUB_SPEC=none). Hub supervision will be unavailable in this image; every other mode is unaffected."; \
       else \
         npm install -g "$SQUAD_HUB_SPEC" \
         # Assert the installed squad-hub actually HAS the verb this image
         # depends on.
         #
         # worker/lib/squad-hub.sh calls `squad-hub oneshot`. Installing a
         # version that predates it does not fail the build, does not fail the
         # deploy, and does not fail until a supervised session reaches the
         # agent -- where the CLI prints its usage, exits 2, and the job dies
         # with "Supervised session failed (exit 2)" pointing at nothing in
         # particular. That happened once, with squad-hub@0.2.0, and cost a
         # full build-deploy-run cycle to see.
         #
         # It runs inside this branch, so it checks an override just as well as
         # the default -- and cannot make an image that opted OUT fail to build.
         && (squad-hub --help 2>&1 | grep -q 'squad-hub oneshot' \
             || (echo "FATAL: squad-hub '$SQUAD_HUB_SPEC' has no 'oneshot' verb, which worker/lib/squad-hub.sh requires. Install a version that has it, or build with SQUAD_HUB_SPEC=none to leave hub supervision out." >&2; exit 1)); \
       fi \
    && useradd -m -s /bin/bash squad \
    # PC-2 (issue #86): a second, distinct, unprivileged user for the ONE mode
    # that ever holds the Azure managed identity (`ralph`; see
    # worker/entrypoint.sh's squad_drop_azure_identity). PC-1's live ACA
    # diagnostic (docs/security-report.md) measured this platform's same-uid
    # /proc/<pid>/environ read as POSSIBLE, so the identity-drop ordering is
    # no longer the only control: a Linux ptrace/DAC check on
    # /proc/<pid>/environ denies a cross-UID read regardless of hidepid, so
    # giving the identity-bearing process a UID distinct from every mode that
    # runs an agent against attacker-influenced input closes that gap. Not a
    # member of the `squad` group, and does not get one -- membership would
    # recreate exactly the same-UID-equivalent access this exists to remove.
    && useradd -m -s /bin/bash squad-identity \
    # /workspace is the one thing BOTH users must reach: every mode, including
    # ralph, unconditionally clones the repository into it near the top of
    # entrypoint.sh, before any mode dispatch. A shared group with the setgid
    # bit gives both users write access to that one shared, secret-free
    # directory tree without putting either user in the other's own group --
    # $HOME for each user (below) stays exclusive to that user alone.
    && groupadd squad-workers \
    && usermod -aG squad-workers squad \
    && usermod -aG squad-workers squad-identity \
    && mkdir -p /workspace \
    && chown root:squad-workers /workspace \
    && chmod 2775 /workspace \
    && chown -R squad:squad /home/squad \
    && chown -R squad-identity:squad-identity /home/squad-identity \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# BUILD CONTEXT IS THE REPOSITORY ROOT, not worker/. It has to be: the image
# must carry config/sandbox-classes.json, which lives outside worker/, and a
# COPY cannot reach above its context. scripts/deploy.ps1 therefore builds with
# `--file worker/Dockerfile <repoRoot>`; scripts/validate.ps1 asserts that,
# because building from worker/ would fail every COPY below.
#
# The catalog is the FIRST path catalogSearchPaths() looks in
# (<__dirname>/sandbox-classes.json). Without it, `squad-dispatch.js decide`
# inside the image exits 70 with reason "catalog-unavailable" -- which is what
# Ralph did on every run before this line existed. worker/tests/test_image_layout.sh
# derives its throwaway layout from these COPY lines, so deleting an entry here
# makes that suite fail rather than silently shipping a broken image.
#
# locate-manifest.js is the SHARED manifest-path decision. It is require()d by
# resolve-capability-route.js and executed as a CLI by
# squad-capability-preflight.sh. Removing it from this line does not degrade
# gracefully: the preflight refuses every session with exit 69 rather than
# reporting "no manifest present", because a Dockerfile edit that turned
# "unsafe path" into "no manifest" would be a fail-OPEN on a path-traversal
# boundary. scripts/validate.ps1's "every shipped require() target is shipped"
# check and worker/tests/test_manifest_path_corpus.sh both fail if it goes.
COPY --chown=squad:squad worker/entrypoint.sh /usr/local/bin/squad-on-aca
COPY --chown=squad:squad worker/lib/squad-capability-preflight.sh worker/lib/squad-token-preflight.sh worker/lib/squad-credentials.sh worker/lib/squad-push.sh worker/lib/squad-git-credential-helper.sh worker/lib/parse-capabilities.js worker/lib/locate-manifest.js worker/lib/resolve-capability-route.js worker/lib/dispatch-decision.js worker/lib/dispatch-lease.js worker/lib/squad-dispatch.js worker/lib/ralph-dispatch.sh worker/lib/git-checkout.sh worker/lib/agent-policy.js worker/lib/squad-policy.sh worker/lib/squad-hub.sh worker/lib/proc-isolation-probe.sh config/sandbox-classes.json /usr/local/lib/squad-on-aca/
RUN sed -i 's/\r$//' /usr/local/bin/squad-on-aca /usr/local/lib/squad-on-aca/squad-capability-preflight.sh /usr/local/lib/squad-on-aca/squad-token-preflight.sh /usr/local/lib/squad-on-aca/squad-credentials.sh /usr/local/lib/squad-on-aca/squad-push.sh /usr/local/lib/squad-on-aca/squad-git-credential-helper.sh /usr/local/lib/squad-on-aca/ralph-dispatch.sh /usr/local/lib/squad-on-aca/git-checkout.sh /usr/local/lib/squad-on-aca/squad-policy.sh /usr/local/lib/squad-on-aca/squad-hub.sh /usr/local/lib/squad-on-aca/proc-isolation-probe.sh \
    && chmod +x /usr/local/bin/squad-on-aca /usr/local/lib/squad-on-aca/squad-capability-preflight.sh /usr/local/lib/squad-on-aca/squad-token-preflight.sh /usr/local/lib/squad-on-aca/squad-git-credential-helper.sh /usr/local/lib/squad-on-aca/proc-isolation-probe.sh

# PC-2 (issue #86): this image's default runtime user is intentionally left
# as root (no trailing USER instruction). worker/entrypoint.sh's own FIRST
# executable action -- before any credential, any child process, or any line
# of user-influenced input is ever touched -- drops to the correct
# unprivileged user for the mode that is about to run (`squad-identity` for
# `ralph`, `squad` for everything else) via `exec runuser`, which replaces
# this process outright. Nothing after that point, in any mode, ever runs as
# root. worker/tests/test_uid_separation.sh asserts the drop happens, and
# that it happens first.
WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/squad-on-aca"]
