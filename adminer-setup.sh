#!/bin/bash

# ============================================
# adminer-setup.sh — Installiert und patcht Adminer für DBngin/Herd (macOS)
# Sicherheit: Fragt vor dem Löschen des Ordnerinhalts nach.
# ============================================
set -euo pipefail

# --- Konfiguration (manuell anpassen) ---
ADMINER_VERSION="5.4.1" # Aktuelle Version von Adminer.org prüfen!
ADMINER_LOCALE="de"     # Sprache: 'de' oder 'en'
DBNGIN_TYPE="mysql"     # Fuer DBngin ist 'mysql' (oder 'postgres') relevant

# --- NEU: Bedingte Suffix-Logik ---
ADMINER_SUFFIX=""
if [ "$ADMINER_LOCALE" = "de" ]; then
  ADMINER_SUFFIX="-de"
fi
# --------------------------------------

DOWNLOAD_URL="https://www.adminer.org/static/download/${ADMINER_VERSION}/adminer-${ADMINER_VERSION}-${DBNGIN_TYPE}${ADMINER_SUFFIX}.php"
TARGET_DIR="$HOME/Herd/adminer"
INDEX_FILE="$TARGET_DIR/index.php"

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ---------- Helper (confirm_yn) ----------
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
      *) echo -e "${YELLOW}Bitte y oder n eingeben.${NC}";;
    esac
  done
}
# -----------------------------------------------------------

trap 'echo -e "${RED}✗ Fehler in Zeile ${LINENO}: Befehl \"${BASH_COMMAND}\" ist fehlgeschlagen.${NC}"' ERR

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Adminer Setup für Herd/DBngin ${ADMINER_VERSION} (${ADMINER_LOCALE})${NC}"
echo -e "${BLUE}========================================${NC}"

# 1. Vorbereitung und Ordner erstellen
echo "→ Stelle sicher, dass der Zielordner existiert: $TARGET_DIR"
mkdir -p "$TARGET_DIR"

# Wechsel in den Adminer-Ordner
cd "$TARGET_DIR"

# 2. Sicherheits-Check und Löschen des Inhalts
if [ "$(find . -maxdepth 1 -mindepth 1 -not -name '.*' | wc -l)" -gt 0 ]; then
    echo -e "${YELLOW}⚠ Der Adminer-Ordner enthält bereits Dateien/Unterordner.${NC}"
    clear_dir="$(confirm_yn "Sollen ALLE Inhalte von '$TARGET_DIR' vor der Installation gelöscht werden?" "y")"
    if [ "$clear_dir" = "y" ]; then
        rm -rf *
        echo -e "${GREEN}✓ Ordnerinhalte gelöscht.${NC}"
    else
        echo -e "${RED}❌ Abbruch: Die Installation benötigt einen leeren Ordner, um die '$INDEX_FILE' korrekt zu platzieren.${NC}"
        exit 1
    fi
else
    echo -e "${GREEN}✓ Ordner ist leer.${NC}"
fi


# 3. Download
echo "→ Lade Adminer Core (${ADMINER_LOCALE}) herunter..."
echo "  URL: $DOWNLOAD_URL"
curl -fsSL -o "$INDEX_FILE" "$DOWNLOAD_URL"

if [ ! -f "$INDEX_FILE" ] || [ ! -s "$INDEX_FILE" ]; then
    echo -e "${RED}❌ Fehler: Download fehlgeschlagen. Bitte URL und ADMINER_VERSION prüfen.${NC}"
    exit 1
fi
echo -e "${GREEN}✓ Download erfolgreich.${NC}"

# 4. Patch der Core-Datei
echo "→ Patche die Core-Datei (entferne leere Passwort-Prüfung)..."

# FIX für "illegal byte sequence" auf macOS: LANG=C voranstellen.
LANG=C sed -i '' 's/if(\$G=="")return//' "$INDEX_FILE"

# Prüfen, ob der Patch erfolgreich war
if grep -q 'if($G=="")return' "$INDEX_FILE"; then
    echo -e "${YELLOW}⚠ Achtung: Der Patch-String wurde nicht gefunden oder das Patching ist fehlgeschlagen. ${NC}"
    echo "  Adminer funktioniert möglicherweise nur mit Passwort.${NC}"
else
    echo -e "${GREEN}✓ Patch erfolgreich angewendet.${NC}"
fi

# 5. Abschließende Hinweise
echo ""
echo -e "${GREEN}✅ Adminer-Setup abgeschlossen!${NC}"
echo "----------------------------------------------------"
echo "URL zum Öffnen:   http://adminer.test"
echo "Login:"
echo "  Server:         127.0.0.1"
echo "  Benutzer:       root"
echo "  Passwort:       [LEER LASSEN]"
echo "----------------------------------------------------"