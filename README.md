# Flatpak packaging for Delta Chat Desktop

## Trigger a new release using Codespaces

These are the steps to trigger a new release using github Codespaces:

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
 - wait for the build of the preview
 - install the preview locally and check if it works
 - after merging the PR the new version will be released


## Running the generate process locally with docker

Alternative to the Codespace: only docker is needed on the machine, nothing
else gets installed.

```sh
./generate_in_docker.sh
```

This builds a container image with all dependencies (node, pnpm,
flatpak-node-generator, ...) and runs `generate.sh` plus `check_cache.sh`
inside it. Local checkouts of deltachat-desktop and core are expected next to
this repo (in `../deltachat-desktop` and `../core`, override with
`DESKTOP_REPO=... CORE_REPO=...`). They are mounted read-only and cloned inside
the container, so they stay untouched — which also means uncommitted changes in
them are not used; generate.sh builds the tags it has pinned.

Clones and caches are kept in the docker volume `chat-delta-generate-work`
between runs (`docker volume rm chat-delta-generate-work` to start fresh).
`./generate_in_docker.sh bash` opens a shell inside the environment.

Afterwards review and commit the changes in `generated/`, then run
`check_cache.sh` again: it verifies the committed cache is complete and
consistent before you trigger a flathub build.


## Building the flatpak locally with docker

To run the full `flatpak-builder` build without installing flatpak and the
runtimes on the machine (useful for verifying manifest changes end-to-end
without a CI round-trip):

```sh
./build_in_docker.sh
```

This builds a container image (`Dockerfile.flatpak`) with flatpak +
flatpak-builder and runs the build against the current working tree, so
uncommitted manifest changes are included. It needs a committed/generated
`generated/` cache (run `generate_in_docker.sh` first if needed) and network
access (github repos, npm tarballs, electron, flatpak runtimes). Only the
host's architecture is built.

The flatpak runtimes, the flatpak-builder cache and the build dir live in the
docker volume `chat-delta-flatpak-work` and are reused between runs
(`docker volume rm chat-delta-flatpak-work` to start fresh). The first run
downloads several GB of runtimes and compiles the Rust core, so expect
30–60+ minutes; later runs are much faster. `./build_in_docker.sh bash` opens a
shell in the environment (the packaged app is at
`/work/build-dir/files/delta` inside the volume).

Notes on why it works the way it does:
- The container runs **as root** and uses a **system** flatpak installation,
  because `bwrap` (which flatpak-builder uses for every build step) cannot set
  up its uid map as a non-root user inside docker, while `flatpak --user`
  refuses to run as root.
- It runs with `--privileged` (plus `/dev/fuse`) so the nested bwrap/user
  namespaces are allowed. This is a local trusted-developer tool and is not part
  of the flathub build.


## Building locally

If you'd like to locally build this flapak, you'll need both `flatpak`
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


### Upgrade to new Release: Re-generating sources

To setup make sure this repo is checked out inside of it's own folder and there is no folder besides it (or the setup script might not do what it should).

Then run `./setup.sh`. (you also need nodejs min version 20 and python3)

> to reset you can run `rm -rf ../.venv/ ../deltachat-* ../flatpak-builder-tools/`
> But be careful as this could destroy your work if you haven't followed the instractions above correctly.

<details>
<summary>manual setup</summary>

install the `flatpak-node-generator` tool with `pipx`:
```sh
git clone https://github.com/flatpak/flatpak-builder-tools.git
pip install pipx
pipx install flatpak-builder-tools/node
```

install nodejs version > 20
<!-- todo command / install fnm then install right version -->

create a python virtual env and enter it, then install aiohttp
```
python -m venv .venv
source .venv/bin/activate
pip install aiohttp toml
```
</details>


Then edit (put in the tags/branches you want to update to) and run the `generate.sh` script:
```sh
CORE_CHECKOUT=v1.140.0
DESKTOP_CHECKOUT=v1.45.4
```

After that, build it locally (if your computer is likely faster than CI, so debugging locally is quicker).
```
rm -r build-dir/ || true && flatpak-builder --install-deps-from=flathub build-dir chat.delta.desktop.yml --ccache
```

> `--ccache` enables sccache, which speeds up subsequent builds.

<details>
<summary>old docs, outdated, but might be helpful for understanding</summary>

## Upgrading to a new release

Get hold of a newer version of the desktop app and the Rust binding,
e.g. `git fetch --tags`.  Check the newest tags out, so that their
dependencies can be seen.

```
cd delta-chat-desktop
git fetch --tags
git checkout v1.13.0  # or whatever the latest tag is
```

```
cd delta-chat-rust
git fetch --tags
git checkout 1.46.0
```

#### Re-generating rust sources

Since flatpak does not allow the build to download things while
building we have to resolve all the cargo dependencies statically
beforehand.  This is done by processing the `Cargo.lock` file into the
`generated-source-rust.json` file:

```
python3 ../flatpak-builder-tools/cargo/flatpak-cargo-generator.py \
    -o generated-sources-rust.json \
    ../deltachat-core-rust/Cargo.lock
```

Make sure you generate it from the correct downloaded release.


#### Re-generating npm sources

Since flatpak does not allow the build to download things while
building we have to resolve all the npm dependencies beforehand.
This is done by converting the `package-lock.json`, which should
contain all the dependencies, into a manifest snipped suitabled for
building flatpaks.

The npm packages for deltachat core jsonrpc client are generated with flatpak-node-generator.
And for dc-desktop dependencies we currently upload and download a cached .pnpm-store directory because pnpm is not yet supported by flatpak-node-generator and might not be anytime soon (because pnpm store is too different from npm cache), see comments in [generate.sh](generate.sh).

</details>