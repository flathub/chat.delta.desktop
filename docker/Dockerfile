# Environment for running generate.sh without installing its dependencies
# (pnpm, flatpak-node-generator, python venv, ...) on the machine.
# Not used by the flathub build - see docker/generate_in_docker.sh for usage.
FROM node:22-bookworm

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        jq \
        python3-venv \
        python3-pip \
        procps \
        curl \
    && rm -rf /var/lib/apt/lists/*

# same as setup.sh does in the codespace; pnpm then downgrades itself to the
# version pinned in deltachat-desktop's packageManager field automatically
RUN npm i -g pnpm

# /work becomes a named volume holding the sibling checkouts (deltachat-desktop,
# deltachat-core-rust, flatpak-builder-tools, .venv) between runs. The container
# runs as the host user, so it has to be writable for everyone; /work/home is
# the container HOME (pnpm cache, pipx installs).
RUN mkdir -p /work/home && chmod 777 /work /work/home

WORKDIR /work/flatpak-desktop
