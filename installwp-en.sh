#!/bin/bash

# ============================================
# installwp-en.sh — Local WordPress installer for Herd + DBngin (macOS)
#
# Credits / Original idea:
# - Brian Coords: https://www.briancoords.com/local-wordpress-with-herd-dbngin-and-wp-cli/
#   GitHub: https://github.com/bacoords
# - Riza (original script): https://github.com/rizaardiyanto1412/rizaardiyanto1412/blob/main/installwp.sh
#
# Further Development/Iteration:
# - Roman Mahr (Use Case, Tests, Requirements)
# - ChatGPT (Refactor/Robustness/UX Iterations)
#
# License: MIT (see LICENSE)
# Disclaimer: "AS IS" – Use at your own risk, without warranty.
# ============================================


# ============================================
# WordPress Test Installation Script (Herd + DBngin)
# ============================================
# Features:
# - Pre-Checks: Herd & DBngin installed? (with links)
# - Optional: PHP memory_limit for WP-CLI (Note: Herd-wp might ignore env)
# - WordPress Core: Stable or "Beta" (= Nightly Build)
# - Locale freely selectable
# - DB Check: Does DB exist? Optional Drop or demand alternative DB name
# - Plugins: confirm individually (e.g., WooCommerce) + extra plugins (slugs)
# - Themes: selection including Indio + Twenty Twenty-Five + Custom Themes
# - Any number of local plugin symlinks
# - Robust Core Download: WP-CLI, Fallback ZIP (to bypass WP-CLI Extractor memory errors)

set -euo pipefail

# --- CI/Tests: bash -n + Dry Run ---
# Tip: Check syntax via: bash -n <script>
# Dry Run: Performs all queries, shows the plan, and exits without making any changes.
DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
  esac
done


# PATCH: ensure _offers is always defined (set -u safety)
_offers=()

# ---------- Colors ----------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Plugin path (ADJUST!)
PLUGIN_DEV_PATH="$HOME/Herd/plugins/wp-content/plugins/ki-bildgenerator"  # Your Plugin Development Folder

trap 'echo -e "${RED}✗ Error in line ${LINENO}: Command \"${BASH_COMMAND}\" failed.${NC}"' ERR

# ---------- Helpers ----------
confirm_yn() {
  # $1 prompt, $2 default (y/n)
  local prompt="$1"
  local def="${2:-y}"
  local ans=""
  while true; do
    if [ "$def" = "y" ]; then
      read -r -p "${prompt} (Y/n): " ans
      ans="${ans:-y}"
    else
      read -r -p "${prompt} (y/N): " ans
      ans="${ans:-n}"
    fi
    case "$ans" in
      y|Y) echo "y"; return 0;;
      n|N) echo "n"; return 0;;
      *) echo -e "${YELLOW}Please enter y or n.${NC}";;
    esac
  done
}

trim() {
  # trim leading/trailing whitespace
  local s="$*"
  s="${s#${s%%[![:space:]]*}}"
  s="${s%${s##*[![:space:]]}}"
  printf '%s' "$s"
}

# ---------- Herd / DBngin presence checks ----------
HERD_LINK="https://herd.laravel.com/"
DBNGIN_LINK="https://dbngin.com/download"

check_requirements() {
  echo -e "${BLUE}Pre-Checks:${NC}"

  # Herd app
  if [ ! -d "/Applications/Herd.app" ] && [ ! -d "$HOME/Applications/Herd.app" ]; then
    echo -e "${RED}✗ Herd does not appear to be installed.${NC}"
    echo -e "Please install Herd: ${BLUE}${HERD_LINK}${NC}"
    exit 1
  fi
  echo -e "${GREEN}✓ Herd found.${NC}"

  # DBngin app
  if [ ! -d "/Applications/DBngin.app" ] && [ ! -d "$HOME/Applications/DBngin.app" ]; then
    echo -e "${RED}✗ DBngin does not appear to be installed.${NC}"
    echo -e "Please install DBngin: ${BLUE}${DBNGIN_LINK}${NC}"
    exit 1
  fi
  echo -e "${GREEN}✓ DBngin found.${NC}"

  # wp-cli
  if ! command -v wp >/dev/null 2>&1; then
    echo -e "${RED}✗ WP-CLI (wp) is not in PATH.${NC}"
    echo -e "Tip: Herd often includes 'wp'; open Herd once and check the CLI Tools."
    exit 1
  fi
  echo -e "${GREEN}✓ WP-CLI found: $(command -v wp)${NC}"

  # mysql client: DBngin-Default-Path (can vary)
  if [ -d "/Users/Shared/DBngin/mysql" ]; then
    # Try to pick any version dir
    local mysqlbin
    mysqlbin="$(ls -d /Users/Shared/DBngin/mysql/*/bin 2>/dev/null | head -n 1 || true)"
    if [ -n "$mysqlbin" ]; then
      export PATH="$mysqlbin:$PATH"
    fi
  fi

  if ! command -v mysql >/dev/null 2>&1; then
    echo -e "${RED}✗ MySQL client (mysql) not found.${NC}"
    echo -e "Start DBngin and ensure a MySQL/MariaDB service is running."
    echo -e "If you installed mysql locally, add it to your PATH."
    exit 1
  fi
  echo -e "${GREEN}✓ mysql found: $(command -v mysql)${NC}"

  echo ""
}

#+#+#+#+---------- WP-CLI wrappers ----------
WP_ALLOW_ROOT_FLAG=""
if [ "${EUID:-$(id -u)}" -eq 0 ]; then
  WP_ALLOW_ROOT_FLAG="--allow-root"
fi

# WP-CLI / PHP handling
# IMPORTANT (Herd/macOS):
# Many setups expose `wp` as a shell function like: wp(){ php /Users/.../Application Support/.../wp "$@"; }
# If that function does NOT quote the path, you get:
#   Could not open input file: /Users/.../Library/Application
# To avoid this, we resolve the *real* wp executable (ignoring functions/aliases) and run it via PHP ourselves with safe quoting.

normalize_mem_limit() {
  # Accepts: 512, 512M, 1G, 1024m, etc. Defaults to 512M.
  local v="${1:-}"
  v="${v//[[:space:]]/}"
  if [ -z "$v" ]; then
    echo "512M"; return
  fi
  # If only digits => megabytes
  if [[ "$v" =~ ^[0-9]+$ ]]; then
    echo "${v}M"; return
  fi
  # Normalize unit to upper-case if present
  if [[ "$v" =~ ^[0-9]+[mMgG]$ ]]; then
    echo "${v%?}$(echo "${v: -1}" | tr 'mg' 'MG')"
    return
  fi
  # Fallback: keep as-is
  echo "$v"
}

WP_CLI_MEMORY_LIMIT_DEFAULT="512M"
WP_CLI_MEMORY_LIMIT="$(normalize_mem_limit "${WP_CLI_MEMORY_LIMIT:-$WP_CLI_MEMORY_LIMIT_DEFAULT}")"

# Resolve wp executable path (ignores shell functions/aliases)
WP_BIN_REAL="$(type -P wp 2>/dev/null || true)"
if [ -z "$WP_BIN_REAL" ]; then
  # Common Herd location fallback
  HERD_WP_FALLBACK="$HOME/Library/Application Support/Herd/bin/wp"
  if [ -f "$HERD_WP_FALLBACK" ]; then
    WP_BIN_REAL="$HERD_WP_FALLBACK"
  fi
fi

if [ -z "$WP_BIN_REAL" ]; then
  echo -e "${RED}✗ Could not determine the real WP-CLI binary path.${NC}"
  echo -e "Note: 'wp' might only be defined as a shell function/alias."
  echo -e "Please ensure an executable 'wp' is in your PATH."
  exit 1
fi

PHP_BIN="$(type -P php 2>/dev/null || true)"
# Avoid shell functions/aliases for php (occurs with macOS/Herd).
# Fallbacks for typical installation locations:
if [ -z "$PHP_BIN" ] && [ -x "/usr/bin/php" ]; then
  PHP_BIN="/usr/bin/php"
fi
if [ -z "$PHP_BIN" ] && [ -x "/opt/homebrew/bin/php" ]; then
  PHP_BIN="/opt/homebrew/bin/php"
fi
if [ -z "$PHP_BIN" ] && [ -x "/usr/local/bin/php" ]; then
  PHP_BIN="/usr/local/bin/php"
fi
if [ -z "$PHP_BIN" ]; then
  echo -e "${RED}✗ php (CLI) not found.${NC}"
  exit 1
fi

run_wp() {
  # Run wp through PHP with robust quoting (works with spaces in Herd paths),
  # and force memory_limit so WP_CLI Extractor doesn't die on 128MB.
  if [ "${DRY_RUN:-0}" -eq 1 ]; then
    echo "[dry-run] wp --path=\"$SITE_ROOT\" $*"
    return 0
  fi
  "$PHP_BIN" -d "memory_limit=${WP_CLI_MEMORY_LIMIT}" "$WP_BIN_REAL" --path="$SITE_ROOT" $WP_ALLOW_ROOT_FLAG "$@"
}

try_run_wp() {
  set +e
  run_wp "$@"
  local st=$?
  set -e
  return $st
}

# ---------- Core download (WP-CLI first, ZIP fallback) ----------
# Args: channel (stable|nightly), locale (e.g. de_DE)

download_wp_core() {
  local channel="$1"     # stable|beta
  local locale="$2"      # de_DE, en_US, ...
  local version="$3"     # latest or specific version number
  local url="$4"         # optional: direct ZIP URL

  echo -e "${BLUE}Downloading WordPress…${NC}"

  # If no URL was passed: try to get it from the API (for "latest").
  if [ -z "${url:-}" ]; then
      # NOTE (macOS Bash 3.2): Do NOT combine a pipe into `python3 -` with a heredoc.
      # A heredoc overrides stdin. We therefore fetch JSON first, then parse via ENV.
      local _api_json
      _api_json="$(curl -fsSL "https://api.wordpress.org/core/version-check/1.7/?channel=${channel}&locale=${locale}" 2>/dev/null || true)"
      url="$(API_JSON="${_api_json}" CHANNEL="${channel}" python3 - <<'PY'
import os, json, re
s=os.environ.get('API_JSON','')
channel=(os.environ.get('CHANNEL') or 'stable').strip().lower()
if not s.strip():
    print('')
    raise SystemExit(0)
try:
    data=json.loads(s)
except Exception:
    print('')
    raise SystemExit(0)

offers=data.get('offers',[]) or []
def is_prerelease(v:str, url:str, resp:str)->bool:
    v_l=(v or '').lower()
    url_l=(url or '').lower()
    resp_l=(resp or '').lower()
    if any(x in v_l for x in ('beta','rc','alpha','nightly','trunk')):
        return True
    if any(x in url_l for x in ('beta','rc','nightly','trunk')):
        return True
    if resp_l in ('beta','rc','development','nightly','trunk'):
        return True
    if re.search(r'(?:rc|beta|alpha)\s*\d*', v_l):
        return True
    return False

# pick first suitable offer
picked=''
for off in offers:
    v=off.get('version') or ''
    url=off.get('download') or (off.get('packages') or {}).get('full') or ''
    resp=off.get('response') or ''
    if not url:
        continue
    pre=is_prerelease(v,url,resp)
    if channel=='beta':
        if not pre:
            continue
    else:
        if pre:
            continue
    picked=url
    break

# fallback if nothing matched
if not picked and offers:
    off=offers[0]
    picked=off.get('download') or (off.get('packages') or {}).get('full') or ''

print(picked or '')
PY
)"
  fi

  # 1) Stable: try WP-CLI first (fast), otherwise ZIP fallback.
  if [ "$channel" = "stable" ]; then
    if [ "${version:-latest}" = "latest" ]; then
      if try_run_wp core download --locale="$locale"; then
        if [ -f "wp-load.php" ]; then
          echo -e "${GREEN}✓ WordPress downloaded via WP-CLI.${NC}"
          return 0
        fi
      fi
    else
      if try_run_wp core download --version="$version" --locale="$locale"; then
        if [ -f "wp-load.php" ]; then
          echo -e "${GREEN}✓ WordPress ${version} downloaded via WP-CLI.${NC}"
          return 0
        fi
      fi
    fi
    echo -e "${YELLOW}⚠ WP-CLI download/unpack failed – falling back to ZIP download.${NC}"
  else
    echo -e "${YELLOW}⚠ Beta channel chosen – using ZIP download (more robust in Herd).${NC}"
  fi

  # 2) ZIP Fallback (requires curl + unzip)
  if ! command -v curl >/dev/null 2>&1; then
    echo -e "${RED}curl is missing. Please install it (macOS: Xcode Command Line Tools).${NC}"
    return 1
  fi
  if ! command -v unzip >/dev/null 2>&1; then
    echo -e "${RED}unzip is missing. Please install it.${NC}"
    return 1
  fi

  if [ -z "${url:-}" ]; then
    echo -e "${RED}No download URL determined (API/network).${NC}"
    return 1
  fi

  echo -e "${BLUE}• Downloading: ${url}${NC}"
  tmpdir="$(mktemp -d)"
  zipfile="${tmpdir}/wp.zip"

  if ! curl -fsSL -L "$url" -o "$zipfile"; then
    echo -e "${RED}ZIP download failed.${NC}"
    rm -rf "$tmpdir"
    return 1
  fi

  if ! unzip -q "$zipfile" -d "$tmpdir"; then
    echo -e "${RED}ZIP could not be unpacked.${NC}"
    rm -rf "$tmpdir"
    return 1
  fi

  if [ ! -d "${tmpdir}/wordpress" ]; then
    echo -e "${RED}Unpacked, but no 'wordpress/' folder found.${NC}"
    rm -rf "$tmpdir"
    return 1
  fi

  cp -R "${tmpdir}/wordpress/." "$PWD/"
  rm -rf "$tmpdir"

  if [ ! -f "wp-load.php" ]; then
    echo -e "${RED}Download complete, but wp-load.php is still missing.${NC}"
    return 1
  fi

  echo -e "${GREEN}✓ WordPress installed via ZIP download.${NC}"
  return 0
}

# ---------- MySQL helpers ----------
DB_USER="root"
DB_PASSWORD=""
DB_HOST="127.0.0.1"

mysql_exec() {
  local q="$1"
  # Dry-run: only skip destructive statements; allow harmless reads/checks
  if [ "${DRY_RUN:-0}" -eq 1 ]; then
    if echo "$q" | grep -Eiq '^[[:space:]]*(CREATE|DROP|ALTER)[[:space:]]'; then
      echo -e "${YELLOW}[dry-run] mysql -h\"$DB_HOST\" -u\"$DB_USER\" ${DB_PASSWORD:+-p\"***\"} -e \"$q\"${NC}"
      return 0
    fi
  fi
  # shellcheck disable=SC2086
  mysql -h"$DB_HOST" -u"$DB_USER" ${DB_PASSWORD:+-p"$DB_PASSWORD"} -e "$q"
}

mysql_can_connect() {
  set +e
  mysql_exec "SELECT 1;" >/dev/null 2>&1
  local st=$?
  set -e
  return $st
}

mysql_db_exists() {
  local db="$1"
  set +e
  local out
  out="$(mysql_exec "SHOW DATABASES LIKE '${db//\'/\\\'}';" 2>/dev/null)"
  local st=$?
  set -e
  if [ $st -ne 0 ]; then
    return 2
  fi
  echo "$out" | tail -n +2 | grep -q "^$db$"
}

# ============================================
# START
# ============================================

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}WordPress Test Installation${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

check_requirements

# ---------- Ask memory limit early ----------
echo -e "${YELLOW}WP-CLI Memory Limit:${NC}"
echo "With Herd, WP-CLI can sometimes crash with 128MB during unpacking."
echo "The script has a ZIP fallback – but a higher limit can still help."
ans_mem="$(confirm_yn "Increase memory limit for WP-CLI?" "n")"
if [ "$ans_mem" = "y" ]; then
  read -r -p "New memory limit (e.g., 512M, 1024M) [${WP_CLI_MEMORY_LIMIT}]: " _ml
    _ml="$(trim "${_ml:-$WP_CLI_MEMORY_LIMIT}")"
    WP_CLI_MEMORY_LIMIT="$(normalize_mem_limit "$_ml")"
fi
  # Safety: always normalize (prevents "512 bytes")
  WP_CLI_MEMORY_LIMIT="$(normalize_mem_limit "$WP_CLI_MEMORY_LIMIT")"


# Best-effort: determine latest Stable version (for Nightly label)
LATEST_STABLE_VERSION="$(
  curl -fsSL "https://api.wordpress.org/core/version-check/1.7/?channel=stable&locale=en_US" 2>/dev/null \
  | python3 -c 'import sys,json
try:
  d=json.load(sys.stdin)
  o=(d.get("offers") or [])
  print(o[0].get("version","") if o else "")
except Exception:
  print("")' 2>/dev/null \
  || true
)"
LATEST_STABLE_VERSION="${LATEST_STABLE_VERSION:-the latest Stable version}"

echo ""

# ---------- WP channel + locale + specific version ----------
echo -e "${YELLOW}WordPress Channel:${NC}"
echo "1) Stable (Default)"
echo "2) Beta/RC (if available – may be unstable)"
echo "3) Nightly (Development status after ${LATEST_STABLE_VERSION}, unversioned)"
read -r -p "Choose (1-3) [1]: " WP_CHANNEL_CHOICE
WP_CHANNEL_CHOICE="${WP_CHANNEL_CHOICE:-1}"

WP_CHANNEL="stable"
API_CHANNEL="stable"

if [ "$WP_CHANNEL_CHOICE" = "2" ]; then
  WP_CHANNEL="beta"
  API_CHANNEL="beta"
elif [ "$WP_CHANNEL_CHOICE" = "3" ]; then
  WP_CHANNEL="nightly"
  API_CHANNEL="nightly"
fi

echo ""
echo -e "${YELLOW}Language / Locale:${NC}"
read -r -p "Locale (e.g., de_DE, en_US) [en_US]: " WP_LOCALE
WP_LOCALE="$(trim "${WP_LOCALE:-en_US}")"

echo ""
echo ""
echo -e "${YELLOW}WordPress Version (last 3) – Channel: ${API_CHANNEL}${NC}"

# Nightly: always fixed URL, no version selection needed.
if [ "$WP_CHANNEL" = "nightly" ]; then
  WP_VERSION="nightly"
  WP_DOWNLOAD_URL="https://wordpress.org/nightly-builds/wordpress-latest.zip"

  # v23 PATCH: Show Nightly Build info (Last-Modified + ETag, if available)
  _hdr="$(curl -fsSI "$WP_DOWNLOAD_URL" 2>/dev/null || true)"
  _lm="$(echo "$_hdr" | awk -F': ' 'tolower($1)=="last-modified"{print $2}' | tr -d '
' | head -n1 || true)"
  _etag="$(echo "$_hdr" | awk -F': ' 'tolower($1)=="etag"{print $2}' | tr -d '
' | head -n1 || true)"

  echo -n "• Nightly chosen: wordpress-latest.zip"
  [ -n "${_lm:-}" ] && echo -n " (Last-Modified: ${_lm})"
  [ -n "${_etag:-}" ] && echo -n " (ETag: ${_etag})"
  echo ""
else
  # Fetches the last 3 versions (and download URLs) from the WordPress API.
  # Output format per line: version|url
  _offers=()
  _api_json="$(curl -fsSL "https://api.wordpress.org/core/version-check/1.7/?channel=${API_CHANNEL}&locale=${WP_LOCALE}" 2>/dev/null || true)"
  # v23 PATCH: if RCs are available, force RC-only + show note
  RC_ONLY_ACTIVE="n"
  if [ "$API_CHANNEL" = "beta" ] && [ -n "${_api_json:-}" ]; then
    RC_ONLY_ACTIVE="$(API_JSON="${_api_json}" python3 - <<'PY'
import os, json, re
s=os.environ.get("API_JSON","")
try:
    data=json.loads(s)
except Exception:
    print("n"); raise SystemExit
offers=data.get("offers",[]) or []
def is_pre(v,u,r):
    v=(v or "").lower(); u=(u or "").lower(); r=(r or "").lower()
    if any(x in v for x in ("beta","rc","alpha","nightly","trunk")): return True
    if any(x in u for x in ("beta","rc","nightly","trunk")): return True
    if r in ("beta","rc","development","nightly","trunk"): return True
    if re.search(r"(?:rc|beta|alpha)\s*\d*", v): return True
    return False
def is_rc(v,u,r):
    v=(v or "").lower(); u=(u or "").lower(); r=(r or "").lower()
    return ("rc" in v) or ("rc" in u) or (r=="rc")
for off in offers:
    v=off.get("version") or ""
    u=off.get("download") or (off.get("packages") or {}).get("full") or ""
    r=off.get("response") or ""
    if v and u and is_pre(v,u,r) and is_rc(v,u,r):
        print("y"); raise SystemExit
print("n")
PY
)"
    if [ "$RC_ONLY_ACTIVE" = "y" ]; then
      echo -e "${BLUE}• RC-only active: RC versions are offered (if available).${NC}"
    fi
  fi


  if [ -n "${_api_json}" ]; then
    while IFS= read -r line; do
      [ -n "$line" ] && _offers+=("$line")
    done < <(API_JSON="${_api_json}" CHANNEL="${API_CHANNEL}" RC_ONLY_ACTIVE="${RC_ONLY_ACTIVE:-n}" python3 - <<'PY'
import os, json, re
s=os.environ.get('API_JSON','')
channel=(os.environ.get('CHANNEL') or 'stable').strip().lower()
rc_only=(os.environ.get('RC_ONLY_ACTIVE') or 'n').strip().lower()=='y'
if not s.strip():
    raise SystemExit(0)
try:
    data=json.loads(s)
except Exception:
    raise SystemExit(0)

offers=data.get('offers',[]) or []

def is_prerelease(v:str, url:str, resp:str)->bool:
    v_l=(v or '').lower()
    url_l=(url or '').lower()
    resp_l=(resp or '').lower()
    if any(x in v_l for x in ('beta','rc','alpha','nightly','trunk')):
        return True
    if any(x in url_l for x in ('beta','rc','nightly','trunk')):
        return True
    if resp_l in ('beta','rc','development','nightly','trunk'):
        return True
    if re.search(r'(?:rc|beta|alpha)\s*\d*', v_l):
        return True
    return False

def is_rc(v:str, url:str, resp:str)->bool:
    v_l=(v or '').lower()
    url_l=(url or '').lower()
    resp_l=(resp or '').lower()
    return ('rc' in v_l) or ('rc' in url_l) or (resp_l == 'rc')

seen=set()
out=[]
for off in offers:
    v=off.get('version') or ''
    url=off.get('download') or (off.get('packages') or {}).get('full') or ''
    resp=off.get('response') or ''
    if not v or not url:
        continue
    pre=is_prerelease(v,url,resp)

    # Channel filtering:
    # - stable: only "clean" releases
    # - beta: only Beta/RC/Alpha/Nightly Offers (if available)
    if channel == 'beta':
        if not pre:
            continue
        if rc_only and not is_rc(v,url,resp):
            continue
    else:
        if pre:
            continue

    if v in seen:
        continue
    seen.add(v)
    out.append((v,url))
    if len(out) >= 3:
        break

for v,url in out:
    print(f"{v}|{url}")
PY
)
  fi

  if [ "${#_offers[@]}" -eq 0 ]; then
    if [ "$WP_CHANNEL" = "beta" ] && [ -n "${_api_json:-}" ]; then
      echo -e "${YELLOW}⚠ The Beta/RC feed currently contains no pre-releases. Using \"latest\" (stable).${NC}"
    else
      echo -e "${YELLOW}⚠ Could not load versions automatically – using \"latest\".${NC}"
    fi
    WP_VERSION="latest"
    WP_DOWNLOAD_URL=""
  else
    echo "1) ${_offers[0]%%|*}"
    [ "${#_offers[@]}" -ge 2 ] && echo "2) ${_offers[1]%%|*}"
    [ "${#_offers[@]}" -ge 3 ] && echo "3) ${_offers[2]%%|*}"
    echo "4) latest (automatic)"
    read -r -p "Choose (1-4) [1]: " _vsel
    _vsel="${_vsel:-1}"

    if [ "$_vsel" = "4" ]; then
      WP_VERSION="latest"
      WP_DOWNLOAD_URL=""
    else
      _idx=$(( _vsel - 1 ))
      if [ "$_idx" -lt 0 ] || [ "$_idx" -ge "${#_offers[@]}" ]; then
        _idx=0
      fi
      WP_VERSION="${_offers[$_idx]%%|*}"
      WP_DOWNLOAD_URL="${_offers[$_idx]#*|}"
    fi
  fi
fi

# v23.1 PATCH: redundant fallback block removed (avoids double warning)

echo ""
# ---------- Site name / URL / DB name (needed early) ----------
echo -e "${YELLOW}Project / Site Name:${NC}"
read -r -p "Installation folder under ~/Herd (e.g., mysite) [wp-testing]: " SITE_NAME
SITE_NAME="$(trim "${SITE_NAME:-wp-testing}")"

# Installation Path (Herd)
SITE_ROOT="$HOME/Herd/$SITE_NAME"

# ---------- Install folder preflight: exists? delete or choose another ----------
# If the target folder already exists, we ask:
# - Delete? (rm -rf)
# - If no: choose a new folder name (until non-existent)
safe_rm_rf() {
  local target="$1"
  # Safety: only allow deleting inside ~/Herd and not the Herd root itself
  if [[ "$target" != "$HOME/Herd/"* ]] || [[ "$target" = "$HOME/Herd" ]] || [[ "$target" = "$HOME/Herd/" ]]; then
    echo -e "${RED}✗ Security abort: would delete non-safe path: $target${NC}"
    exit 1
  fi
  if [ "${DRY_RUN:-0}" -eq 1 ]; then
    echo "[dry-run] rm -rf \"$target\""
    return 0
  fi
  rm -rf "$target"
}

while [ -e "$SITE_ROOT" ]; do
  echo -e "${YELLOW}⚠ The installation folder already exists:${NC} $SITE_ROOT"
  del="$(confirm_yn "Should the folder be deleted?" "n")"
  if [ "$del" = "y" ]; then
    safe_rm_rf "$SITE_ROOT"
    echo -e "${GREEN}✓ Folder deleted.${NC}"
    break
  fi
  echo -e "${YELLOW}Please choose a different folder name.${NC}"
  read -r -p "New installation folder under ~/Herd: " SITE_NAME
  SITE_NAME="$(trim "$SITE_NAME")"
  if [ -z "$SITE_NAME" ]; then
    echo -e "${YELLOW}Folder name must not be empty.${NC}"
    SITE_NAME="wp-testing"
  fi
  SITE_ROOT="$HOME/Herd/$SITE_NAME"
done


# Herd typically uses .test
read -r -p "Domain (without http, e.g., mysite.test) [${SITE_NAME}.test]: " WP_DOMAIN
WP_DOMAIN="$(trim "${WP_DOMAIN:-${SITE_NAME}.test}")"
WP_URL="https://${WP_DOMAIN}"

DEFAULT_DB_NAME="$SITE_NAME"
DB_NAME="$DEFAULT_DB_NAME"

echo ""
# ---------- DB preflight: connection + exists? drop/rename ----------
echo ""
echo -e "${BLUE}DB Check (DBngin):${NC}"
if ! mysql_can_connect; then
  echo -e "${RED}✗ Cannot connect to MySQL.${NC}"
  echo "• Please start DBngin and a MySQL/MariaDB service (Port/Host: ${DB_HOST})."
  echo "• If you use a different host/port, adjust DB_HOST/DB_USER in the script."
  exit 1
fi

echo -e "${GREEN}✓ MySQL connection ok.${NC}"

# If default DB exists: ask to drop or choose different DB name
if mysql_db_exists "$DB_NAME"; then
  echo -e "${YELLOW}⚠ Database '${DB_NAME}' already exists.${NC}"
  drop="$(confirm_yn "Should '${DB_NAME}' be dropped (DROP)?" "n")"
  if [ "$drop" = "y" ]; then
    mysql_exec "DROP DATABASE IF EXISTS \`${DB_NAME}\`;"
    echo -e "${GREEN}✓ Database '${DB_NAME}' dropped.${NC}"
  else
    echo -e "${YELLOW}Then a different database name must be used (unlike the folder name).${NC}"
    while true; do
      read -r -p "New DB Name: " _db
      _db="$(trim "$_db")"
      if [ -z "$_db" ]; then
        echo -e "${YELLOW}DB name must not be empty.${NC}"
        continue
      fi
      if [ "$_db" = "$DEFAULT_DB_NAME" ]; then
        echo -e "${YELLOW}Please choose a different name than '${DEFAULT_DB_NAME}'.${NC}"
        continue
      fi
      DB_NAME="$_db"
      if mysql_db_exists "$DB_NAME"; then
        echo -e "${YELLOW}DB '${DB_NAME}' also exists. Please choose a different name.${NC}"
        continue
      fi
      break
    done
  fi
elif [ $? -eq 2 ]; then
  echo -e "${YELLOW}⚠ Could not check DB existence (SQL error). Continuing.${NC}"
fi

# ---------- WP title + admin ----------
echo ""
read -r -p "Website Title (empty = $SITE_NAME): " WP_TITLE
WP_TITLE="$(trim "${WP_TITLE:-$SITE_NAME}")"

read -r -p "Admin Username (empty = admin): " WP_ADMIN_USER
WP_ADMIN_USER="$(trim "${WP_ADMIN_USER:-admin}")"

read -r -s -p "Admin Password (empty = automatically generate): " WP_ADMIN_PASSWORD
echo ""
if [ -z "${WP_ADMIN_PASSWORD}" ]; then
  if command -v openssl >/dev/null 2>&1; then
    WP_ADMIN_PASSWORD="$(openssl rand -base64 18 | tr -d '\n' | tr -d '/+' | cut -c1-24)"
  elif command -v python3 >/dev/null 2>&1; then
    WP_ADMIN_PASSWORD="$(python3 - <<'PY'
import secrets, string
alphabet = string.ascii_letters + string.digits
print(''.join(secrets.choice(alphabet) for _ in range(24)))
PY
)"
  else
    WP_ADMIN_PASSWORD="$(date +%s%N)"
  fi
  echo -e "${YELLOW}→ Password was automatically generated.${NC}"
fi

read -r -p "Admin Email (empty = admin@$WP_URL): " WP_ADMIN_EMAIL
WP_ADMIN_EMAIL="$(trim "${WP_ADMIN_EMAIL:-admin@$WP_URL}")"

# ---------- Plugins (confirm each) + extras ----------
echo ""
echo -e "${YELLOW}Select plugins (confirm individually):${NC}"

# Always installed dev plugins (can still be skipped if you want)
INSTALL_QUERY_MONITOR="$(confirm_yn "Install Query Monitor?" "y")"
INSTALL_DEBUG_BAR="$(confirm_yn "Install Debug Bar?" "y")"
INSTALL_ADMINER="$(confirm_yn "Install Adminer (WP Adminer)?" "y")"

INSTALL_WC="$(confirm_yn "Install WooCommerce?" "n")"
INSTALL_YOAST="$(confirm_yn "Install Yoast SEO?" "n")"
INSTALL_CF7="$(confirm_yn "Install Contact Form 7?" "n")"
INSTALL_ELEMENTOR="$(confirm_yn "Install Elementor? (will NOT be activated by default)" "n")"
INSTALL_ACF="$(confirm_yn "Install Advanced Custom Fields (ACF)?" "n")"

EXTRA_PLUGINS=()
add_more_plugins="$(confirm_yn "Specify more plugins by slug?" "n")"
if [ "$add_more_plugins" = "y" ]; then
  echo "Enter plugin slugs (e.g., 'regenerate-thumbnails'). Empty input finishes."
  while true; do
    read -r -p "Plugin Slug (empty=done): " p
    p="$(trim "$p")"
    [ -z "$p" ] && break
    EXTRA_PLUGINS+=("$p")
  done
fi

# ---------- Plugin symlinks ----------
# Target: wp-content/plugins/<name> -> <local path>
PLUGIN_LINK_PATHS=()
PLUGIN_LINK_NAMES=()

echo ""
echo -e "${YELLOW}Symlinks to local plugins:${NC}"
echo -e "${BLUE}Optional fixed Dev Path:${NC}"
# If Herd folder + Dev Plugin folder exist: prompt whether the symlink should be set.
if [ -d "$HOME/Herd" ] && [ -n "${PLUGIN_DEV_PATH:-}" ] && [ -d "$PLUGIN_DEV_PATH" ]; then
  echo "Found Dev Plugin Folder:"
  echo "  $PLUGIN_DEV_PATH"
  use_dev="$(confirm_yn "Create symlink to this Dev Plugin Folder?" "n")"
  if [ "$use_dev" = "y" ]; then
    _dev_name="$(basename "$PLUGIN_DEV_PATH")"
    PLUGIN_LINK_PATHS+=("$PLUGIN_DEV_PATH")
    PLUGIN_LINK_NAMES+=("$_dev_name")
    echo -e "${GREEN}✓ noted:${NC} $_dev_name  ←  $PLUGIN_DEV_PATH"
  else
    echo -e "${YELLOW}• Dev path is skipped.${NC}"
  fi
fi

create_symlinks="$(confirm_yn "Create symlinks to local plugin folders?" "n")"
if [ "$create_symlinks" = "y" ]; then
  echo -e "${BLUE}Enter local plugin paths. Empty input finishes.${NC}"
  while true; do
    read -r -p "Plugin Path (empty=done): " _p
    _p="$(trim "$_p")"
    [ -z "$_p" ] && break

    if [ ! -d "$_p" ]; then
      echo -e "${YELLOW}⚠ Folder not found: $_p${NC}"
      keep="$(confirm_yn "Include anyway?" "n")"
      [ "$keep" != "y" ] && continue
    fi

    read -r -p "Symlink name in wp-content/plugins (empty=folder name): " _name
    _name="$(trim "${_name:-$(basename "$_p")}")"

    PLUGIN_LINK_PATHS+=("$_p")
    PLUGIN_LINK_NAMES+=("$_name")

    echo -e "${GREEN}✓ noted:${NC} $_name  ←  $_p"
  done
fi

# ---------- Theme selection + custom ----------
echo ""
echo -e "${YELLOW}Theme Selection:${NC}"
echo "1) Twenty Twenty-Five"
echo "2) Twenty Twenty-Four"
echo "3) Storefront (WooCommerce)"
echo "4) Astra"
echo "5) Indio (Brian Gardner)"
echo "6) None (Keep default)"
echo "7) Other Themes by Slug (Custom)"
read -r -p "Choose (1-7) [1]: " THEME_CHOICE
THEME_CHOICE="${THEME_CHOICE:-1}"

CUSTOM_THEMES=()
CUSTOM_THEME_ACTIVATE=""
if [ "$THEME_CHOICE" = "7" ]; then
  echo "Enter theme slugs (e.g., 'generatepress'). Empty input finishes."
  while true; do
    read -r -p "Theme Slug (empty=done): " t
    t="$(trim "$t")"
    [ -z "$t" ] && break
    CUSTOM_THEMES+=("$t")
  done
  if [ "${#CUSTOM_THEMES[@]}" -gt 0 ]; then
    read -r -p "Which theme should be activated? (Slug, empty=first): " act
    act="$(trim "$act")"
    CUSTOM_THEME_ACTIVATE="${act:-${CUSTOM_THEMES[0]}}"
  else
    THEME_CHOICE="6"
  fi
fi

# ---------- Summary + confirm ----------
echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Installation Summary${NC}"
echo -e "${GREEN}========================================${NC}"
echo "Site Folder:    $SITE_ROOT"
echo "WordPress URL:  $WP_URL"
echo "WordPress:      $([ "$WP_CHANNEL" = "stable" ] && echo "Stable" || echo "Beta/Nightly")"
echo "Locale:         $WP_LOCALE"
echo "Database Name:  $DB_NAME"
echo "WP-CLI Memory:  ${WP_CLI_MEMORY_LIMIT}"

echo ""
echo "Plugins (install):"
echo "  • Query Monitor:   $INSTALL_QUERY_MONITOR"
echo "  • Debug Bar:       $INSTALL_DEBUG_BAR"
echo "  • Adminer:         $INSTALL_ADMINER"
echo "  • WooCommerce:     $INSTALL_WC"
echo "  • Yoast SEO:       $INSTALL_YOAST"
echo "  • Contact Form 7:  $INSTALL_CF7"
echo "  • Elementor:       $INSTALL_ELEMENTOR"
echo "  • ACF:             $INSTALL_ACF"
if [ "${#EXTRA_PLUGINS[@]}" -gt 0 ]; then
  echo "  • Extra:           ${EXTRA_PLUGINS[*]}"
fi

if [ "$WP_LOCALE" != "en_US" ]; then
  echo -e "${BLUE}→ Finalizing Language Settings for Core & Plugins...${NC}"
  
  # 1. Install all missing plugin translations
  run_wp_best_effort language plugin install --all --locale="$WP_LOCALE" >/dev/null 2>&1 || true
  
  # 2. Update and activate all translations (this step is critical)
  run_wp_best_effort language plugin update --all --locale="$WP_LOCALE" >/dev/null 2>&1 || true
  
  # 3. Update core language
  run_wp_best_effort core language update >/dev/null 2>&1 || true

  echo -e "${GREEN}✓ Language settings successfully completed for $WP_LOCALE${NC}"
fi

echo ""
if [ "${#PLUGIN_LINK_NAMES[@]}" -gt 0 ]; then
  echo "Plugin Symlinks: Yes (${#PLUGIN_LINK_NAMES[@]} items)"
  for i in "${!PLUGIN_LINK_NAMES[@]}"; do
    echo "  • ${PLUGIN_LINK_NAMES[$i]}  ←  ${PLUGIN_LINK_PATHS[$i]}"
  done
else
  echo "Plugin Symlinks: No"
fi

echo ""
echo "Theme:"
case "$THEME_CHOICE" in
  1) echo "  • Twenty Twenty-Five" ;;
  2) echo "  • Twenty Twenty-Four" ;;
  3) echo "  • Storefront" ;;
  4) echo "  • Astra" ;;
  5) echo "  • Indio" ;;
  6) echo "  • None (Keep default)" ;;
  7)
    if [ "${#CUSTOM_THEMES[@]}" -eq 0 ]; then
      echo "  • Custom: (none specified) → Default"
    else
      echo -n "  • Custom: ${CUSTOM_THEMES[*]}"
      if [ -n "${CUSTOM_THEME_ACTIVATE:-}" ]; then
        echo " (activate: $CUSTOM_THEME_ACTIVATE)"
      else
        echo ""
      fi
    fi
    ;;
  *) echo "  • Default" ;;
esac

echo -e "${GREEN}========================================${NC}"
if [ "$DRY_RUN" -eq 1 ]; then
  echo -e "${BLUE}Dry Run active (--dry-run): no changes will be made.${NC}"
  exit 0
fi

proceed="$(confirm_yn "Proceed?" "y")"
if [ "$proceed" != "y" ]; then
  echo "Installation aborted."
  exit 0
fi

if [ "${DRY_RUN:-0}" -eq 1 ]; then
  echo ""
  echo -e "${YELLOW}Dry Run active: No changes were made. Exiting after summary.${NC}"
  exit 0
fi

# ============================================
# EXECUTION
# ============================================

# 1) Create site directory

echo ""
echo -e "${BLUE}[1/9] Creating Site Folder...${NC}"
mkdir -p "$SITE_ROOT"
cd "$SITE_ROOT"
echo -e "${GREEN}✓ Folder created: $PWD${NC}"

# 2) Create database

echo ""
echo -e "${BLUE}[2/9] Creating Database...${NC}"
mysql_exec "CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\`;"
echo -e "${GREEN}✓ Database '${DB_NAME}' ready.${NC}"

# 3) Download WordPress

echo ""
echo -e "${BLUE}[3/9] Installing WordPress Core...${NC}"
if command -v curl >/dev/null 2>&1; then
  echo "• Connectivity Check: wordpress.org ..."
  curl -Is https://wordpress.org/ | head -n 1 || true
  echo "• Connectivity Check: downloads.wordpress.org ..."
  curl -Is https://downloads.wordpress.org/ | head -n 1 || true
  # Locale-specific check (e.g. de.wordpress.org, en.wordpress.org)
  if [ "$WP_LOCALE" != "en_US" ]; then
    echo "• Connectivity Check: locale-specific wordpress.org ..."
    curl -Is "https://${WP_LOCALE%.*}.wordpress.org/" | head -n 1 || true
  fi
fi

download_wp_core "$WP_CHANNEL" "$WP_LOCALE" "$WP_VERSION" "${WP_DOWNLOAD_URL:-}"

# 4) Create wp-config

DB_PREFIX="wp_"

use_custom_prefix="$(confirm_yn "Create a custom table prefix? (Default: wp_)" "n")"
if [ "$use_custom_prefix" = "y" ]; then
  read -r -p "Prefix suffix (e.g. museum) [leave empty to keep wp_]: " DB_PREFIX_SUFFIX
  DB_PREFIX_SUFFIX="$(echo "${DB_PREFIX_SUFFIX:-}" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9_')"
  if [ -n "$DB_PREFIX_SUFFIX" ]; then
    DB_PREFIX="wp_${DB_PREFIX_SUFFIX}_"
  fi
fi

# Line 1184 (Approximate)
run_wp_best_effort() {
  # Best-effort wrapper: Executes the command in a subshell and returns the exit code
  # without triggering the main script's ERR trap.
  
  # Save the WP-CLI command's return value
  local rc=0

  # Execute the WP-CLI command in a subshell
  (
    # Temporarily enable the original ERR trap, if it was defined
    local old_trap
    old_trap="$(trap -p ERR || true)"
    eval "$old_trap" 2>/dev/null || true
    
    # Disable set -e and ERR trap in this subshell
    set +e
    trap - ERR

    # Execute the command
    run_wp "$@"
    
    # Save the subshell's exit code
    exit $?
  )
  
  # Save the subshell's exit code
  rc=$?
  
  # The main script's trap and set -e remain unaffected.
  return $rc
}

echo ""
echo -e "${BLUE}[4/9] Creating wp-config.php...${NC}"
run_wp config create \
  --dbname="$DB_NAME" --dbuser="$DB_USER" --dbpass="$DB_PASSWORD" --dbhost="$DB_HOST" --dbprefix="$DB_PREFIX" \
  --skip-check --force

run_wp config set WP_DEBUG true --raw
run_wp config set WP_DEBUG_LOG true --raw
run_wp config set WP_DEBUG_DISPLAY false --raw
run_wp config set SCRIPT_DEBUG true --raw

echo -e "${GREEN}✓ wp-config.php created (Debug Mode enabled)${NC}"

# 5) Install WordPress

echo ""
echo -e "${BLUE}[5/9] Installing WordPress...${NC}"
run_wp core install --url="$WP_URL" --title="$WP_TITLE" --admin_user="$WP_ADMIN_USER" --admin_password="$WP_ADMIN_PASSWORD" --admin_email="$WP_ADMIN_EMAIL" --skip-email

echo -e "${GREEN}✓ WordPress installed${NC}"

# 5b) Activate locale (esp. important if core came from generic ZIP or nightly)

echo ""
echo -e "${BLUE}[6/9] Activating Language...${NC}"
# Best-effort: install & activate language pack
set +e
run_wp language core install "$WP_LOCALE" --activate >/dev/null 2>&1
st=$?
set -e
if [ $st -ne 0 ]; then
  echo -e "${YELLOW}⚠ Could not automatically activate language pack '$WP_LOCALE' (possibly Nightly without pack).${NC}"
else
  echo -e "${GREEN}✓ Language '$WP_LOCALE' activated.${NC}"
fi

# 6) Create plugin symlinks

echo ""
echo -e "${BLUE}[7/9] Creating Plugin Symlinks...${NC}"
if [ "${#PLUGIN_LINK_NAMES[@]}" -eq 0 ]; then
  echo -e "${YELLOW}↷ No symlinks noted${NC}"
else
  for i in "${!PLUGIN_LINK_NAMES[@]}"; do
    SRC="${PLUGIN_LINK_PATHS[$i]}"
    NAME="${PLUGIN_LINK_NAMES[$i]}"
    DEST="$SITE_ROOT/wp-content/plugins/$NAME"

    echo ""
    echo -e "${YELLOW}• $NAME${NC}"
    echo "  From: $SRC"
    echo "  To: $DEST"

    if [ -e "$DEST" ] || [ -L "$DEST" ]; then
      echo -e "${YELLOW}⚠ Target already exists: $DEST${NC}"
      rep="$(confirm_yn "Replace?" "n")"
      if [ "$rep" = "y" ]; then
        rm -rf "$DEST"
      else
        echo -e "${YELLOW}↷ Skipped${NC}"
        continue
      fi
    fi

    if [ ! -d "$SRC" ]; then
      echo -e "${YELLOW}⚠ Source is not a folder: $SRC${NC}"
      tr="$(confirm_yn "Try symlink anyway?" "n")"
      [ "$tr" != "y" ] && continue
    fi

    ln -s "$SRC" "$DEST"
    echo -e "${GREEN}✓ Symlink created${NC}"
  done
fi

# 7) Install plugins

echo ""
echo -e "${BLUE}[8/9] Installing Plugins...${NC}"

install_plugin_if() {
  local flag="$1"; shift
  local slug="$1"; shift
  local activate="${1:-yes}"
  if [ "$flag" = "y" ]; then
    if [ "$activate" = "yes" ]; then
      echo "• Installing $slug (activate)..."
      run_wp plugin install "$slug" --activate
    else
      echo "• Installing $slug (no activate)..."
      run_wp plugin install "$slug"
    fi
    
    # NEW: Install language pack for this plugin
    if [ "$WP_LOCALE" != "en_US" ]; then
      set +e
      run_wp language plugin install "$slug" "$WP_LOCALE" --skip-activate >/dev/null 2>&1 || true
      set -e
    fi
    # END NEW

    echo -e "${GREEN}  ✓ $slug installed${NC}"
  fi
}

install_plugin_if "$INSTALL_QUERY_MONITOR" "query-monitor" "yes"
install_plugin_if "$INSTALL_DEBUG_BAR" "debug-bar" "yes"
# Adminer: correct WordPress.org slug is pexlechris-adminer
install_plugin_if "$INSTALL_ADMINER" "pexlechris-adminer" "yes"
if [ "$INSTALL_ADMINER" = "y" ]; then
  echo "  → Access: wp-admin → Tools → Adminer"
fi

if [ "${INSTALL_WC:-n}" = "y" ]; then
    echo "• Installing woocommerce (activate, final language fix)..."
    
    # Standard installation without the faulty --skip-setup parameter
    run_wp plugin install woocommerce --activate
    
    # CRITICAL STEP 1: Immediately deactivate the setup wizard in the database.
    # This prevents English initialization.
    run_wp_best_effort option update woocommerce_setup_wizard_skipped 'yes' >/dev/null 2>&1 || true
    
    # CRITICAL STEP 2: Force a US location for email templates (which often remain English)
    # Changed from 'DE:BW' to 'US:CA' as a typical US default for an English script.
    run_wp_best_effort option update woocommerce_default_country 'US:CA' >/dev/null 2>&1 || true
    
    # Update general language setting
    run_wp_best_effort option update WPLANG "$WP_LOCALE" >/dev/null 2>&1 || true
    
    echo -e "${GREEN}  ✓ woocommerce installed${NC}"
fi

install_plugin_if "$INSTALL_YOAST" "wordpress-seo" "yes"
install_plugin_if "$INSTALL_CF7" "contact-form-7" "yes"
install_plugin_if "$INSTALL_ELEMENTOR" "elementor" "no"
install_plugin_if "$INSTALL_ACF" "advanced-custom-fields" "yes"

if [ "${#EXTRA_PLUGINS[@]}" -gt 0 ]; then
  echo ""
  echo -e "${YELLOW}Extra Plugins:${NC}"
  for p in "${EXTRA_PLUGINS[@]}"; do
    echo "• Installing $p (activate)..."
    run_wp plugin install "$p" --activate
    echo -e "${GREEN}  ✓ $p installed${NC}"
  done
fi

# 8) Install theme(s)

echo ""
echo -e "${BLUE}[9/9] Installing Theme(s)...${NC}"

case "$THEME_CHOICE" in
  1)
    echo "• Installing Twenty Twenty-Five..."
    run_wp theme install twentytwentyfive --activate
    ;;
  2)
    echo "• Installing Twenty Twenty-Four..."
    run_wp theme install twentytwentyfour --activate
    ;;
  3)
    echo "• Installing Storefront..."
    run_wp theme install storefront --activate
    ;;
  4)
    echo "• Installing Astra..."
    run_wp theme install astra --activate
    ;;
  5)
    echo "• Installing Indio..."
    run_wp theme install indio --activate
    ;;
  6)
    echo "• Keeping default theme..."
    ;;
  7)
    echo -e "${YELLOW}Custom Themes:${NC}"
    if [ "${#CUSTOM_THEMES[@]}" -eq 0 ]; then
      echo "• No custom themes specified – skipping."
    else
      for t in "${CUSTOM_THEMES[@]}"; do
        if [ "$t" = "$CUSTOM_THEME_ACTIVATE" ]; then
          echo "• Installing $t (activate)..."
          run_wp theme install "$t" --activate
        else
          echo "• Installing $t..."
          run_wp theme install "$t"
        fi
      done
    fi
    ;;
  *)
    echo "• Keeping default theme..."
    ;;
esac

echo -e "${GREEN}✓ Plugins & Themes installed${NC}"

# ---------- Useful settings ----------
echo ""
echo -e "${BLUE}Useful Settings…${NC}"

# Set Permalinks
echo -e "${BLUE}→ Setting Permalink Structure...${NC}"

# Execute WP-CLI command and filter the Herd warning.
# Add || true to prevent the ERR trap from being triggered.
run_wp_best_effort rewrite structure '/%postname%/' 2>&1 \
  | grep -Eiv "Could not open input file: /Users/romanmahr/Library/Application" || true 
rc=$?

if [ $rc -ne 0 ]; then
  # The warning is issued if WP-CLI truly fails.
  echo -e "${YELLOW}⚠ Could not set permalink structure (Exit $rc) – continuing.${NC}"
fi

# ...
run_wp_best_effort option update default_comment_status closed >/dev/null 2>&1 || true
run_wp_best_effort option update timezone_string 'Europe/Berlin' >/dev/null 2>&1 || true

echo -e "${GREEN}✓ Useful basic settings complete${NC}"
echo ""

if [ "${INSTALL_WC:-n}" = "y" ]; then
  PROMPT_TEXT="Create test posts, pages & products?"
else
  PROMPT_TEXT="Create test posts & pages?"
fi

create_content="$(confirm_yn "$PROMPT_TEXT" "n")"
if [ "$create_content" = "y" ]; then
  run_wp post create --post_title='Test Blog Post 1' --post_content='This is a test post for featured image testing.' --post_status=publish --post_type=post
  run_wp post create --post_title='Test Blog Post 2' --post_content='This is another test post.' --post_status=publish --post_type=post
  run_wp post create --post_title='Test Page' --post_content='This is a test page.' --post_status=publish --post_type=page
  # 2. WordPress Products (if Woocommerce was chosen)
  if [ "${INSTALL_WC:-n}" = "y" ]; then
    echo -e "${BLUE}→ Creating test products...${NC}"
    run_wp post create --post_title='Test Product 1' --post_content='Description of the test product' --post_status=publish --post_type=product >/dev/null 2>&1
    echo "Success: Created product 1."
    run_wp post create --post_title='Test Product 2' --post_content='Another test product' --post_status=publish --post_type=product >/dev/null 2>&1
    echo "Success: Created product 2."
  fi
  echo -e "${GREEN}✓ Test content created${NC}"
fi

echo -e "${BLUE}→ Finalizing language settings...${NC}"
run_wp_best_effort core language update >/dev/null 2>&1 || true

# ---------- Final summary ----------
echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}✓ Installation Complete!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo "Site Details:"
echo "  URL:              $WP_URL"
echo "  Admin URL:        $WP_URL/wp-admin"
echo "  Database:         $DB_NAME"
echo "  Admin User:       $WP_ADMIN_USER"
echo "  Admin Password:   $WP_ADMIN_PASSWORD"
echo "  WordPress:        $([ "$WP_CHANNEL" = "stable" ] && echo "Stable" || echo "Beta/Nightly")"

set +e
ver="$(run_wp core version 2>/dev/null)"
set -e
[ -n "$ver" ] && echo "  WP Version:       $ver"

echo ""
if [ "${#PLUGIN_LINK_NAMES[@]}" -gt 0 ]; then
  echo "Plugin Symlinks: Yes (${#PLUGIN_LINK_NAMES[@]} items)"
  for i in "${!PLUGIN_LINK_NAMES[@]}"; do
    echo "  • ${PLUGIN_LINK_NAMES[$i]}  ←  ${PLUGIN_LINK_PATHS[$i]}"
  done
else
  echo "Plugin Symlinks: No"
fi

echo ""
echo -e "${YELLOW}Next Steps:${NC}"
echo "1. Open http://$WP_URL in your browser"
echo "2. Login with $WP_ADMIN_USER / $WP_ADMIN_PASSWORD"
echo "3. Test your features!"
echo ""
echo -e "${BLUE}Happy Testing! 🚀${NC}"