#!/usr/bin/env bash
# ----------------------------------------------------------------------------
# bruno-build-publish.sh — Build Bruno from source, publish internal libs first,
# then publish @usebruno/js and @usebruno/cli to your Verdaccio/JFrog registry,
# and (optionally) install it for a smoke test.
#
# Now also:
#  - Archives sources only (no node_modules/dist/.git) as: bruno-sources-${VERSION_SUFFIX}.tar.gz
#  - Streams logs to: bruno-build-publish.${VERSION_SUFFIX}.log
#  - Uploads both artifacts to Artifactory:
#       - sources  → cagbu-dev-opensource-release-node
#       - logs     → cagbu-dev-opensource-release-logs
# ----------------------------------------------------------------------------
# Docs: See README-bruno-build-publish.md (how/why, config, full flow)
# Quick start (zsh):
#   # Verdaccio
#   REG_MODE=verdaccio VERDACCIO_URL=http://127.0.0.1:8080 ./bruno-build-publish.sh
#   # JFrog (virtual for install, local for publish)
#   REG_MODE=jfrog ART_INSTALL_REG=https://<host>/artifactory/api/npm/<virtual>/ \
#     ART_PUBLISH_REG=https://<host>/artifactory/api/npm/<local>/ ART_TOKEN=XXXXX \
#     ./bruno-build-publish.sh
#   # Dry run (no mutations)
#   DRY_RUN=1 ./bruno-build-publish.sh

set -euo pipefail

# ---------- Config (env overrides) ------------------------------------------
: "${REG_MODE:=verdaccio}"                    # verdaccio | jfrog
: "${WORKDIR:=${PWD}/bruno-src}"
: "${BRUNO_GIT:=https://github.com/usebruno/bruno}"
: "${BRUNO_REF:=}"
: "${DO_GLOBAL_INSTALL_TEST:=true}"
: "${DO_TEMP_INSTALL_TEST:=true}"
: "${DO_BUILD_APP:=false}"
: "${VERSION_SUFFIX:=release.$(date +%Y%m%d%H%M%S)}"
: "${NPM_TAG:=opensourcebuild}"
: "${DRY_RUN:=0}"                             # 1 = print actions; skip mutating ops

# Verdaccio inputs
: "${VERDACCIO_URL:=http://127.0.0.1:8080}"
: "${NPM_TOKEN:=}"

# JFrog inputs (YOUR EXACT REPOS — overrideable)
# If you prefer to pass ART_URL/ART_VIRTUAL_REPO/ART_LOCAL_REPO, leave these blank.
: "${ART_INSTALL_REG:=https://artifacthub-phx.oci.oraclecorp.com/artifactory/api/npm/cagbu-dev-internal-release-node-npm-virtual/}"
: "${ART_PUBLISH_REG:=https://artifacthub-phx.oci.oraclecorp.com/artifactory/api/npm/cagbu-dev-internal-release-node/}"
: "${ART_TOKEN:=}"    # API Key or Bearer token

# If ART_INSTALL_REG/ART_PUBLISH_REG are blank, you may instead use:
: "${ART_URL:=}"                 # e.g. https://artifacthub-phx.oci.oraclecorp.com
: "${ART_VIRTUAL_REPO:=}"        # e.g. cagbu-dev-opensource-release-node-npm-virtual
: "${ART_LOCAL_REPO:=}"          # e.g. cagbu-dev-opensource-release-node

# New: where to upload extra artifacts (archives/logs). Override if needed.
: "${ART_ARCHIVE_REPO:=cagbu-dev-internal-release-node}"
: "${ART_LOGS_REPO:=cagbu-dev-opensource-release-logs}"

# Internals
PUBLIC_REG="https://registry.npmjs.org"
WORKSPACES_OFF=(--workspaces=false)

# npmrc paths (set after repo init)
NPMRC_INSTALL=""
NPMRC_PUBLISH=""

# Logging (to file + stdout)
LOG_FILE="${PWD}/bruno-build-publish.${VERSION_SUFFIX}.log"
# tee the entire script output into the log (stderr included)
exec > >(tee -a "$LOG_FILE") 2>&1

# ---------- Helpers ----------------------------------------------------------
log()  { printf "\033[1;34m[INFO]\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m[WARN]\033[0m %s\n" "$*"; }
die()  { printf "\033[1;31m[ERR ]\033[0m %s\n" "$*" >&2; exit 1; }
req()  { command -v "$1" >/dev/null || die "Missing required command: $1"; }

run() {
  if [ "${DRY_RUN}" = "1" ]; then
    printf '[DRY] %s\n' "$*"
  else
    "$@"
  fi
}
trim_trailing_slash() { local s="$1"; s="${s%/}"; printf '%s' "$s"; }

json_get_name()    { node -p 'require("./package.json").name'    2>/dev/null; }
json_get_version() { node -p 'require("./package.json").version' 2>/dev/null; }

compute_new_version() {
  node -e 'const fs=require("fs");const p=JSON.parse(fs.readFileSync("package.json","utf8"));const base=String(p.version||"0.0.0").split("-")[0];console.log(base+"-'"${VERSION_SUFFIX}"'");'
}

maybe_use_nvm() {
  local v="unknown"; v="$(node -v 2>/dev/null || echo unknown)"
  if echo "$v" | grep -Eq '^v(1[0-7]|2[3-9])'; then
    warn "Detected $v; Bruno tends to work best with Node 18/20/22."
  fi
}

npm_ping() {
  local registry="$1" token="${2:-}"
  log "Registry ping (npm): $registry"
  # Use the install npmrc so auth & scope are correct
  if NPM_CONFIG_USERCONFIG="$NPMRC_INSTALL" npm "${WORKSPACES_OFF[@]}" ping --registry "$registry" >/dev/null 2>&1; then
    log "npm ping OK: $registry"
    return 0
  fi
  log "npm ping failed; trying HTTP GET to /-/ping"
  local url
  url="$(trim_trailing_slash "$registry")/-/ping"
  local curl_args=(-fsS -X GET)
  # Add both Artifactory auth header variants if token provided
  if [ -n "$token" ]; then
    curl_args+=(-H "X-JFrog-Art-Api: ${token}")
    curl_args+=(-H "Authorization: Bearer ${token}")
  fi
  if curl "${curl_args[@]}" "$url" >/dev/null 2>&1; then
    log "HTTP ping OK: $url"
    return 0
  fi
  warn "Failed to ping registry: $registry"
  return 1
}

npm_cfg_get() { npm "${WORKSPACES_OFF[@]}" config get "$@" 2>&1; }
npm_view()    { npm "${WORKSPACES_OFF[@]}" view "$@" 2>/dev/null; }

# --- Run npm with workspaces disabled and explicit npmrc --------------------
npm_unset_ws() {
  # usage: npm_unset_ws <npmrc_path> <command and args...>
  local npmrc="$1"; shift
  NPM_CONFIG_USERCONFIG="$npmrc" \
  env -u npm_config_workspace -u npm_config_workspaces -u npm_config_workspace_enabled \
      NPM_CONFIG_LEGACY_PEER_DEPS=1 npm_config_ignore_scripts=1 "$@"
}

npm_pack_dir() {
  # Pack does not need network, but keep env clean
  local dir="$1" tgz
  ( cd "$dir" >/dev/null
    tgz="$(npm_unset_ws "${NPMRC_INSTALL}" npm pack --silent)"
    printf "%s/%s" "$PWD" "$tgz"
  )
}

npm_publish_tgz() {
  # usage: npm_publish_tgz <tgz> <registry> <tag> [--access public]
  local tgz="$1" registry="$2" tag="$3" access="${4:---access public}"
  npm_unset_ws "${NPMRC_PUBLISH}" npm publish "$tgz" --registry "$registry" --tag "$tag" $access
}

npm_pack_publish_dir() {
  local dir="$1" registry="$2" tag="$3"
  if [ "${DRY_RUN}" = "1" ]; then
    printf '[DRY] npm pack in %s; publish to %s (tag: %s)\n' "$dir" "$registry" "$tag"
    return 0
  fi
  local tgz; tgz="$(npm_pack_dir "$dir")"
  npm_publish_tgz "$tgz" "$registry" "$tag"
  rm -f "$tgz"
}

# ------ Create two npmrc files: one for install (virtual), one for publish (local)
write_dual_npmrcs() {
  local install_registry="$1" install_token="$2" publish_registry="$3" publish_token="$4"

  local inst
  inst="$(trim_trailing_slash "$install_registry")/"
  local pub
  pub="$(trim_trailing_slash "$publish_registry")/"

  NPMRC_INSTALL="$PWD/.npmrc.install"
  NPMRC_PUBLISH="$PWD/.npmrc.publish"

  log "Writing $NPMRC_INSTALL (reads via VIRTUAL) and $NPMRC_PUBLISH (writes via LOCAL)"

  # INSTALL npmrc
  cat > "$NPMRC_INSTALL" <<EOF
registry=$inst
always-auth=true
@usebruno:registry=$inst
EOF
  if [ -n "$install_token" ]; then
    local hp="${install_registry#http://}"; hp="${hp#https://}"; hp="$(trim_trailing_slash "$hp")/"
    echo "//${hp}:_authToken=${install_token}" >> "$NPMRC_INSTALL"
  fi

  # PUBLISH npmrc — critical: scope points to LOCAL
  cat > "$NPMRC_PUBLISH" <<EOF
registry=$pub
always-auth=true
@usebruno:registry=$pub
EOF
  if [ -n "$publish_token" ]; then
    local hp2="${publish_registry#http://}"; hp2="${hp2#https://}"; hp2="$(trim_trailing_slash "$hp2")/"
    echo "//${hp2}:_authToken=${publish_token}" >> "$NPMRC_PUBLISH"
  fi
}

ensure_repo() {
  # Make sure the parent directory exists so git can clone into WORKDIR
  local parent; parent="$(dirname "$WORKDIR")"
  if [ ! -d "$parent" ]; then
    log "Creating parent directory: $parent"
    run mkdir -p "$parent"
    # If DRY_RUN, mkdir above was skipped; ensure it exists for the rest of the dry flow
    if [ "${DRY_RUN}" = "1" ] && [ ! -d "$parent" ]; then mkdir -p "$parent"; fi
  fi

  # Case 1: already have a usable tree with package.json
  if [ -d "$WORKDIR" ] && [ -f "$WORKDIR/package.json" ]; then
    log "Using existing Bruno source at $WORKDIR"
    cd "$WORKDIR"
    if [ -n "$BRUNO_REF" ] && [ -d .git ]; then
      log "Checking out ref: $BRUNO_REF"
      run git checkout --quiet "$BRUNO_REF"
    fi
    return 0
  fi

    # Case 2: repo exists — fetch, otherwise clone
  if [ -d "$WORKDIR/.git" ]; then
    log "Updating existing repo at $WORKDIR"
    run git -C "$WORKDIR" fetch --all --tags --prune
  else
    if [ -n "$BRUNO_REF" ]; then
      log "Cloning Bruno @ ${BRUNO_REF} → $WORKDIR"
      if [ "${DRY_RUN}" = "1" ]; then
        # Simulate a repo with package.json so later steps work
        log "[DRY] Simulating clone of $BRUNO_REF at $WORKDIR"
        mkdir -p "$WORKDIR"
        printf '{ "name": "bruno", "version": "0.0.0" }\n' > "$WORKDIR/package.json"
      else
        # Try shallow clone of the exact ref
        run git clone --depth=1 --branch "$BRUNO_REF" --single-branch "$BRUNO_GIT" "$WORKDIR" || {
          warn "Shallow clone of '$BRUNO_REF' failed; falling back to full clone"
          run git clone "$BRUNO_GIT" "$WORKDIR"
          run git -C "$WORKDIR" fetch --tags --force --prune
          run git -C "$WORKDIR" -c advice.detachedHead=false checkout --quiet "$BRUNO_REF"
        }
      fi
    else
      log "Cloning Bruno (default branch) → $WORKDIR"
      if [ "${DRY_RUN}" = "1" ]; then
        log "[DRY] Simulating clone at $WORKDIR"
        mkdir -p "$WORKDIR"
        printf '{ "name": "bruno", "version": "0.0.0" }\n' > "$WORKDIR/package.json"
      else
        run git clone --depth=1 "$BRUNO_GIT" "$WORKDIR"
      fi
    fi
  fi

  cd "$WORKDIR" || die "Cannot enter $WORKDIR"
  if [ -n "$BRUNO_REF" ]; then
    log "Checking out ref: $BRUNO_REF"
    if [ "${DRY_RUN}" = "1" ]; then
      log "[DRY] Would checkout $BRUNO_REF"
    else
      run git checkout --quiet "$BRUNO_REF"
    fi
  fi

  # Sanity
  if [ ! -f package.json ]; then
    if [ "${DRY_RUN}" = "1" ]; then
      printf '{ "name": "bruno", "version": "0.0.0" }\n' > package.json
      warn "Dry-run: created stub package.json"
    else
      die "Bruno repo bootstrap failed: $WORKDIR does not contain package.json"
    fi
  fi
}

# -------- JFrog helpers: auth headers + visibility waiting with curl fallback --
jfrog_headers() {
  # Prints curl -H args if ART_TOKEN set (both API key and Bearer forms)
  if [ -n "${ART_TOKEN:-}" ]; then
    printf -- "-H X-JFrog-Art-Api:%s -H Authorization:Bearer:%s" "$ART_TOKEN" "$ART_TOKEN" | sed 's/ /" "/g' | xargs -n1 echo | sed 's/^/-H "/;s/$/"/'
  fi
}

jfrog_base_url_from_any() {
  # Derive https://host/artifactory from either full api/npm URL or ART_URL
  if [ -n "${ART_URL:-}" ]; then
    printf '%s/artifactory' "$(trim_trailing_slash "$ART_URL")"
    return 0
  fi
  local src="${ART_PUBLISH_REG:-${ART_INSTALL_REG:-}}"
  [ -n "$src" ] || { echo ""; return 0; }
  src="$(trim_trailing_slash "$src")"
  # strip /api/npm/<repo> if present
  src="${src%%/api/npm/*}"
  # ensure trailing /artifactory
  if [[ "$src" != *"/artifactory" ]]; then
    src="${src%/}/artifactory"
  fi
  printf '%s' "$src"
}

upload_to_artifactory() {
  # usage: upload_to_artifactory <repoName> <localFile> <destPathRelativeToRepo>
  local repo="$1" file="$2" dest_rel="$3"
  local base; base="$(jfrog_base_url_from_any)"
  [ -n "$base" ] || { warn "Cannot derive Artifactory base URL; skip upload for $file"; return 1; }
  [ -f "$file" ] || { warn "File not found for upload: $file"; return 1; }

  local url="${base%/}/$repo/$dest_rel"
  local curl_args=()
  if [ -n "${ART_TOKEN:-}" ]; then
    curl_args+=(-H "X-JFrog-Art-Api: ${ART_TOKEN}")
    curl_args+=(-H "Authorization: Bearer ${ART_TOKEN}")
  fi

  log "Uploading $(basename "$file") → $url"
  if [ "${DRY_RUN}" = "1" ]; then
    printf '[DRY] curl -T %q %q (with auth headers if set)\n' "$file" "$url"
    return 0
  fi

  # Use PUT with -T to create/overwrite
  if ! curl -fsS -X PUT "${curl_args[@]}" -T "$file" "$url"; then
    warn "Upload failed: $file → $url"
    return 1
  fi
  log "Upload OK: $file"
}

create_sources_archive() {
  # usage: create_sources_archive <srcDir> <outFile>
  local src="$1" out="$2"
  log "Creating sources archive (no node_modules/dist/.git): $out"
  if [ "${DRY_RUN}" = "1" ]; then
    printf '[DRY] tar czf %q --exclude patterns from %q\n' "$out" "$src"
    return 0
  fi
  (
    cd "$src"
    tar -czf "$out" \
      --exclude='./node_modules' \
      --exclude='**/node_modules' \
      --exclude='./dist' \
      --exclude='**/dist' \
      --exclude='./build' \
      --exclude='**/build' \
      --exclude='./.git' \
      --exclude='**/.git' \
      --exclude='./.turbo' \
      --exclude='**/.turbo' \
      --exclude='./.cache' \
      --exclude='**/.cache' \
      .
  )
}

wait_for_package_visibility() {
  local name="$1" ver="$2" reg_raw="$3" timeout="${4:-120}"
  local reg; reg="$(trim_trailing_slash "$reg_raw")"
  local end=$(( $(date +%s) + timeout ))
  export NPM_CONFIG_CACHE_MIN=0
  export NPM_CONFIG_PREFER_OFFLINE=false
  if [ "${DRY_RUN}" = "1" ]; then
    log "DRY: skip wait for $name@$ver on $reg"; return 0
  fi
  log "Waiting for $name@$ver to appear on $reg ..."
  local enc_name; enc_name="$(node -e 'console.log(encodeURIComponent(process.argv[1]))' "$name" 2>/dev/null || echo "$name")"
  local hdrs; hdrs="$(jfrog_headers)"

  while [ "$(date +%s)" -lt "$end" ]; do
    if NPM_CONFIG_USERCONFIG="$NPMRC_INSTALL" npm_view "${name}@${ver}" version --registry "$reg" >/dev/null; then
      log "Found via npm view: $name@$ver"; return 0
    fi
    if eval "curl -fsS $hdrs '$reg/$enc_name' 2>/dev/null | grep -q '\"$ver\"'"; then
      log "Found via registry JSON: $name@$ver"; return 0
    fi
    sleep 2
  done
  warn "Timeout waiting for visibility: $name@$ver on $reg"
  warn "Debug: npm view ${name}@${ver} --registry $reg"
  NPM_CONFIG_USERCONFIG="$NPMRC_INSTALL" npm_view "${name}@${ver}" version --registry "$reg" || true
  return 1
}

version_exists_in_registry() {
  if [ "${DRY_RUN}" = "1" ]; then return 1; fi
  NPM_CONFIG_USERCONFIG="$NPMRC_INSTALL" node -e '
    const [name,ver,reg] = process.argv.slice(1);
    const {execSync} = require("child_process");
    try {
      const out = execSync(`npm view ${name}@${ver} version --registry ${reg}`, {
        stdio:["ignore","pipe","pipe"],
        env:{...process.env, NPM_CONFIG_USERCONFIG: process.env.NPM_CONFIG_USERCONFIG || ""}
      }).toString().trim();
      process.exit(out ? 0 : 1);
    } catch(e){ process.exit(1); }
  ' "$1" "$2" "$(trim_trailing_slash "$3")"
}

npm_mirror_publish() {
  local spec="$1"
  local resolved_name resolved_ver source_reg tried_public=0

  # 1) Try public npm first (use install npmrc so proxy/ssl env applies)
  resolved_name="$(NPM_CONFIG_USERCONFIG="$NPMRC_INSTALL" npm "${WORKSPACES_OFF[@]}" view "$spec" name --registry "$PUBLIC_REG" 2>/dev/null || true)"
  resolved_ver="$(NPM_CONFIG_USERCONFIG="$NPMRC_INSTALL" npm "${WORKSPACES_OFF[@]}" view "$spec" version --registry "$PUBLIC_REG" 2>/dev/null || true)"
  if [ -n "$resolved_name" ] && [ -n "$resolved_ver" ]; then
    source_reg="$PUBLIC_REG"; tried_public=1
  else
    # 2) Fall back to your authenticated install registry (Artifactory virtual)
    resolved_name="$(NPM_CONFIG_USERCONFIG="$NPMRC_INSTALL" npm "${WORKSPACES_OFF[@]}" view "$spec" name --registry "$install_registry" 2>/dev/null || true)"
    resolved_ver="$(NPM_CONFIG_USERCONFIG="$NPMRC_INSTALL" npm "${WORKSPACES_OFF[@]}" view "$spec" version --registry "$install_registry" 2>/dev/null || true)"
    [ -n "$resolved_name" ] && [ -n "$resolved_ver" ] && source_reg="$install_registry"
  fi

  if [ -z "$resolved_name" ] || [ -z "$resolved_ver" ]; then
    warn "Unable to resolve $spec from either public npm or install registry; skipping mirror."
    return 0
  fi

  if version_exists_in_registry "$resolved_name" "$resolved_ver" "$publish_registry"; then
    log "Mirror skip — already present: ${resolved_name}@${resolved_ver} in $publish_registry"
    return 0
  fi

  log "Mirroring ${resolved_name}@${resolved_ver} from $source_reg → $publish_registry (public_hit=$tried_public)"
  if [ "${DRY_RUN}" = "1" ]; then
    printf '[DRY] npm pack %s@%s --registry %s; npm publish tgz --registry %s\n' "$resolved_name" "$resolved_ver" "$source_reg" "$publish_registry"
  else
    local tgz
    tgz="$(NPM_CONFIG_USERCONFIG="$NPMRC_INSTALL" npm pack "${resolved_name}@${resolved_ver}" --registry "$source_reg" 2>/dev/null | tail -n1)" || true
    [ -n "${tgz:-}" ] && [ -f "$tgz" ] || die "npm pack failed for ${resolved_name}@${resolved_ver} from $source_reg"
    npm_unset_ws "${NPMRC_PUBLISH}" npm publish "$tgz" --registry "$publish_registry" --access public || \
      warn "Publish of ${resolved_name}@${resolved_ver} returned non-zero; continuing."
    rm -f "$tgz"
  fi
}

# ---------- Patch @usebruno/common exports so subpaths resolve ----------
patch_bruno_common_exports() {
  local cdir="packages/bruno-common"
  local pj="$cdir/package.json"
  [ -f "$pj" ] || { warn "Missing $pj (layout changed?); skipping exports patch."; return 0; }
  if [ "${DRY_RUN}" = "1" ]; then printf '[DRY] patch exports in %s\n' "$pj"; return 0; fi
  node -e '
    const fs=require("fs"); const f=process.argv[1];
    const p=JSON.parse(fs.readFileSync(f,"utf8"));
    p.main = p.main || "dist/cjs/index.js";
    p.module = p.module || "dist/esm/index.js";
    p.types = p.types || "dist/index.d.ts";
    if (!p.exports || typeof p.exports!=="object") p.exports = {};
    p.exports["."] = p.exports["."] || {"require":"./dist/cjs/index.js","import":"./dist/esm/index.js","types":"./dist/index.d.ts"};
    p.exports["./runner"] = p.exports["./runner"] || {"require":"./dist/runner/cjs/index.js","import":"./dist/runner/esm/index.js","types":"./dist/runner/index.d.ts"};
    p.exports["./utils"] = p.exports["./utils"] || {"require":"./dist/utils/cjs/index.js","import":"./dist/utils/esm/index.js","types":"./dist/utils/index.d.ts"};
    fs.writeFileSync(f, JSON.stringify(p,null,2)+"\n");
    console.log("Patched exports in", f);
  ' "$pj" >/dev/null && log "Ensured subpath exports for @usebruno/common (./runner, ./utils)."
}

# ---------- Patch bruno-js to use @usebruno/vm2 --------------------------
patch_bruno_js_vm2() {
  local jsdir="packages/bruno-js"
  local pj="$jsdir/package.json"
  local sr="$jsdir/src/runtime/script-runtime.js"
  [ -d "$jsdir" ] || { warn "Expected $jsdir not found; skipping vm2 patch."; return 0; }
  if [ -f "$pj" ]; then
    if [ "${DRY_RUN}" = "1" ]; then printf '[DRY] patch deps in %s\n' "$pj"; else
      node -e '
        const fs=require("fs"); const p=JSON.parse(fs.readFileSync("'"$pj"'", "utf8"));
        p.dependencies = p.dependencies||{}; let changed=false;
        if(!p.dependencies["@usebruno/vm2"]){ p.dependencies["@usebruno/vm2"]="^3.9.19"; changed=true; }
        if(p.dependencies.vm2){ delete p.dependencies.vm2; changed=true; }
        if(changed){ fs.writeFileSync("'"$pj"'", JSON.stringify(p,null,2)+"\n"); console.log("changed"); }
      ' >/dev/null || true
      log "Updated $pj deps: ensured @usebruno/vm2 present, removed legacy vm2."
    fi
  fi
  if [ -f "$sr" ] && grep -Eq "require\(['\"]vm2['\"]\)" "$sr"; then
    if [ "${DRY_RUN}" = "1" ]; then printf "[DRY] sed swap require('vm2')→@usebruno/vm2 in %s\n" "$sr"; else
      sed -i.bak -e "s|require('vm2')|require('@usebruno/vm2')|g" -e "s|require(\"vm2\")|require('@usebruno/vm2')|g" "$sr" && rm -f "$sr.bak"
      log "Patched $sr to use @usebruno/vm2"
    fi
  fi
}

# ---------- Patch graphql-docs peer ranges to include React 19 ------------
patch_bruno_graphql_docs_peers() {
  local gdir="packages/bruno-graphql-docs"
  local pj="$gdir/package.json"
  [ -f "$pj" ] || { warn "Missing $pj (layout changed?); skipping peer patch."; return 0; }
  if [ "${DRY_RUN}" = "1" ]; then printf '[DRY] widen peerDependencies in %s\n' "$pj"; return 0; fi
  node -e '
    const fs=require("fs"); const f=process.argv[1];
    const p=JSON.parse(fs.readFileSync(f,"utf8"));
    p.peerDependencies = p.peerDependencies || {};
    const want = "^17 || ^18 || ^19";
    if (p.peerDependencies.react !== want) p.peerDependencies.react = want;
    if (p.peerDependencies["react-dom"] !== want) p.peerDependencies["react-dom"] = want;
    p.peerDependenciesMeta = Object.assign({}, p.peerDependenciesMeta, {
      react: { optional: true }, "react-dom": { optional: true }
    });
    fs.writeFileSync(f, JSON.stringify(p,null,2)+"\n");
    console.log("Widened peer ranges in", f);
  ' "$pj" >/dev/null && log "Widened @usebruno/graphql-docs peers to ^17 || ^18 || ^19 (react, react-dom)."
}

# ---------- Bump and publish a workspace package (fixed var names) ----------
bump_and_publish_in_dir() {
  local dir="$1" registry="$2"
  [ -f "$dir/package.json" ] || die "Expected $dir/package.json"
  (
    cd "$dir" >/dev/null
    local name ver newver; name="$(json_get_name)"; ver="$(json_get_version)"
    newver="$(compute_new_version)"
    log "Bumping ${name} → ${newver}"
    run npm version "$newver" --no-git-tag-version >/dev/null
    log "Publishing ${name}@${newver} to ${registry} (tag: ${NPM_TAG})"
    npm_pack_publish_dir "$PWD" "$registry" "$NPM_TAG"
    echo "$newver"
  )
}

registry_proxies_public_npm() {
  local reg="$1"
  if NPM_CONFIG_USERCONFIG="$NPMRC_INSTALL" npm_view path version --registry "$reg" >/dev/null 2>&1; then return 0; else return 1; fi
}

# ---------- Main flow --------------------------------------------------------
main() {
  req git; req node; req npm
  req tar; req curl

  local install_registry publish_registry token_for_install token_for_publish

  case "$REG_MODE" in
    verdaccio)
      install_registry="$(trim_trailing_slash "$VERDACCIO_URL")/"
      publish_registry="$install_registry"
      token_for_install="$NPM_TOKEN"
      token_for_publish="$NPM_TOKEN"
      ;;
    jfrog)
      # Prefer explicit full URLs if provided, else derive from ART_URL + repo names
      if [ -n "${ART_INSTALL_REG}" ] && [ -n "${ART_PUBLISH_REG}" ]; then
        install_registry="$(trim_trailing_slash "$ART_INSTALL_REG")/"
        publish_registry="$(trim_trailing_slash "$ART_PUBLISH_REG")/"
      else
        [ -n "$ART_URL" ] && [ -n "$ART_VIRTUAL_REPO" ] && [ -n "$ART_LOCAL_REPO" ] \
          || die "For jfrog mode, set ART_INSTALL_REG & ART_PUBLISH_REG, OR set ART_URL + ART_VIRTUAL_REPO + ART_LOCAL_REPO."
        local base; base="$(trim_trailing_slash "$ART_URL")"
        install_registry="$base/artifactory/api/npm/$ART_VIRTUAL_REPO/"
        publish_registry="$base/artifactory/api/npm/$ART_LOCAL_REPO/"
      fi
      token_for_install="${ART_TOKEN:-}"
      token_for_publish="${ART_TOKEN:-}"
      log "JFrog mode: install=$install_registry  publish=$publish_registry"
      ;;
    *)
      die "Unknown REG_MODE: $REG_MODE (use 'verdaccio' or 'jfrog')"
      ;;
  esac

  ensure_repo
  maybe_use_nvm

  # Create npmrcs (no single .npmrc that can override scope on publish!)
  write_dual_npmrcs "$install_registry" "$token_for_install" "$publish_registry" "$token_for_publish"
  npm_ping "$install_registry"

  # Mirror shims/forks
  npm_mirror_publish "@usebruno/vm2@^3.9.19"
  npm_mirror_publish "@usebruno/crypto-js@^3.1.9"

  # Patches
  patch_bruno_js_vm2
  patch_bruno_common_exports
  patch_bruno_graphql_docs_peers

  log "Installing dependencies via npm ci"
  if [ "${DRY_RUN}" = "1" ]; then
    printf '[DRY] npm ci\n'
  else
    NPM_CONFIG_USERCONFIG="$NPMRC_INSTALL" NPM_CONFIG_LEGACY_PEER_DEPS=1 npm ci \
      || NPM_CONFIG_USERCONFIG="$NPMRC_INSTALL" NPM_CONFIG_LEGACY_PEER_DEPS=1 npm install
  fi

  # Build internal libs
  log "Building internal libraries in order"
  run npm run --workspace @usebruno/common build
  run npm run --workspace @usebruno/requests build
  run npm run --workspace @usebruno/query build
  run npm run --workspace @usebruno/converters build
  run npm run --workspace @usebruno/graphql-docs build
  run npm run --workspace @usebruno/filestore build

  if [ "${DO_BUILD_APP}" = "true" ]; then
    log "Building @usebruno/app"
    run npm run --workspace @usebruno/app build
  else
    warn "Skipping @usebruno/app build (DO_BUILD_APP=false)"
  fi

  # Publish internal libs (BUMP + PUBLISH + PIN)
  PKG_NAMES=( "@usebruno/common" "@usebruno/requests" "@usebruno/query" "@usebruno/converters" "@usebruno/graphql-docs" "@usebruno/filestore" )
  PKG_DIRS=(  "packages/bruno-common" "packages/bruno-requests" "packages/bruno-query" "packages/bruno-converters" "packages/bruno-graphql-docs" "packages/bruno-filestore" )

  PINS_LINES=""
  local i
  for i in $(seq 0 $((${#PKG_NAMES[@]}-1))); do
    NAME="${PKG_NAMES[$i]}"; DIR="${PKG_DIRS[$i]}"
    if [ ! -f "$DIR/package.json" ]; then warn "Missing $DIR/package.json, skipping $NAME"; continue; fi
    (
      cd "$DIR" >/dev/null
      base_ver="$(node -p 'require("./package.json").version.split("-")[0]')"
      new_ver="${base_ver}-${VERSION_SUFFIX}"
      log "Bumping $NAME → $new_ver"
      npm_unset_ws "${NPMRC_INSTALL}" npm version "$new_ver" --no-git-tag-version >/dev/null
      log "Publishing $NAME@$new_ver to $publish_registry (tag: $NPM_TAG)"
      npm_pack_publish_dir "$PWD" "$publish_registry" "$NPM_TAG"
    )
    v_now="$(node -p "require('./${DIR}/package.json').version")"
    PINS_LINES="${PINS_LINES}${NAME}==${v_now}\n"
    wait_for_package_visibility "$NAME" "$v_now" "$install_registry" 90 || true
  done

  # Bump & publish @usebruno/js and collect version
  local js_dir="packages/bruno-js" js_ver=""
  if [ -d "$js_dir" ]; then
    base_js="$(node -p 'require("./packages/bruno-js/package.json").version.split("-")[0]')"
    new_js="${base_js}-${VERSION_SUFFIX}"
    log "Bumping @usebruno/js → $new_js"
    ( cd "$js_dir" && npm_unset_ws "${NPMRC_INSTALL}" npm version "$new_js" --no-git-tag-version >/dev/null )
    log "Generating @usebruno/js sandbox bundles"
    ( cd "$js_dir" && NPM_CONFIG_USERCONFIG="$NPMRC_INSTALL" npm run sandbox:bundle-libraries || true )
    log "Publishing @usebruno/js@$new_js to $publish_registry (tag: $NPM_TAG)"
    npm_pack_publish_dir "$js_dir" "$publish_registry" "$NPM_TAG"
    js_ver="$(node -p 'require("./packages/bruno-js/package.json").version')"
    PINS_LINES="${PINS_LINES}@usebruno/js==${js_ver}\n"
    wait_for_package_visibility "@usebruno/js" "$js_ver" "$install_registry" 120 || true
  else
    warn "Expected $js_dir not found — repo layout changed?"
  fi

  # Pin ALL internal package versions into CLI package.json
  local cli_dir="packages/bruno-cli"
  [ -d "$cli_dir" ] || die "Expected $cli_dir not found — repo layout changed?"
  log "Pinning internal deps into CLI package.json"
  PINS_JSON="$(node -e '
    const fs=require("fs");
    const pkgs = [
      ["@usebruno/common","packages/bruno-common/package.json"],
      ["@usebruno/requests","packages/bruno-requests/package.json"],
      ["@usebruno/query","packages/bruno-query/package.json"],
      ["@usebruno/converters","packages/bruno-converters/package.json"],
      ["@usebruno/graphql-docs","packages/bruno-graphql-docs/package.json"],
      ["@usebruno/filestore","packages/bruno-filestore/package.json"],
      ["@usebruno/js","packages/bruno-js/package.json"]
    ];
    const obj={};
    for(const [name, path] of pkgs){
      try { const ver=JSON.parse(fs.readFileSync(path,"utf8")).version; if(ver) obj[name]=ver; } catch(e){}
    }
    process.stdout.write(JSON.stringify(obj));
  ')"
  if [ "${DRY_RUN}" = "1" ]; then
    printf '[DRY] apply pins to packages/bruno-cli/package.json: %s\n' "$PINS_JSON"
  else
    PINS_JSON="$PINS_JSON" node -e '
      const fs=require("fs"); const pins=JSON.parse(process.env.PINS_JSON||"{}");
      const f="packages/bruno-cli/package.json"; const p=JSON.parse(fs.readFileSync(f,"utf8"));
      p.dependencies=p.dependencies||{};
      for(const [name,ver] of Object.entries(pins)){ p.dependencies[name]=ver; }
      fs.writeFileSync(f, JSON.stringify(p,null,2)+"\n");
      console.log("CLI deps pinned");
    ' >/dev/null
    (
      cd "$cli_dir" >/dev/null
      tgz="$(npm_unset_ws "${NPMRC_INSTALL}" npm pack --silent)" || exit 1
      want_js="$new_js"
      got_js="$(tar -xzOf "$tgz" package/package.json | node -e 'let s="";process.stdin.on("data",d=>s+=d);process.stdin.on("end",()=>{const p=JSON.parse(s);console.log(p.dependencies["@usebruno/js"]||"")});')"
      rm -f "$tgz"
      [ "$got_js" = "$want_js" ] || die "Tarball deps not pinned: @usebruno/js is $got_js, expected $want_js"
      log "Verified tarball pins: @usebruno/js@$got_js"
    )
  fi

  # Publish the CLI (bumped)
  base_cli="$(node -p 'require("./packages/bruno-cli/package.json").version.split("-")[0]')"
  new_cli="${base_cli}-${VERSION_SUFFIX}"
  log "Bumping @usebruno/cli → $new_cli"
  ( cd "$cli_dir" && npm_unset_ws "${NPMRC_INSTALL}" npm version "$new_cli" --no-git-tag-version >/dev/null )
  log "Publishing @usebruno/cli@$new_cli to $publish_registry (tag: $NPM_TAG)"
  npm_pack_publish_dir "$cli_dir" "$publish_registry" "$NPM_TAG"
  wait_for_package_visibility "@usebruno/cli" "$new_cli" "$install_registry" 120 || true

  # Global install smoke test (only if install registry proxies npmjs)
  if [ "${DO_GLOBAL_INSTALL_TEST}" = "true" ]; then
    log "Global install test from your registry"
    if registry_proxies_public_npm "$install_registry"; then
      if [ "${DRY_RUN}" = "1" ]; then
        printf '[DRY] npm install -g @usebruno/cli@%s --registry %s\n' "$NPM_TAG" "$install_registry"
      else
        NPM_CONFIG_USERCONFIG="$NPMRC_INSTALL" npm install -g @usebruno/cli@"$NPM_TAG" --registry "$install_registry" || {
          warn "Global install failed via registry — skipping smoke test"; exit 0; }
      fi
    else
      warn "Install registry does not proxy npmjs — skipping smoke test"
    fi
    if command -v bru >/dev/null 2>&1 && bru --help >/dev/null 2>&1; then
      log "CLI smoke test: bru --help OK"
      log "CLI version check: $(bru --version || echo 'unable to read version')"
    else
      warn "CLI smoke test failed — try: 'npm ls -g @usebruno/*' and 'which bru'"
    fi
  else
    warn "Skipped global install test (DO_GLOBAL_INSTALL_TEST=false)"
  fi

  # Temp project install smoke test — skip for jfrog (it’s tuned for Verdaccio)
  if [ "${DO_TEMP_INSTALL_TEST}" = "true" ]; then
    if [ "$REG_MODE" != "verdaccio" ]; then
      warn "Temp install test is tailored for Verdaccio; skipping (REG_MODE=$REG_MODE)"
    else
      log "Temp install test of @usebruno/cli@$new_cli from $install_registry"
      tmpdir="$(mktemp -d -t bruno-cli-install-XXXXXX)"; trap 'rm -rf "$tmpdir"' EXIT
      install_trimmed="$(trim_trailing_slash "$install_registry")/"
      mkdir -p "$tmpdir"
      cat >"$tmpdir/.npmrc" <<EOF
registry=$install_trimmed
always-auth=true
@usebruno:registry=$install_trimmed
EOF
      if [ -n "${token_for_install:-}" ]; then
        hp="${install_registry#http://}"; hp="${hp#https://}"; hp="$(trim_trailing_slash "$hp")/"
        echo "//${hp}:_authToken=${token_for_install}" >> "$tmpdir/.npmrc"
      fi
      ( cd "$tmpdir" && NPM_CONFIG_USERCONFIG="$tmpdir/.npmrc" npm init -y >/dev/null )
      ( cd "$tmpdir" && NPM_CONFIG_USERCONFIG="$tmpdir/.npmrc" npm install @usebruno/cli@"$new_cli" --registry "$install_registry" || true )
    fi
  else
    warn "Skipped temp install test (DO_TEMP_INSTALL_TEST=false)"
  fi

  # ---- NEW: create sources archive and upload --------------------------------
  local ARCHIVE_NAME="bruno-sources-${VERSION_SUFFIX}.tar.gz"
  local ARCHIVE_PATH="${PWD}/${ARCHIVE_NAME}"
  create_sources_archive "$WORKDIR" "$ARCHIVE_PATH" || warn "Failed to create sources archive"

  # Upload sources archive to ART_ARCHIVE_REPO (defaults to cagbu-dev-opensource-release-node)
  # Destination path includes a friendly folder and filename with VERSION_SUFFIX
  upload_to_artifactory "$ART_ARCHIVE_REPO" "$ARCHIVE_PATH" "bruno/sources/${ARCHIVE_NAME}" || true

  # Upload log file to ART_LOGS_REPO
  upload_to_artifactory "$ART_LOGS_REPO" "$LOG_FILE" "bruno/logs/bruno-build-publish.${VERSION_SUFFIX}.log" || true
  # ----------------------------------------------------------------------------

  log "Done. Installed/published against: $install_registry (publish → $publish_registry)"
  log "Artifacts:"
  log " - Sources archive: $ARCHIVE_PATH"
  log " - Build log:       $LOG_FILE"
  log "Tip: git-ignore .npmrc.install / .npmrc.publish if you commit this repo."
}

main "$@"
