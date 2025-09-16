# Bruno build + publish automation — how and why

This document explains why `bruno-build-publish.sh` exists, what it does end‑to‑end, how to configure it for Verdaccio or JFrog Artifactory, and what artifacts and checks it produces along the way.

## Why this script exists

Publishing Bruno from source to an internal registry requires a precise sequence:

- Prepare a clean workspace and deterministic versions.
- Patch a few packages for internal compatibility and security.
- Build internal workspaces in a dependency-safe order.
- Publish internal libraries first, then publish `@usebruno/js` and finally `@usebruno/cli`.
- Pin the CLI’s internal deps to the freshly published versions to avoid fetching stale transitive versions.
- Smoke test installs and capture artifacts (logs + source archive) for traceability.

This script automates that entire pipeline reliably, integrates with Verdaccio or JFrog, and produces logs and a source archive you can upload for provenance.

## What it does at a glance

Inputs → Actions → Outputs

- Inputs

  - Source repo ref to build (default: Bruno upstream, branch/tag/commit via `BRUNO_REF`).
  - Registry mode: `verdaccio` or `jfrog` with corresponding URLs/tokens.
  - Version/tag settings (`VERSION_SUFFIX`, `NPM_TAG`).
  - Flags for smoke tests and app build.

- Actions

  - Clones/updates sources, sets `set -euo pipefail`, and creates two separate npmrc files (install vs publish).
  - Mirrors select forks/shims from npm if missing internally.
  - Applies small compatibility patches.
  - Installs deps, builds internal packages in order, bumps versions with a suffixed pre-release, and publishes.
  - Pins internal versions into the CLI and verifies the tarball is pinned.
  - Optional smoke tests.
  - Creates a “sources-only” tarball and uploads artifacts (archive + build log) to Artifactory.

- Outputs

  - Published packages in your registry with consistent version suffix.
  - A log streamed to `bruno-build-publish.<VERSION_SUFFIX>.log`.
  - `bruno-sources-<VERSION_SUFFIX>.tar.gz` with only sources (no node_modules/dist/.git).
  - Optional global/temp install smoke test results in the log.

## Key design choices

- Two npmrc files

  - `.npmrc.install` (reads): points to the registry used for installs (Verdaccio or Artifactory virtual); contains auth if provided.
  - `.npmrc.publish` (writes): points to the publishing registry (Verdaccio or Artifactory local); contains auth if provided.
  - Rationale: never mix install and publish endpoints; avoid accidental scope overrides when publishing.

- Versioning strategy

  - All internal packages are bumped from their base semver to `<base>-<VERSION_SUFFIX>` to form a unique, traceable pre-release.
  - A single `NPM_TAG` (default `opensourcebuild`) is applied to all publishes for easy install testing.

- Deterministic builds and safe mode

  - `set -euo pipefail` and a `run` wrapper; a `DRY_RUN=1` mode prints actions without mutating state.
  - `npm ci` preferred; falls back to `npm install` if needed for local iterations.

- Registry health & visibility

  - Pings the install registry.
  - Waits for package visibility after publish using `npm view` plus a direct registry JSON check.

- Traceability artifacts

  - Streams stdout/stderr to a timestamped log file.
  - Archives sources minus heavy/build folders for reproducible investigations.

## Configuration (env vars)

General

- `REG_MODE`: `verdaccio` | `jfrog` (default `verdaccio`).
- `WORKDIR`: where the Bruno source lives (default: `./bruno-src`).
- `BRUNO_GIT`: upstream repo URL (default: `https://github.com/usebruno/bruno`).
- `BRUNO_REF`: git ref to checkout (branch/tag/sha). Empty = default branch.
- `DO_GLOBAL_INSTALL_TEST`: run global install smoke test (default `true`).
- `DO_TEMP_INSTALL_TEST`: run a temp project install (Verdaccio-only) (default `true`).
- `DO_BUILD_APP`: also build `@usebruno/app` (default `false`).
- `VERSION_SUFFIX`: pre-release suffix added to all versions (default `release.<timestamp>`).
- `NPM_TAG`: dist-tag used on publish (default `opensourcebuild`).
- `DRY_RUN`: `1` prints actions only; no changes.

Verdaccio

- `VERDACCIO_URL`: base URL (e.g., `http://127.0.0.1:8080`).
- `NPM_TOKEN`: auth token (optional if registry allows anonymous).

JFrog (choose ONE of the following configuration patterns)

- Direct registry URLs
  - `ART_INSTALL_REG`: your virtual npm repo (reads).
  - `ART_PUBLISH_REG`: your local npm repo (writes).

- Derived from base + names
  - `ART_URL`: e.g., `https://artifacthub.example.com`.
  - `ART_VIRTUAL_REPO`: e.g., `cagbu-dev-opensource-release-node-npm-virtual`.
  - `ART_LOCAL_REPO`: e.g., `cagbu-dev-opensource-release-node`.

- Auth
  - `ART_TOKEN`: API Key or Bearer token; both header styles are sent.

Artifact uploads (Artifactory)

- `ART_ARCHIVE_REPO`: repo to store the sources archive (default `cagbu-dev-internal-release-node`).
- `ART_LOGS_REPO`: repo to store the build logs (default `cagbu-dev-opensource-release-logs`).

## End-to-end flow

1. Ensure tooling and repo

- Requires: `git`, `node`, `npm`, `tar`, `curl`.
- Clones Bruno into `WORKDIR` (or updates/uses existing).
- Optionally checks out `BRUNO_REF`.
- Light Node version check with a hint to use Node 18/20/22 if you’re on something exotic.

1. Configure npm

- Writes `.npmrc.install` (read/virtual) and `.npmrc.publish` (write/local) with the right scope `@usebruno`.
- Pings the install registry for a quick sanity check.

1. Mirror must-have shims/forks if missing internally

- `@usebruno/vm2@^3.9.19`
- `@usebruno/crypto-js@^3.1.9`
- Logic: resolve from public npm (preferred) or your install registry, then publish to your publish registry if that version is missing.

1. Apply small compatibility patches

- `@usebruno/common`: ensure subpath exports (`.`, `./runner`, `./utils`) with proper CJS/ESM/types mapping.
- `bruno-js`: replace legacy `vm2` with `@usebruno/vm2` dependency and require path.
- `bruno-graphql-docs`: widen peers `react` and `react-dom` to `^17 || ^18 || ^19` and mark optional to ease downstream usage.

1. Install deps

- `npm ci` with `.npmrc.install` (falls back to `npm install` if needed).

1. Build internal libraries in order

- `@usebruno/common`
- `@usebruno/requests`
- `@usebruno/query`
- `@usebruno/converters`
- `@usebruno/graphql-docs`
- `@usebruno/filestore`
- Optionally build `@usebruno/app` if `DO_BUILD_APP=true`.

1. Publish internal libs first (bump + publish + visibility)

- Bumps each package to `<base>-<VERSION_SUFFIX>` with `--no-git-tag-version`.
- Packs and publishes each to the publish registry with `--tag <NPM_TAG>`.
- Waits for visibility on the install registry (useful for virtual repos that front the local).

1. Publish `@usebruno/js`

- Bumps to `<base>-<VERSION_SUFFIX>`.
- Runs `sandbox:bundle-libraries` (best-effort) to prepare sandbox bundles.
- Publishes and waits for visibility.

1. Pin all internal versions into `@usebruno/cli`

- Reads the freshly published internal versions and writes them into `packages/bruno-cli/package.json`.
- Verifies by packing the CLI and checking the tarball’s `package.json` that `@usebruno/js` matches the expected new version.

1. Publish `@usebruno/cli`

- Bumps to `<base>-<VERSION_SUFFIX>` and publishes with the common tag.
- Waits for registry visibility.

1. Smoke tests (optional)

- Global install test from your install registry if it proxies public npm.
- Temporary project install test (Verdaccio-only) using a disposable `.npmrc` and `npm install @usebruno/cli@<version>`.

1. Produce and upload artifacts

- Creates `bruno-sources-<VERSION_SUFFIX>.tar.gz` from sources only (excludes: node_modules, dist, build, .git, .turbo, .cache, etc.).
- Uploads the source archive to `ART_ARCHIVE_REPO` and the build log to `ART_LOGS_REPO` under friendly paths.

1. Completion summary in logs

- Confirms install/publish registries and lists artifact paths.

## How to run

Verdaccio example (local dev)

```sh
# In zsh
export REG_MODE=verdaccio
export VERDACCIO_URL="http://127.0.0.1:8080"
# Optional if auth is required
# export NPM_TOKEN=... 

# Build and publish the latest default branch
./bruno-build-publish.sh

# Or build a specific tag/commit
BRUNO_REF=v2.9.1 ./bruno-build-publish.sh
```

JFrog example (virtual for install, local for publish)

```sh
# In zsh
export REG_MODE=jfrog
export ART_INSTALL_REG="https://<host>/artifactory/api/npm/<virtual-repo>/"
export ART_PUBLISH_REG="https://<host>/artifactory/api/npm/<local-repo>/"
export ART_TOKEN=XXXXX   # API key or access token

./bruno-build-publish.sh
```

Dry run (no mutations)

```sh
DRY_RUN=1 ./bruno-build-publish.sh
```

Tuning versions and tags

```sh
VERSION_SUFFIX="release.$(date +%Y%m%d%H%M%S)" NPM_TAG=opensourcebuild ./bruno-build-publish.sh
```

## Inputs/outputs “contract”

Inputs

- Authenticated access to the selected registry/registries.
- Git access to `BRUNO_GIT` and optional `BRUNO_REF`.
- Node/npm available locally.

Outputs

- Internal packages published with versions like `<base>-<VERSION_SUFFIX>` and tagged `<NPM_TAG>`.
- Log file: `bruno-build-publish.<VERSION_SUFFIX>.log` (streamed live).
- Source archive: `bruno-sources-<VERSION_SUFFIX>.tar.gz`.
- Optional smoke-test evidence in the log.

Error modes

- Missing tools/commands cause an early exit.
- Registry ping or visibility waits may warn and continue where safe.
- Tarball dependency pin check is strict; it fails if the CLI isn’t pinned to the expected `@usebruno/js` version.

Success criteria

- All target packages exist in the publish registry; resolved via the install registry.
- CLI tarball verified to depend on the newly published internal versions.
- Artifacts uploaded if Artifactory is configured.

## Troubleshooting tips

- Auth failures
  - Verify tokens (`NPM_TOKEN` or `ART_TOKEN`) and that your registry endpoints are correct (trailing slashes matter in the env vars, the script normalizes them).

- “Package not visible” timeouts
  - Some registries take time to index; the script uses both `npm view` and a JSON endpoint check with headers for JFrog.
  - You can re-run; versions are pre-release suffixed and won’t collide with public builds.

- CLI install failures in the smoke test
  - Ensure your install registry proxies public npm, or the script will skip the global install test.
  - For Verdaccio, confirm upstreams and auth are set correctly.

- Node version quirks
  - If you’re on Node outside 18/20/22, the script logs a warning. Use nvm to switch if needed.

## Security considerations

- Tokens are written only to local `.npmrc.install` / `.npmrc.publish` files in the working directory or temp folder (for the temp install test). Do not commit these files.
- The script avoids echoing tokens into the log; headers are only attached to curl calls.

## Adjacent improvements (optional)

- Add a CI job that sets `DRY_RUN=1` and validates the flow on every update.
- Gate real publishes behind a manual approval with `DRY_RUN=0`.
- Parameterize the wait time for visibility if your registry is slower/faster than the defaults.

---

If you only need the quick start: set `REG_MODE`, point to your registry, and run `./bruno-build-publish.sh`. The log and sources archive will be created alongside the script and uploaded if Artifactory variables are provided.
