#!/bin/bash

# ============================================
# installwp-de.sh — Local WordPress installer for Herd + DBngin (macOS)
#
# Credits / Ursprungsidee:
# - Brian Coords: https://www.briancoords.com/local-wordpress-with-herd-dbngin-and-wp-cli/
#   GitHub: https://github.com/bacoords
# - Riza (ursprüngliches Script): https://github.com/rizaardiyanto1412/rizaardiyanto1412/blob/main/installwp.sh
#
# Weiterentwicklung/Iteration:
# - Roman Mahr (Use-Case, Tests, Anforderungen)
# - ChatGPT (Refactor/Robustheit/UX-Iterationen)
#
# Lizenz: MIT (siehe LICENSE)
# Haftungsausschluss: "AS IS" – Nutzung auf eigene Verantwortung, ohne Gewähr.
# ============================================


# ============================================
# WordPress Test-Installation Script (Herd + DBngin)
# ============================================
# Features:
# - Vorab-Checks: Herd & DBngin installiert? (mit Links)
# - Optional: PHP memory_limit für WP-CLI (Hinweis: Herd-wp kann env. ignorieren)
# - WordPress Core: Stable oder "Beta" (= Nightly Build)
# - Sprache/Locale frei wählbar
# - DB-Prüfung: Existiert DB bereits? optional Drop oder alternativen DB-Namen verlangen
# - Plugins: einzeln bestätigen (z.B. WooCommerce) + zusätzliche Plugins (Slugs)
# - Themes: Auswahl inkl. Indio + Twenty Twenty-Five + Custom Themes
# - Beliebig viele lokale Plugin-Symlinks
# - Robuster Core-Download: WP-CLI, Fallback ZIP (um WP-CLI Extractor memory errors zu umgehen)
# - Debug Log Symlink: Erstellung nur auf WP-Standardbasis
# - NEU: debug-viewer.php Script zum Live-Log-Watching (Browser-Zugriff)
# - NEU: SMTP-Konfigurations-Hinweise für Mailpit/Mailhog

set -euo pipefail

# --- CI/Tests: bash -n + Dry Run ---
# Tip: Syntax prüfen via: bash -n <script>
# Dry Run: Führt alle Abfragen aus, zeigt den Plan und beendet, ohne etwas zu ändern.
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

# Plugin-Pfad (ANPASSEN!)
PLUGIN_DEV_PATH="$HOME/Herd/plugins/wp-content/plugins/ki-bildgenerator"  # Dein Plugin-Entwicklungs-Ordner

trap 'echo -e "${RED}${BOLD}✗ Fehler in Zeile ${LINENO}: Befehl \"${BASH_COMMAND}\" ist fehlgeschlagen.${NC}"' ERR

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
      *) echo -e "${YELLOW}Bitte y oder n eingeben.${NC}";;
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
  echo -e "${BLUE}Vorab-Checks:${NC}"

  # Herd app
  if [ ! -d "/Applications/Herd.app" ] && [ ! -d "$HOME/Applications/Herd.app" ]; then
    echo -e "${RED}✗ Herd scheint nicht installiert zu sein.${NC}"
    echo -e "Bitte installiere Herd: ${BLUE}${HERD_LINK}${NC}"
    exit 1
  fi
  echo -e "${GREEN}✓ Herd gefunden.${NC}"

  # DBngin app
  if [ ! -d "/Applications/DBngin.app" ] && [ ! -d "$HOME/Applications/DBngin.app" ]; then
    echo -e "${RED}✗ DBngin scheint nicht installiert zu sein.${NC}"
    echo -e "Bitte installiere DBngin: ${BLUE}${DBNGIN_LINK}${NC}"
    exit 1
  fi
  echo -e "${GREEN}✓ DBngin gefunden.${NC}"

  # wp-cli
  if ! command -v wp >/dev/null 2>&1; then
    echo -e "${RED}✗ WP-CLI (wp) ist nicht im PATH.${NC}"
    echo -e "Tipp: Herd bringt häufig ein 'wp' mit; öffne Herd einmal und prüfe die CLI Tools."
    exit 1
  fi
  echo -e "${GREEN}✓ WP-CLI gefunden: $(command -v wp)${NC}"

  # mysql client: DBngin-Default-Pfad (kann abweichen)
  if [ -d "/Users/Shared/DBngin/mysql" ]; then
    # Try to pick any version dir
    local mysqlbin
    mysqlbin="$(ls -d /Users/Shared/DBngin/mysql/*/bin 2>/dev/null | head -n 1 || true)"
    if [ -n "$mysqlbin" ]; then
      export PATH="$mysqlbin:$PATH"
    fi
  fi

  if ! command -v mysql >/dev/null 2>&1; then
    echo -e "${RED}✗ MySQL-Client (mysql) nicht gefunden.${NC}"
    echo -e "Starte DBngin und stelle sicher, dass ein MySQL/MariaDB Service läuft."
    echo -e "Wenn du mysql lokal installiert hast, füge es zum PATH hinzu."
    exit 1
  fi
  echo -e "${GREEN}✓ mysql gefunden: $(command -v mysql)${NC}"

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
  echo -e "${RED}✗ Konnte den echten WP-CLI Binary-Pfad nicht ermitteln.${NC}"
  echo -e "Hinweis: 'wp' ist evtl. nur als Shell-Funktion/Alias definiert."
  echo -e "Bitte stelle sicher, dass ein ausführbares 'wp' im PATH liegt."
  exit 1
fi

PHP_BIN="$(type -P php 2>/dev/null || true)"
# Vermeide Shell-Funktionen/Aliase für php (kommt bei macOS/Herd vor).
# Fallbacks für typische Installationsorte:
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
  echo -e "${RED}✗ php (CLI) nicht gefunden.${NC}"
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
  # Best-effort wrapper: Führt den Befehl in einer Subshell aus und gibt den Exit-Code
  # zurück, ohne den ERR-Trap des Hauptskripts auszulösen.
  # Dies ist nützlich für optionale Befehle (z.B. plugin install), die fehlschlagen können.
  ( set +e; run_wp "$@" >/dev/null 2>&1; return $? )
}

# ---------- Core download (WP-CLI first, ZIP fallback) ----------
# Args: channel (stable|nightly), locale (e.g. de_DE)

download_wp_core() {
  local channel="$1"     # stable|beta
  local locale="$2"      # de_DE, en_US, ...
  local version="$3"     # latest oder konkrete Versionsnummer
  local url="$4"         # optional: direkte ZIP-URL

  echo -e "${BLUE}WordPress herunterladen…${NC}"

  # Falls keine URL übergeben wurde: versuche sie aus dem API zu holen (für „latest“).
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

  # 1) Stable: zuerst WP-CLI probieren (schnell), sonst ZIP-Fallback.
  if [ "$channel" = "stable" ]; then
    if [ "${version:-latest}" = "latest" ]; then
      if try_run_wp core download --locale="$locale"; then
        if [ -f "wp-load.php" ]; then
          echo -e "${GREEN}✓ WordPress via WP-CLI heruntergeladen.${NC}"
          return 0
        fi
      fi
    else
      if try_run_wp core download --version="$version" --locale="$locale"; then
        if [ -f "wp-load.php" ]; then
          echo -e "${GREEN}✓ WordPress ${version} via WP-CLI heruntergeladen.${NC}"
          return 0
        fi
      fi
    fi
    echo -e "${YELLOW}⚠ WP-CLI Download/Entpacken fehlgeschlagen – weiche auf ZIP-Download aus.${NC}"
  else
    echo -e "${YELLOW}⚠ Beta-Kanal gewählt – verwende ZIP-Download (robuster in Herd).${NC}"
  fi

  # 2) ZIP-Fallback (benötigt curl + unzip)
  if ! command -v curl >/dev/null 2>&1; then
    echo -e "${RED}curl fehlt. Bitte installieren (macOS: Xcode Command Line Tools).${NC}"
    return 1
  fi
  if ! command -v unzip >/dev/null 2>&1; then
    echo -e "${RED}unzip fehlt. Bitte installieren.${NC}"
    return 1
  fi

  if [ -z "${url:-}" ]; then
    echo -e "${RED}Keine Download-URL ermittelt (API/Netzwerk).${NC}"
    return 1
  fi

  echo -e "${BLUE}• Lade: ${url}${NC}"
  tmpdir="$(mktemp -d)"
  zipfile="${tmpdir}/wp.zip"

  if ! curl -fsSL -L "$url" -o "$zipfile"; then
    echo -e "${RED}ZIP-Download fehlgeschlagen.${NC}"
    rm -rf "$tmpdir"
    return 1
  fi

  if ! unzip -q "$zipfile" -d "$tmpdir"; then
    echo -e "${RED}ZIP konnte nicht entpackt werden.${NC}"
    rm -rf "$tmpdir"
    return 1
  fi

  if [ ! -d "${tmpdir}/wordpress" ]; then
    echo -e "${RED}Entpackt, aber kein „wordpress/“-Ordner gefunden.${NC}"
    rm -rf "$tmpdir"
    return 1
  fi

  cp -R "${tmpdir}/wordpress/." "$PWD/"
  rm -rf "$tmpdir"

  if [ ! -f "wp-load.php" ]; then
    echo -e "${RED}Download abgeschlossen, aber wp-load.php fehlt weiterhin.${NC}"
    return 1
  fi

  echo -e "${GREEN}✓ WordPress via ZIP-Download installiert.${NC}"
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
echo -e "${BLUE}WordPress Test-Installation${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

check_requirements

# ---------- Ask memory limit early ----------
echo -e "${YELLOW}WP-CLI Memory-Limit:${NC}"
echo "Bei Herd kann WP-CLI beim Entpacken manchmal mit 128MB sterben."
echo "Das Script hat einen ZIP-Fallback – trotzdem kann ein höheres Limit helfen."
ans_mem="$(confirm_yn "Memory-Limit für WP-CLI erhöhen?" "n")"
if [ "$ans_mem" = "y" ]; then
  read -r -p "Neues Memory-Limit (z.B. 512M, 1024M) [${WP_CLI_MEMORY_LIMIT}]: " _ml
    _ml="$(trim "${_ml:-$WP_CLI_MEMORY_LIMIT}")"
    WP_CLI_MEMORY_LIMIT="$(normalize_mem_limit "$_ml")"
fi
  # Sicherheitshalber immer normalisieren (verhindert "512 bytes")
  WP_CLI_MEMORY_LIMIT="$(normalize_mem_limit "$WP_CLI_MEMORY_LIMIT")"


# Best-effort: letzte Stable-Version ermitteln (für Nightly-Label)
echo -e "${BLUE}• Versuche, die neueste stabile WordPress-Version abzurufen (Best-Effort)...${NC}" # <--- NEUE Status-Ausgabe
set +e # NEU: Deaktiviere sofortigen Abbruch, um Netzwerkfehler zu ignorieren
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
set -e # NEU: Aktiviere sofortigen Abbruch wieder
LATEST_STABLE_VERSION="${LATEST_STABLE_VERSION:-der letzten Stable-Version}"
echo -e "${GREEN}✓ Stable-Version für Label: ${LATEST_STABLE_VERSION}${NC}" # <--- NEUE Status-Ausgabe

echo ""

# ---------- WP channel + locale + konkrete Version ----------
echo -e "${YELLOW}WordPress Kanal:${NC}"
echo "1) Stable (Standard)"
echo "2) Beta/RC (falls verfügbar – kann instabil sein)"
echo "3) Nightly (Entwicklungsstand nach ${LATEST_STABLE_VERSION}, nicht versioniert)"
read -r -p "Wählen Sie (1-3) [1]: " WP_CHANNEL_CHOICE
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
echo -e "${YELLOW}Sprache / Locale:${NC}"
read -r -p "Locale (z.B. de_DE, en_US) [de_DE]: " WP_LOCALE
WP_LOCALE="$(trim "${WP_LOCALE:-de_DE}")"

echo ""
echo ""
echo -e "${YELLOW}WordPress Version (letzte 3) – Kanal: ${API_CHANNEL}${NC}"

# Nightly: immer feste URL, keine Version-Auswahl nötig.
if [ "$WP_CHANNEL" = "nightly" ]; then
  WP_VERSION="nightly"
  WP_DOWNLOAD_URL="https://wordpress.org/nightly-builds/wordpress-latest.zip"

  # v23 PATCH: Nightly Build-Info anzeigen (Last-Modified + ETag, falls vorhanden)
  _hdr="$(curl -fsSI "$WP_DOWNLOAD_URL" 2>/dev/null || true)"
  _lm="$(echo "$_hdr" | awk -F': ' 'tolower($1)=="last-modified"{print $2}' | tr -d '
' | head -n1 || true)"
  _etag="$(echo "$_hdr" | awk -F': ' 'tolower($1)=="etag"{print $2}' | tr -d '
' | head -n1 || true)"

  echo -n "• Nightly gewählt: wordpress-latest.zip"
  [ -n "${_lm:-}" ] && echo -n " (Last-Modified: ${_lm})"
  [ -n "${_etag:-}" ] && echo -n " (ETag: ${_etag})"
  echo ""
else
  # Holt die letzten 3 Versionen (und Download-URLs) aus dem WordPress API.
  # Ausgabeformat je Zeile: version|url
  _offers=()
  _api_json="$(curl -fsSL "https://api.wordpress.org/core/version-check/1.7/?channel=${API_CHANNEL}&locale=${WP_LOCALE}" 2>/dev/null || true)"
  # v23 PATCH: wenn RCs vorhanden sind, RC-only erzwingen + Hinweis anzeigen
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
    u=off.get("download") or (off.get("packages") or dict()).get("full") or ""
    r=off.get("response") or ""
    if v and u and is_pre(v,u,r) and is_rc(v,u,r):
        print("y"); raise SystemExit
print("n")
PY
)"
    if [ "$RC_ONLY_ACTIVE" = "y" ]; then
      echo -e "${BLUE}• RC-only aktiv: RC-Versionen werden angeboten (falls vorhanden).${NC}"
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
    url=off.get('download') or (off.get('packages') or dict()).get('full') or ''
    resp=off.get('response') or ''
    if not v or not url:
        continue
    pre=is_prerelease(v,url,resp)

    # Channel filtering:
    # - stable: nur "saubere" Releases
    # - beta: nur Beta/RC/Alpha/Nightly Offers (falls verfügbar)
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
      echo -e "${YELLOW}⚠ Der Beta/RC-Feed enthält aktuell keine Vorab-Versionen. Verwende „latest“ (stable).
${NC}"
    else
      echo -e "${YELLOW}⚠ Konnte Versionen nicht automatisch laden – verwende „latest“.${NC}"
    fi
    WP_VERSION="latest"
    WP_DOWNLOAD_URL=""
  else
    echo "1) ${_offers[0]%%|*}"
    [ "${#_offers[@]}" -ge 2 ] && echo "2) ${_offers[1]%%|*}"
    [ "${#_offers[@]}" -ge 3 ] && echo "3) ${_offers[2]%%|*}"
    echo "4) latest (automatisch)"
    read -r -p "Wählen Sie (1-4) [1]: " _vsel
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
echo -e "${YELLOW}Projekt / Site-Name:${NC}"
read -r -p "Installationsordner unter ~/Herd (z.B. mysite) [wp-testing]: " SITE_NAME
SITE_NAME="$(trim "${SITE_NAME:-wp-testing}")"

# Installationspfad (Herd)
SITE_ROOT="$HOME/Herd/$SITE_NAME"

# ---------- Install folder preflight: exists? delete or choose another ----------
# Wenn der Zielordner bereits existiert, fragen wir:
# - Löschen? (rm -rf)
# - Wenn nein: neuen Ordnernamen wählen (bis nicht existent)
safe_rm_rf() {
  local target="$1"
  # Safety: only allow deleting inside ~/Herd and not the Herd root itself
  if [[ "$target" != "$HOME/Herd/"* ]] || [[ "$target" = "$HOME/Herd" ]] || [[ "$target" = "$HOME/Herd/" ]]; then
    echo -e "${RED}✗ Sicherheitsabbruch: würde nicht-sicheren Pfad löschen: $target${NC}"
    exit 1
  fi
  if [ "${DRY_RUN:-0}" -eq 1 ]; then
    echo "[dry-run] rm -rf \"$target\""
    return 0
  fi
  rm -rf "$target"
}

while [ -e "$SITE_ROOT" ]; do
  echo -e "${YELLOW}⚠ Der Installationsordner existiert bereits:${NC} $SITE_ROOT"
  del="$(confirm_yn "Soll der Ordner gelöscht werden?" "n")"
  if [ "$del" = "y" ]; then
    safe_rm_rf "$SITE_ROOT"
    echo -e "${GREEN}✓ Ordner gelöscht.${NC}"
    break
  fi
  echo -e "${YELLOW}Bitte einen anderen Ordnernamen wählen.${NC}"
  read -r -p "Neuer Installationsordner unter ~/Herd: " SITE_NAME
  SITE_NAME="$(trim "$SITE_NAME")"
  if [ -z "$SITE_NAME" ]; then
    echo -e "${YELLOW}Ordnername darf nicht leer sein.${NC}"
    SITE_NAME="wp-testing"
  fi
  SITE_ROOT="$HOME/Herd/$SITE_NAME"
done


# Herd nutzt typischerweise .test
read -r -p "Domain (ohne http, z.B. mysite.test) [${SITE_NAME}.test]: " WP_DOMAIN
WP_DOMAIN="$(trim "${WP_DOMAIN:-${SITE_NAME}.test}")"
WP_URL="https://${WP_DOMAIN}"

DEFAULT_DB_NAME="$SITE_NAME"
DB_NAME="$DEFAULT_DB_NAME"

echo ""
# ---------- DB preflight: connection + exists? drop/rename ----------
echo ""
echo -e "${BLUE}DB-Check (DBngin):${NC}"
if ! mysql_can_connect; then
  echo -e "${RED}✗ Kann nicht zu MySQL verbinden.${NC}"
  echo "• Bitte starte DBngin und einen MySQL/MariaDB Service (Port/Host: ${DB_HOST})."
  echo "• Wenn du mysql lokal installiert hast, füge es zum PATH hinzu."
  exit 1
fi

echo -e "${GREEN}✓ MySQL Verbindung ok.${NC}"

# If default DB exists: ask to drop or choose different DB name
if mysql_db_exists "$DB_NAME"; then
  echo -e "${YELLOW}⚠ Datenbank '${DB_NAME}' existiert bereits.${NC}"
  drop="$(confirm_yn "Soll '${DB_NAME}' gelöscht (DROP) werden?" "n")"
  if [ "$drop" = "y" ]; then
    mysql_exec "DROP DATABASE IF EXISTS \`${DB_NAME}\`;"
    echo -e "${GREEN}✓ Datenbank '${DB_NAME}' gelöscht.${NC}"
  else
    echo -e "${YELLOW}Dann muss ein anderer Datenbankname verwendet werden (ungleich Ordnername).${NC}"
    while true; do
      read -r -p "Neuer DB-Name: " _db
      _db="$(trim "$_db")"
      if [ -z "$_db" ]; then
        echo -e "${YELLOW}DB-Name darf nicht leer sein.${NC}"
        continue
      fi
      if [ "$_db" = "$DEFAULT_DB_NAME" ]; then
        echo -e "${YELLOW}Bitte einen anderen Namen als '${DEFAULT_DB_NAME}' wählen.${NC}"
        continue
      fi
      DB_NAME="$_db"
      if mysql_db_exists "$DB_NAME"; then
        echo -e "${YELLOW}DB '${DB_NAME}' existiert ebenfalls. Bitte anderen Namen wählen.${NC}"
        continue
      fi
      break
    done
  fi
elif [ $? -eq 2 ]; then
  echo -e "${YELLOW}⚠ Konnte DB-Existenz nicht prüfen (SQL-Fehler). Fahre fort.${NC}"
fi

# ---------- WP title + admin ----------
echo ""
read -r -p "Website-Titel (leer = $SITE_NAME): " WP_TITLE
WP_TITLE="$(trim "${WP_TITLE:-$SITE_NAME}")"

read -r -p "Admin Benutzername (leer = admin): " WP_ADMIN_USER
WP_ADMIN_USER="$(trim "${WP_ADMIN_USER:-admin}")"

read -r -s -p "Admin Passwort (leer = automatisch generieren): " WP_ADMIN_PASSWORD
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
  echo -e "${YELLOW}→ Passwort wurde automatisch generiert.${NC}"
fi

read -r -p "Admin E-Mail (leer = admin@$WP_DOMAIN): " WP_ADMIN_EMAIL
WP_ADMIN_EMAIL="$(trim "${WP_ADMIN_EMAIL:-admin@$WP_DOMAIN}")"

# === FIX #1: E-Mail-Bereinigung (ULTRA-ROBUST V3 - Iterativ) ===
# Entfernt wiederholt alle führenden und abschließenden Anführungszeichen (', ").
_tmp_email="$WP_ADMIN_EMAIL"

# Führe die Bereinigung in einer Schleife durch, bis keine Änderungen mehr erfolgen.
while true; do
  _old_email="$_tmp_email"
  # Entferne ein Paar Anführungszeichen am Anfang und Ende
  _tmp_email="$(echo "$_tmp_email" | sed "s/^['\"]//; s/['\"]$//")"
  # Nach jedem Sed-Durchlauf trimmen, falls Leerzeichen dazwischen waren
  _tmp_email="$(trim "$_tmp_email")"
  
  # Wenn der String sich nicht mehr geändert hat, ist er sauber
  if [ "$_old_email" = "$_tmp_email" ]; then
    break
  fi
done

WP_ADMIN_EMAIL="$_tmp_email"


# ---------- Plugins (confirm each) + extras ----------
echo ""
echo -e "${YELLOW}Plugins auswählen (jeweils einzeln bestätigen):${NC}"

# Always installed dev plugins (can still be skipped if you want)
INSTALL_QUERY_MONITOR="$(confirm_yn "Query Monitor installieren?" "y")"
INSTALL_DEBUG_BAR="$(confirm_yn "Debug Bar installieren?" "y")"
INSTALL_ADMINER="$(confirm_yn "Adminer (WP Adminer Plugin) installieren?" "y")"

# NEU: SMTP Plugins
echo ""
echo -e "${YELLOW}E-Mail Versand (Mail Catcher / SMTP):${NC}"
INSTALL_WP_MAIL_SMTP="$(confirm_yn "WP Mail SMTP installieren? (Empfohlen für Herd/Mailpit)" "y")"
INSTALL_POST_SMTP="$(confirm_yn "Post SMTP Mailer/Email Log installieren? (Alternative)" "n")"

echo ""
echo -e "${YELLOW}Bekannte Plugins:${NC}"
INSTALL_WC="$(confirm_yn "WooCommerce installieren?" "n")"
INSTALL_YOAST="$(confirm_yn "Yoast SEO installieren?" "n")"
INSTALL_CF7="$(confirm_yn "Contact Form 7 installieren?" "n")"
INSTALL_ELEMENTOR="$(confirm_yn "Elementor installieren?" "n")"
INSTALL_ACF="$(confirm_yn "Advanced Custom Fields (ACF) installieren?" "n")"

EXTRA_PLUGINS=()
add_more_plugins="$(confirm_yn "Weitere Plugins per Slug angeben?" "n")"
if [ "$add_more_plugins" = "y" ]; then
  echo "Gib Plugin-Slugs ein (z.B. 'regenerate-thumbnails'). Leere Eingabe beendet."
  while true; do
    read -r -p "Plugin-Slug (leer=fertig): " p
    p="$(trim "$p")"
    [ -z "$p" ] && break
    EXTRA_PLUGINS+=("$p")
  done
fi

# NEU: Abfrage Debug Log Symlink
echo ""
echo -e "${YELLOW}Debug Log Komfort (Symlink / Viewer):${NC}"
INSTALL_DEBUG_SYMLINK="$(confirm_yn "Symlink im Root für debug.log (zeigt auf wp-content/debug.log) aktivieren?" "y")"
INSTALL_BROWSER_VIEWER="$(confirm_yn "Browser-Log-Viewer (debug-viewer.php) im Root erstellen?" "y")"

# ---------- Plugin symlinks ----------
# Ziel: wp-content/plugins/<name> -> <local path>
PLUGIN_LINK_PATHS=()
PLUGIN_LINK_NAMES=()

echo ""
echo -e "${YELLOW}Symlinks zu lokalen Plugins:${NC}"
echo -e "${BLUE}Optionaler fester Dev-Pfad:${NC}"
# Wenn Herd-Ordner + Dev-Plugin-Ordner existieren: Nachfrage, ob der Symlink gesetzt werden soll.
if [ -d "$HOME/Herd" ] && [ -n "${PLUGIN_DEV_PATH:-}" ] && [ -d "$PLUGIN_DEV_PATH" ]; then
  echo "Gefundener Dev-Plugin-Ordner:"
  echo "  $PLUGIN_DEV_PATH"
  use_dev="$(confirm_yn "Symlink auf diesen Dev-Plugin-Ordner erstellen?" "n")"
  if [ "$use_dev" = "y" ]; then
    _dev_name="$(basename "$PLUGIN_DEV_PATH")"
    PLUGIN_LINK_PATHS+=("$PLUGIN_DEV_PATH")
    PLUGIN_LINK_NAMES+=("$_dev_name")
    echo -e "${GREEN}✓ vorgemerkt:${NC} $_dev_name  ←  $PLUGIN_DEV_PATH"
  else
    echo -e "${YELLOW}• Dev-Pfad wird übersprungen.${NC}"
  fi
fi

create_symlinks="$(confirm_yn "Symlinks zu lokalen Plugin-Ordnern erstellen?" "n")"
if [ "$create_symlinks" = "y" ]; then
  echo -e "${BLUE}Gib lokale Plugin-Pfade an. Leere Eingabe beendet.${NC}"
  while true; do
    read -r -p "Plugin-Pfad (leer=fertig): " _p
    _p="$(trim "$_p")"
    [ -z "$_p" ] && break

    if [ ! -d "$_p" ]; then
      echo -e "${YELLOW}⚠ Ordner nicht gefunden: $_p${NC}"
      keep="$(confirm_yn "Trotzdem aufnehmen?" "n")"
      [ "$keep" != "y" ] && continue
    fi

    read -r -p "Symlink-Name in wp-content/plugins (leer=Ordnername): " _name
    _name="$(trim "${_name:-$(basename "$_p")}")"

    PLUGIN_LINK_PATHS+=("$_p")
    PLUGIN_LINK_NAMES+=("$_name")

    echo -e "${GREEN}✓ vorgemerkt:${NC} $_name  ←  $_p"
  done
fi

# ---------- Theme selection + custom ----------
echo ""
echo -e "${YELLOW}Theme Auswahl:${NC}"
echo "1) Twenty Twenty-Five"
echo "2) Twenty Twenty-Four"
echo "3) Storefront (WooCommerce)"
echo "4) Astra"
echo "5) Indio (Brian Gardner)"
echo "6) Keins (Standard beibehalten)"
echo "7) Andere Themes per Slug (Custom)"
read -r -p "Wählen Sie (1-7) [1]: " THEME_CHOICE
THEME_CHOICE="${THEME_CHOICE:-1}"

CUSTOM_THEMES=()
CUSTOM_THEME_ACTIVATE=""
if [ "$THEME_CHOICE" = "7" ]; then
  echo "Gib Theme-Slugs ein (z.B. 'generatepress'). Leere Eingabe beendet."
  while true; do
    read -r -p "Theme-Slug (leer=fertig): " t
    t="$(trim "$t")"
    [ -z "$t" ] && break
    CUSTOM_THEMES+=("$t")
  done
  if [ "${#CUSTOM_THEMES[@]}" -gt 0 ]; then
    read -r -p "Welches Theme soll aktiviert werden? (Slug, leer=erstes): " act
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
  echo "Plugin-Symlinks: Ja (${#PLUGIN_LINK_NAMES[@]} Stück)"
  for i in "${!PLUGIN_LINK_NAMES[@]}"; do
    echo "  • ${PLUGIN_LINK_NAMES[$i]}  ←  ${PLUGIN_LINK_PATHS[$i]}"
  done
else
  echo "Plugin-Symlinks: Nein"
fi

echo ""
echo "Theme:"
case "$THEME_CHOICE" in
  1) echo "  • Twenty Twenty-Five" ;;
  2) echo "  • Twenty Twenty-Four" ;;
  3) echo "  • Storefront (WooCommerce)" ;;
  4) echo "  • Astra" ;;
  5) echo "  • Indio" ;;
  6) echo "  • Standard" ;;
  7)
    if [ "${#CUSTOM_THEMES[@]}" -eq 0 ]; then
      echo "  • Custom: (keine angegeben) → Standard"
    else
      echo -n "  • Custom: ${CUSTOM_THEMES[*]}"
      if [ -n "${CUSTOM_THEME_ACTIVATE:-}" ]; then
        echo " (activate: $CUSTOM_THEME_ACTIVATE)"
      else
        echo ""
      fi
    fi
    ;;
  *) echo "  • Standard" ;;
esac

echo -e "${GREEN}========================================${NC}"
if [ "$DRY_RUN" -eq 1 ]; then
  echo -e "${BLUE}Dry Run aktiv (--dry-run): keine Änderungen werden durchgeführt.${NC}"
  exit 0
fi

proceed="$(confirm_yn "Fortfahren?" "y")"
if [ "$proceed" != "y" ]; then
  echo "Installation abgebrochen."
  exit 0
fi

if [ "${DRY_RUN:-0}" -eq 1 ]; then
  echo ""
  echo -e "${YELLOW}Dry Run aktiv: Keine Änderungen wurden vorgenommen. Beende nach Summary.${NC}"
  exit 0
fi

# ============================================
# EXECUTION
# ============================================

# 1) Create site directory

echo ""
echo -e "${BLUE}[1/10] Erstelle Site-Ordner...${NC}"
mkdir -p "$SITE_ROOT"
cd "$SITE_ROOT"
echo -e "${GREEN}✓ Ordner erstellt: $PWD${NC}"

# 2) Create database

echo ""
echo -e "${BLUE}[2/10] Erstelle Datenbank...${NC}"
mysql_exec "CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\`;"
echo -e "${GREEN}✓ Datenbank '${DB_NAME}' bereit.${NC}"

# 3) Download WordPress

echo ""
echo -e "${BLUE}[3/10] WordPress Core installieren...${NC}"
if command -v curl >/dev/null 2>&1; then
  echo "• Connectivity-Check: wordpress.org ..."
  curl -Is https://wordpress.org/ | head -n 1 || true
  echo "• Connectivity-Check: downloads.wordpress.org ..."
  curl -Is https://downloads.wordpress.org/ | head -n 1 || true
  if [ "$WP_LOCALE" = "de_DE" ]; then
    echo "• Connectivity-Check: de.wordpress.org ..."
    curl -Is https://de.wordpress.org/ | head -n 1 || true
  fi
fi

download_wp_core "$WP_CHANNEL" "$WP_LOCALE" "$WP_VERSION" "${WP_DOWNLOAD_URL:-}"

# 4) Create wp-config

DB_PREFIX="wp_"

use_custom_prefix="$(confirm_yn "Einen eigenen Tabellenprefix erstellen? (Default: wp_)" "n")"
if [ "$use_custom_prefix" = "y" ]; then
  read -r -p "Prefix suffix (e.g. museum) [leave empty to keep wp_]: " DB_PREFIX_SUFFIX
  DB_PREFIX_SUFFIX="$(echo "${DB_PREFIX_SUFFIX:-}" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9_')"
  if [ -n "$DB_PREFIX_SUFFIX" ]; then
    DB_PREFIX="wp_${DB_PREFIX_SUFFIX}_"
  fi
fi

echo ""
echo -e "${BLUE}[4/10] wp-config erstellen...${NC}"
run_wp core config \
  --dbname="$DB_NAME" \
  --dbuser="$DB_USER" \
  --dbpass="$DB_PASSWORD" \
  --dbhost="$DB_HOST" \
  --dbprefix="$DB_PREFIX" \
  --skip-check \
  --locale="$WP_LOCALE"

if [ ! -f "wp-config.php" ]; then
  echo -e "${RED}✗ Konnte wp-config.php nicht erstellen.${NC}"
  exit 1
fi
echo -e "${GREEN}✓ wp-config.php erstellt.${NC}"

# 5) Add debug constants to wp-config.php (before happy blogging)
echo ""
echo -e "${BLUE}[5/10] Debug-Konstanten setzen...${NC}"

# Setze die Konstanten mit WP-CLI (WP-CLI ist besser als manuelle sed-Bearbeitung)
run_wp config set WP_DEBUG true --type=constant --raw
run_wp config set WP_DEBUG_LOG true --type=constant --raw
run_wp config set WP_DEBUG_DISPLAY false --type=constant --raw
run_wp config set SCRIPT_DEBUG true --type=constant --raw

echo -e "${GREEN}✓ Debug-Konstanten in wp-config.php gesetzt.${NC}"


# 6) Core install

echo ""
echo -e "${BLUE}[6/10] WordPress Core installieren...${NC}"

# FIX: Alle quotes um bereinigte Variablen entfernen (verhindert "" in Datenbankfeldern)
WP_INSTALL_COMMAND="core install \
  --url=$WP_URL \
  --title=$WP_TITLE \
  --admin_user=$WP_ADMIN_USER \
  --admin_password=$WP_ADMIN_PASSWORD \
  --admin_email=$WP_ADMIN_EMAIL \
  --skip-email"

if ! run_wp $WP_INSTALL_COMMAND; then
  echo -e "${RED}✗ WP-CLI core install ist fehlgeschlagen.${NC}"
  echo "• Prüfe, ob die Datenbank ${DB_NAME} bereits Daten enthält."
  exit 1
fi
echo -e "${GREEN}✓ WordPress Core installiert.${NC}"

# 6.5) Korrektur der Site-URL (behebt https://https// Fehler)
echo ""
echo -e "${BLUE}[6.5/10] Korrigiere Site-URL...${NC}"

# Setze siteurl und home Optionen explizit, um die Doppelung zu beheben.
# Dies ist die robusteste Methode, um das double-protocol problem zu fixen.
run_wp option update siteurl "$WP_URL" || true
run_wp option update home "$WP_URL" || true

echo -e "${GREEN}✓ Site-URL auf ${WP_URL} korrigiert.${NC}"

# 7) Theme installieren und aktivieren

echo ""
echo -e "${BLUE}[7/10] Theme installieren und aktivieren...${NC}"

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
      echo "• Installiere Custom Themes: ${CUSTOM_THEMES[*]}"
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
      echo -e "${GREEN}✓ Theme '${THEME_SLUG}' installiert und aktiviert.${NC}"
    else
      echo -e "${YELLOW}⚠ Theme '${THEME_SLUG}' installiert, konnte aber nicht aktiviert werden.${NC}"
    fi
  else
    echo -e "${YELLOW}⚠ Theme '${THEME_SLUG}' konnte nicht installiert werden. Standard-Theme aktiv.${NC}"
  fi
else
  echo "• Kein Theme zur Installation/Aktivierung ausgewählt. Standard-Theme bleibt aktiv."
fi

# 8) Plugin-Symlinks erstellen

echo ""
echo -e "${BLUE}[8/10] Plugin-Symlinks erstellen...${NC}"

if [ "${#PLUGIN_LINK_NAMES[@]}" -gt 0 ]; then
  for i in "${!PLUGIN_LINK_NAMES[@]}"; do
    _link_name="${PLUGIN_LINK_NAMES[$i]}"
    _target_path="${PLUGIN_LINK_PATHS[$i]}"
    _link_path="wp-content/plugins/$_link_name"

    if [ -e "$_link_path" ]; then
      echo -e "${YELLOW}• Achtung: Link-Ziel existiert bereits (wp-content/plugins/$_link_name). Überspringe.${NC}"
      continue
    fi

    if [ "${DRY_RUN:-0}" -eq 1 ]; then
      echo "[dry-run] ln -s \"$_target_path\" \"$_link_path\""
    else
      # Erstelle einen absoluten Symlink auf den Entwicklungs-Ordner
      ln -s "$_target_path" "$_link_path"
      echo -e "${GREEN}✓ Symlink erstellt: $_link_name ← $_target_path${NC}"
    fi
  done
else
  echo "• Keine Plugin-Symlinks erstellt."
fi

# 9) Plugins und Extras installieren (ohne Aktivierung)

echo ""
echo -e "${BLUE}[9/10] Plugins und Extras installieren...${NC}"

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
PLUGINS_TO_INSTALL+=("${EXTRA_PLUGINS[@]:-}") # FIX: Null-sichere Expansion

if [ "${#PLUGINS_TO_INSTALL[@]}" -gt 0 ]; then
  echo "• Installiere: ${PLUGINS_TO_INSTALL[*]}"
  
  # NEU: Entferne Silent-Wrapper, um WP-CLI-Fehlermeldungen zu sehen.
  # Verwende 'set +e' / 'set -e' um den Skript-Abbruch bei Fehler zu verhindern.
  
  set +e
  echo -e "${BLUE}--- WP-CLI Output (Start) ---${NC}"
  # run_wp gibt die Ausgabe an stdout/stderr weiter
  # FIX (v24): --skip-if-already-installed entfernt, da es in älteren WP-CLI-Versionen (Herd) einen Fehler wirft.
  run_wp plugin install "${PLUGINS_TO_INSTALL[@]}"
  WP_CLI_STATUS=$?
  echo -e "${BLUE}--- WP-CLI Output (End) ---${NC}"
  set -e

  if [ $WP_CLI_STATUS -eq 0 ]; then
    echo -e "${GREEN}✓ Plugins erfolgreich installiert (Exit Code 0).${NC}"
  else
    echo -e "${RED}✗ FEHLER: Plugin-Installation mit WP-CLI fehlgeschlagen (Exit Code $WP_CLI_STATUS).${NC}"
    echo "  → Bitte prüfen Sie die Konsolenausgabe oben auf Fehlermeldungen von WP-CLI."
  fi
else
  echo "• Keine Plugins zur Installation ausgewählt."
fi


# 10) Plugins aktivieren

echo ""
echo -e "${BLUE}[10/10] Plugins und Sprache finalisieren...${NC}"

# Aktiviere alle Plugins, die installiert wurden (inkl. Symlinks, wenn sie jetzt existieren)
# run_wp_best_effort plugin activate --all
echo -e "${GREEN}✓ Plugin-Installation abgeschlossen. Keine Plugins wurden aktiviert.${NC}"

# 10.1) Sprache finalisieren (wenn nötig)
# Lädt die Language Packs herunter und stellt sicher, dass das Backend die richtige Sprache verwendet.
run_wp_best_effort language core update >/dev/null 2>&1 || true
run_wp_best_effort language plugin update --all >/dev/null 2>&1 || true
echo -e "${GREEN}✓ Sprach-Finalisierung abgeschlossen${NC}"

# 10.2) Prüfe Logging-Funktionalität
echo ""
echo -e "${BLUE}[10.2/10] Prüfe Debug Log...${NC}"

DEBUG_LOG_PATH="wp-content/debug.log"
WP_CONTENT_DIR="wp-content"
CURRENT_USER=$(whoami)

# 1. Datei-Existenz sicherstellen und Berechtigungen setzen (vor dem Schreibtest)
if [ ! -d "$WP_CONTENT_DIR" ]; then mkdir -p "$WP_CONTENT_DIR"; fi
if [ ! -f "$DEBUG_LOG_PATH" ]; then touch "$DEBUG_LOG_PATH"; fi

# Setze die Berechtigungen vor dem Test (für Herd/macOS Standard)
chmod 775 "$WP_CONTENT_DIR" || true
chmod 664 "$DEBUG_LOG_PATH" 2>/dev/null || true


# 2. Schreibe den Test-Eintrag direkt mit file_put_contents (robusteste Methode)
TEST_LOG_MESSAGE="[INSTALL-SCRIPT-TEST] Installation erfolgreich abgeschlossen und Debug Log-Funktion geprüft am $(date +'%Y-%m-%d %H:%M:%S')"

# Die Funktion schreibt direkt in die Datei und ignoriert wp-config/error_log-Fallbacks.
PHP_COMMAND="file_put_contents(\"$WP_CONTENT_DIR/debug.log\", \"[\" . date('d-M-Y H:i:s') . \"] $TEST_LOG_MESSAGE\n\", FILE_APPEND);"
run_wp eval "$PHP_COMMAND" >/dev/null 2>&1


# 3. Prüfen, ob der Test erfolgreich war
if [ -f "$DEBUG_LOG_PATH" ] && grep -q "INSTALL-SCRIPT-TEST" "$DEBUG_LOG_PATH"; then
    echo -e "${GREEN}✓ Test-Eintrag erfolgreich in $DEBUG_LOG_PATH geschrieben.${NC}"
    echo "  → Bitte prüfen Sie jetzt die Datei manuell auf dem Dateisystem."
else
    echo -e "${RED}✗ Konnte keinen Test-Eintrag in $DEBUG_LOG_PATH finden.${NC}"
    echo "  → Der Fehler liegt nun **ausschließlich** an fehlenden Berechtigungen oder einem globalen PHP-Lock."
    echo ""
    echo -e "${YELLOW}🚨 MANUELLE KORREKTUR ERFORDERLICH (Berechtigungen):${NC}"
    echo "  Führen Sie bitte im Terminal aus (Ihr Passwort ist erforderlich):"
    echo -e "  ${BOLD}sudo chown -R $CURRENT_USER:staff $WP_CONTENT_DIR${NC}"
fi
echo -e "${GREEN}✓ Debug Log-Prüfung abgeschlossen.${NC}"

# NEU: 10.7 Debug Log Symlink
if [ "$INSTALL_DEBUG_SYMLINK" = "y" ]; then
  echo ""
  echo -e "${BLUE}[10.7/10] Debug Log Symlink erstellen...${NC}" 

  if [ -e "$SITE_ROOT/debug.log" ]; then
    echo -e "${YELLOW}• Achtung: $SITE_ROOT/debug.log existiert bereits. Überspringe Symlink-Erstellung.${NC}"
  elif [ "${DRY_RUN:-0}" -eq 1 ]; then
    echo "[dry-run] ln -s \"wp-content/debug.log\" \"$SITE_ROOT/debug.log\""
  else
    # Die Zieldatei (wp-content/debug.log) selbst muss nicht existieren.
    ln -s "wp-content/debug.log" "$SITE_ROOT/debug.log"
    echo -e "${GREEN}✓ Relativer Symlink '$SITE_ROOT/debug.log' erstellt (zeigt auf wp-content/debug.log).${NC}"
  fi
fi

# NEU: 10.8 Browser Log Viewer Script (debug-viewer.php)
if [ "$INSTALL_BROWSER_VIEWER" = "y" ]; then
  echo ""
  echo -e "${BLUE}[10.8/10] Browser Debug Log Viewer (debug-viewer.php) erstellen...${NC}" 
  VIEWER_SCRIPT="debug-viewer.php"

  # Der Code zur Erstellung der PHP-Datei
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

// KORRIGIERTE ZEILE: WP_CONTENT_DIR ist jetzt definiert.
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
    echo "[dry-run] Erstelle PHP-Datei: $VIEWER_SCRIPT"
  else
    echo -e "${GREEN}✓ PHP-Skript '$VIEWER_SCRIPT' erstellt.${NC}"
    echo "  → Aufrufbar unter: ${WP_URL}/$VIEWER_SCRIPT"
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
  echo "Plugin-Symlinks: Ja (${#PLUGIN_LINK_NAMES[@]} Stück)"
  for i in "${!PLUGIN_LINK_NAMES[@]}"; do
    echo "  • ${PLUGIN_LINK_NAMES[$i]}  ←  ${PLUGIN_LINK_PATHS[$i]}"
  done
else
  echo "Plugin-Symlinks: Nein"
fi

# NEU: SMTP Hinweise
echo ""
echo -e "${YELLOW}E-MAIL TESTING (Mailpit / Mailhog):${NC}"
if [ "$INSTALL_WP_MAIL_SMTP" = "y" ] || [ "$INSTALL_POST_SMTP" = "y" ]; then
  echo "Sie haben ein SMTP Plugin installiert. Bitte in den Plugin-Einstellungen konfigurieren:"
  echo -e "  • SMTP Host:        ${BOLD}127.0.0.1${NC} (oder localhost)"
  echo -e "  • SMTP Port:        ${BOLD}1025${NC}"
  echo "  • Encryption:       None"
  echo "  • Authentication:   Off"
else
  echo "Kein spezielles SMTP Plugin installiert. Herd nutzt standardmäßig Mailpit (erreichbar via Herd App)."
fi

# NEU: Debug Viewer / Symlink Hinweis
echo ""
echo -e "${YELLOW}DEBUGGING COMFORT:${NC}"
if [ "$INSTALL_BROWSER_VIEWER" = "y" ]; then
    echo -e "${GREEN}Browser Viewer (Live):  ${BOLD}$WP_URL/debug-viewer.php${NC} (Zeigt den aktuellen Inhalt des Logs ohne Cache)"
fi
if [ "$INSTALL_DEBUG_SYMLINK" = "y" ]; then
    echo -e "${GREEN}Debug Log Symlink:      $WP_URL/debug.log (Falls Herd/Webserver Symlinks erlaubt)"
fi
echo -e "Terminal Live Viewer: ${BOLD}cd $SITE_ROOT && tail -f wp-content/debug.log${NC}"

echo "Enjoy debugging!"