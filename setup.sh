#!/bin/bash
set -e

cd ..
git clone https://github.com/deltachat/deltachat-desktop.git --depth 10
git clone https://github.com/deltachat/deltachat-core-rust.git --depth 10

python3 -m venv .venv
source .venv/bin/activate
pip install aiohttp toml

git clone https://github.com/flatpak/flatpak-builder-tools/ --depth 1
pip install pipx
pipx install flatpak-builder-tools/node