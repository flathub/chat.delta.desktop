# Flatpak packaging for Delta Chat Desktop

Flatpak packaging is done by flatpak-builder and needs some preparation.
Since the final build process happens inside a sandbox with no network access we
need to provide lists with all dependencies [pnpm-sources](./generated/pnpm-sources.json)
and [rust-sources](./generated/sources-rust.json).

flatpak-builder pre-fetches these declared sources so they trigger no network
calls in the build process.
Some direct links to dependencies have no entries in package.json and would
not be prefetched by flatpak-builder so we have to inject them. See [tool_inject_linked_deps](./tool_inject_linked_deps.mjs)


## Build process

The build happens in **three distinct phases**, where the last one is performed in the
network-less sandbox.

### Phase 1 — generate (`generate.sh`, network available)

Manually executed - either in a codespace (after ./setup.sh) or on a local
machine (optional inside a docker container). It resolves the dependency graph
and writes the sources list in `generated/*.json` that will be commited.

These files include `pnpm-sources.json` holds ~900 entries, one per npm tarball
(URL + sha512), the electron/esbuild/node-gyp caches and a few generated
helper files (`populate_pnpm_store.py`, `pnpm-manifest.json`). Rust deps are
listed the same way in `sources-rust.json`.

This is also where the from-source core is linked into the lockfile ([link_local.sh])
and the linked packages' otherwise invisible runtime deps are injected 
([tool_inject_linked_deps.mjs](./tool_inject_linked_deps.mjs)).

The changes need to be committed so the flatpak builder that runs on flathub will process them.
(flatpak-builder can also be run inside a local docker container to test the result)

### Phase 2 — flatpak-builder fetches the declared sources (network available)

flatpak-builder reads the `sources:` list and materializes every entry onto disk
**before** entering the sandbox. Network access is restricted to exactly the URLs
and hashes declared in `generated/` (content addressed, cached). Afterwards every
npm tarball sits as a plain file under `flatpak-node/pnpm-tarballs/`, the caches
are extracted, and the helper scripts are written.

### Phase 3 — the sandbox build (NO network)

Everything in the manifest's `build-commands` runs here, inside bwrap with no
network. This is where the **store is prefilled and then consumed**:

1. `populate_pnpm_store.py … pnpm-tarballs pnpm-store` — rebuilds the offline
   pnpm (v11, content-addressed) **store** from the raw tarballs fetched in
   phase 2. The store is never committed or downloaded whole; it is reconstructed
   offline from the individual tarballs on every build.
2. `storeDir: …/pnpm-store` is appended to `pnpm-workspace.yaml` so pnpm uses it.
3. `pnpm install --offline --frozen-lockfile` resolves the committed lockfile
   entirely from that store — no network.
4. the desktop is built and packaged with electron-builder.

> Note: flatpak-node-generator would normally run `populate_pnpm_store.py` itself
> as an auto step during phase 2. We strip that (the `jq` filter in `generate.sh`)
> and run it ourselves in phase 3 — see the comments in
> [`build-commands`](./chat.delta.desktop.yml#L139).

[link_local.sh]: https://github.com/deltachat/deltachat-desktop/blob/main/bin/link_core/link_local.sh


## Trigger a new release

The easiest environment is a github Codespace, but the generate step can equally
be run with [Docker](#running-the-generate-process-locally-with-docker) or on a
[native checkout](#generating-the-sources-on-a-native-checkout). The release
steps themselves are the same:

- create a new PR release-x.x.x
- edit `generate.sh` in codespace and change the tags for
  
  ```
    CORE_CHECKOUT=vx.x.x
    DESKTOP_CHECKOUT=vx.x.x
  ```
 - add the new release in `<releases>` in chat.delta.desktop.appdata.xml
   - add a link to the Release Changelog
   - add some more info about the release
   - see [Release info](https://docs.flathub.org/docs/for-app-authors/metainfo-guidelines/#release)
 - start the setup script in console `./setup.sh`
 - start the generate script in console `./generate.sh`
 - commit all changes
 - wait for the build of the preview
 - install the preview locally and check if it works
 - after merging the PR the new version will be released


## Running the generate process locally with docker

Alternative to the Codespace: only docker is needed on the machine, nothing
else gets installed.

```sh
./docker/generate_in_docker.sh
```

This builds a container image with all dependencies (node, pnpm,
flatpak-node-generator, ...) and runs `generate.sh`
inside it. Local checkouts of deltachat-desktop and core are expected next to
this repo (in `../deltachat-desktop` and `../core`, override with
`DESKTOP_REPO=... CORE_REPO=...`). They are mounted read-only and cloned inside
the container, so they stay untouched — which also means uncommitted changes in
them are not used; generate.sh builds the tags it has pinned.

Clones and caches are kept in the docker volume `chat-delta-generate-work`
between runs (`docker volume rm chat-delta-generate-work` to start fresh).
`./docker/generate_in_docker.sh bash` opens a shell inside the environment.

Afterwards review and commit the changes in `generated/` before you trigger a flathub build.


## Building the flatpak locally with docker

To run the full `flatpak-builder` build without installing flatpak and the
runtimes on the machine (useful for verifying manifest changes end-to-end
without a CI round-trip):

```sh
./docker/build_in_docker.sh
```

This builds a container image (`docker/Dockerfile.flatpak`) with flatpak +
flatpak-builder and runs the build against the current working tree, so
uncommitted manifest changes are included. It needs the `generated/` cache
(run `docker/generate_in_docker.sh` first if needed) and network
access (github repos, npm tarballs, electron, flatpak runtimes). Only the
host's architecture is built.

The flatpak runtimes, the flatpak-builder cache and the build dir live in the
docker volume `chat-delta-flatpak-work` and are reused between runs
(`docker volume rm chat-delta-flatpak-work` to start fresh). The first run
downloads several GB of runtimes and compiles the Rust core, so expect
that to take some time; later runs are much faster. `./docker/build_in_docker.sh bash`
opens a shell in the environment (the packaged app is at `/work/build-dir/files/delta`
inside the volume).

### Installing and running the result

The build above leaves the app inside the volume, not on the host. To turn it
into a single installable bundle (`./chat.delta.desktop.flatpak`), export it with:

```sh
./docker/bundle_in_docker.sh
```

Then install and run it with the host's `flatpak` (needs `flatpak` installed on
the host). The app depends on the Electron base app, so install that once:

```sh
flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
flatpak install --user flathub org.electronjs.Electron2.BaseApp//25.08   # once
flatpak install --user ./chat.delta.desktop.flatpak
flatpak run chat.delta.desktop
```

The locally built bundle is unsigned, so flatpak asks you to confirm the install.
Remove it again with `flatpak uninstall --user chat.delta.desktop`.

Notes on why it works the way it does:
- The container runs **as root** and uses a **system** flatpak installation,
  because `bwrap` (which flatpak-builder uses for every build step) cannot set
  up its uid map as a non-root user inside docker, while `flatpak --user`
  refuses to run as root.
- It runs with `--privileged` (plus `/dev/fuse`) so the nested bwrap/user
  namespaces are allowed. This is a local trusted-developer tool and is not part
  of the flathub build.


## Building locally

If you'd like to locally build this flatpak, you'll need both `flatpak`
and `flatpak-builder` installed.  E.g. on Debian you can run `apt
install flatpak flatpak-builder` to install these tools.  See
https://flatpak.org/setup/ for more information on this for your
platform.

### flatpak dependencies

If you haven't done so yet, you need to have
[flathub](https://flathub.org) set up as a remote repository:

```
flatpak remote-add --if-not-exists \
    flathub https://flathub.org/repo/flathub.flatpakrepo
```

### Building the application

To simply build the application in a build-directory invoke
`flatpak-builder` pointing to the manifest:
```
flatpak-builder --install-deps-from=flathub build-dir chat.delta.desktop.yml
```

To install the local build you can add the `--install` flag.  To
upload the built application to a repository, which can just be a
local directory, add the `--repo=repo` flag.


### Uploading to flathub

Each commit to the https://github.com/flathub/chat.delta.desktop
master branch will result in a new release being published to
flathub.  So once a pull request is merged no more work needs to be
done to publish the release.


## Generating the sources on a native checkout

A third option besides [Codespaces](#trigger-a-new-release) and
[Docker](#running-the-generate-process-locally-with-docker): run `generate.sh`
directly on your machine. You need **nodejs >= 22** and **python3**.

Make sure this repo is checked out in its own folder with nothing else beside it
(otherwise `setup.sh` may not do what it should), then run `./setup.sh` to clone
the sibling repos and install the tooling.

> to reset you can run `rm -rf ../.venv/ ../deltachat-* ../flatpak-builder-tools/`
> But be careful as this could destroy your work if you haven't followed the instructions above correctly.

<details>
<summary>manual setup (instead of setup.sh)</summary>

install the `flatpak-node-generator` tool with `pipx`:
```sh
git clone https://github.com/flatpak/flatpak-builder-tools.git
pip install pipx
pipx install flatpak-builder-tools/node
```

install nodejs >= 22 (e.g. via `fnm` or `nvm`)

create a python virtual env, activate it, then install the generator's python deps:
```
python -m venv .venv
source .venv/bin/activate
pip install aiohttp toml tomlkit
```
</details>

Then set the target tags at the top of `generate.sh` and run `./generate.sh`:
```sh
# edit these in generate.sh
CORE_CHECKOUT=vX.Y.Z
DESKTOP_CHECKOUT=vX.Y.Z
```

The remaining release steps (PR, appdata entry, preview, merge) are the same as
the [release flow above](#trigger-a-new-release) — only the environment differs.
To verify the result locally, build with `flatpak-builder` (see
[Building locally](#building-locally)); `--ccache` speeds up repeat builds:
```
rm -r build-dir/ || true && flatpak-builder --install-deps-from=flathub build-dir chat.delta.desktop.yml --ccache
```
