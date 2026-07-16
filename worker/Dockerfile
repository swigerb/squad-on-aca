FROM node:24-bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive \
    CI=true \
    COPILOT_AUTO_UPDATE=false \
    COPILOT_ALLOW_ALL=true \
    SQUAD_MODE=smoke \
    WORKDIR=/workspace \
    SQUAD_ON_ACA_HOME=/opt/squad-on-aca

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
    && mkdir -p /workspace "$SQUAD_ON_ACA_HOME" \
    && chown -R squad:squad /workspace /home/squad "$SQUAD_ON_ACA_HOME" \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

COPY --chown=squad:squad worker/lib "$SQUAD_ON_ACA_HOME/lib"
COPY --chown=squad:squad config "$SQUAD_ON_ACA_HOME/config"
COPY --chown=squad:squad worker/entrypoint.sh /usr/local/bin/squad-on-aca
RUN sed -i 's/\r$//' /usr/local/bin/squad-on-aca \
    && find "$SQUAD_ON_ACA_HOME/lib" -type f -exec sed -i 's/\r$//' {} + \
    && chmod +x /usr/local/bin/squad-on-aca "$SQUAD_ON_ACA_HOME/lib/resolve-capabilities.js" "$SQUAD_ON_ACA_HOME/lib/squad-capability-preflight.sh"

USER squad
WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/squad-on-aca"]
