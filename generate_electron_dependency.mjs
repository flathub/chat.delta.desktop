//@ts-check
import { createHash } from "crypto";
import { readFileSync, writeFileSync } from "fs";

const packages = JSON.parse(
  readFileSync("generated/proxy-registry-cache-manifest.json", "utf-8")
);

const electron_package = packages.find(({ url }) =>
  url.startsWith("https://registry.npmjs.org/electron/-/electron")
);

const electron_version = electron_package.url.match(/\d+?.\d+?.\d+?/)[0];

console.log("found electron version:", electron_version);

function calculateSHA256(blob) {
  const hash = createHash("sha256");
  hash.update(blob);
  return hash.digest("hex");
}

const base_url = `https://github.com/electron/electron/releases/download/v${electron_version}`;

const url_shasums = `${base_url}/SHASUMS256.txt`;
const request_shasums = await fetch(url_shasums);
const blob = await request_shasums.blob();
const shasum_file_hash = calculateSHA256(Buffer.from(await blob.arrayBuffer()));
const shasums = (await blob.text()).split("\n").map((line) => line.split(" *"));

// console.log({ shasums, shasum_file_hash });

const arm64_filename = `electron-v${electron_version}-linux-arm64.zip`;
const amd64_filename = `electron-v${electron_version}-linux-x64.zip`;

function findHashFor(filename) {
  //@ts-expect-error
  return shasums.find(([_hash, file]) => filename === file)[0];
}

const electron = [
  // not actually needed see https://www.electronjs.org/docs/latest/tutorial/installation#cache
  // {
  //   type: "file",
  //   url: url_shasums,
  //   sha256: shasum_file_hash,
  //   "dest-filename": `SHASUMS256.txt-${electron_version}`,
  //   dest: "cache/electron",
  // },
  {
    type: "file",
    url: `${base_url}/${arm64_filename}`,
    sha256: findHashFor(arm64_filename),
    "dest-filename": arm64_filename,
    dest: "cache/electron/" + findHashFor(arm64_filename),
    "only-arches": ["aarch64"],
  },
  {
    type: "file",
    url: `${base_url}/${amd64_filename}`,
    sha256: findHashFor(amd64_filename),
    "dest-filename": amd64_filename,
    dest: "cache/electron/" + '33ad7cf20a81d15fc3ce9cc6dab119e211030607726ff9cdca91887b57227c04', // TODO: find out how to get this in code ,//findHashFor(arm64_filename),
    "only-arches": ["x86_64"],
  },
];

// console.log(electron);

writeFileSync(
  "generated/electron-cache-manifest.json",
  JSON.stringify(electron, null, 2),
  "utf-8"
);
