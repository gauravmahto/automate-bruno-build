#!/usr/bin/env bash
set -euo pipefail

# ──────────────────────────────
# Config (env-overridable)
# ──────────────────────────────
REG_MODE="${REG_MODE:-verdaccio}"                       # verdaccio|artifactory
REPO_DIR="${REPO_DIR:-$PWD/bruno-src}"
GIT_URL="${GIT_URL:-https://github.com/usebruno/bruno}"
BRANCH="${BRANCH:-}"                                     # optional branch/tag
DO_SMOKE="${DO_SMOKE:-true}"
NPM_TAG="${NPM_TAG:-dev}"
TSUFFIX="${VERSION_SUFFIX:-local.$(date +%Y%m%d%H%M%S)}"

VERDACCIO_URL="${VERDACCIO_URL:-http://127.0.0.1:8080}"
NPM_TOKEN="${NPM_TOKEN:-}"
ART_URL="${ART_URL:-}"
ART_VIRTUAL_REPO="${ART_VIRTUAL_REPO:-npm-virtual}"
ART_LOCAL_REPO="${ART_LOCAL_REPO:-npm-local}"
ART_TOKEN="${ART_TOKEN:-}"

# Internal package list & order (libs first, then app/cli/electron)
INTERNAL_LIBS=(
  "@usebruno/common"
  "@usebruno/converters"
  "@usebruno/query"
  "@usebruno/graphql-docs"
  "@usebruno/requests"
  "@usebruno/filestore"
)
APP_PKG="@usebruno/app"
CLI_PKG="@usebruno/cli"
ELECTRON_PKG="@usebruno/electron"

# ──────────────────────────────
# Helpers
# ──────────────────────────────
log(){ printf "\033[1;34m[INFO]\033[0m %s\n" "$*"; }
warn(){ printf "\033[1;33m[WARN]\033[0m %s\n" "$*"; }
fail(){ printf "\033[1;31m[FAIL]\033[0m %s\n" "$*"; exit 1; }
trim_trailing_slash(){ local s="${1%/}"; printf %s "$s"; }

req(){ command -v "$1" >/dev/null || fail "Missing required tool: $1"; }

node_ok(){
  local major
  major="$(node -p 'process.versions.node.split(".")[0]')" || return 1
  [[ "$major" == "18" || "$major" == "20" ]]
}

set_registry_auth(){
  local scope="@usebruno" reg="$1" token="$2"
  log "Writing .npmrc for $reg"
  cat > "$REPO_DIR/.npmrc" <<EOF
registry=$reg
always-auth=true
//${reg#http://}/:_authToken=${token}
//${reg#https://}/:_authToken=${token}
@usebruno:registry=$reg
EOF
}

verdaccio_endpoints(){
  local base; base="$(trim_trailing_slash "$VERDACCIO_URL")"
  INSTALL_REG="$base/"; PUBLISH_REG="$base/"
  TOKEN_INSTALL="$NPM_TOKEN"; TOKEN_PUBLISH="$NPM_TOKEN"
}

artifactory_endpoints(){
  local base; base="$(trim_trailing_slash "$ART_URL")"
  INSTALL_REG="$base/artifactory/api/npm/${ART_VIRTUAL_REPO}/"
  PUBLISH_REG="$base/artifactory/api/npm/${ART_LOCAL_REPO}/"
  TOKEN_INSTALL="$ART_TOKEN"; TOKEN_PUBLISH="$ART_TOKEN"
}

ensure_repo(){
  if [[ ! -d "$REPO_DIR/.git" ]]; then
    log "Cloning Bruno → $REPO_DIR"
    git clone "$GIT_URL" "$REPO_DIR"
  else
    log "Updating existing repo"
    git -C "$REPO_DIR" fetch --all --prune
  fi
  if [[ -n "$BRANCH" ]]; then
    git -C "$REPO_DIR" checkout -B local "$BRANCH" --track "origin/$BRANCH" || git -C "$REPO_DIR" checkout "$BRANCH"
  fi
}

ping_registry(){
  local url="$1"
  log "Registry ping: ${url%-/}-/ping"
  if ! curl -fsS "${url%-/}-/ping" >/dev/null; then
    warn "Failed to ping registry: ${url}"
  fi
}

npm_ci_root(){
  pushd "$REPO_DIR" >/dev/null
  log "Installing dependencies via npm ci"
  npm ci
  popd >/dev/null
}

# Return package dir from its name, e.g. @usebruno/common → packages/bruno-common
pkg_dir_from_name(){
  local name="$1"
  jq -r --arg n "$name" '
    .workspaces[] as $w
    | $w
  ' "$REPO_DIR/package.json" \
  | while read -r w; do
      if [[ -f "$REPO_DIR/$w/package.json" ]]; then
        if jq -e --arg n "$name" '.name == $n' "$REPO_DIR/$w/package.json" >/dev/null; then
          echo "$REPO_DIR/$w"; return 0
        fi
      fi
    done
}

bump_pkg_version(){
  local dir="$1" newver="$2"
  jq --arg v "$newver" '.version=$v' "$dir/package.json" > "$dir/package.json.tmp"
  mv "$dir/package.json.tmp" "$dir/package.json"
}

publish_pkg(){
  local dir="$1" tag="$2" reg="$3"
  pushd "$dir" >/dev/null
  log "Publishing $(jq -r .name package.json)@$(jq -r .version package.json) → $reg (tag: $tag)"
  npm publish --registry "$reg" --tag "$tag" --access public
  popd >/dev/null
}

build_pkg(){
  local dir="$1"
  pushd "$dir" >/dev/null
  if jq -e '.scripts.build? // empty' package.json >/dev/null; then
    npm run build
  fi
  popd >/dev/null
}

rewrite_cli_deps(){
  local cli_dir="$1"; shift
  # args are name=version pairs
  local tmp="$cli_dir/package.json.tmp"; cp "$cli_dir/package.json" "$tmp"
  for nv in "$@"; do
    local name="${nv%%=*}" ver="${nv#*=}"
    # in deps and devDeps if present
    if jq -e --arg n "$name" '.dependencies[$n]' "$tmp" >/dev/null; then
      tmp2="$tmp.1"; jq --arg n "$name" --arg v "$ver" '.dependencies[$n]=$v' "$tmp" > "$tmp2"; mv "$tmp2" "$tmp"
    fi
    if jq -e --arg n "$name" '.devDependencies[$n]' "$tmp" >/dev/null; then
      tmp2="$tmp.1"; jq --arg n "$name" --arg v "$ver" '.devDependencies[$n]=$v' "$tmp" > "$tmp2"; mv "$tmp2" "$tmp"
    fi
  done
  mv "$tmp" "$cli_dir/package.json"
}

# ──────────────────────────────
# Main
# ──────────────────────────────
main(){
  req git; req node; req npm; req jq; req curl

  if ! node_ok; then
    warn "Detected Node $(node -v); Bruno deps expect Node 18/20. Consider: fnm install 20 && fnm use 20"
  fi

  # Resolve endpoints
  case "$REG_MODE" in
    verdaccio) verdaccio_endpoints ;;
    artifactory) artifactory_endpoints ;;
    *) fail "Unknown REG_MODE: $REG_MODE" ;;
  esac

  ensure_repo

  # Auth for install & build
  set_registry_auth "$INSTALL_REG" "$TOKEN_INSTALL"

  ping_registry "$INSTALL_REG"

  npm_ci_root

  # Build & publish internal libs with new local versions
  declare -a rewrites=()
  for name in "${INTERNAL_LIBS[@]}"; do
    local dir ver newver
    dir="$(pkg_dir_from_name "$name")" || fail "Could not locate $name in workspaces"
    ver="$(jq -r .version "$dir/package.json")"
    newver="${ver}-${TSUFFIX}"
    log "Bumping $name → $newver"
    bump_pkg_version "$dir" "$newver"
    build_pkg "$dir"
    # Auth for publish (in case different registry)
    set_registry_auth "$PUBLISH_REG" "$TOKEN_PUBLISH"
    publish_pkg "$dir" "$NPM_TAG" "$PUBLISH_REG"
    rewrites+=("$name=$newver")
  done

  # Build app AFTER libs are available
  APP_DIR="$(pkg_dir_from_name "$APP_PKG")"
  if [[ -n "$APP_DIR" ]]; then
    log "Building $APP_PKG"
    build_pkg "$APP_DIR"
  fi

  # Rewrite CLI deps to our freshly published lib versions, bump CLI, build & publish
  CLI_DIR="$(pkg_dir_from_name "$CLI_PKG")"
  [[ -n "$CLI_DIR" ]] || fail "Could not locate $CLI_PKG"

  rewrite_cli_deps "$CLI_DIR" "${rewrites[@]}"

  CLI_VER="$(jq -r .version "$CLI_DIR/package.json")"
  CLI_NEW="${CLI_VER}-${TSUFFIX}"
  log "Bumping $CLI_PKG → $CLI_NEW"
  bump_pkg_version "$CLI_DIR" "$CLI_NEW"

  # Ensure the CLI's lock reflects rewritten deps to pull from our registry
  # Scope to CLI to avoid workspace-wide peer conflicts (React 19 vs peer React ^17)
  pushd "$CLI_DIR" >/dev/null
  npm install --package-lock-only --legacy-peer-deps
  popd >/dev/null

  build_pkg "$CLI_DIR"

  set_registry_auth "$PUBLISH_REG" "$TOKEN_PUBLISH"
  publish_pkg "$CLI_DIR" "$NPM_TAG" "$PUBLISH_REG"

  # Global smoke test from our registry
  log "Global install test from your registry"
  npm i -g --registry "$INSTALL_REG" "$CLI_PKG@${CLI_NEW}" >/dev/null 2>&1 || true

  if command -v bru >/dev/null; then
    if bru --help >/dev/null 2>&1; then
      log "CLI smoke test OK: bru --help"
      bru --version || true
    else
      warn "CLI smoke test: 'bru --help' had a non-zero exit"
    fi
  else
    warn "CLI version check: bru not on PATH yet"
  fi

  log "Done. Installed/published against: $INSTALL_REG (publish → $PUBLISH_REG)"
  log "Tip: remove the generated .npmrc before committing this repo upstream."
}

main "$@"
