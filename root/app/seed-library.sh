#!/usr/bin/env bash
# =============================================================================
# seed-library.sh  (runs as the `steam` user, BEFORE Steam starts)
# -----------------------------------------------------------------------------
# Registers DATA_DIR (default /data) as a Steam library folder by writing
# libraryfolders.vdf, because Steam's headless GUI won't let you add a path by
# hand and it only scans libraries listed in that file.
#
# Strategy: regenerate libraryfolders.vdf from scratch with two entries:
#   "0" -> the internal library (/config/.steam/debian-installation)
#   "1" -> DATA_DIR
# plus a libraryfolder.vdf marker inside DATA_DIR/steamapps. Steam fills in the
# per-library "apps" list itself from the appmanifest_*.acf files on start, so
# we only register the path.
#
# Env:
#   DATA_DIR  library mount to register (default /data)
#   LIBVDF    path to libraryfolders.vdf
# =============================================================================
set -euo pipefail

DATA_DIR="${DATA_DIR:-/data}"
STEAM_ROOT="/config/.steam/debian-installation"
LIBVDF="${LIBVDF:-${STEAM_ROOT}/steamapps/libraryfolders.vdf}"

log() { echo "[seed-library] $*"; }

mkdir -p "$(dirname "${LIBVDF}")"
mkdir -p "${DATA_DIR}/steamapps"

# --- marker in the library ROOT ---
# Steam places libraryfolder.vdf (singular) in the ROOT of each library folder,
# i.e. ${DATA_DIR}/libraryfolder.vdf — NOT inside steamapps/. A minimal one with
# contentid 0 is accepted; Steam rewrites it with the real contentid on scan.
if [[ ! -f "${DATA_DIR}/libraryfolder.vdf" ]]; then
    cat > "${DATA_DIR}/libraryfolder.vdf" <<'EOF'
"libraryfolder"
{
	"contentid"		"0"
	"label"		""
}
EOF
    log "wrote ${DATA_DIR}/libraryfolder.vdf"
fi
# Remove the misplaced marker a previous version wrote inside steamapps/.
rm -f "${DATA_DIR}/steamapps/libraryfolder.vdf" 2>/dev/null || true

# --- preserve the internal library's contentid if we already have one ---
internal_path="${STEAM_ROOT}"
internal_contentid="0"
if [[ -f "${LIBVDF}" ]]; then
    cid="$(grep -A6 '"0"' "${LIBVDF}" | grep -m1 '"contentid"' | sed -E 's/.*"contentid"[[:space:]]+"([0-9]*)".*/\1/' || true)"
    [[ -n "${cid}" ]] && internal_contentid="${cid}"
fi

# --- (re)write libraryfolders.vdf with both libraries ---
# Tabs are what Steam uses as indentation; keep them.
cat > "${LIBVDF}" <<EOF
"libraryfolders"
{
	"0"
	{
		"path"		"${internal_path}"
		"label"		""
		"contentid"		"${internal_contentid}"
		"totalsize"		"0"
		"update_clean_bytes_tally"		"0"
		"time_last_update_verified"		"0"
		"apps"
		{
		}
	}
	"1"
	{
		"path"		"${DATA_DIR}"
		"label"		""
		"contentid"		"0"
		"totalsize"		"0"
		"update_clean_bytes_tally"		"0"
		"time_last_update_verified"		"0"
		"apps"
		{
		}
	}
}
EOF
log "registered ${DATA_DIR} as library \"1\" in ${LIBVDF}"
