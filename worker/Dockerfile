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
    && npm install -g @github/copilot@1.0.69-2 @bradygaster/squad-cli@0.11.0 squad-hub@0.3.0 \
    # Assert the pinned squad-hub actually HAS the verb this image depends on.
    #
    # worker/lib/squad-hub.sh calls `squad-hub oneshot`. Pinning a version that
    # predates it does not fail the build, does not fail the deploy, and does
    # not fail until a supervised session reaches the agent -- where the CLI
    # prints its usage, exits 2, and the job dies with "Supervised session
    # failed (exit 2)" pointing at nothing in particular. That happened once,
    # with squad-hub@0.2.0, and cost a full build-deploy-run cycle to see.
    #
    # One line here turns that into a build failure with the reason in it.
    && (squad-hub --help 2>&1 | grep -q 'squad-hub oneshot' \
        || (echo "FATAL: the pinned squad-hub has no 'oneshot' verb, which worker/lib/squad-hub.sh requires. Pin a version that has it." >&2; exit 1)) \
    && useradd -m -s /bin/bash squad \
    && mkdir -p /workspace \
    && chown -R squad:squad /workspace /home/squad \
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
COPY --chown=squad:squad worker/lib/squad-capability-preflight.sh worker/lib/squad-token-preflight.sh worker/lib/squad-credentials.sh worker/lib/squad-push.sh worker/lib/squad-git-credential-helper.sh worker/lib/parse-capabilities.js worker/lib/locate-manifest.js worker/lib/resolve-capability-route.js worker/lib/dispatch-decision.js worker/lib/dispatch-lease.js worker/lib/squad-dispatch.js worker/lib/ralph-dispatch.sh worker/lib/git-checkout.sh worker/lib/agent-policy.js worker/lib/squad-policy.sh worker/lib/squad-hub.sh config/sandbox-classes.json /usr/local/lib/squad-on-aca/
RUN sed -i 's/\r$//' /usr/local/bin/squad-on-aca /usr/local/lib/squad-on-aca/squad-capability-preflight.sh /usr/local/lib/squad-on-aca/squad-token-preflight.sh /usr/local/lib/squad-on-aca/squad-credentials.sh /usr/local/lib/squad-on-aca/squad-push.sh /usr/local/lib/squad-on-aca/squad-git-credential-helper.sh /usr/local/lib/squad-on-aca/ralph-dispatch.sh /usr/local/lib/squad-on-aca/git-checkout.sh /usr/local/lib/squad-on-aca/squad-policy.sh /usr/local/lib/squad-on-aca/squad-hub.sh \
    && chmod +x /usr/local/bin/squad-on-aca /usr/local/lib/squad-on-aca/squad-capability-preflight.sh /usr/local/lib/squad-on-aca/squad-token-preflight.sh /usr/local/lib/squad-on-aca/squad-git-credential-helper.sh

USER squad
WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/squad-on-aca"]
