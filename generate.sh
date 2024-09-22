#!/bin/bash
set -e

# must be tags for now
# (if you want to use sth else, you need to read this script and modify it accordingly)
CORE_CHECKOUT=v1.142.12
DESKTOP_CHECKOUT=monorepo-testrelease-rc0

# pnpm is not so easy to install offline, since it's cache is in a special format
# (instead of storing all packages in a directory, it stores all files of those packages into an content addressable store
# simon is not sure if it is even possible to add support for pnpm's cache format to flatpak-node generator unless
# - you also add some other cache format to pnpm that caches what it downloads from the internet in a more simple format
# - or add additional steps to workaround this issue )
# @Simon-Laux: So my workaround for now is to download dependencies into cache, then zip the cache and upload to some s3 storage,
# because then the downloader in flatpak-builder only needs to download one zip file.
# I have also considered using git LFS, but since the archive is around 177mb the 10gb free space on github will fill up quickly,
# also retrieving the file from there looked tricky, since flatpak-builder does not natively support git-LFS.
# If you got a better idea, then please get in contact by creating an issue on https://github.com/flathub/chat.delta.desktop/issues
S3_INTERNAL_URL=s3://deltachat
S3_EXTERNAL_URL=https://deltachat.fra1.digitaloceanspaces.com

# this script needs:
# - serveral repos checked out next to this repo
#  - flatpak-builder-tools
#  - deltachat-core-rust
#  - deltachat-desktop
# - python3, nodejs 20, flatpak-node-generator
# - jq

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
cd ../deltachat-desktop
pnpm config set store-dir $(pwd)/.pnpm-store --location project
echo "[desktop deps: ignore other architectures]"
# desktop modify package json to exclude all unused architectures
# the temporary file `package.new.json` is nessesary because jq does not support in place editing of files.
jq ".pnpm.supportedArchitectures.os = [\"linux\"] | .pnpm.supportedArchitectures.cpu = [\"x64\", \"arm64\"]" package.json > package.new.json
mv package.new.json package.json
echo "[desktop deps: fetching]"
rm -rf .pnpm-store node_modules || true
pnpm i --frozen-lockfile

echo "[desktop deps: make pnpm store reproducible -> remove 'checkedAt'-timestamps]"
shopt -s globstar # enable glob pattern
for file in .pnpm-store/**/*-index.json; do
    sed -i 's/"checkedAt":[0-9]\+/"checkedAt":0/g' $file
done

echo "[desktop deps: compressing result]"
rm ../chat.delta.desktop/generated/desktop-pnpm-cache.tar.xz || true
tar --mtime='1970-01-01' -cJvf ../chat.delta.desktop/generated/desktop-pnpm-cache.tar.xz .pnpm-store
cd -

echo "[desktop deps upload to s3]"
DESKTOP_DEPS_HASH=$(sha512sum generated/desktop-pnpm-cache.tar.xz | cut -d " " -f 1)
echo "desktop deps hash: $DESKTOP_DEPS_HASH"
DESKTOP_DEPS_FILENAME="desktop-pnpm-cache.$DESKTOP_CHECKOUT.$DESKTOP_COMMIT_HASH.${DESKTOP_DEPS_HASH:0:8}.tar.xz"
echo "desktop deps filename: $DESKTOP_DEPS_FILENAME"
s3cmd put generated/desktop-pnpm-cache.tar.xz $S3_INTERNAL_URL/$DESKTOP_DEPS_FILENAME
s3cmd setacl $S3_INTERNAL_URL/$DESKTOP_DEPS_FILENAME --acl-public

cat >generated/desktop-pnpm-cache.json <<EOL
[
    {
        "type": "archive",
        "url": "${S3_EXTERNAL_URL}/${DESKTOP_DEPS_FILENAME}",
        "strip-components": 1,
        "sha512": "${DESKTOP_DEPS_HASH}",
        "dest": "flatpak-node/pnpm-home/.pnpm-store"
    }
]
EOL

rm generated/desktop-pnpm-cache.tar.xz

echo "[@deltachat/jsonrpc-client build-dependencies]"
cd ../deltachat-core-rust/deltachat-jsonrpc/typescript
rm -r node_modules || true
npm i --lockfile-version 2 --package-lock-only
cd -

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
        "dest": "main",
    }
]
EOL

cat >generated/core-git.json <<EOL
[
    {
        "type": "git",
        "url": "https://github.com/deltachat/deltachat-core-rust.git",
        "tag": "${CORE_CHECKOUT}",
        "commit": "${CORE_COMMIT_HASH}",
    }
]
EOL

echo "[done]"