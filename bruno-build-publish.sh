#!/usr/bin/env bash
# ----------------------------------------------------------------------------
# bruno-build-publish.sh — Build Bruno from source, publish internal libs first,
# then publish @usebruno/js and @usebruno/cli to your Verdaccio/JFrog registry,
# and (optionally) install it for a smoke test.
# ----------------------------------------------------------------------------
set -euo pipefail

# ---------- Config (env overrides) ------------------------------------------
: "${REG_MODE:=verdaccio}"                    # verdaccio | jfrog
: "${WORKDIR:=${PWD}/bruno-src}"
: "${BRUNO_GIT:=https://github.com/usebruno/bruno}"
: "${BRUNO_REF:=}"
: "${DO_GLOBAL_INSTALL_TEST:=true}"
: "${DO_TEMP_INSTALL_TEST:=true}"
: "${DO_BUILD_APP:=false}"
: "${VERSION_SUFFIX:=local.$(date +%Y%m%d%H%M%S)}"
: "${NPM_TAG:=dev}"
: "${DRY_RUN:=0}"                             # 1 = print actions; skip mutating ops

# Verdaccio inputs
: "${VERDACCIO_URL:=http://127.0.0.1:8080}"
: "${NPM_TOKEN:=}"

# JFrog inputs
: "${ART_URL:=}"
: "${ART_VIRTUAL_REPO:=npm-virtual}"
: "${ART_LOCAL_REPO:=npm-local}"
: "${ART_TOKEN:=}"

# Internals
PUBLIC_REG="https://registry.npmjs.org"
WORKSPACES_OFF=(--workspaces=false)

# ---------- Helpers ----------------------------------------------------------
log()  { printf "\033[1;34m[INFO]\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m[WARN]\033[0m %s\n" "$*"; }
die()  { printf "\033[1;31m[ERR ]\033[0m %s\n" "$*" >&2; exit 1; }
req()  { command -v "$1" >/dev/null || die "Missing required command: $1"; }

run() {
  if [ "${DRY_RUN}" = "1" ]; then printf '[DRY] %s\n' "$*"; return 0; fi
  eval "$@"
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
  local url="$1"
  log "Registry ping: $url"
  if ! curl -fsS "$url/-/ping" >/dev/null 2>&1; then
    warn "Failed to ping registry: $url"
  fi
}

npm_cfg_get() { npm "${WORKSPACES_OFF[@]}" config get "$@" 2>&1; }
npm_view()    { npm "${WORKSPACES_OFF[@]}" view "$@" 2>/dev/null; }
npm_publish() { npm_unset_ws npm publish "$@"; }

# --- Publish helpers (pack first, then publish tgz with workspace flags unset) ---
npm_unset_ws() {
  # run a command with workspace flags/env disabled
  env -u npm_config_workspace -u npm_config_workspaces -u npm_config_workspace_enabled \
      NPM_CONFIG_LEGACY_PEER_DEPS=1 npm_config_ignore_scripts=1 "$@"
}

npm_pack_dir() {
  # usage: npm_pack_dir <dir> -> echoes tgz path
  local dir="$1" tgz
  ( cd "$dir" >/dev/null
    # ensure clean build scripts still run, but avoid workspace context
    tgz="$(npm_unset_ws npm pack --silent)"
    printf "%s/%s" "$PWD" "$tgz"
  )
}

npm_publish_tgz() {
  # usage: npm_publish_tgz <tgz> <registry> <tag> [--access public]
  local tgz="$1" registry="$2" tag="$3" access="${4:---access public}"
  npm_unset_ws npm publish "$tgz" --registry "$registry" --tag "$tag" $access
}

npm_pack_publish_dir() {
  # usage: npm_pack_publish_dir <dir> <registry> <tag>
  local dir="$1" registry="$2" tag="$3"
  if [ "${DRY_RUN}" = "1" ]; then
    printf '[DRY] npm pack in %s; publish to %s (tag: %s)\n' "$dir" "$registry" "$tag"
    return 0
  fi
  local tgz; tgz="$(npm_pack_dir "$dir")"
  npm_publish_tgz "$tgz" "$registry" "$tag"
  rm -f "$tgz"
}

write_project_npmrc() {
  local install_registry="$1" token_install="$2" publish_registry="${3:-}" token_publish="${4:-}"
  log "Writing repo .npmrc for registry: $install_registry"
  local install_trimmed; install_trimmed="$(trim_trailing_slash "$install_registry")/"
  # If a project .npmrc already exists, keep it to respect existing auth (e.g., user-provided Verdaccio token)
  if [ -f .npmrc ]; then
    log "Detected existing .npmrc in repo — preserving it."
    return 0
  fi
  if [ "${DRY_RUN}" = "1" ]; then
    printf '[DRY] write .npmrc for %s\n' "$install_trimmed"
  else
    cat > .npmrc <<EOF
registry=$install_trimmed
always-auth=true
@usebruno:registry=$install_trimmed
EOF
    if [ -n "$token_install" ]; then
      local hp="${install_registry#http://}"; hp="${hp#https://}"; hp="$(trim_trailing_slash "$hp")/"
      echo "//${hp}:_authToken=${token_install}" >> .npmrc
    fi
    if [ -n "${publish_registry:-}" ] && [ "$publish_registry" != "$install_registry" ] && [ -n "${token_publish:-}" ]; then
      local pub="${publish_registry#http://}"; pub="${pub#https://}"; pub="$(trim_trailing_slash "$pub")/"
      echo "//${pub}:_authToken=${token_publish}" >> .npmrc
    fi
  fi
}

ensure_repo() {
  # Prefer using an existing local source checkout if present
  if [ -f "$WORKDIR/package.json" ] && [ -d "$WORKDIR" ]; then
    log "Using existing Bruno source at $WORKDIR"
    cd "$WORKDIR"
    # Only attempt ref checkout if it's a git repo
    if [ -n "$BRUNO_REF" ] && [ -d .git ]; then
      log "Checking out ref: $BRUNO_REF"
      run git checkout --quiet "$BRUNO_REF"
    fi
    return 0
  fi
  if [ ! -d "$WORKDIR/.git" ]; then
    log "Cloning Bruno → $WORKDIR"
    run git clone --depth=1 "$BRUNO_GIT" "$WORKDIR"
  else
    log "Updating existing repo"
    run git -C "$WORKDIR" fetch --all --prune
  fi
  cd "$WORKDIR"
  if [ -n "$BRUNO_REF" ]; then
    log "Checking out ref: $BRUNO_REF"
    run git checkout --quiet "$BRUNO_REF"
  fi
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
  while [ "$(date +%s)" -lt "$end" ]; do
    if NPM_CONFIG_USERCONFIG="$PWD/.npmrc" npm_view "${name}@${ver}" version --registry "$reg" >/dev/null; then
      log "Found via npm view: $name@$ver"; return 0
    fi
    sleep 2
  done
  warn "Timeout waiting for visibility: $name@$ver on $reg"
  warn "Debug: npm config get registry → $(NPM_CONFIG_USERCONFIG="$PWD/.npmrc" npm_cfg_get registry 2>/dev/null || echo n/a)"
  warn "Debug: npm view ${name}@${ver} --registry $reg"
  NPM_CONFIG_USERCONFIG="$PWD/.npmrc" npm_view "${name}@${ver}" version --registry "$reg" || true
  return 1
}

version_exists_in_registry() {
  if [ "${DRY_RUN}" = "1" ]; then return 1; fi
  NPM_CONFIG_USERCONFIG="$PWD/.npmrc" node -e '
    const [name,ver,reg] = process.argv.slice(1);
    const {execSync} = require("child_process");
    try {
      const out = execSync(`npm '"${WORKSPACES_OFF[*]}"' view ${name}@${ver} version --registry ${reg}`, {
        stdio:["ignore","pipe","pipe"],
        env:{...process.env, NPM_CONFIG_USERCONFIG: process.env.NPM_CONFIG_USERCONFIG || ""}
      }).toString().trim();
      process.exit(out ? 0 : 1);
    } catch(e){ process.exit(1); }
  ' "$1" "$2" "$(trim_trailing_slash "$3")"
}

npm_mirror_publish() {
  local spec="$1" resolved_name resolved_ver
  resolved_name="$(npm_view "$spec" name --registry "$PUBLIC_REG" || true)"
  resolved_ver="$(npm_view "$spec" version --registry "$PUBLIC_REG" || true)"
  if [ -z "$resolved_name" ] || [ -z "$resolved_ver" ]; then
    warn "Unable to resolve name/version for '$spec' from public registry; skipping mirror."
    return 0
  fi
  if version_exists_in_registry "$resolved_name" "$resolved_ver" "$publish_registry"; then
    log "Mirror skip — already present: ${resolved_name}@${resolved_ver} in $publish_registry"
    return 0
  fi
  log "Mirroring ${resolved_name}@${resolved_ver} → $publish_registry"
  if [ "${DRY_RUN}" = "1" ]; then
    printf '[DRY] npm pack %s@%s; npm publish tgz\n' "$resolved_name" "$resolved_ver"
  else
    local tgz; tgz="$(npm pack "${resolved_name}@${resolved_ver}" --registry "$PUBLIC_REG" 2>/dev/null | tail -n1)" || true
    [ -n "${tgz:-}" ] && [ -f "$tgz" ] || die "npm pack failed for ${resolved_name}@${resolved_ver}"
    npm_publish "$tgz" --registry "$publish_registry" --access public || warn "Publish of ${resolved_name}@${resolved_ver} returned non-zero; continuing."
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
  if [ ! -d "$jsdir" ]; then warn "Expected $jsdir not found; skipping vm2 patch."; return 0; fi
  if [ -f "$pj" ]; then
    if [ "${DRY_RUN}" = "1" ]; then printf '[DRY] patch deps in %s\n' "$pj"; else
      node -e '
        const fs=require("fs"); const p=JSON.parse(fs.readFileSync("'"$pj"'", "utf8"));
        p.dependencies = p.dependencies||{}; let changed=false;
        if(!p.dependencies["@usebruno/vm2"]){ p.dependencies["@usebruno/vm2"]="^3.9.19"; changed=true; }
        if(p.dependencies.vm2){ delete p.dependencies.vm2; changed=true; }
        if(changed){ fs.writeFileSync("'"$pj"'", JSON.stringify(p,null,2)+"\n"); console.log("changed"); }
      ' >/dev/null && log "Updated $pj deps: ensured @usebruno/vm2 present, removed legacy vm2." || true
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
    const widen = (name) => {
      const cur = p.peerDependencies[name];
      const want = "^17 || ^18 || ^19";
      if (!cur || cur !== want) p.peerDependencies[name] = want;
    };
    widen("react"); widen("react-dom");
    p.peerDependenciesMeta = Object.assign({}, p.peerDependenciesMeta, {
      react: { optional: true }, "react-dom": { optional: true }
    });
    fs.writeFileSync(f, JSON.stringify(p,null,2)+"\n");
    console.log("Widened peer ranges in", f);
  ' "$pj" >/dev/null && log "Widened @usebruno/graphql-docs peers to ^17 || ^18 || ^19 (react, react-dom)."
}

# ---------- Bump and publish a workspace package ----------------------------
bump_and_publish_in_dir() {
  local dir="$1" registry="$2"
  [ -f "$dir/package.json" ] || die "Expected $dir/package.json"
  (
    cd "$dir" >/dev/null
    local name ver newver; name="$(json_get_name)"; ver="$(json_get_version)"
    newver="$(compute_new_version)"
    log "Bumping ${name} → ${newver}"
    run npm version "$newver" --no-git-tag-version >/dev/null
    log "Publishing $NAME@$new_ver to $publish_registry (tag: $NPM_TAG)"
    npm_pack_publish_dir "$DIR" "$publish_registry" "$NPM_TAG"
    echo "$newver"
  )
}

registry_proxies_public_npm() {
  local reg="$1"
  if NPM_CONFIG_USERCONFIG="$PWD/.npmrc" npm_view path version --registry "$reg" >/dev/null 2>&1; then return 0; else return 1; fi
}

# ---------- Main flow --------------------------------------------------------
main() {
  req git; req node; req npm

  local install_registry publish_registry token_for_install token_for_publish
  case "$REG_MODE" in
    verdaccio)
      install_registry="$(trim_trailing_slash "$VERDACCIO_URL")/"
      publish_registry="$install_registry"
      token_for_install="$NPM_TOKEN"
      token_for_publish="$NPM_TOKEN"
      ;;
    jfrog)
      [ -n "$ART_URL" ] || die "ART_URL is required in jfrog mode"
      local art_base; art_base="$(trim_trailing_slash "$ART_URL")"
      local virtual_repo="${ART_VIRTUAL_REPO:-npm-virtual}"
      local local_repo="${ART_LOCAL_REPO:-npm-local}"
      install_registry="$art_base/api/npm/$virtual_repo/"
      publish_registry="$art_base/api/npm/$local_repo/"
      token_for_install="${ART_TOKEN:-}"; token_for_publish="${ART_TOKEN:-}"
      [ -n "$ART_TOKEN" ] || warn "ART_TOKEN not set — relying on prior npm login for jfrog"
      ;;
    *) die "Unknown REG_MODE: $REG_MODE (use 'verdaccio' or 'jfrog')" ;;
  esac

  ensure_repo
  maybe_use_nvm

  write_project_npmrc "$install_registry" "$token_for_install" "$publish_registry" "$token_for_publish"
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
    NPM_CONFIG_USERCONFIG="$PWD/.npmrc" NPM_CONFIG_LEGACY_PEER_DEPS=1 npm ci \
      || NPM_CONFIG_USERCONFIG="$PWD/.npmrc" NPM_CONFIG_LEGACY_PEER_DEPS=1 npm install
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
      npm_unset_ws npm version "$new_ver" --no-git-tag-version >/dev/null
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
    ( cd "$js_dir" && npm_unset_ws npm version "$new_js" --no-git-tag-version >/dev/null )
    # Ensure bundled quickjs browser libraries are generated for runtime
    log "Generating @usebruno/js sandbox bundles"
    ( cd "$js_dir" && NPM_CONFIG_USERCONFIG="$PWD/../../.npmrc" npm run sandbox:bundle-libraries || true )
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
    # Force-set pins via JSON rewrite for scoped deps and verify
    PINS_JSON="$PINS_JSON" node -e '
      const fs=require("fs"); const pins=JSON.parse(process.env.PINS_JSON||"{}");
      const f="packages/bruno-cli/package.json"; const p=JSON.parse(fs.readFileSync(f,"utf8"));
      p.dependencies=p.dependencies||{};
      for(const [name,ver] of Object.entries(pins)){ p.dependencies[name]=ver; }
      fs.writeFileSync(f, JSON.stringify(p,null,2)+"\n");
      const after=JSON.parse(fs.readFileSync(f,"utf8")).dependencies;
      const mismatches=Object.entries(pins).filter(([k,v])=>after[k]!==v);
      if(mismatches.length){
        console.error("Pin verification failed:", mismatches);
        process.exit(2);
      } else {
        console.log("CLI deps pinned OK:", JSON.stringify(Object.fromEntries(Object.entries(after).filter(([k])=>k.startsWith("@usebruno/"))),null,2));
      }
    ' >/dev/null
    # Validate pins inside the packed tarball prior to publish
    (
      cd "$cli_dir" >/dev/null
      tgz="$(npm_unset_ws npm pack --silent)" || exit 1
      want_js="$new_js"
      got_js="$(tar -xzOf "$tgz" package/package.json | node -e 'const fs=require("fs");let s="";process.stdin.on("data",d=>s+=d);process.stdin.on("end",()=>{const p=JSON.parse(s);console.log(p.dependencies["@usebruno/js"]||"")});')"
      rm -f "$tgz"
      if [ "$got_js" != "$want_js" ]; then
        die "Tarball deps not pinned: @usebruno/js is $got_js, expected $want_js"
      else
        log "Verified tarball pins: @usebruno/js@$got_js"
      fi
    )
  fi

  # Publish the CLI (bumped)
  base_cli="$(node -p 'require("./packages/bruno-cli/package.json").version.split("-")[0]')"
  new_cli="${base_cli}-${VERSION_SUFFIX}"
  log "Bumping @usebruno/cli → $new_cli"
  ( cd "$cli_dir" && npm_unset_ws npm version "$new_cli" --no-git-tag-version >/dev/null )
  log "Publishing @usebruno/cli@$new_cli to $publish_registry (tag: $NPM_TAG)"
  npm_pack_publish_dir "$cli_dir" "$publish_registry" "$NPM_TAG"
  wait_for_package_visibility "@usebruno/cli" "$new_cli" "$install_registry" 120 || true

  # Global install smoke test
  if [ "${DO_GLOBAL_INSTALL_TEST}" = "true" ]; then
    log "Global install test from your registry"
    if registry_proxies_public_npm "$install_registry"; then
      if [ "${DRY_RUN}" = "1" ]; then
        printf '[DRY] npm install -g @usebruno/cli@%s --registry %s\n' "$NPM_TAG" "$install_registry"
      else
        NPM_CONFIG_USERCONFIG="$PWD/.npmrc" npm install -g @usebruno/cli@"$NPM_TAG" --registry "$install_registry" || {
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

  # Temp project install smoke test (installs the exact published CLI version from Verdaccio)
  if [ "${DO_TEMP_INSTALL_TEST}" = "true" ]; then
    if [ "$REG_MODE" != "verdaccio" ]; then
      warn "Temp install test is tailored for Verdaccio; skipping (REG_MODE=$REG_MODE)"
    else
      log "Temp install test of @usebruno/cli@$new_cli from $install_registry"
      tmpdir="$(mktemp -d -t bruno-cli-install-XXXXXX)"
      trap 'rm -rf "$tmpdir"' EXIT
      install_trimmed="$(trim_trailing_slash "$install_registry")/"
      if [ "${DRY_RUN}" = "1" ]; then
        printf '[DRY] create temp dir and .npmrc in %s (registry=%s)\n' "$tmpdir" "$install_trimmed"
      else
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
      fi
      if [ "${DRY_RUN}" = "1" ]; then
        printf '[DRY] npm install @usebruno/cli@%s --registry %s (in %s)\n' "$new_cli" "$install_registry" "$tmpdir"
      else
        (
          cd "$tmpdir"
          NPM_CONFIG_USERCONFIG="$tmpdir/.npmrc" npm install @usebruno/cli@"$new_cli" --registry "$install_registry"
          if [ -x "$tmpdir/node_modules/.bin/bru" ]; then
            log "Temp project bru --version → $($tmpdir/node_modules/.bin/bru --version || echo 'unknown')"
          else
            warn "bru binary not found in temp project — install may have failed"
          fi
        )
      fi
    fi
  else
    warn "Skipped temp install test (DO_TEMP_INSTALL_TEST=false)"
  fi

  log "Done. Installed/published against: $install_registry (publish → $publish_registry)"
  log "Tip: remove the generated .npmrc before committing this repo upstream."
}

main "$@"
