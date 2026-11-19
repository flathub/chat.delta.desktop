#!/bin/bash
# Runs inside the container started by docker/generate_in_docker.sh.
# Takes the role of setup.sh (which is written for the codespace),
# then runs generate.sh.
set -e
cd /work/flatpak-desktop

echo "[container setup: sibling checkouts]"
# clone from the read-only host mounts - fast, no network for the bulk of the
# objects. A second remote points at github, because the host checkout may not
# have the release tag yet: generate.sh runs `git fetch --all --tags`, which
# fetches from both remotes and picks up whatever the local one is missing.
clone_local() { # <host mount> <dest> <github url>
    if [ ! -d "$2" ]; then
        git clone "$1" "$2"
        git -C "$2" remote add github "$3"
    fi
}
clone_local /host/deltachat-desktop ../deltachat-desktop https://github.com/deltachat/deltachat-desktop.git
clone_local /host/deltachat-core-rust ../deltachat-core-rust https://github.com/chatmail/core.git

echo "[container setup: update flatpak-builder-tools]"
# The work volume persists between runs, so update the tools every time:
# a stale generator breaks on newer upstream releases (e.g. electron 44+ dropped
# linux-armv7l, which older flatpak-node-generator versions still expect).
if [ -d ../flatpak-builder-tools ]; then
    git -C ../flatpak-builder-tools fetch --depth 1 origin HEAD
    git -C ../flatpak-builder-tools reset --hard FETCH_HEAD
else
    git clone https://github.com/flatpak/flatpak-builder-tools --depth 1 ../flatpak-builder-tools
fi

echo "[container setup: python venv + flatpak-node-generator]"
# pipx installs into $HOME/.local (inside the /work volume)
export PATH="$HOME/.local/bin:$PATH"
if [ ! -d ../.venv ]; then
    python3 -m venv ../.venv
fi
source ../.venv/bin/activate
pip install --quiet --upgrade aiohttp toml tomlkit pipx
# --force reinstalls from the freshly updated checkout
pipx install --force ../flatpak-builder-tools/node

bash generate.sh
