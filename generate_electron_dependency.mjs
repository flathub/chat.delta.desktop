//@ts-check
import { createHash } from "crypto";
import { readFileSync, writeFileSync } from "fs";
import { dirname } from "path";
import url from "url";

const packages = JSON.parse(
  readFileSync("generated/proxy-registry-cache-manifest.json", "utf-8")
);

const electron_package = packages.find(({ url }) =>
  url.startsWith("https://registry.npmjs.org/electron/-/electron")
);

const electron_version = electron_package.url.match(/\d+?.\d+?.\d+?/)[0];

console.log("found electron version:", electron_version);

function sha256(url) {
  return createHash("sha256").update(url).digest("hex");
}

const base_url = `https://github.com/electron/electron/releases/download/v${electron_version}`;

const url_shasums = `${base_url}/SHASUMS256.txt`;
const request_shasums = await fetch(url_shasums);
const blob = await request_shasums.blob();
// const shasum_file_hash = sha256(Buffer.from(await blob.arrayBuffer()));
const shasums = (await blob.text()).split("\n").map((line) => line.split(" *"));

// console.log({ shasums, shasum_file_hash });

const arm64_filename = `electron-v${electron_version}-linux-arm64.zip`;
const amd64_filename = `electron-v${electron_version}-linux-x64.zip`;

function findHashFor(filename) {
  //@ts-expect-error
  return shasums.find(([_hash, file]) => filename === file)[0];
}

// yes it's the hash of the url not the file:
// this function is a modified copy from https://github.com/electron/get/blob/e6a31acc76f191c526a1d4bd2b6a188ab0e7cb48/src/Cache.ts#L17-L27
function getCacheDirectory(downloadUrl) {
  // needs to be url.parse even though that api is deprecated
  const parsedDownloadUrl = url.parse(downloadUrl);
  const { search: _0, hash: _1, pathname, ...rest } = parsedDownloadUrl;
  const strippedUrl = url.format({
    ...rest,
    pathname: dirname(pathname || "electron"),
  });
  console.log({strippedUrl}, sha256(strippedUrl));
  return sha256(strippedUrl);
}

/* Both consumers read this one location, in @electron/get's layout
(<root>/<sha256 of the url dir>/<filename>):
- electron's postinstall passes `electron_config_cache` (set in the manifest to
  this dir) as the cache root
- electron-builder >= 26 ignores ELECTRON_CACHE and uses @electron/get's
  default root $XDG_CACHE_HOME/electron, which the manifest env makes the
  same dir
On a cache hit @electron/get returns the file without fetching SHASUMS256.txt,
so the zips are all that is needed offline. */
const cache_root = "flatpak-node/cache/electron/";

const electron = [
  {
    type: "file",
    url: `${base_url}/${arm64_filename}`,
    sha256: findHashFor(arm64_filename),
    "dest-filename": arm64_filename,
    // yes it's the hash of the url not the file: https://github.com/electron/get/blob/e6a31acc76f191c526a1d4bd2b6a188ab0e7cb48/src/Cache.ts#L17-L27
    dest: cache_root + getCacheDirectory(`${base_url}/${arm64_filename}`),
    "only-arches": ["aarch64"],
  },
  {
    type: "file",
    url: `${base_url}/${amd64_filename}`,
    sha256: findHashFor(amd64_filename),
    "dest-filename": amd64_filename,
    // yes it's the hash of the url not the file: https://github.com/electron/get/blob/e6a31acc76f191c526a1d4bd2b6a188ab0e7cb48/src/Cache.ts#L17-L27
    dest: cache_root + getCacheDirectory(`${base_url}/${amd64_filename}`),
    "only-arches": ["x86_64"],
  },
];

writeFileSync(
  "generated/electron-cache-manifest.json",
  JSON.stringify(electron, null, 2),
  "utf-8"
);
