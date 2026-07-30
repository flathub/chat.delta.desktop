//@ts-check
/* Makes deltachat-desktop's `link:`-ed local packages survive electron-builder
   packaging.

   link_local.sh turns @deltachat/jsonrpc-client and @deltachat/stdio-rpc-server
   into pnpm `link:` dependencies pointing at the locally built core. A `link:`
   dependency has no lockfile snapshot, so its own runtime deps (yerpc,
   isomorphic-ws, @deltachat/tiny-emitter, ...) are invisible to both
   bin/build/writeFlatDependencies.js and electron-builder's own dependency
   resolver - electron-builder packages ONLY what its resolver finds in the pnpm
   graph and ignores anything merely copied into node_modules.

   The only thing electron-builder honours is the dependency graph, so this script
   puts the linked packages' runtime dependencies into it: it adds them as direct
   dependencies of the given workspace package. Versions are pinned to exactly
   what the lockfile already resolved (the published packages were installed by
   the earlier frozen install, so their deps are already in the store).

   Usage:
     node tool_inject_linked_deps.mjs <target-package.json> <pnpm-lock.yaml> <link-target-dir>...
*/
import { readFileSync, writeFileSync, existsSync, readdirSync } from "fs";
import { join, dirname, resolve } from "path";
import { createRequire } from "module";

const [targetPkgPath, lockfilePath, ...linkTargets] = process.argv.slice(2);
if (!targetPkgPath || !lockfilePath || linkTargets.length === 0) {
  console.error(
    "usage: node tool_inject_linked_deps.mjs <target-package.json> <pnpm-lock.yaml> <link-target-dir>...",
  );
  process.exit(1);
}

// yaml and semver live in the workspace, not next to this (separately shipped)
// script. yaml is hoisted to the root node_modules; semver only exists in the
// pnpm store, so look it up there.
const workspaceRoot = dirname(resolve(lockfilePath));
const rootRequire = createRequire(join(workspaceRoot, "package.json"));
const { parse } = rootRequire("yaml");

/** createRequire anchored at a package in the pnpm store @param {string} name */
function storeRequire(name) {
  const store = join(workspaceRoot, "node_modules/.pnpm");
  const dir = readdirSync(store)
    .filter((d) => d.startsWith(`${name}@`))
    .sort()
    .pop();
  if (!dir) throw new Error(`${name} not found in pnpm store`);
  return createRequire(join(store, dir, "node_modules", name, "package.json"));
}
const semver = existsSync(join(workspaceRoot, "node_modules/semver"))
  ? rootRequire("semver")
  : storeRequire("semver")("semver");

const lockfile = parse(readFileSync(lockfilePath, "utf8"));

/** all concrete versions the lockfile knows for a package name
 * @param {string} name */
function lockfileVersions(name) {
  const versions = new Set();
  for (const section of [lockfile.snapshots, lockfile.packages]) {
    for (const key of Object.keys(section ?? {})) {
      // keys look like `name@1.2.3` or `name@1.2.3(peer@4.5.6)`
      const at = key.lastIndexOf("@");
      if (at <= 0) continue;
      const n = key.slice(0, at);
      if (n !== name) continue;
      const v = key.slice(at + 1).replace(/\(.*\)$/, "");
      if (semver.valid(v)) versions.add(v);
    }
  }
  return [...versions];
}

/** Find a locally-built package (e.g. the stdio-rpc-server platform binary,
 * @deltachat/stdio-rpc-server-<os>-<arch>) under a link target. It lives in
 * platform_package/<cargo-target>/, and the file: path recorded in package.json
 * may have been rewritten for the sandbox, so locate it by name on disk instead.
 * @param {string} linkTarget @param {string} name */
function findLocalPackage(linkTarget, name) {
  const platformDir = join(linkTarget, "platform_package");
  if (!existsSync(platformDir)) return null;
  for (const entry of readdirSync(platformDir)) {
    const pkgJson = join(platformDir, entry, "package.json");
    if (!existsSync(pkgJson)) continue;
    if (JSON.parse(readFileSync(pkgJson, "utf8")).name === name) {
      return resolve(join(platformDir, entry));
    }
  }
  return null;
}

const targetPkg = JSON.parse(readFileSync(targetPkgPath, "utf8"));
targetPkg.dependencies = targetPkg.dependencies ?? {};

const injected = [];
for (const linkTarget of linkTargets) {
  const manifest = JSON.parse(
    readFileSync(join(linkTarget, "package.json"), "utf8"),
  );
  const deps = { ...manifest.dependencies, ...manifest.optionalDependencies };
  for (const [name, range] of Object.entries(deps)) {
    if (targetPkg.dependencies[name]) continue; // don't override an existing dep

    // local file:/link: dep (the rpc-server platform binary) - not in the
    // registry/lockfile, so point at the real directory on disk
    if (range.startsWith("file:") || range.startsWith("link:")) {
      const localDir = findLocalPackage(linkTarget, name);
      if (!localDir) {
        console.warn(
          `WARN: local package ${name} (${range}) not found, skipped`,
        );
        continue;
      }
      targetPkg.dependencies[name] = `file:${localDir}`;
      injected.push(`${name}@file:${localDir}`);
      continue;
    }

    const exact = semver.maxSatisfying(lockfileVersions(name), range);
    if (!exact) {
      console.warn(
        `WARN: no lockfile version of ${name} satisfies ${range}, skipped`,
      );
      continue;
    }
    targetPkg.dependencies[name] = exact;
    injected.push(`${name}@${exact}`);
  }
}

writeFileSync(targetPkgPath, JSON.stringify(targetPkg, null, 2) + "\n");
console.log(
  injected.length
    ? `injected into ${targetPkg.name}: ${injected.join(", ")}`
    : "nothing to inject",
);
