FROM node:24-bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive \
    CI=true \
    COPILOT_AUTO_UPDATE=false \
    COPILOT_ALLOW_ALL=true \
    SQUAD_MODE=smoke \
    WORKDIR=/workspace

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
    && useradd -m -s /bin/bash squad \
    && mkdir -p /workspace \
    && chown -R squad:squad /workspace /home/squad \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

COPY --chown=squad:squad entrypoint.sh /usr/local/bin/squad-on-aca
COPY --chown=squad:squad lib/squad-capability-preflight.sh lib/parse-capabilities.js lib/ralph-dispatch.sh /usr/local/lib/squad-on-aca/
RUN sed -i 's/\r$//' /usr/local/bin/squad-on-aca /usr/local/lib/squad-on-aca/squad-capability-preflight.sh /usr/local/lib/squad-on-aca/ralph-dispatch.sh \
    && chmod +x /usr/local/bin/squad-on-aca /usr/local/lib/squad-on-aca/squad-capability-preflight.sh

USER squad
WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/squad-on-aca"]
