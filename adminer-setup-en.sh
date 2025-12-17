#!/bin/bash

# ============================================
# adminer-setup-en.sh — Installs and patches Adminer for DBngin/Herd (macOS)
# Security: Prompts before deleting folder contents.
# ============================================
set -euo pipefail

# --- Configuration (manual adjustment) ---
ADMINER_VERSION="5.4.1" # Check for the current version on Adminer.org!
ADMINER_LOCALE="en"     # Language: 'de' or 'en'
DBNGIN_TYPE="mysql"     # For DBngin, 'mysql' (or 'postgres') is relevant

# --- NEW: Conditional Suffix Logic ---
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
      *) echo -e "${YELLOW}Please enter y or n.${NC}";;
    esac
  done
}
# -----------------------------------------------------------

trap 'echo -e "${RED}✗ Error in line ${LINENO}: Command \"${BASH_COMMAND}\" failed.${NC}"' ERR

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Adminer Setup for Herd/DBngin ${ADMINER_VERSION} (${ADMINER_LOCALE})${NC}"
echo -e "${BLUE}========================================${NC}"

# 1. Preparation and folder creation
echo "→ Ensuring target folder exists: $TARGET_DIR"
mkdir -p "$TARGET_DIR"

# Change into the Adminer folder
cd "$TARGET_DIR"

# 2. Security Check and deleting contents (NEW, safe logic)
# Checks if the folder contains more than just hidden system files.
if [ "$(find . -maxdepth 1 -mindepth 1 -not -name '.*' | wc -l)" -gt 0 ]; then
    echo -e "${YELLOW}⚠ The Adminer folder already contains files/subfolders.${NC}"
    clear_dir="$(confirm_yn "Should ALL contents of '$TARGET_DIR' be deleted before installation?" "y")"
    if [ "$clear_dir" = "y" ]; then
        rm -rf *
        echo -e "${GREEN}✓ Folder contents deleted.${NC}"
    else
        echo -e "${RED}❌ Abort: The installation requires an empty folder to correctly place the '$INDEX_FILE'.${NC}"
        exit 1
    fi
else
    # Folder is empty, continue
    echo -e "${GREEN}✓ Folder is empty.${NC}"
fi


# 3. Download
echo "→ Downloading Adminer Core (${ADMINER_LOCALE})..."
echo "  URL: $DOWNLOAD_URL"
curl -fsSL -o "$INDEX_FILE" "$DOWNLOAD_URL"

# Check if the download was successful
if [ ! -f "$INDEX_FILE" ] || [ ! -s "$INDEX_FILE" ]; then
    echo -e "${RED}❌ Error: Download failed. Please check URL and ADMINER_VERSION.${NC}"
    exit 1
fi
echo -e "${GREEN}✓ Download successful.${NC}"

# 4. Patching the core file
# We patch to allow the passwordless 'root' access from DBngin.
echo "→ Patching core file (remove empty password check)..."

# FIX for "illegal byte sequence" on macOS: Prepend LANG=C to bypass BSD-sed's encoding check.
# We search for the critical part 'if($G=="")return' and replace it with nothing.
LANG=C sed -i '' 's/if(\$G=="")return//' "$INDEX_FILE"

# Check if the patch was successful: If the string is NOT found anymore, it's OK.
if grep -q 'if($G=="")return' "$INDEX_FILE"; then
    echo -e "${YELLOW}⚠ Warning: The patch string was not found or patching failed. ${NC}"
    echo "  Adminer may only work with a password.${NC}"
else
    echo -e "${GREEN}✓ Patch successfully applied.${NC}"
fi

# 5. Final notes
echo ""
echo -e "${GREEN}✅ Adminer Setup complete!${NC}"
echo "----------------------------------------------------"
echo "URL to open:   http://adminer.test"
echo "Login:"
echo "  Server:         127.0.0.1"
echo "  User:           root"
echo "  Password:       [LEAVE BLANK]"
echo "----------------------------------------------------"