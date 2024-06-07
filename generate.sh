#!/bin/sh
set -e

CORE_CHECKOUT=simon/npm-rpc-package-make-local-non-symlinked-instalation-possible
DESKTOP_CHECKOUT=simon/respect-no-asar-in-after-pack-hook

# this script needs:
# - serveral repos checked out next to this repo
#  - flatpak-builder-tools
#  - deltachat-core-rust
#  - deltachat-desktop
# - python3, nodejs 20, flatpak-node-generator


# git checkout & print hashes
cd ../deltachat-core-rust
git fetch --all
git checkout $CORE_CHECKOUT
CORE_COMMIT_HASH=$(git rev-parse HEAD)
cd -
cd ../deltachat-desktop
git fetch --all
git checkout $DESKTOP_CHECKOUT
DESKTOP_COMMIT_HASH=$(git rev-parse HEAD)
cd -
# generate sources
echo "[core build dependencies]"
python3 ../flatpak-builder-tools/cargo/flatpak-cargo-generator.py -o generated/sources-rust.json ../deltachat-core-rust/Cargo.lock

echo "[desktop build dependencies]"
flatpak-node-generator -o generated/sources-npm.json -r npm ../deltachat-desktop/package-lock.json

echo "[@deltachat/jsonrpc-client build-dependencies]"
cd ../deltachat-core-rust/deltachat-jsonrpc/typescript
rm -r node_modules || true
npm i --lockfile-version 2 --package-lock-only
cd -

flatpak-node-generator -o generated/sources-jsonrpc-client-npm.json -r npm ../deltachat-core-rust/deltachat-jsonrpc/typescript/package-lock.json
cp ../deltachat-core-rust/deltachat-jsonrpc/typescript/package-lock.json generated/deltachat-jsonrpc.typescript.package-lock.json 

echo "[Done, you need to put these hashes into the manifests]"
echo "core:    $CORE_COMMIT_HASH"
echo "desktop: $DESKTOP_COMMIT_HASH"