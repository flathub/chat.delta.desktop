#!/bin/bash
# Runs the real flatpak-builder build inside docker, so the whole manifest can be
# verified end-to-end locally (no CI round-trip). Uses the current working tree
# (bind-mounted), so uncommitted manifest changes are built.
#
#   ./build_in_docker.sh          build chat.delta.desktop.yml and verify
#   ./build_in_docker.sh bash     interactive shell in the environment
#
# Runtimes, the flatpak-builder cache and build-dir live in the named volume
# "chat-delta-flatpak-work" and are reused between runs
# (docker volume rm chat-delta-flatpak-work to start fresh).
#
# --privileged is needed because flatpak-builder runs nested bwrap/user
# namespaces that docker's default seccomp/apparmor otherwise blocks. This is a
# local trusted-dev tool, not part of the flathub build.
#
# Runs as root inside the container: bwrap's uid-map setup fails as a non-root
# user even under --privileged ("setting up uid map: Permission denied"). The
# repo is bind-mounted read-only-in-spirit (the build only reads generated/);
# build-dir and caches live in the volume, so nothing root-owned lands in the
# working tree.
set -e
cd "$(dirname "$0")"

docker build -f Dockerfile.flatpak -t chat-delta-flatpak .

TTY_FLAG=""
if [ -t 0 ]; then TTY_FLAG="-t"; fi

run() {
    exec docker run --rm -i $TTY_FLAG \
        --privileged \
        --device /dev/fuse \
        -e HOME=/work/home \
        -v chat-delta-flatpak-work:/work \
        -v "$PWD:/work/flatpak-desktop" \
        -w /work/flatpak-desktop \
        chat-delta-flatpak \
        "$@"
}

if [ $# -gt 0 ]; then
    run "$@"
else
    run bash build_in_docker_inner.sh
fi
