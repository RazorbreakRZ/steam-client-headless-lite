#!/usr/bin/env bash
# =============================================================================
# run.sh  (runs as the unprivileged `steam` user, as tini's grandchild)
# -----------------------------------------------------------------------------
# Lightweight supervisor for the headless GUI stack + the Steam client:
#
#     Xvfb  ->  Openbox  ->  x11vnc  ->  noVNC/websockify  ->  Steam client
#
# Signal handling:
#   - We trap SIGTERM/SIGINT BEFORE starting any child, set a `shutting_down`
#     flag, and tear children down in reverse order.
#   - A single `wait -n` blocks on whichever child exits first.
#   - Clean stop (we received a signal)      -> exit 0.
#   - Steam (or any child) crashes on its own -> propagate its real exit code,
#     so the crash is visible in `docker logs`/health and in `on-failure`
#     restart policies. Under the shipped `restart: unless-stopped` the
#     container restarts regardless, but operators see a crash in the logs
#     rather than a masked clean stop.
# =============================================================================
set -uo pipefail

log()  { echo "[run] $*"; }
warn() { echo "[run][WARN] $*" >&2; }
die()  { echo "[run][FATAL] $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Validate / normalise environment
# ---------------------------------------------------------------------------
WEB_PORT="${WEB_PORT:-8080}"
VNC_PORT="${VNC_PORT:-5900}"
DISPLAY_NUM="${DISPLAY_NUM:-99}"
SCREEN_RES="${SCREEN_RES:-1280x800x24}"
VNC_PASSWORD="${VNC_PASSWORD:-}"
VNC_EXPOSE="${VNC_EXPOSE:-false}"
STEAM_ARGS="${STEAM_ARGS:--silent -no-browser}"

is_port() { [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 )); }

is_port "${WEB_PORT}" || die "WEB_PORT='${WEB_PORT}' is not a valid port (1-65535)."
is_port "${VNC_PORT}" || die "VNC_PORT='${VNC_PORT}' is not a valid port (1-65535)."
[[ "${DISPLAY_NUM}" =~ ^[0-9]+$ ]] || die "DISPLAY_NUM='${DISPLAY_NUM}' is not numeric."
[[ "${SCREEN_RES}" =~ ^[0-9]+x[0-9]+x[0-9]+$ ]] \
    || die "SCREEN_RES='${SCREEN_RES}' must look like WIDTHxHEIGHTxDEPTH, e.g. 1280x800x24."

export DISPLAY=":${DISPLAY_NUM}"

# ---------------------------------------------------------------------------
# VNC exposure matrix (security):
#   VNC_EXPOSE=false (default) -> bind x11vnc to localhost only. The LAN never
#                                 sees the raw RFB port; noVNC still works since
#                                 websockify connects over localhost.
#   VNC_EXPOSE=true            -> bind x11vnc on all interfaces, but ONLY if a
#                                 VNC_PASSWORD is set. Legacy VNC auth is weak, so
#                                 exposing an unauthenticated RFB port to the LAN
#                                 is refused (FATAL).
# ---------------------------------------------------------------------------
VNC_BIND_ARGS=(-localhost)
case "${VNC_EXPOSE}" in
    false) VNC_BIND_ARGS=(-localhost) ;;
    true)
        if [[ -z "${VNC_PASSWORD}" ]]; then
            die "VNC_EXPOSE=true requires VNC_PASSWORD to be set (refusing to expose an unauthenticated VNC port to the LAN)."
        fi
        VNC_BIND_ARGS=()
        ;;
    *) die "VNC_EXPOSE='${VNC_EXPOSE}' must be 'true' or 'false'." ;;
esac

# ---------------------------------------------------------------------------
# Child process tracking + signal handling
# ---------------------------------------------------------------------------
declare -a PIDS=()
XVFB_PID=""; OPENBOX_PID=""; X11VNC_PID=""; NOVNC_PID=""; STEAM_PID=""
shutting_down=0

cleanup() {
    shutting_down=1
    log "shutdown requested; stopping children in reverse order..."
    for pid in "${STEAM_PID}" "${NOVNC_PID}" "${X11VNC_PID}" "${OPENBOX_PID}" "${XVFB_PID}"; do
        if [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null; then
            kill -TERM "${pid}" 2>/dev/null || true
        fi
    done
    # give them a moment, then hard-kill stragglers
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        local alive=0
        for pid in "${STEAM_PID}" "${NOVNC_PID}" "${X11VNC_PID}" "${OPENBOX_PID}" "${XVFB_PID}"; do
            [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null && alive=1
        done
        [[ "${alive}" -eq 0 ]] && break
        sleep 0.5
    done
    for pid in "${STEAM_PID}" "${NOVNC_PID}" "${X11VNC_PID}" "${OPENBOX_PID}" "${XVFB_PID}"; do
        [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null && kill -KILL "${pid}" 2>/dev/null || true
    done
}
# Trap BEFORE starting any child.
trap cleanup SIGTERM SIGINT

wait_for_x() {
    log "waiting for X display ${DISPLAY} ..."
    for _ in $(seq 1 50); do
        if xdpyinfo -display "${DISPLAY}" >/dev/null 2>&1; then
            log "X display ${DISPLAY} is up."
            return 0
        fi
        sleep 0.2
    done
    die "X display ${DISPLAY} did not come up in time."
}

# ---------------------------------------------------------------------------
# 1) Xvfb — virtual framebuffer
# ---------------------------------------------------------------------------
log "starting Xvfb on ${DISPLAY} (${SCREEN_RES})"
Xvfb "${DISPLAY}" -screen 0 "${SCREEN_RES}" -nolisten tcp -ac &
XVFB_PID=$!
PIDS+=("${XVFB_PID}")
wait_for_x

# ---------------------------------------------------------------------------
# 2) Openbox — minimal window manager
# ---------------------------------------------------------------------------
log "starting Openbox"
openbox &
OPENBOX_PID=$!
PIDS+=("${OPENBOX_PID}")

# ---------------------------------------------------------------------------
# 3) x11vnc — VNC server bound to the Xvfb display
# ---------------------------------------------------------------------------
X11VNC_AUTH_ARGS=(-nopw)
if [[ -n "${VNC_PASSWORD}" ]]; then
    mkdir -p "${HOME}/.vnc"
    x11vnc -storepasswd "${VNC_PASSWORD}" "${HOME}/.vnc/passwd" >/dev/null 2>&1
    X11VNC_AUTH_ARGS=(-rfbauth "${HOME}/.vnc/passwd")
fi
log "starting x11vnc on :${VNC_PORT} (expose=${VNC_EXPOSE})"
x11vnc \
    -display "${DISPLAY}" \
    -rfbport "${VNC_PORT}" \
    -forever \
    -shared \
    -nolookup \
    -quiet \
    "${VNC_BIND_ARGS[@]}" \
    "${X11VNC_AUTH_ARGS[@]}" &
X11VNC_PID=$!
PIDS+=("${X11VNC_PID}")

# ---------------------------------------------------------------------------
# 4) noVNC / websockify — web access to the VNC session
#    The websockify CLI is provided by python3-websockify (dependency of the
#    websockify package). --web serves the noVNC static client.
# ---------------------------------------------------------------------------
log "starting noVNC/websockify web UI on :${WEB_PORT}"
websockify \
    --web /usr/share/novnc \
    "${WEB_PORT}" \
    "localhost:${VNC_PORT}" &
NOVNC_PID=$!
PIDS+=("${NOVNC_PID}")

# ---------------------------------------------------------------------------
# 5) Steam desktop client
#    First run: Steam shows the Subscriber Agreement in the noVNC window; the
#    user accepts it, logs in (user/password/Steam Guard), then adds /data as a
#    library folder. The authenticated session persists under /config (HOME).
# ---------------------------------------------------------------------------
log "starting Steam client (args: ${STEAM_ARGS})"
# shellcheck disable=SC2086
steam ${STEAM_ARGS} &
STEAM_PID=$!
PIDS+=("${STEAM_PID}")

log "all services started. Web UI: http://<host>:${WEB_PORT}/vnc.html"

# ---------------------------------------------------------------------------
# Wait for the first child to exit, then decide clean-vs-crash.
# ---------------------------------------------------------------------------
wait -n
code=$?

if [[ "${shutting_down}" -eq 1 ]]; then
    log "clean shutdown (signal received); exiting 0"
    cleanup
    exit 0
fi

warn "a child process exited unexpectedly (code ${code}); tearing down."
cleanup
exit "${code}"
