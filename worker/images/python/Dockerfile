# squad-worker-python -- the image behind the sandbox-python-3-12 class.
#
# WHY THIS EXISTS. config/sandbox-classes.json used to pin the plain
# squad-worker image for this class while claiming python3/pip3, which that
# image does not carry. The in-worker preflight refused the session (correctly),
# but the catalog had already made a claim nothing verified. This image makes
# the claim true instead of deleting it: capability routing only means anything
# if "a repository that needs Python gets an image that has Python".
#
# It EXTENDS the published worker by digest rather than rebuilding it, so
# /usr/local/bin/squad-on-aca (entrypoint), /usr/local/lib/squad-on-aca/*
# (capability preflight, dispatch core, git checkout, agent policy) and the
# Copilot/Squad CLI toolchain are byte-identical to the worker that ACA Jobs
# run. A sandbox worker is still a Squad worker.
#
# The base is pinned by DIGEST, not by tag: re-tagging the registry must not be
# able to change what this image is built on.
#
# CPython 3.12 is copied from the official python:3.12-slim-bookworm image
# rather than installed from apt, because Debian bookworm ships 3.11 and this
# class's id promises 3.12. Only the interpreter's own files are copied
# (libpython, stdlib, headers, the two entry points) -- copying all of
# /usr/local would clobber the base image's node, npm and yarn.
#
# The RUN block at the end is a BUILD-TIME SMOKE TEST, not decoration. It fails
# the build if the interpreter is missing a shared library, if the version is
# not 3.12, or if any part of the Squad worker payload was displaced. An image
# that cannot back the catalog's claim must never reach a digest that someone
# can pin.

FROM python:3.12-slim-bookworm AS cpython

FROM acrsquadacah81u42kq.azurecr.io/squad-worker@sha256:266a8c319862565a2ae92f412115cca324c90c1ac228f5fb754a8c0eb0fdc3f3

USER root

# Shared libraries CPython 3.12 links against, plus jq and make. Everything
# here is bookworm main; no third-party apt source is added.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        jq \
        make \
        netbase \
        tzdata \
        libbz2-1.0 \
        libcrypt1 \
        libexpat1 \
        libffi8 \
        libgdbm-compat4 \
        libgdbm6 \
        liblzma5 \
        libncursesw6 \
        libnsl2 \
        libreadline8 \
        libsqlite3-0 \
        libssl3 \
        libtinfo6 \
        libtirpc3 \
        libuuid1 \
        zlib1g \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

COPY --from=cpython /usr/local/lib/libpython3.12.so.1.0 /usr/local/lib/libpython3.12.so.1.0
COPY --from=cpython /usr/local/lib/python3.12 /usr/local/lib/python3.12
COPY --from=cpython /usr/local/include/python3.12 /usr/local/include/python3.12
COPY --from=cpython /usr/local/bin/python3.12 /usr/local/bin/python3.12
COPY --from=cpython /usr/local/bin/pip3.12 /usr/local/bin/pip3.12

RUN ldconfig \
    && ln -sf /usr/local/bin/python3.12 /usr/local/bin/python3 \
    && ln -sf /usr/local/bin/python3.12 /usr/local/bin/python \
    && ln -sf /usr/local/bin/pip3.12 /usr/local/bin/pip3 \
    && ln -sf /usr/local/bin/pip3.12 /usr/local/bin/pip

USER squad
WORKDIR /workspace

# Build-time smoke test. Fails the build rather than shipping a digest that
# would make config/sandbox-classes.json lie again.
RUN set -eux; \
    python3 -c 'import sys; assert sys.version_info[:2] == (3, 12), sys.version'; \
    python3 -c 'import bz2, ctypes, decimal, hashlib, json, lzma, readline, socket, sqlite3, ssl, uuid, venv, zlib; print(ssl.OPENSSL_VERSION)'; \
    python3 --version; \
    pip3 --version; \
    python --version; \
    pip --version; \
    node --version; \
    npm --version; \
    yarn --version; \
    git --version; \
    jq --version; \
    make --version | head -n 1; \
    bash --version | head -n 1; \
    curl --version | head -n 1; \
    test -x /usr/local/bin/squad-on-aca; \
    test -x /usr/local/lib/squad-on-aca/squad-capability-preflight.sh; \
    test -f /usr/local/lib/squad-on-aca/squad-dispatch.js; \
    test -f /usr/local/lib/squad-on-aca/resolve-capability-route.js; \
    test -f /usr/local/lib/squad-on-aca/agent-policy.js; \
    test -f /usr/local/lib/squad-on-aca/git-checkout.sh

ENTRYPOINT ["/usr/local/bin/squad-on-aca"]
