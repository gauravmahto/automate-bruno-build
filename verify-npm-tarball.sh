#!/usr/bin/env bash
# verify-npm-tarball.sh
# Validate SHA512 for an npm package tarball from public npm and Artifactory.
# Usage:
#   bash verify-npm-tarball.sh @usebruno/vm2@3.9.19 \
#       --install-reg "https://artifacthub-phx.oci.oraclecorp.com/artifactory/api/npm/cagbu-dev-internal-release-node-npm-virtual/" \
#       --npmrc-install "$PWD/.npmrc.install" \
#       --token "$ARTIFACTHUB_KEY"
#
# Exit code:
#   0  all checked registries OK (integrity matches)
#   1  any mismatch or fatal error

set -euo pipefail

# ---------- Defaults (override via flags) ----------
PUBLIC_REG="https://registry.npmjs.org"
INSTALL_REG=""
NPMRC_INSTALL="${NPMRC_INSTALL:-$PWD/.npmrc.install}"
TOKEN="${ARTIFACTHUB_KEY:-${ART_TOKEN:-}}"

# ---------- Parse args ----------
if [ $# -lt 1 ]; then
  echo "Usage: $0 <pkg[@ver|@tag]> [--install-reg URL] [--npmrc-install PATH] [--token TOKEN]" >&2
  exit 1
fi
SPEC="$1"; shift || true
while [[ $# -gt 0 ]]; then
  case "$1" in
    --install-reg) INSTALL_REG="$2"; shift 2;;
    --npmrc-install) NPMRC_INSTALL="$2"; shift 2;;
    --token) TOKEN="$2"; shift 2;;
    --public-reg) PUBLIC_REG="$2"; shift 2;;
    *) echo "Unknown flag: $1" >&2; exit 1;;
  esac
done

# ---------- Helpers ----------
redact() { sed -E 's/(_authToken=)[^ ]+/\1<REDACTED>/g;s/(AuthToken: )[A-Za-z0-9._-]+/\1<REDACTED>/g'; }

have() { command -v "$1" >/dev/null 2>&1; }
req() { have "$1" || { echo "Missing required command: $1" >&2; exit 1; }; }

b64sha512() { # prints base64(sha512(file))
  openssl dgst -sha512 -binary "$1" | openssl base64 -A
}

bytes() { wc -c < "$1" | tr -d '[:space:]'; }

npmi() { # npm with install npmrc and workspaces disabled
  NPM_CONFIG_USERCONFIG="$NPMRC_INSTALL" npm --workspaces=false "$@"
}

# ---------- Pre-flight ----------
req node; req npm; req curl; req openssl

echo "=== Context ====================================================="
echo "Spec           : $SPEC"
echo "Public registry: $PUBLIC_REG"
[ -n "$INSTALL_REG" ] && echo "Install registry: $INSTALL_REG" || echo "Install registry: (not provided)"
echo "npmrc install  : $NPMRC_INSTALL"
echo "Node/npm       : $(node -v) / $(npm -v)"
if [ -f "$NPMRC_INSTALL" ]; then
  echo "--- $NPMRC_INSTALL (redacted) -----------------------------------"
  cat "$NPMRC_INSTALL" | redact
fi
echo "================================================================="
echo

# Resolve name/version once (prefer install registry, fall back to public)
RES_NAME="$(npmi view "$SPEC" name --registry "${INSTALL_REG:-$PUBLIC_REG}" 2>/dev/null || true)"
RES_VER="$(npmi view "$SPEC" version --registry "${INSTALL_REG:-$PUBLIC_REG}" 2>/dev/null || true)"
if [ -z "$RES_NAME" ] || [ -z "$RES_VER" ]; then
  # Try public if initial failed
  RES_NAME="$(npmi view "$SPEC" name --registry "$PUBLIC_REG" 2>/dev/null || true)"
  RES_VER="$(npmi view "$SPEC" version --registry "$PUBLIC_REG" 2>/dev/null || true)"
fi
[ -n "$RES_NAME" ] && [ -n "$RES_VER" ] || { echo "Failed to resolve $SPEC to name/version from either registry." >&2; exit 1; }

echo "Resolved       : ${RES_NAME}@${RES_VER}"
echo

# Registries to check (skip duplicates/empties)
declare -a REGS=()
REGS+=("$PUBLIC_REG")
[ -n "$INSTALL_REG" ] && REGS+=("$INSTALL_REG")

# Deduplicate simple (preserve order)
declare -A seen=()
unique_regs=()
for r in "${REGS[@]}"; do
  if [ -n "${r:-}" ] && [ -z "${seen[$r]:-}" ]; then
    unique_regs+=("$r"); seen[$r]=1
  fi
done

status=0

for REG in "${unique_regs[@]}"; do
  echo ">>> Checking registry: $REG"
  INTEGRITY="$(npmi view "${RES_NAME}@${RES_VER}" dist.integrity --registry "$REG" 2>/dev/null || true)"
  TARBALL="$(npmi view "${RES_NAME}@${RES_VER}" dist.tarball   --registry "$REG" 2>/dev/null || true)"

  if [ -z "$TARBALL" ]; then
    echo "  !! No dist.tarball found via npm view (registry may block metadata) — trying to guess URL..."
    # Fallback: construct canonical tarball URL used by registries (@scope pkgs)
    # Most registries support .../@scope%2Fname/-/name-VERSION.tgz
    base="${REG%/}"
    pkg_basename="$(echo "$RES_NAME" | sed 's|.*/||')"   # e.g., vm2
    enc_scope_name="$(node -e 'console.log(encodeURIComponent(process.argv[1]))' "$RES_NAME")"
    TARBALL="${base}/${enc_scope_name}/-/${pkg_basename}-${RES_VER}.tgz"
    echo "  -> Guessed tarball: $TARBALL"
  else
    echo "  dist.tarball   : $TARBALL"
  fi

  if [ -n "$INTEGRITY" ]; then
    echo "  dist.integrity : $INTEGRITY"
  else
    echo "  dist.integrity : (missing; will compare tarball only)"
  fi

  # Download tarball
  OUT="tarball.$(echo "$REG" | sed 's|https\?://||;s|/|_|g').tgz"
  echo "  Download       : $OUT"
  HDRS=()
  # Add token headers for Artifactory if token is present and URL seems to be your host
  if [[ -n "$TOKEN" && "$REG" == *"artifacthub-phx.oci.oraclecorp.com"* ]]; then
    HDRS+=(-H "X-JFrog-Art-Api: ${TOKEN}")
    HDRS+=(-H "Authorization: Bearer ${TOKEN}")
  fi
  if ! curl -fsS "${HDRS[@]}" -o "$OUT" "$TARBALL"; then
    echo "  !! curl failed to fetch tarball" >&2
    status=1
    echo
    continue
  fi

  # Compute sha512
  FILE_B64="$(b64sha512 "$OUT")"
  FILE_HEX="$(openssl dgst -sha512 "$OUT" | awk '{print $2}')"
  SIZE="$(bytes "$OUT")"

  # Normalize integrity (strip 'sha512-' prefix if present)
  META_B64="${INTEGRITY#sha512-}"

  echo "  size(bytes)    : $SIZE"
  echo "  file sha512 b64: $FILE_B64"
  echo "  file sha512 hex: $FILE_HEX"

  if [ -n "$INTEGRITY" ]; then
    if [ "$FILE_B64" = "$META_B64" ]; then
      echo "  ✅ Integrity match for ${RES_NAME}@${RES_VER} on $REG"
    else
      echo "  ❌ Integrity MISMATCH on $REG"
      echo "     meta (b64): $META_B64"
      echo "     file (b64): $FILE_B64"
      status=1
    fi
  else
    echo "  ⚠️  No integrity in metadata; cannot compare against registry claim."
  fi

  echo
done

if [ $status -eq 0 ]; then
  echo "All checked registries OK."
else
  echo "One or more registries failed integrity verification." >&2
fi

exit $status
