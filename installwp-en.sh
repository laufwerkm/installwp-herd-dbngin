#!/bin/bash

# ============================================
# installwp-en.sh — Local WordPress installer for Herd + DBngin (macOS)
#
# Credits / Original Idea:
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
# - Optional: PHP memory_limit for WP-CLI (Note: Herd-wp may ignore env)
# - WordPress Core: Stable or "Beta" (= Nightly Build)
# - Selectable language/locale
# - DB Check: Does DB already exist? optional drop or alternative DB name required
# - Plugins: individual confirmation (e.g., WooCommerce) + extra plugins (slugs)
# - Themes: Selection including Indio + Twenty Twenty-Five + Custom Themes
# - Arbitrarily many local plugin symlinks
# - Robust Core Download: WP-CLI, Fallback ZIP (to bypass WP-CLI Extractor memory errors)
# - Debug Log Symlink: Creation only on WP standard basis
# - NEW: debug-viewer.php script for live log watching (browser access)
# - NEW: SMTP configuration hints for Mailpit/Mailhog

set -euo pipefail

# --- CI/Tests: bash -n + Dry Run ---
# Tip: Check syntax via: bash -n <script>
# Dry Run: Executes all prompts, displays the plan, and exits without making changes.
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
BOLD='\033[1m'
NC='\033[0m'

# Plugin Path (ADJUST!)
PLUGIN_DEV_PATH="$HOME/Herd/plugins/wp-content/plugins/ki-bildgenerator"  # Your Plugin Development Folder

trap 'echo -e "${RED}${BOLD}✗ Error in line ${LINENO}: Command \"${BASH_COMMAND}\" failed.${NC}"' ERR

# ---------- Helpers ----------
confirm_yn() {
  # $1 prompt, $2 default (y/n)
  local prompt="$1"
  local def="${2:-y}"
  local ans=""
  while true; do
    if [ "$def" = "y" ]; then
      # If default is 'y', highlight Y. Use echo -e inside $(...) for robust coloring with read -p.
      read -r -p "$(echo -e "${prompt} (${GREEN}Y${NC}/n): ")" ans
      ans="${ans:-y}"
    else
      # If default is 'n', highlight N. Use echo -e inside $(...) for robust coloring with read -p.
      read -r -p "$(echo -e "${prompt} (y/${GREEN}N${NC}): ")" ans
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

  # mysql client: DBngin default path (may differ)
  if [ -d "/Users/Shared/DBngin/mysql" ]; then
    # Try to pick any version dir
    local mysqlbin
    mysqlbin="$(ls -d /Users/Shared/DBngin/mysql/*/bin 2>/dev/null | head -n 1 || true)"
    if [ -n "$mysqlbin" ]; then
      export PATH="$mysqlbin:$PATH"
    fi
  fi

  if ! command -v mysql >/dev/null 2>&1; then
    echo -e "${RED}✗ MySQL Client (mysql) not found.${NC}"
    echo -e "Start DBngin and ensure a MySQL/MariaDB service is running."
    echo -e "If you installed mysql locally, add it to the PATH."
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
  echo -e "Note: 'wp' may only be defined as a shell function/alias."
  echo -e "Please ensure an executable 'wp' is in PATH."
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

run_wp_best_effort() {
  # Best-effort wrapper: Executes the command in a subshell and returns the exit code
  # without triggering the main script's ERR trap.
  # This is useful for optional commands (e.g., plugin install) that might fail.
  ( set +e; run_wp "$@" >/dev/null 2>&1; return $? )
}

# ---------- Core download (WP-CLI first, ZIP fallback) ----------
# Args: channel (stable|nightly), locale (e.g. de_DE)

download_wp_core() {
  local channel="$1"     # stable|beta
  local locale="$2"      # de_DE, en_US, ...
  local version="$3"     # latest or specific version number
  local url="$4"         # optional: direct ZIP URL

  echo -e "${BLUE}Downloading WordPress...${NC}"

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
    # FIX: Replace {} with dict() for older Bash compatibility
    u=off.get('download') or (off.get('packages') or dict()).get('full') or ''
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
    # FIX: Replace {} with dict() for older Bash compatibility
    picked=off.get('download') or (off.get('packages') or dict()).get('full') or ''

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
    echo -e "${YELLOW}⚠ WP-CLI download/extraction failed – falling back to ZIP download.${NC}"
  else
    echo -e "${YELLOW}⚠ Beta channel selected – using ZIP download (more robust in Herd).${NC}"
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
    echo -e "${RED}Could not unzip the ZIP file.${NC}"
    rm -rf "$tmpdir"
    return 1
  fi

  if [ ! -d "${tmpdir}/wordpress" ]; then
    echo -e "${RED}Unzipped, but no 'wordpress/' folder found.${NC}"
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
echo "With Herd, WP-CLI can sometimes die with 128MB during extraction."
echo "The script has a ZIP fallback – but a higher limit can still help."
ans_mem="$(confirm_yn "Increase memory limit for WP-CLI?" "n")"
if [ "$ans_mem" = "y" ]; then
  read -r -p "New memory limit (e.g. 512M, 1024M) [${WP_CLI_MEMORY_LIMIT}]: " _ml
    _ml="$(trim "${_ml:-$WP_CLI_MEMORY_LIMIT}")"
    WP_CLI_MEMORY_LIMIT="$(normalize_mem_limit "$_ml")"
fi
  # Normalize as a safety measure (prevents "512 bytes")
  WP_CLI_MEMORY_LIMIT="$(normalize_mem_limit "$WP_CLI_MEMORY_LIMIT")"


# Best-effort: determine latest stable version (for Nightly label)
echo -e "${BLUE}• Trying to retrieve the latest stable WordPress version (Best-Effort)...${NC}" # <--- NEW status output
set +e # NEW: Disable immediate exit to ignore network errors
LATEST_STABLE_VERSION="$(
  curl -fsSL "https://api.wordpress.org/core/version-check/1.7/?channel=stable&locale=en_US" 2>/dev/null \
  | python3 -c 'import sys,json
try:
  d=json.load(sys.stdin)
  o=(d.get("offers") or [])
  print(o[0].get("version","") if o else "")
except Exception:
  print("")' 2>/dev/null
)"
set -e # NEW: Re-enable immediate exit
LATEST_STABLE_VERSION="${LATEST_STABLE_VERSION:-the last stable version}"
echo -e "${GREEN}✓ Stable version for label: ${LATEST_STABLE_VERSION}${NC}" # <--- NEW status output

echo ""

# ---------- WP channel + locale + specific version ----------
echo -e "${YELLOW}WordPress Channel:${NC}"
echo "1) Stable (Default)"
echo "2) Beta/RC (if available – may be unstable)"
echo "3) Nightly (Development build after ${LATEST_STABLE_VERSION}, unversioned)"
read -r -p "Select (1-3) [1]: " WP_CHANNEL_CHOICE
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
read -r -p "Locale (e.g. de_DE, en_US) [en_US]: " WP_LOCALE
WP_LOCALE="$(trim "${WP_LOCALE:-en_US}")"

echo ""
echo ""
echo -e "${YELLOW}WordPress Version (last 3) – Channel: ${API_CHANNEL}${NC}"

# Nightly: fixed URL, no version selection needed.
if [ "$WP_CHANNEL" = "nightly" ]; then
  WP_VERSION="nightly"
  WP_DOWNLOAD_URL="https://wordpress.org/nightly-builds/wordpress-latest.zip"

  # v23 PATCH: Show Nightly Build Info (Last-Modified + ETag, if available)
  _hdr="$(curl -fsSI "$WP_DOWNLOAD_URL" 2>/dev/null || true)"
  _lm="$(echo "$_hdr" | awk -F': ' 'tolower($1)=="last-modified"{print $2}' | tr -d '
' | head -n1 || true)"
  _etag="$(echo "$_hdr" | awk -F': ' 'tolower($1)=="etag"{print $2}' | tr -d '
' | head -n1 || true)"

  echo -n "• Nightly selected: wordpress-latest.zip"
  [ -n "${_lm:-}" ] && echo -n " (Last-Modified: ${_lm})"
  [ -n "${_etag:-}" ] && echo -n " (ETag: ${_etag})"
  echo ""
else
  # Fetches the last 3 versions (and download URLs) from the WordPress API.
  # Output format per line: version|url
  _offers=()
  _api_json="$(curl -fsSL "https://api.wordpress.org/core/version-check/1.7/?channel=${API_CHANNEL}&locale=${WP_LOCALE}" 2>/dev/null || true)"
  # v23 PATCH: if RCs are present, enforce RC-only + show hint
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
    # FIX: Replace {} with dict() for older Bash compatibility
    u=off.get("download") or (off.get("packages") or dict()).get("full") or ""
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
    # FIX: Replace {} with dict() for older Bash compatibility
    url=off.get('download') or (off.get('packages') or dict()).get('full') or ''
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
      echo -e "${YELLOW}⚠ The Beta/RC feed currently contains no pre-release versions. Using 'latest' (stable).
${NC}"
    else
      echo -e "${YELLOW}⚠ Could not load versions automatically – using 'latest'.${NC}"
    fi
    WP_VERSION="latest"
    WP_DOWNLOAD_URL=""
  else
    echo "1) ${_offers[0]%%|*}"
    [ "${#_offers[@]}" -ge 2 ] && echo "2) ${_offers[1]%%|*}"
    [ "${#_offers[@]}" -ge 3 ] && echo "3) ${_offers[2]%%|*}"
    echo "4) latest (automatic)"
    read -r -p "Select (1-4) [1]: " _vsel
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

echo ""
# ---------- Site name / URL / DB name (needed early) ----------
echo -e "${YELLOW}Project / Site Name:${NC}"
read -r -p "Installation folder under ~/Herd (e.g. mysite) [wp-testing]: " SITE_NAME
SITE_NAME="$(trim "${SITE_NAME:-wp-testing}")"

# Installation path (Herd)
SITE_ROOT="$HOME/Herd/$SITE_NAME"

# ---------- Install folder preflight: exists? delete or choose another ----------
# If the target folder already exists, we ask:
# - Delete? (rm -rf)
# - If no: choose a new folder name (until non-existent)
safe_rm_rf() {
  local target="$1"
  # Safety: only allow deleting inside ~/Herd and not the Herd root itself
  if [[ "$target" != "$HOME/Herd/"* ]] || [[ "$target" = "$HOME/Herd" ]] || [[ "$target" = "$HOME/Herd/" ]]; then
    echo -e "${RED}✗ Security Abort: would delete non-safe path: $target${NC}"
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
    echo -e "${YELLOW}Folder name cannot be empty.${NC}"
    SITE_NAME="wp-testing"
  fi
  SITE_ROOT="$HOME/Herd/$SITE_NAME"
done


# Herd typically uses .test
read -r -p "Domain (without http, e.g. mysite.test) [${SITE_NAME}.test]: " WP_DOMAIN
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
  echo "• If you installed mysql locally, add it to the PATH."
  exit 1
fi

echo -e "${GREEN}✓ MySQL connection OK.${NC}"

# If default DB exists: ask to drop or choose different DB name
if mysql_db_exists "$DB_NAME"; then
  echo -e "${YELLOW}⚠ Database '${DB_NAME}' already exists.${NC}"
  drop="$(confirm_yn "Should '${DB_NAME}' be dropped (DROP)?" "n")"
  if [ "$drop" = "y" ]; then
    mysql_exec "DROP DATABASE IF EXISTS \`${DB_NAME}\`;"
    echo -e "${GREEN}✓ Database '${DB_NAME}' dropped.${NC}"
  else
    echo -e "${YELLOW}Then a different database name must be used (not equal to folder name).${NC}"
    while true; do
      read -r -p "New DB Name: " _db
      _db="$(trim "$_db")"
      if [ -z "$_db" ]; then
        echo -e "${YELLOW}DB name cannot be empty.${NC}"
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

read -r -s -p "Admin Password (empty = auto-generate): " WP_ADMIN_PASSWORD
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

read -r -p "Admin Email (empty = admin@$WP_DOMAIN): " WP_ADMIN_EMAIL
WP_ADMIN_EMAIL="$(trim "${WP_ADMIN_EMAIL:-admin@$WP_DOMAIN}")"

# === FIX #1: Email Cleaning (ULTRA-ROBUST V3 - Iterative) ===
# Repeatedly removes all leading and trailing quotes (', ").
_tmp_email="$WP_ADMIN_EMAIL"

# Perform cleaning in a loop until no more changes occur.
while true; do
  _old_email="$_tmp_email"
  # Remove one pair of quotes at the start and end
  _tmp_email="$(echo "$_tmp_email" | sed "s/^['\"]//; s/['\"]$//")"
  # Trim after each Sed pass, in case there were spaces in between
  _tmp_email="$(trim "$_tmp_email")"
  
  # If the string has not changed, it is clean
  if [ "$_old_email" = "$_tmp_email" ]; then
    break
  fi
done

WP_ADMIN_EMAIL="$_tmp_email"


# ---------- Plugins (confirm each) + extras ----------
echo ""
echo -e "${YELLOW}Select Plugins (confirm each individually):${NC}"

# Always installed dev plugins (can still be skipped if you want)
INSTALL_QUERY_MONITOR="$(confirm_yn "Install Query Monitor?" "y")"
INSTALL_DEBUG_BAR="$(confirm_yn "Install Debug Bar?" "y")"
INSTALL_ADMINER="$(confirm_yn "Install Adminer (WP Adminer Plugin)?" "y")"

# NEW: SMTP Plugins
echo ""
echo -e "${YELLOW}Email Sending (Mail Catcher / SMTP):${NC}"
INSTALL_WP_MAIL_SMTP="$(confirm_yn "Install WP Mail SMTP? (Recommended for Herd/Mailpit)" "y")"
INSTALL_POST_SMTP="$(confirm_yn "Install Post SMTP Mailer/Email Log? (Alternative)" "n")"

echo ""
echo -e "${YELLOW}Known Plugins:${NC}"
INSTALL_WC="$(confirm_yn "Install WooCommerce?" "n")"
INSTALL_YOAST="$(confirm_yn "Install Yoast SEO?" "n")"
INSTALL_CF7="$(confirm_yn "Install Contact Form 7?" "n")"
INSTALL_ELEMENTOR="$(confirm_yn "Install Elementor?" "n")"
INSTALL_ACF="$(confirm_yn "Install Advanced Custom Fields (ACF)?" "n")"

EXTRA_PLUGINS=()
add_more_plugins="$(confirm_yn "Specify more plugins by slug?" "n")"
if [ "$add_more_plugins" = "y" ]; then
  echo "Enter Plugin Slugs (e.g., 'regenerate-thumbnails'). Empty input finishes."
  while true; do
    read -r -p "Plugin Slug (empty=done): " p
    p="$(trim "$p")"
    [ -z "$p" ] && break
    EXTRA_PLUGINS+=("$p")
  done
fi

# NEW: Debug Log Symlink Prompt
echo ""
echo -e "${YELLOW}Debug Log Comfort (Symlink / Viewer):${NC}"
INSTALL_DEBUG_SYMLINK="$(confirm_yn "Enable symlink in root for debug.log (points to wp-content/debug.log)?" "y")"
INSTALL_BROWSER_VIEWER="$(confirm_yn "Create browser log viewer (debug-viewer.php) in root?" "y")"

# ---------- Plugin symlinks ----------
# Target: wp-content/plugins/<name> -> <local path>
PLUGIN_LINK_PATHS=()
PLUGIN_LINK_NAMES=()

echo ""
echo -e "${YELLOW}Symlinks to local plugins:${NC}"
echo -e "${BLUE}Optional fixed Dev Path:${NC}"
# If Herd folder + Dev Plugin folder exist: ask if the symlink should be created.
if [ -d "$HOME/Herd" ] && [ -n "${PLUGIN_DEV_PATH:-}" ] && [ -d "$PLUGIN_DEV_PATH" ]; then
  echo "Found Dev Plugin folder:"
  echo "  $PLUGIN_DEV_PATH"
  use_dev="$(confirm_yn "Create symlink to this Dev Plugin folder?" "n")"
  if [ "$use_dev" = "y" ]; then
    _dev_name="$(basename "$PLUGIN_DEV_PATH")"
    PLUGIN_LINK_PATHS+=("$PLUGIN_DEV_PATH")
    PLUGIN_LINK_NAMES+=("$_dev_name")
    echo -e "${GREEN}✓ noted:${NC} $_dev_name  ←  $PLUGIN_DEV_PATH"
  else
    echo -e "${YELLOW}• Dev path skipped.${NC}"
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

    read -r -p "Symlink Name in wp-content/plugins (empty=folder name): " _name
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
read -r -p "Select (1-7) [1]: " THEME_CHOICE
THEME_CHOICE="${THEME_CHOICE:-1}"

CUSTOM_THEMES=()
CUSTOM_THEME_ACTIVATE=""
if [ "$THEME_CHOICE" = "7" ]; then
  echo "Enter Theme Slugs (e.g., 'generatepress'). Empty input finishes."
  while true; do
    read -r -p "Theme Slug (empty=done): " t
    t="$(trim "$t")"
    [ -z "$t" ] && break
    CUSTOM_THEMES+=("$t")
  done
  if [ "${#CUSTOM_THEMES[@]}" -gt 0 ]; then
    read -r -p "Which theme should be activated? (Slug, empty=first one): " act
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
echo "Plugins (install only):"
echo "  • Query Monitor:    $INSTALL_QUERY_MONITOR"
echo "  • Debug Bar:        $INSTALL_DEBUG_BAR"
echo "  • Adminer:          $INSTALL_ADMINER"
echo "  • WP Mail SMTP:     $INSTALL_WP_MAIL_SMTP"
echo "  • Post SMTP:        $INSTALL_POST_SMTP"
echo "  • WooCommerce:      $INSTALL_WC"
echo "  • Yoast SEO:        $INSTALL_YOAST"
echo "  • Contact Form 7:   $INSTALL_CF7"
echo "  • Elementor:        $INSTALL_ELEMENTOR"
echo "  • ACF:              $INSTALL_ACF"
if [ "${#EXTRA_PLUGINS[@]}" -gt 0 ]; then
  echo "  • Extra:            ${EXTRA_PLUGINS[*]}"
fi

echo ""
echo "Debugging:"
echo "  • Symlink debug.log: $INSTALL_DEBUG_SYMLINK"
echo "  • Browser Viewer:    $INSTALL_BROWSER_VIEWER"

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
  3) echo "  • Storefront (WooCommerce)" ;;
  4) echo "  • Astra" ;;
  5) echo "  • Indio" ;;
  6) echo "  • Default" ;;
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
  echo -e "${YELLOW}Dry Run active: No changes were made. Exiting after Summary.${NC}"
  exit 0
fi

# ============================================
# EXECUTION
# ============================================

# 1) Create site directory

echo ""
echo -e "${BLUE}[1/10] Creating Site Folder...${NC}"
mkdir -p "$SITE_ROOT"
cd "$SITE_ROOT"
echo -e "${GREEN}✓ Folder created: $PWD${NC}"

# 2) Create database

echo ""
echo -e "${BLUE}[2/10] Creating Database...${NC}"
mysql_exec "CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\`;"
echo -e "${GREEN}✓ Database '${DB_NAME}' ready.${NC}"

# 3) Download WordPress

echo ""
echo -e "${BLUE}[3/10] Installing WordPress Core...${NC}"
if command -v curl >/dev/null 2>&1; then
  echo "• Connectivity Check: wordpress.org ..."
  curl -Is https://wordpress.org/ | head -n 1 || true
  echo "• Connectivity Check: downloads.wordpress.org ..."
  curl -Is https://downloads.wordpress.org/ | head -n 1 || true
  # Check for locale specific download site
  if [[ "$WP_LOCALE" =~ ^(de|fr|es|it|ja|ko|pt|ru|zh)_ ]]; then
    _loc_prefix="${WP_LOCALE%%_*}"
    echo "• Connectivity Check: ${_loc_prefix}.wordpress.org ..."
    curl -Is https://${_loc_prefix}.wordpress.org/ | head -n 1 || true
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

echo ""
echo -e "${BLUE}[4/10] Creating wp-config...${NC}"
run_wp core config \
  --dbname="$DB_NAME" \
  --dbuser="$DB_USER" \
  --dbpass="$DB_PASSWORD" \
  --dbhost="$DB_HOST" \
  --dbprefix="$DB_PREFIX" \
  --skip-check \
  --locale="$WP_LOCALE"

if [ ! -f "wp-config.php" ]; then
  echo -e "${RED}✗ Could not create wp-config.php.${NC}"
  exit 1
fi
echo -e "${GREEN}✓ wp-config.php created.${NC}"

# 5) Add debug constants to wp-config.php (before happy blogging)
echo ""
echo -e "${BLUE}[5/10] Setting Debug Constants...${NC}"

# Set constants with WP-CLI (WP-CLI is better than manual sed editing)
run_wp config set WP_DEBUG true --type=constant --raw
run_wp config set WP_DEBUG_LOG true --type=constant --raw
run_wp config set WP_DEBUG_DISPLAY false --type=constant --raw
run_wp config set SCRIPT_DEBUG true --type=constant --raw

echo -e "${GREEN}✓ Debug constants set in wp-config.php.${NC}"


# 6) Core install

echo ""
echo -e "${BLUE}[6/10] Installing WordPress Core...${NC}"

# FIX: Remove all quotes around cleaned variables (prevents "" in database fields)
WP_INSTALL_COMMAND="core install \
  --url=$WP_URL \
  --title=$WP_TITLE \
  --admin_user=$WP_ADMIN_USER \
  --admin_password=$WP_ADMIN_PASSWORD \
  --admin_email=$WP_ADMIN_EMAIL \
  --skip-email"

if ! run_wp $WP_INSTALL_COMMAND; then
  echo -e "${RED}✗ WP-CLI core install failed.${NC}"
  echo "• Check if database ${DB_NAME} already contains data."
  exit 1
fi
echo -e "${GREEN}✓ WordPress Core installed.${NC}"

# 6.5) Correct Site URL (fixes https://https// error)
echo ""
echo -e "${BLUE}[6.5/10] Correcting Site URL...${NC}"

# Explicitly set siteurl and home options to fix the double-protocol problem.
# This is the most robust method to fix the double-protocol problem.
run_wp option update siteurl "$WP_URL" || true
run_wp option update home "$WP_URL" || true

echo -e "${GREEN}✓ Site URL corrected to ${WP_URL}.${NC}"

# 7) Install and activate theme

echo ""
echo -e "${BLUE}[7/10] Installing and Activating Theme...${NC}"

THEME_SLUG=""
case "$THEME_CHOICE" in
  1) THEME_SLUG="twentytwentyfive" ;;
  2) THEME_SLUG="twentytwentyfour" ;;
  3) THEME_SLUG="storefront" ;;
  4) THEME_SLUG="astra" ;;
  5) THEME_SLUG="indio" ;;
  6) THEME_SLUG="" ;;
  7) # Custom Themes
    if [ "${#CUSTOM_THEMES[@]}" -gt 0 ]; then
      echo "• Installing Custom Themes: ${CUSTOM_THEMES[*]}"
      for t in "${CUSTOM_THEMES[@]}"; do
        run_wp_best_effort theme install "$t"
      done
      THEME_SLUG="${CUSTOM_THEME_ACTIVATE}"
    fi
    ;;
esac

if [ -n "$THEME_SLUG" ]; then
  if run_wp_best_effort theme install "$THEME_SLUG"; then
    if run_wp_best_effort theme activate "$THEME_SLUG"; then
      echo -e "${GREEN}✓ Theme '${THEME_SLUG}' installed and activated.${NC}"
    else
      echo -e "${YELLOW}⚠ Theme '${THEME_SLUG}' installed, but could not be activated.${NC}"
    fi
  else
    echo -e "${YELLOW}⚠ Theme '${THEME_SLUG}' could not be installed. Default theme remains active.${NC}"
  fi
else
  echo "• No theme selected for installation/activation. Default theme remains active."
fi

# 8) Create Plugin Symlinks

echo ""
echo -e "${BLUE}[8/10] Creating Plugin Symlinks...${NC}"

if [ "${#PLUGIN_LINK_NAMES[@]}" -gt 0 ]; then
  for i in "${!PLUGIN_LINK_NAMES[@]}"; do
    _link_name="${PLUGIN_LINK_NAMES[$i]}"
    _target_path="${PLUGIN_LINK_PATHS[$i]}"
    _link_path="wp-content/plugins/$_link_name"

    if [ -e "$_link_path" ]; then
      echo -e "${YELLOW}• Attention: Link target already exists (wp-content/plugins/$_link_name). Skipping.${NC}"
      continue
    fi
    # FIX: Corrected syntax error: replaced '}' with 'fi'
    
    if [ "${DRY_RUN:-0}" -eq 1 ]; then
      echo "[dry-run] ln -s \"$_target_path\" \"$_link_path\""
    else
      # Create an absolute symlink to the development folder
      ln -s "$_target_path" "$_link_path"
      echo -e "${GREEN}✓ Symlink created: $_link_name ← $_target_path${NC}"
    fi
  done
else
  echo "• No plugin symlinks created."
fi

# 9) Install Plugins and Extras (without activation)

echo ""
echo -e "${BLUE}[9/10] Installing Plugins and Extras...${NC}"

PLUGINS_TO_INSTALL=()
[ "$INSTALL_QUERY_MONITOR" = "y" ] && PLUGINS_TO_INSTALL+=("query-monitor")
[ "$INSTALL_DEBUG_BAR" = "y" ] && PLUGINS_TO_INSTALL+=("debug-bar")
[ "$INSTALL_ADMINER" = "y" ] && PLUGINS_TO_INSTALL+=("adminer")
[ "$INSTALL_WP_MAIL_SMTP" = "y" ] && PLUGINS_TO_INSTALL+=("wp-mail-smtp")
[ "$INSTALL_POST_SMTP" = "y" ] && PLUGINS_TO_INSTALL+=("post-smtp")
[ "$INSTALL_WC" = "y" ] && PLUGINS_TO_INSTALL+=("woocommerce")
[ "$INSTALL_YOAST" = "y" ] && PLUGINS_TO_INSTALL+=("wordpress-seo")
[ "$INSTALL_CF7" = "y" ] && PLUGINS_TO_INSTALL+=("contact-form-7")
[ "$INSTALL_ELEMENTOR" = "y" ] && PLUGINS_TO_INSTALL+=("elementor")
[ "$INSTALL_ACF" = "y" ] && PLUGINS_TO_INSTALL+=("advanced-custom-fields")
PLUGINS_TO_INSTALL+=("${EXTRA_PLUGINS[@]:-}") # FIX: Null-safe expansion

if [ "${#PLUGINS_TO_INSTALL[@]}" -gt 0 ]; then
  echo "• Installing: ${PLUGINS_TO_INSTALL[*]}"
  
  # Remove silent wrapper to show WP-CLI error messages.
  # Use 'set +e' / 'set -e' to prevent script termination on error.
  
  set +e
  echo -e "${BLUE}--- WP-CLI Output (Start) ---${NC}"
  # run_wp passes output to stdout/stderr
  # FIX (v24): --skip-if-already-installed removed as it throws an error in older WP-CLI versions (Herd).
  run_wp plugin install "${PLUGINS_TO_INSTALL[@]}"
  WP_CLI_STATUS=$?
  echo -e "${BLUE}--- WP-CLI Output (End) ---${NC}"
  set -e

  if [ $WP_CLI_STATUS -eq 0 ]; then
    echo -e "${GREEN}✓ Plugins installed successfully (Exit Code 0).${NC}"
  else
    echo -e "${RED}✗ ERROR: Plugin installation with WP-CLI failed (Exit Code $WP_CLI_STATUS).${NC}"
    echo "  → Please check the console output above for WP-CLI error messages."
  fi
else
  echo "• No plugins selected for installation."
fi


# 10) Finalize Plugins and Language

echo ""
echo -e "${BLUE}[10/10] Finalizing Plugins and Language...${NC}"

# Activate all installed plugins (including symlinks if they exist now)
# run_wp_best_effort plugin activate --all # <--- LINE COMMENTED OUT (Activation not desired)
echo -e "${GREEN}✓ Plugin installation complete. No plugins were activated (as requested by user).${NC}"

# 10.1) Finalize language (if needed)
# Downloads language packs and ensures the backend uses the correct language.
run_wp_best_effort language core update >/dev/null 2>&1 || true
run_wp_best_effort language plugin update --all >/dev/null 2>&1 || true
echo -e "${GREEN}✓ Language finalization complete.${NC}"

# 10.2) Check Logging Functionality
echo ""
echo -e "${BLUE}[10.2/10] Checking Debug Log...${NC}"

DEBUG_LOG_PATH="wp-content/debug.log"
WP_CONTENT_DIR="wp-content"
CURRENT_USER=$(whoami)

# 1. Ensure file existence and set permissions (before write test)
if [ ! -d "$WP_CONTENT_DIR" ]; then mkdir -p "$WP_CONTENT_DIR"; fi
if [ ! -f "$DEBUG_LOG_PATH" ]; then touch "$DEBUG_LOG_PATH"; fi

# Set permissions before the test (for Herd/macOS standard)
chmod 775 "$WP_CONTENT_DIR" || true
chmod 664 "$DEBUG_LOG_PATH" 2>/dev/null || true


# 2. Write the test entry directly with file_put_contents (most robust method)
TEST_LOG_MESSAGE="[INSTALL-SCRIPT-TEST] Installation successfully completed and Debug Log function checked on $(date +'%Y-%m-%d %H:%M:%S')"

# The function writes directly to the file and ignores wp-config/error_log fallbacks.
PHP_COMMAND="file_put_contents(\"$WP_CONTENT_DIR/debug.log\", \"[\" . date('d-M-Y H:i:s') . \"] $TEST_LOG_MESSAGE\n\", FILE_APPEND);"
run_wp eval "$PHP_COMMAND" >/dev/null 2>&1


# 3. Check if the test was successful
if [ -f "$DEBUG_LOG_PATH" ] && grep -q "INSTALL-SCRIPT-TEST" "$DEBUG_LOG_PATH"; then
    echo -e "${GREEN}✓ Test entry successfully written to $DEBUG_LOG_PATH.${NC}"
    echo "  → Please check the file manually on the filesystem now."
else
    echo -e "${RED}✗ Could not find a test entry in $DEBUG_LOG_PATH.${NC}"
    echo "  → The error is now **exclusively** due to missing permissions or a global PHP lock."
    echo ""
    echo -e "${YELLOW}🚨 MANUAL CORRECTION REQUIRED (Permissions):${NC}"
    echo "  Please execute in the terminal (Your password is required):"
    echo -e "  ${BOLD}sudo chown -R $CURRENT_USER:staff $WP_CONTENT_DIR${NC}"
fi
echo -e "${GREEN}✓ Debug Log check complete.${NC}"

# NEW: 10.7 Debug Log Symlink
if [ "$INSTALL_DEBUG_SYMLINK" = "y" ]; then
  echo ""
  echo -e "${BLUE}[10.7/10] Creating Debug Log Symlink...${NC}" 

  if [ -e "$SITE_ROOT/debug.log" ]; then
    echo -e "${YELLOW}• Attention: $SITE_ROOT/debug.log already exists. Skipping symlink creation.${NC}"
  elif [ "${DRY_RUN:-0}" -eq 1 ]; then
    echo "[dry-run] ln -s \"wp-content/debug.log\" \"$SITE_ROOT/debug.log\""
  else
    # The target file (wp-content/debug.log) itself does not need to exist.
    ln -s "wp-content/debug.log" "$SITE_ROOT/debug.log"
    echo -e "${GREEN}✓ Relative symlink '$SITE_ROOT/debug.log' created (points to wp-content/debug.log).${NC}"
  fi
fi

# NEW: 10.8 Browser Log Viewer Script (debug-viewer.php)
if [ "$INSTALL_BROWSER_VIEWER" = "y" ]; then
  echo ""
  echo -e "${BLUE}[10.8/10] Creating Browser Debug Log Viewer (debug-viewer.php)...${NC}" 
  VIEWER_SCRIPT="debug-viewer.php"

  # The code for creating the PHP file
  cat > "$VIEWER_SCRIPT" <<'PHP_VIEWER'
<?php
/**
 * Browser Log Viewer for debug.log (Herd/local development only)
 *
 * Checks if WP_DEBUG_LOG is defined and safely outputs the log file content.
 * Does not cache the response in the browser.
 */

if ( ! file_exists( dirname( __FILE__ ) . '/wp-load.php' ) ) {
    die( 'Error: WordPress core not found.' );
}

// 1. Load WordPress to access constants like WP_CONTENT_DIR
require_once( dirname( __FILE__ ) . '/wp-load.php' );

// CORRECTED LINE: WP_CONTENT_DIR is now defined.
define( 'DEBUG_LOG_FILE', WP_CONTENT_DIR . '/debug.log' );


// 2. Check for required debug constants (security measure)
if ( ! ( defined( 'WP_DEBUG_LOG' ) && WP_DEBUG_LOG ) ) {
    header( 'Content-Type: text/plain' );
    die( "Error: WP_DEBUG_LOG is not set to true in wp-config.php. Log viewer disabled for security." );
}

// 3. Check file existence and readability
if ( ! file_exists( DEBUG_LOG_FILE ) || ! is_readable( DEBUG_LOG_FILE ) ) {
    header( 'Content-Type: text/plain' );
    die( "Error: Debug log file not found or unreadable:\n" . DEBUG_LOG_FILE );
}


// 4. Output the file content safely with "no cache" headers
header( 'Content-Type: text/plain; charset=utf-8' );
header( 'Cache-Control: no-store, no-cache, must-revalidate, max-age=0' );
header( 'Pragma: no-cache' );
header( 'Expires: Fri, 01 Jan 1990 00:00:00 GMT' );

// Output the full content
readfile( DEBUG_LOG_FILE );
PHP_VIEWER

  if [ "${DRY_RUN:-0}" -eq 1 ]; then
    echo "[dry-run] Creating PHP file: $VIEWER_SCRIPT"
  else
    echo -e "${GREEN}✓ PHP script '$VIEWER_SCRIPT' created.${NC}"
    echo "  → Accessible at: ${WP_URL}/$VIEWER_SCRIPT"
  fi
fi


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

# NEW: SMTP Hints
echo ""
echo -e "${YELLOW}EMAIL TESTING (Mailpit / Mailhog):${NC}"
if [ "$INSTALL_WP_MAIL_SMTP" = "y" ] || [ "$INSTALL_POST_SMTP" = "y" ]; then
  echo "You installed an SMTP plugin. Please configure it in the plugin settings:"
  echo -e "  • SMTP Host:        ${BOLD}127.0.0.1${NC} (or localhost)"
  echo -e "  • SMTP Port:        ${BOLD}1025${NC}"
  echo "  • Encryption:       None"
  echo "  • Authentication:   Off"
else
  echo "No specific SMTP plugin installed. Herd uses Mailpit by default (accessible via Herd App)."
fi

# NEW: Debug Viewer / Symlink Hint
echo ""
echo -e "${YELLOW}DEBUGGING COMFORT:${NC}"
if [ "$INSTALL_BROWSER_VIEWER" = "y" ]; then
    echo -e "${GREEN}Browser Viewer (Live):  ${BOLD}$WP_URL/debug-viewer.php${NC} (Shows the current log content without cache)"
fi
if [ "$INSTALL_DEBUG_SYMLINK" = "y" ]; then
    echo -e "${GREEN}Debug Log Symlink:      $WP_URL/debug.log (If Herd/webserver allows symlinks)"
fi
echo -e "Terminal Live Viewer: ${BOLD}cd $SITE_ROOT && tail -f wp-content/debug.log${NC}"

echo "Enjoy debugging!"