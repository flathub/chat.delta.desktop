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
electron BaseApp.  At the time of this writing they are the 18.08
versions, but check the `chat.delta.desktop.yml`'s `runtime-version`
and `base-version` properties for the current version numbers.

```
flatpak install flathub \
    org.freedesktop.Platform//18.08 \
    org.freedesktop.Sdk//18.08 \
    io.atom.electron.BaseApp//18.08
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
building we have to resolve all the npm dependencies statically
beforehand.  This is done by letting npm put the dependencies into a
`package-lock.json` file without actually downloading them and than
converting that into a manifest snipped called
`generated-sources.json`.

To create the `generated-sources.json` file you need a copy of the
https://github.com/flatpak/flatpak-builder-tools.git repository and
invoke the `npm/flatpak-npm-generator.py` script, e.g.:

```
python3 ../flatpak-builder-tools/npm/flatpak-npm-generator.py \
    -o generated-sources-npm.json \
    npm ../deltachat-desktop-X.Y.Z/package-lock.json
```

This will produce the `generated-sources.json` file which is referenced
in the `chat.delta.desktop.yml` manifest.  Make sure you generate it
from the correct downloaded release.
