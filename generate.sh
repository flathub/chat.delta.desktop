#!/bin/bash
set -e

# must be tags for now
# (if you want to use sth else, you need to read this script and modify it accordingly)
CORE_CHECKOUT=v1.159.4
DESKTOP_CHECKOUT=v1.58.2

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
# generate sources
echo "[core build dependencies]"
python3 ../flatpak-builder-tools/cargo/flatpak-cargo-generator.py -o generated/sources-rust.json ../deltachat-core-rust/Cargo.lock

echo "[desktop build dependencies]"

# start proxy registry that records the packages that are fetched
node record.mjs &
PID_RECORD=$!

cd ../deltachat-desktop
pnpm config set registry http://localhost:3000 --location project
rm -r $(pwd)/.pnpm-store || true
pnpm config set store-dir $(pwd)/.pnpm-store --location project
echo "[desktop deps: ignore other architectures]"
# desktop modify package json to exclude all unused architectures
# the temporary file `package.new.json` is nessesary because jq does not support in place editing of files.
jq ".pnpm.supportedArchitectures.os = [\"linux\"] | .pnpm.supportedArchitectures.cpu = [\"x64\", \"arm64\"]" package.json > package.new.json
mv package.new.json package.json
echo "[desktop deps: fetching]"
rm -rf .pnpm-store node_modules || true
pnpm i --frozen-lockfile

# make the proxy registry save what it recorded
kill -SIGINT $PID_RECORD
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
result=$(npm view pnpm@9.11.0 --json | jq "{url: .dist.tarball, integrity: .dist.integrity}")

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
