# Flatpak packaging for Delta Chat Desktop

## Building

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

install the `flatpak-node-generator` tool with `pipx`:
```sh
git clone https://github.com/flatpak/flatpak-builder-tools.git
pip install pipx
pipx flatpak-builder-tools/node
```

install nodejs version > 20
<!-- todo command / install fnm then install right version -->

create a python virtual env and enter it, then install aiohttp
<!-- todo command -->

Then edit (put in the tags/branches you want to update to) and run the `generate.sh` script:
```sh
CORE_CHECKOUT=v1.140.0
DESKTOP_CHECKOUT=v1.45.4
```

The script then gives you the commit hashes you should add to the build manifest, there you need to also specify branch/tag.

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

Upstream ships the package-lock.json file so it should not be
necessary to generate it.  However, sometimes the file is not
updated in lockstep with package.json and then dependencies will
be missing during build time.  In that case, it's best to wait for
upstream to provide the lock file, but it should be possible to run
`npm install` to get the lockfile updated.

To create the `generated-sources.json` file you need a copy of the
https://github.com/flatpak/flatpak-builder-tools.git repository and
install the `flatpak-node-generator` tool with `pipx`:
```sh
git clone https://github.com/flatpak/flatpak-builder-tools.git
pip install pipx
pipx flatpak-builder-tools/node
```
Then invoke the `node/flatpak-node-generator.py` script, e.g.:

```sh
flatpak-node-generator -o generated-sources-npm.json -r npm ../deltachat-desktop/package-lock.json
```

This will produce the `generated-sources-npm.json` file which is referenced
in the `chat.delta.desktop.yml` manifest.  Because that file is quite big
and Github seems to not like big files all too much, the generator offers
a --split option, cf. https://github.com/flatpak/flatpak-builder-tools/blob/204309e0066a66a6f3c9ad7c5edb870513a7504c/node/README.md#splitting-mode.

</details>