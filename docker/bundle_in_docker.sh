#!/bin/bash
# creates a local chat.delta.desktop.flatpak in the current work space
# for testing the generated sources and the offline pnpm store. The flatpak is
# self-contained and can be installed on any host with flatpak >= 1.12.
# Electron base app is NOT included so you need to run
# flatpak install --user flathub org.electronjs.Electron2.BaseApp//25.08
# once on the host before you can run the flatpak.
set -e
cd "$(dirname "$0")/.."

docker build -f docker/Dockerfile.flatpak -t chat-delta-flatpak .

docker run --rm \
    --privileged \
    --device /dev/fuse \
    -e HOME=/work/home \
    -e BUNDLE=chat.delta.desktop.flatpak \
    -e HOST_UID="$(id -u)" \
    -e HOST_GID="$(id -g)" \
    -v chat-delta-flatpak-work:/work \
    -v "$PWD:/work/flatpak-desktop" \
    chat-delta-flatpak \
    bash -euc '
        test -d /work/build-dir/files || {
            echo "no build found - run ./docker/build_in_docker.sh first" >&2
            exit 1
        }
        rm -rf /work/repo-bundle
        flatpak build-export /work/repo-bundle /work/build-dir
        flatpak build-bundle /work/repo-bundle \
            "/work/flatpak-desktop/$BUNDLE" chat.delta.desktop
        chown "$HOST_UID:$HOST_GID" "/work/flatpak-desktop/$BUNDLE"
    '

echo "wrote ./chat.delta.desktop.flatpak"
