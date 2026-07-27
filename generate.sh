#!/bin/bash
set -e

# must be tags for now
# (if you want to use sth else, you need to read this script and modify it accordingly)
CORE_CHECKOUT=v2.57.0
DESKTOP_CHECKOUT=v2.57.0

# this script cd's around, so remember where our own files live
REPO_DIR=$(cd "$(dirname "$0")" && pwd)

# this script needs:
# environment:
# - serveral repos checked out next to this repo (you may run setup.sh to do that for you)
#  - flatpak-builder-tools
#  - deltachat-core-rust
#  - deltachat-desktop
# dependencies:
# - python3, nodejs 20
# - jq
# - flatpak-node-generator (setup.sh installs this for you)
# you can call "nix develop" to install those dependencies if you are doing this on nix


# if -d ../.venv
# then
source ../.venv/bin/activate
# fi

# git checkout & print hashes
echo "[git checkout core]"
cd ../deltachat-core-rust
git fetch --all --tags
git checkout $CORE_CHECKOUT
CORE_COMMIT_HASH=$(git rev-parse HEAD)
cd -
echo "[git checkout desktop]"
cd ../deltachat-desktop
git fetch --all --tags
# discard tracked-file modifications a previous (possibly failed) run left
# behind (sed-ed link_local.sh, link: entries from pnpm add, ...)
git checkout -- .
git checkout $DESKTOP_CHECKOUT
git clean -d -x -f
DESKTOP_COMMIT_HASH=$(git rev-parse HEAD)
cd -

# The pnpm running here and the one running inside the
# flatpak sandbox have to be the same version
PNPM_VERSION=$(jq -r '(.packageManager // "") | split("+")[0] | sub("^pnpm@"; "")' ../deltachat-desktop/package.json)
if [ -z "$PNPM_VERSION" ]; then
    echo "no packageManager field in ../deltachat-desktop/package.json" >&2
    exit 1
fi
PNPM_VERSION_HERE=$(cd ../deltachat-desktop && pnpm --version | tail -1)
if [ "$PNPM_VERSION_HERE" != "$PNPM_VERSION" ]; then
    echo "pnpm version mismatch: desktop $DESKTOP_CHECKOUT declares $PNPM_VERSION, but the pnpm running there is $PNPM_VERSION_HERE" >&2
    echo "the flatpak sandbox runs $PNPM_VERSION, and a cache recorded with a different pnpm makes the build fail with a 404" >&2
    echo "run 'corepack enable' (or install pnpm@$PNPM_VERSION otherwise) and try again" >&2
    exit 1
fi
echo "[pnpm version: $PNPM_VERSION]"

# generate sources
echo "[core build dependencies]"
python3 ../flatpak-builder-tools/cargo/flatpak-cargo-generator.py -o generated/sources-rust.json ../deltachat-core-rust/Cargo.lock

echo "[desktop build dependencies]"

# the recorded indices are only additive, while the manifest listing them is
# rewritten from scratch below - without this, leftovers from earlier runs stay
# in git without ever being installed into the sandbox
rm -rf generated/proxy-registry-cache-indices

# Clean up first in case an old record.mjs is still running
# (-x: only an exact command-line match, so this can never hit other processes)
pkill -xf "node record.mjs" 2>/dev/null && sleep 1 || true

# start proxy registry that records the packages that are fetched
node record.mjs &
PID_RECORD=$!

# wait until it actually serves, and abort right away if it died on startup
# instead of recording into the void
for i in $(seq 1 20); do
    if curl -sf http://localhost:3000/__alive >/dev/null; then
        break
    fi
    if ! kill -0 $PID_RECORD 2>/dev/null; then
        echo "record.mjs died on startup (see error above)" >&2
        exit 1
    fi
    if [ "$i" = 20 ]; then
        echo "record.mjs did not come up on port 3000" >&2
        exit 1
    fi
    sleep 0.5
done

cd ../deltachat-desktop
pnpm config set registry http://localhost:3000 --location project
rm -r $(pwd)/.pnpm-store || true
pnpm config set store-dir $(pwd)/.pnpm-store --location project
echo "[desktop deps: ignore other architectures]"
# the flatpak sandbox has to apply the exact same narrowing, so this lives in a
# script that both this file and the manifest call
python3 "$REPO_DIR/tool_limit_architectures.py" pnpm-workspace.yaml
echo "[desktop deps: fetching]"
# pnpm keeps an on-disk packument cache and answers metadata requests from it
# without ever asking the (recording) registry - anything served from that cache
# is missing from the recording and 404s in the sandbox. The cache is versioned
# (pnpm 11: <cache>/pnpm/v11/metadata{,-full}), so wipe the whole pnpm cache dir
# rather than a version-specific subpath, otherwise the recording is incomplete.
rm -rf "${XDG_CACHE_HOME:-$HOME/.cache}/pnpm"
rm -rf .pnpm-store node_modules || true
pnpm i --frozen-lockfile

echo "[desktop deps: record link_local.sh metadata]"
# The sandbox runs link_local.sh (a series of `pnpm add`) after the offline
# install. Unlike the frozen-lockfile install above, which only downloads
# tarballs by URL, `pnpm add` re-resolves the graph and requests the metadata of
# every package in the lockfile - including optional platform packages
# (@esbuild/aix-ppc64, ...) whose tarballs are never downloaded. The replay
# proxy can only serve what was recorded, so run the exact same commands here:
git checkout -- ./bin/link_core/link_local.sh
sed -i "s/pnpm add/pnpm add --prefer-offline/g" ./bin/link_core/link_local.sh
env CORE_REPO_CHECKOUT=../deltachat-core-rust ./bin/link_core/link_local.sh

# The linked jsonrpc-client/stdio-rpc-server pull in runtime deps (yerpc,
# isomorphic-ws, ...) that a `link:` dep hides from electron-builder's packager,
# so the packaged app would die with "Cannot find package 'yerpc'". Add them as
# direct deps of target-electron so they enter the dependency graph, and record
# the resulting install (it re-resolves and may pull new tarballs) so the sandbox
# can replay it. The manifest runs the exact same two commands.
node "$REPO_DIR/tool_inject_linked_deps.mjs" \
    packages/target-electron/package.json pnpm-lock.yaml \
    ../deltachat-core-rust/deltachat-jsonrpc/typescript \
    ../deltachat-core-rust/deltachat-rpc-server/npm-package
pnpm install

# undo everything the recording changed in the desktop checkout (sed above,
# link: entries in package.json/lockfile, injected deps) - tool_strip.mjs later
# reads the pristine lockfile, and the next generate.sh run needs a clean tree
git checkout -- .

# make the proxy registry save what it recorded, and wait for it to finish:
# record.mjs writes the manifest and used_versions_strip_info.json from its async
# SIGINT handler, so without the wait the script races ahead and later steps
# (e.g. tool_strip.mjs) run before those files exist. A non-zero exit here means
# the recording itself failed, which we want to surface right away.
kill -SIGINT $PID_RECORD
wait $PID_RECORD
cd -

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

echo "[pnpm package to install pnpm]"
# $PNPM_VERSION is the version desktop declares and the one this run used, see above
result=$(npm view "pnpm@$PNPM_VERSION" --json | jq "{url: .dist.tarball, integrity: .dist.integrity}")

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

echo "[generate manifest that puts electron binary into cache]"

node generate_electron_dependency.mjs

echo "[strip unused versions from pnpm package indices]"

node tool_strip.mjs
rm generated/used_versions_strip_info.json

echo "[done]"
