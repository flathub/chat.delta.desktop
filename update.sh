#!/bin/bash
set -e
# This is an helper script to aid with updating

rm -rf /tmp/dcd-flatpak/ || true

mkdir -p  /tmp/dcd-flatpak/

cd /tmp/dcd-flatpak/

git clone --branch 1.60.0 --depth 1 https://github.com/deltachat/deltachat-core-rust/
git clone --branch v1.22.2 --depth 1 https://github.com/deltachat/deltachat-desktop/


cd -

source ../.venv/bin/activate # you might need to adjust this path

python3 ../flatpak-builder-tools/cargo/flatpak-cargo-generator.py \
    -o generated-sources-rust.json \
    /tmp/dcd-flatpak/deltachat-core-rust/Cargo.lock

python3 ../flatpak-builder-tools/node/flatpak-node-generator.py \
    npm /tmp/dcd-flatpak/deltachat-desktop/package-lock.json \
    --recursive --split --xdg-layout \
    --output generated-sources-npm.json