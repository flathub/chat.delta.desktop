#!/bin/bash
set -e

# must be tags for now
# (if you want to use sth else, you need to read this script and modify it accordingly)
CORE_CHECKOUT=v2.59.0
DESKTOP_CHECKOUT=v2.59.0

# this script needs:
# environment:
# - serveral repos checked out next to this repo
#  - flatpak-builder-tools
#  - deltachat-core-rust
#  - deltachat-desktop
# dependencies:
# - python3, nodejs 20
# - jq
# - flatpak-node-generator (setup.sh installs this for you)
# you can call "nix develop" to install those dependencies if you are doing this on nix
# or setup.sh inside a code space or use docker/generate_in_docker.sh to run this
# inside a docker container (no installs needed on the host besides docker)


# if -d ../.venv
# then
source ../.venv/bin/activate
# fi

# git checkout & print hashes
echo "[git checkout core]"
cd ../deltachat-core-rust
git fetch --all --tags
git checkout $CORE_CHECKOUT
# reset --hard so a reused checkout (e.g. the docker work volume) starts pristine:
# tool_inject_linked_deps.mjs edit tracked files, and git clean
# does NOT revert those - leaving prior-run edits in place would make the generated
# sources depend on run history instead of the tag.
git reset --hard $CORE_CHECKOUT
CORE_COMMIT_HASH=$(git rev-parse HEAD)
cd -
echo "[git checkout desktop]"
cd ../deltachat-desktop
git fetch --all --tags
git checkout $DESKTOP_CHECKOUT
git reset --hard $DESKTOP_CHECKOUT
git clean -d -x -f
DESKTOP_COMMIT_HASH=$(git rev-parse HEAD)
cd -
# This manifest targets the pnpm 11 store (v11) and points pnpm at the store via
# storeDir in pnpm-workspace.yaml. pnpm 10 uses a different store version and
# reads store-dir from .npmrc, so bail out early with a clear message instead of
# producing a store the sandbox pnpm cannot read.
DESKTOP_PNPM_MAJOR=$(jq -r '(.packageManager // "") | sub("^pnpm@"; "") | split(".")[0]' ../deltachat-desktop/package.json)
if [ "$DESKTOP_PNPM_MAJOR" != "11" ]; then
    echo "ERROR: deltachat-desktop $DESKTOP_CHECKOUT pins pnpm $DESKTOP_PNPM_MAJOR, but this manifest targets pnpm 11 (store v11)." >&2
    echo "       Pick a desktop version that uses pnpm 11, or adapt the store version + storeDir wiring." >&2
    exit 1
fi

# generate sources
echo "[core build dependencies]"
python3 ../flatpak-builder-tools/cargo/flatpak-cargo-generator.py -o generated/sources-rust.json ../deltachat-core-rust/Cargo.lock

echo "[link locally-built core into desktop deps]"
# Link @deltachat/jsonrpc-client + @deltachat/stdio-rpc-server to the from-source
# core so the committed lockfile references them via `link:`. At build time this
# is reproduced with a single offline `pnpm install --frozen-lockfile`.
# Why here and not in the sandbox: `pnpm add` re-resolves the whole dependency
# graph and fetches registry metadata (packuments/attestations), which the pnpm
# store does not carry - so it cannot run offline. Doing it here (network is
# available) bakes the links into the lockfile; the offline frozen install then
# just recreates the symlinks (their deps are already in the store).
# CORE_REPO_CHECKOUT is set explicitly so the recorded link path
# (../../../deltachat-core-rust/...) matches the symlink the manifest creates.
(
  cd ../deltachat-desktop
  CORE_REPO_CHECKOUT=../deltachat-core-rust bash ./bin/link_core/link_local.sh
)
# A `link:` dep has no lockfile snapshot, so electron-builder (which packages only
# what the pnpm graph resolves) drops the linked packages' runtime deps (yerpc,
# isomorphic-ws, ...) and the app dies at runtime with "Cannot find package
# 'yerpc'". Inject them as direct deps of target-electron and re-resolve so they
# enter the committed lockfile and get packaged.
node tool_inject_linked_deps.mjs \
    ../deltachat-desktop/packages/target-electron/package.json \
    ../deltachat-desktop/pnpm-lock.yaml \
    ../deltachat-core-rust/deltachat-jsonrpc/typescript \
    ../deltachat-core-rust/deltachat-rpc-server/npm-package
(cd ../deltachat-desktop && pnpm install)

# Capture the linked lockfile + workspace package.json manifests so the build can
# reapply them over the pristine git checkout before installing.
# --owner/--group/--numeric-owner: normalize ownership to root:0 so the archive
# does not carry the maintainer's uid/gid (the build sandbox cannot restore it).
tar czf generated/linked-core-overrides.tar.gz \
    --owner=0 --group=0 --numeric-owner \
    -C ../deltachat-desktop \
    pnpm-lock.yaml $(cd ../deltachat-desktop && ls -d packages/*/package.json)

echo "[desktop build dependencies via flatpak-node-generator (pnpm v11 store)]"
# Emits all npm tarballs, a script that builds an offline pnpm store, plus the
# electron / esbuild / playwright / node-gyp caches.
# Default store version is v10; deltachat-desktop uses pnpm 11 => v11.
flatpak-node-generator pnpm --pnpm-store-version v11 \
    -o generated/pnpm-sources.json ../deltachat-desktop/pnpm-lock.yaml

# Drop the generator's auto-run "finalize" shell source (store population +
# storeDir + node-gyp headers). It runs in flatpak's *source* phase, where the
# node SDK extension is not on PATH (breaks setup_sdk_node_headers.sh) and where
# $PWD is the module build-dir root, not the desktop checkout in main/ (so its
# `>> pnpm-workspace.yaml` would hit the wrong file). We run these three steps
# ourselves from build-commands in the manifest instead. Everything else the
# generator emits (tarballs, caches, the populate script + manifest, the
# electron/esbuild symlink sources which carry their own dest) is kept as-is.
jq 'map(select(.type != "shell" or ((.commands // []) | map(select(test("populate_pnpm_store"))) | length) == 0))' \
    generated/pnpm-sources.json > generated/pnpm-sources.json.tmp
mv generated/pnpm-sources.json.tmp generated/pnpm-sources.json

echo "[@deltachat/jsonrpc-client build-dependencies]"
cd ../deltachat-core-rust/deltachat-jsonrpc/typescript
rm -r node_modules || true
npm i --lockfile-version 2 --package-lock-only
cd -
pwd

flatpak-node-generator -o generated/sources-jsonrpc-client-npm.json -r npm ../deltachat-core-rust/deltachat-jsonrpc/typescript/package-lock.json
cp ../deltachat-core-rust/deltachat-jsonrpc/typescript/package-lock.json generated/deltachat-jsonrpc.typescript.package-lock.json

echo "[writing to manifest files]"
cat >generated/desktop-git.json <<EOL
[
    {
        "type": "git",
        "url": "https://github.com/deltachat/deltachat-desktop.git",
        "tag": "${DESKTOP_CHECKOUT}",
        "commit": "${DESKTOP_COMMIT_HASH}",
        "dest": "main"
    }
]
EOL

cat >generated/core-git.json <<EOL
[
    {
        "type": "git",
        "url": "https://github.com/chatmail/core.git",
        "tag": "${CORE_CHECKOUT}",
        "commit": "${CORE_COMMIT_HASH}",
        "dest": "."
    }
]
EOL

# The generator prepares the offline store, but does not provide a pnpm binary.
# Install the exact pnpm version the desktop pins in packageManager (must be a
# pnpm that understands the v11 store, i.e. pnpm 11), fetched from a static
# tarball because global npm install is not possible in the read-only sandbox.
PNPM_VERSION=$(jq -r '(.packageManager // "") | sub("^pnpm@"; "") | split("+")[0]' ../deltachat-desktop/package.json)
echo "[pnpm package to install pnpm@$PNPM_VERSION]"
result=$(npm view pnpm@$PNPM_VERSION --json | jq "{url: .dist.tarball, integrity: .dist.integrity}")

# Use Python to decode the integrity hash and construct the manifest source item
python3 - <<EOL > generated/pnpm.json
import json
import sys
import base64

data = json.loads('''$result''')

if data.get("integrity", "").startswith("sha512-"):
    output = {
        "type": "archive",
        "url": data["url"],
        "sha512": base64.b64decode(data["integrity"].replace("sha512-", "")).hex(),
        "dest": "pnpm"
    }
    print(json.dumps(output, indent=2))
else:
    print("Input package has unexpected hash, expected sha512", file=sys.stderr)
    sys.exit(1)
EOL

echo "[done]"
