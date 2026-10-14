#!/usr/bin/env bash
# =============================================================================
# entrypoint.sh  (runs as ROOT, as tini's direct child)
# -----------------------------------------------------------------------------
# linuxserver.io-style startup:
#   1. Remap the `steam` user/group to PUID/PGID.
#   2. Apply UMASK and TZ.
#   3. Fix ownership of /config and /data (optional, CHOWN_ON_START).
#   4. exec gosu to drop privileges to `steam` and hand off to run.sh.
#
# gosu is used (not su) so the Steam process becomes tini's grandchild directly,
# keeping signal forwarding and zombie reaping intact.
# =============================================================================
set -euo pipefail

log()  { echo "[entrypoint] $*"; }
warn() { echo "[entrypoint][WARN] $*" >&2; }
die()  { echo "[entrypoint][FATAL] $*" >&2; exit 1; }

# ---- UMASK ----
if [[ -n "${UMASK:-}" ]]; then
    if [[ "${UMASK}" =~ ^[0-7]{3,4}$ ]]; then
        umask "${UMASK}"
        log "umask set to ${UMASK}"
    else
        warn "UMASK='${UMASK}' is not a valid octal mask; keeping default."
    fi
fi

# ---- Timezone ----
# Make TZ actually functional: point /etc/localtime at the zoneinfo file and
# record it in /etc/timezone. WARN and keep the image default if the zone is
# missing rather than failing the container.
if [[ -n "${TZ:-}" ]]; then
    if [[ -f "/usr/share/zoneinfo/${TZ}" ]]; then
        ln -sf "/usr/share/zoneinfo/${TZ}" /etc/localtime
        echo "${TZ}" > /etc/timezone
        log "timezone set to ${TZ}"
    else
        warn "TZ='${TZ}' not found in /usr/share/zoneinfo; using image default."
    fi
fi

# ---- Remap steam user/group to PUID/PGID ----
PUID="${PUID:-1000}"
PGID="${PGID:-1000}"
[[ "${PUID}" =~ ^[0-9]+$ ]] || die "PUID='${PUID}' is not numeric."
[[ "${PGID}" =~ ^[0-9]+$ ]] || die "PGID='${PGID}' is not numeric."

current_gid="$(getent group steam | cut -d: -f3 || true)"
current_uid="$(id -u steam 2>/dev/null || true)"

if [[ "${current_gid}" != "${PGID}" ]]; then
    log "remapping group steam -> GID ${PGID}"
    groupmod -o -g "${PGID}" steam
fi
if [[ "${current_uid}" != "${PUID}" ]]; then
    log "remapping user steam -> UID ${PUID}"
    usermod -o -u "${PUID}" steam
fi

# ---- Ownership of persistent volumes ----
# Default on; can be disabled on huge libraries where the recursive chown is slow
# and ownership is already correct.
if [[ "${CHOWN_ON_START:-true}" == "true" ]]; then
    log "ensuring ownership of /config and /data (CHOWN_ON_START=true)"
    chown steam:steam /config /data || true
    # /config is small (session/config); chown it recursively.
    chown -R steam:steam /config || true
    # /data (the library) may be enormous; only fix the top level by default.
    chown steam:steam /data || true
else
    log "CHOWN_ON_START=false; skipping ownership fixup"
fi

# ---- Register /data as a Steam library folder (pre-seed) ----
# Steam only looks for installed games in the folders listed in
# libraryfolders.vdf, and its headless GUI will not let you type an arbitrary
# path to add one. So, with Steam NOT yet running, we register /data ourselves:
#   1. drop a libraryfolder.vdf marker inside /data/steamapps
#   2. add a "/data" entry to the global libraryfolders.vdf (idempotent)
# Only done when /data/steamapps exists (i.e. a real library is mounted). Steam
# recalculates the per-library "apps" list from the appmanifest_*.acf files on
# start, so we only need to register the PATH, not every app.
STEAM_LIBVDF="/config/.steam/debian-installation/steamapps/libraryfolders.vdf"
if [[ -d /data/steamapps ]]; then
    if [[ ! -f "${STEAM_LIBVDF}" ]] || ! grep -q '"/data"' "${STEAM_LIBVDF}"; then
        log "registering /data as a Steam library folder in libraryfolders.vdf"
        /usr/sbin/gosu steam env DATA_DIR=/data LIBVDF="${STEAM_LIBVDF}" bash /app/seed-library.sh \
            || warn "could not pre-seed the Steam library; you may need to add it in the UI"
    else
        log "/data already registered as a Steam library"
    fi
fi

log "handing off to run.sh as user steam (uid=${PUID} gid=${PGID})"
exec /usr/sbin/gosu steam /app/run.sh
