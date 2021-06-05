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

You also need to install the required flatpak runtime, SDK and
electron BaseApp.  At the time of this writing they are the 20.08
versions, but check the `chat.delta.desktop.yml`'s `runtime-version`
and `base-version` properties for the current version numbers.

```
flatpak install flathub \
    org.freedesktop.Platform//20.08 \
    org.freedesktop.Sdk//20.08 \
    org.electronjs.Electron2.BaseApp//20.08 \
    org.freedesktop.Sdk.Extension.node10//20.08
```


### Building the application

To simply build the application in a build-directory invoke
`flatpak-builder` pointing to the manifest:
```
flatpak-builder build-dir chat.delta.desktop.yml
```

To install the local build you can add the `--install` flag.  To
upload the built application to a repository, which can just be a
local directory, add the `--repo=repo` flag.


### Uploading to flathub

Each commit to the https://github.com/flathub/chat.delta.desktop
master branch will result in a new release being published to
flathub.  So once a pull request is merged no more work needs to be
done to publish the release.


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

### Re-generating rust sources

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


### Re-generating npm sources

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
invoke the `node/flatpak-node-generator.py` script, e.g.:

```
python3 ../flatpak-builder-tools/node/flatpak-node-generator.py \
    npm ../deltachat-desktop/package-lock.json \
    --recursive --split --xdg-layout \
    --output generated-sources-npm.json
```

This will produce the `generated-sources-npm-?.json` files which is referenced
in the `chat.delta.desktop.yml` manifest.  Because that file is quite big
and Github seems to not like big files all too much, the generator offers
a --split option, cf. https://github.com/flatpak/flatpak-builder-tools/blob/204309e0066a66a6f3c9ad7c5edb870513a7504c/node/README.md#splitting-mode.
