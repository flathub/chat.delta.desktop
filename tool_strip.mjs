///@ts-check
import { readFile, writeFile, rm } from "fs/promises";
import { existsSync } from "fs";
import { basename, join } from "path";

/** @type {Record<string,string[]>} */
// @ts-ignore
const stripInfo = JSON.parse(
  await readFile("generated/used_versions_strip_info.json"),
);

/* `pnpm` itself is not a dependency - its metadata only gets fetched by pnpm's own
update check - so it has no entry in the strip info and its index (>5 MB) would be
kept in full. Keep the version that generated/pnpm.json installs into the build. */
// @ts-ignore
const pnpmArchiveUrl = JSON.parse(await readFile("generated/pnpm.json"))["url"];
const pnpmVersion = basename(pnpmArchiveUrl)
  .replace(/^pnpm-/, "")
  .replace(/\.tgz$/, "");
stripInfo["pnpm"] = [...(stripInfo["pnpm"] ?? []), pnpmVersion];

/* The strip info is keyed by the package name as it appears in tarball urls
(`/@scope/name/-/name-1.0.0.tgz`), but package metadata is requested under both
`/@scope/name` and `/@scope%2Fname` depending on the client - pnpm >=11 uses the
encoded form. Both spellings end up as separate directories in the cache, so both
need to be stripped. */
/** @param {string} packageName */
function indexPathsFor(packageName) {
  const names = packageName.includes("/")
    ? [packageName, packageName.replaceAll("/", "%2F")]
    : [packageName];
  return names
    .map((name) =>
      join("generated/proxy-registry-cache-indices", name, "index.json"),
    )
    .filter((path) => existsSync(path));
}

for (const packageName in stripInfo) {
  if (Object.prototype.hasOwnProperty.call(stripInfo, packageName)) {
    const usedVersions = stripInfo[packageName];
    for (const pathToIndex of indexPathsFor(packageName)) {
      // @ts-ignore
      const index = JSON.parse(await readFile(pathToIndex));
      const allVersions = Object.keys(index["versions"]);

      const unusedVersions = allVersions.filter(
        (version) => !usedVersions.includes(version),
      );
      // console.log({allVersions, unusedVersions});

      unusedVersions.forEach((version) => {
        delete index["versions"][version];
        delete index["time"][version];
      });

      // Theoretical issue: we may need to adjust "time" object's modified property to the latest available version after filtering

      delete index["users"];

      await writeFile(pathToIndex, JSON.stringify(index, null, 2), "utf-8");
    }
  }
}
