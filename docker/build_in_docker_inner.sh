#!/bin/bash
# Runs inside the container from docker/build_in_docker.sh: installs the flatpak
# runtimes the manifest needs (once, cached in the volume), then builds and does
# a quick sanity check on the packaged rpc-server.
set -e
cd /work/flatpak-desktop

# We run as root (bwrap's uid-map setup needs it in docker), but `flatpak --user`
# refuses to run as root. So use a SYSTEM installation instead, and persist it in
# the volume by pointing /var/lib/flatpak at a volume dir (otherwise the multi-GB
# runtimes would re-download every run).
# Remove any leftover per-user install (e.g. from an earlier --user attempt),
# otherwise the flathub remote exists in two installations and flatpak commands
# become ambiguous and abort.
rm -rf /work/home/.local/share/flatpak
mkdir -p /work/flatpak-system
if [ ! -L /var/lib/flatpak ]; then
    rm -rf /var/lib/flatpak
    ln -s /work/flatpak-system /var/lib/flatpak
fi

echo "[flatpak: remote + runtimes]"
flatpak --system remote-add --if-not-exists flathub \
    https://flathub.org/repo/flathub.flatpakrepo
# versions must match runtime-version/base-version/sdk-extensions in the manifest
flatpak --system install -y --noninteractive flathub \
    org.freedesktop.Platform//25.08 \
    org.freedesktop.Sdk//25.08 \
    org.freedesktop.Sdk.Extension.node22//25.08 \
    org.freedesktop.Sdk.Extension.rust-stable//25.08 \
    org.electronjs.Electron2.BaseApp//25.08

echo "[flatpak-builder]"
# --disable-rofiles-fuse: the rofiles-fuse overlay flatpak-builder normally uses
# is unreliable inside docker; disabling it trades a bit of speed for reliability.
# build-dir and the download/cache state live in the volume, so nothing
# root-owned is written into the bind-mounted working tree.
flatpak-builder --install-deps-from=flathub --force-clean \
    --disable-rofiles-fuse \
    --state-dir=/work/flatpak-builder-state \
    /work/build-dir chat.delta.desktop.yml

echo "[verify: rpc-server in the packaged app]"
APP=/work/build-dir/files/delta/resources/app
if [ -d "$APP/node_modules/@deltachat" ]; then
    echo "  @deltachat packages in packaged node_modules:"
    ls "$APP/node_modules/@deltachat" | sed 's/^/    /'
    for p in stdio-rpc-server stdio-rpc-server-linux-x64 stdio-rpc-server-linux-arm64 jsonrpc-client; do
        [ -e "$APP/node_modules/@deltachat/$p" ] && echo "  OK  @deltachat/$p present"
    done
else
    echo "  (no resources/app/node_modules - build may have failed earlier)"
fi
echo "[done]"
