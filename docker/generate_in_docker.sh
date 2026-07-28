#!/bin/bash
# Runs generate.sh inside a docker container, so nothing
# beyond docker is needed on the machine.
#
# The deltachat-desktop and core checkouts on this disk are mounted read-only
# and cloned from there inside the container - generate.sh checks out tags and
# runs `git clean` in its copies, the checkouts on the disk stay untouched
# (which also means: uncommitted local changes in them are NOT used).
# The clones, the python venv and all caches live in the named volume
# "chat-delta-generate-work" and are reused between runs
# (delete with `docker volume rm chat-delta-generate-work` to start fresh).
#
#   ./docker/generate_in_docker.sh            full run
#   ./docker/generate_in_docker.sh bash       interactive shell in the environment
#
# Repo locations can be overridden: DESKTOP_REPO=... CORE_REPO=... ./docker/generate_in_docker.sh
set -e
# cd to the repo root (this script lives in docker/); everything below is relative
# to it: the sibling checkouts, the bind mount ($PWD) and the docker build context.
cd "$(dirname "$0")/.."

DESKTOP_REPO=$(cd "${DESKTOP_REPO:-../deltachat-desktop}" && pwd)
CORE_REPO=$(cd "${CORE_REPO:-../core}" && pwd)

docker build -f docker/Dockerfile -t chat-delta-generate .

# -t only when we have a terminal, so this also works from scripts/CI
TTY_FLAG=""
if [ -t 0 ]; then TTY_FLAG="-t"; fi

# run as the host user: files written into the bind-mounted repo (generated/)
# must not end up root-owned
run() {
    exec docker run --rm -i $TTY_FLAG \
        --user "$(id -u):$(id -g)" \
        -e HOME=/work/home \
        -v chat-delta-generate-work:/work \
        -v "$PWD:/work/flatpak-desktop" \
        -v "$DESKTOP_REPO:/host/deltachat-desktop:ro" \
        -v "$CORE_REPO:/host/deltachat-core-rust:ro" \
        -w /work/flatpak-desktop \
        chat-delta-generate \
        "$@"
}

if [ $# -gt 0 ]; then
    run "$@"
else
    run bash docker/generate_in_docker_inner.sh
fi
