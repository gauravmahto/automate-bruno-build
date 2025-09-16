#!/usr/bin/env bash
# delete-npm-in-artifactory.sh
# Delete an npm package (entire package or one version) from a JFrog Artifactory *local* npm repo.
# Works with Artifactory's "plus" path (@scope+name/x.y.z/...) and the scoped tarball path (@scope%2Fname/-/name-x.y.z.tgz)

set -euo pipefail

# ======== CONFIG ========
ART_URL="${ART_URL:-https://artifacthub-phx.oci.oraclecorp.com/artifactory}"
ART_REPO="${ART_REPO:-cagbu-dev-opensource-release-node}"       # local repo name
PKG="${PKG:-@usebruno/vm2}"                                      # npm package
VER="${VER:-3.9.19}"                                             # version; empty to delete entire package

# Auth: set ONE of these (or export them in env). Script will auto-try both if both provided.
ART_ACCESS_TOKEN="${ART_ACCESS_TOKEN:-${ARTIFACTHUB_KEY:-}}"
ART_API_KEY="${ART_API_KEY:-}"

# Safety
CONFIRM="${CONFIRM:-yes}"  # set to "no" to require y/N confirmation

# ======== HELPERS ========
die(){ echo "[ERR] $*" >&2; exit 1; }
info(){ echo "[INFO] $*"; }
warn(){ echo "[WARN] $*"; }

curl_auth() {
  # usage: curl_auth <METHOD> <URL> [curl extra args...]
  local method="$1"; shift
  local url="$1"; shift
  local rc=1

  # Try Bearer first if provided
  if [ -n "$ART_ACCESS_TOKEN" ]; then
    if curl -sfS -X "$method" -H "Authorization: Bearer ${ART_ACCESS_TOKEN}" "$url" "$@" ; then
      return 0
    fi
    rc=$?
  fi
  # Try API key if provided or Bearer failed
  if [ -n "$ART_API_KEY" ]; then
    if curl -sfS -X "$method" -H "X-JFrog-Art-Api: ${ART_API_KEY}" "$url" "$@" ; then
      return 0
    fi
    rc=$?
  fi
  return "$rc"
}

need_auth_or_die() {
  [ -n "$ART_ACCESS_TOKEN" ] || [ -n "$ART_API_KEY" ] || die "Provide ART_ACCESS_TOKEN (Bearer) or ART_API_KEY."
  # Sanity ping to pick the right header
  if curl_auth GET "${ART_URL}/api/system/ping" -i >/dev/null 2>&1; then
    info "Auth check OK"
  else
    die "Auth failed against ${ART_URL}/api/system/ping. Check token/key and network."
  fi
}

confirm_or_abort() {
  if [ "$CONFIRM" = "yes" ]; then return 0; fi
  read -r -p "About to DELETE from ${ART_REPO}. Continue? [y/N] " ans
  case "$ans" in [yY][eE][sS]|[yY]) ;; *) die "Aborted."; esac
}

# URL builders (two layouts)
enc_pkg="$(python3 - <<'PY' "$PKG"
import sys, urllib.parse
print(urllib.parse.quote(sys.argv[1], safe=''))
PY
)"
pkg_name="${PKG#*/}"                 # e.g. vm2
plus_pkg="@${PKG#@}"                 # e.g. @usebruno/vm2 -> @usebruno/vm2 (we need + later)
plus_pkg="${plus_pkg/\//+}"          # -> @usebruno+vm2

folder_url_ver="${ART_URL}/${ART_REPO}/${plus_pkg}/${VER}/"                                 # e.g. .../@usebruno+vm2/3.9.19/
tgz_url_ver="${ART_URL}/${ART_REPO}/${enc_pkg}/-/${pkg_name}-${VER}.tgz"                    # e.g. .../@usebruno%2Fvm2/-/vm2-3.9.19.tgz
pkg_root_plus="${ART_URL}/${ART_REPO}/${plus_pkg}"                                          # package root (plus layout)
pkg_root_enc="${ART_URL}/${ART_REPO}/${enc_pkg}"                                            # package root (encoded layout)

# ======== MAIN ========
need_auth_or_die
confirm_or_abort

if [ -z "$VER" ]; then
  info "Deleting ENTIRE PACKAGE: ${PKG}"
  # Try both roots; one will exist depending on how it was uploaded
  for url in "$pkg_root_plus" "$pkg_root_enc"; do
    info "DELETE $url (recursive folder delete)"
    if curl_auth DELETE "$url" -i ; then
      info "Deleted: $url"
    else
      warn "DELETE failed or not found: $url"
    fi
  done
else
  info "Deleting VERSION ${PKG}@${VER}"
  # 1) Delete version folder under plus layout (removes xml/zip and tgz if stored there)
  info "DELETE (folder) $folder_url_ver"
  if curl_auth DELETE "$folder_url_ver" -i ; then
    info "Deleted folder: $folder_url_ver"
  else
    warn "Folder delete failed or not found: $folder_url_ver"
  fi

  # 2) Delete scoped tarball path if it exists (some uploads store it here)
  info "DELETE (tarball) $tgz_url_ver"
  if curl_auth DELETE "$tgz_url_ver" -i ; then
    info "Deleted tarball: $tgz_url_ver"
  else
    warn "Tarball delete failed or not found: $tgz_url_ver"
  fi
fi

# Reindex npm metadata for the repo so clients see the update immediately
reindex_url="${ART_URL}/api/npm/${ART_REPO}/reindex"
info "POST reindex: $reindex_url"
if curl_auth POST "$reindex_url" -i ; then
  info "Reindex triggered."
else
  warn "Reindex call failed. You may need permissions: 'Manage' on ${ART_REPO}."
fi

info "Done."
