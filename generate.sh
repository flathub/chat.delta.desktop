#!/bin/bash
set -e

# must be tags for now
# (if you want to use sth else, you need to read this script and modify it accordingly)
CORE_CHECKOUT=v2.56.0
DESKTOP_CHECKOUT=v2.56.0

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

# start proxy registry that records the packages that are fetched
node record.mjs &
PID_RECORD=$!

cd ../deltachat-desktop
pnpm config set registry http://localhost:3000 --location project
rm -r $(pwd)/.pnpm-store || true
pnpm config set store-dir $(pwd)/.pnpm-store --location project
echo "[desktop deps: ignore other architectures]"
# the flatpak sandbox has to apply the exact same narrowing, so this lives in a
# script that both this file and the manifest call
python3 "$REPO_DIR/tool_limit_architectures.py" pnpm-workspace.yaml
echo "[desktop deps: fetching]"
rm -rf .pnpm-store node_modules || true
pnpm i --frozen-lockfile

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
