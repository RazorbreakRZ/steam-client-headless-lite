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
XVFB_PID=""; OPENBOX_PID=""; X11VNC_PID=""; NOVNC_PID=""; STEAM_PID=""; WATCHDOG_PID=""; MAXIMISER_PID=""
shutting_down=0
cleanup_done=0

cleanup() {
    # Idempotent: the trap and the normal exit paths may both call this.
    [[ "${cleanup_done}" -eq 1 ]] && return 0
    cleanup_done=1
    shutting_down=1
    log "shutdown requested; stopping children in reverse order..."

    # Stop the watchdog and maximiser first so they don't fire during teardown.
    [[ -n "${WATCHDOG_PID}" ]] && kill -TERM "${WATCHDOG_PID}" 2>/dev/null || true
    [[ -n "${MAXIMISER_PID}" ]] && kill -TERM "${MAXIMISER_PID}" 2>/dev/null || true

    # Ask Steam to quit cleanly via its own command (lets it flush state), then
    # fall back to signalling the tracked PID. Steam spawns helpers
    # (steamwebhelper, reaper, ...) that must also be reaped.
    if [[ -n "${STEAM_BIN:-}" ]]; then
        "${STEAM_BIN}" -shutdown >/dev/null 2>&1 || true
    fi

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

    # Sweep any Steam helper processes left behind (best effort).
    pkill -TERM -f 'steamwebhelper' 2>/dev/null || true
    pkill -TERM -f '/steam/'        2>/dev/null || true
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
# 4b) Window maximiser (belt-and-suspenders for the Openbox rules).
#     The modern Steam UI is rendered by steamwebhelper (CEF). It opens its
#     window tiny (e.g. 200x200) in the corner and CEF can resize it AFTER map,
#     sometimes defeating Openbox's <application> rule — leaving a black
#     screen with a tiny window. This background loop repeatedly moves+resizes
#     any steam/steamwebhelper window to fill the screen, for a while after
#     start, then settles into an occasional nudge. Uses wmctrl + xdotool.
# ---------------------------------------------------------------------------
maximiser() {
    local w h deadline
    w="${SCREEN_RES%%x*}"                 # e.g. 1280
    local rest="${SCREEN_RES#*x}"
    h="${rest%%x*}"                        # e.g. 800
    deadline=$(( $(date +%s) + 600 ))      # actively fix for the first 10 min
    # Steam's CEF windows are often override-redirect: the window manager and
    # wmctrl (EWMH) cannot see or move them. xdotool operates on the raw X
    # window ID, so it CAN resize/move them. We search by window class and
    # resize every steamwebhelper window to fill the screen, skipping the tiny
    # helper/placeholder windows is unnecessary — enlarging them is harmless.
    while :; do
        [[ "${shutting_down}" -eq 1 ]] && return 0
        while read -r wid; do
            [[ -n "${wid}" ]] || continue
            # Resize + move by raw window ID (works on override-redirect windows).
            xdotool windowsize "${wid}" "${w}" "${h}" 2>/dev/null || true
            xdotool windowmove "${wid}" 0 0 2>/dev/null || true
        done < <(
            # Match the steamwebhelper window class on display :99. We do NOT use
            # --onlyvisible: Steam's CEF UI window is override-redirect and that
            # filter hides it. Search by class catches it by raw window ID.
            xdotool search --class "steamwebhelper" 2>/dev/null
        )
        if (( $(date +%s) > deadline )); then
            sleep 15
        else
            sleep 2
        fi
    done
}
maximiser &
MAXIMISER_PID=$!

# ---------------------------------------------------------------------------
# 5) Steam desktop client
#    First run: Steam shows the Subscriber Agreement in the noVNC window; the
#    user accepts it, logs in (user/password/Steam Guard), then adds /data as a
#    library folder. The authenticated session persists under /config (HOME).
#
#    Debian's steam-installer places the launcher at /usr/games/steam, which is
#    NOT on the default PATH for the non-root user in a slim image (that caused
#    an earlier `steam: command not found` / exit 127). Resolve the binary
#    explicitly across the known locations instead of relying on PATH.
# ---------------------------------------------------------------------------
STEAM_BIN=""
for candidate in /usr/games/steam /usr/bin/steam /usr/local/bin/steam; do
    if [[ -x "${candidate}" ]]; then
        STEAM_BIN="${candidate}"
        break
    fi
done
# Last resort: whatever is on PATH, if any.
if [[ -z "${STEAM_BIN}" ]]; then
    STEAM_BIN="$(command -v steam || true)"
fi
[[ -n "${STEAM_BIN}" ]] || die "Steam launcher not found (looked in /usr/games/steam, /usr/bin/steam, /usr/local/bin/steam and PATH)."

log "all infrastructure started. Web UI: http://<host>:${WEB_PORT}/vnc.html"

# ---------------------------------------------------------------------------
# Steam supervision loop.
#
# WHY A LOOP: Steam legitimately restarts ITSELF. After installing a client
# update it prints "Restarting Steam by request..." and the original steam.sh
# exits (commonly with code 71 / EX_OSERR) before relaunching. It also exits
# when the user quits from the UI. A one-shot `wait -n` would treat that normal
# self-restart as a crash and tear the whole container down — which is exactly
# what happened. So we run Steam in the FOREGROUND and relaunch it when it
# exits, unless we're shutting down. A sliding-window counter guards against a
# genuine crash-loop (Steam dying repeatedly in a short span).
#
# Meanwhile a lightweight watchdog checks the infrastructure PIDs; if Xvfb /
# x11vnc / noVNC die, that IS fatal and we exit so Docker restarts us clean.
# ---------------------------------------------------------------------------

STEAM_MAX_RESTARTS="${STEAM_MAX_RESTARTS:-5}"   # max restarts within the window
STEAM_RESTART_WINDOW="${STEAM_RESTART_WINDOW:-60}"  # seconds

# Infrastructure watchdog: runs in the background, exits (killing run.sh via a
# SIGTERM to the process group) if any core service dies while not shutting down.
infra_watchdog() {
    while :; do
        sleep 5
        [[ "${shutting_down}" -eq 1 ]] && return 0
        for svc_pid in "${XVFB_PID}" "${X11VNC_PID}" "${NOVNC_PID}"; do
            if [[ -n "${svc_pid}" ]] && ! kill -0 "${svc_pid}" 2>/dev/null; then
                warn "infrastructure process ${svc_pid} died; triggering shutdown."
                # Signal the main shell to tear down with a non-zero result.
                kill -TERM $$ 2>/dev/null || true
                return 1
            fi
        done
    done
}
infra_watchdog &
WATCHDOG_PID=$!

restart_count=0
window_start=$(date +%s)

while :; do
    log "starting Steam client: ${STEAM_BIN} ${STEAM_ARGS}"
    # Foreground: block here until THIS steam invocation exits.
    # shellcheck disable=SC2086
    "${STEAM_BIN}" ${STEAM_ARGS} &
    STEAM_PID=$!
    wait "${STEAM_PID}"
    code=$?
    STEAM_PID=""

    # Shutting down? Clean exit regardless of Steam's code.
    if [[ "${shutting_down}" -eq 1 ]]; then
        log "clean shutdown (signal received); exiting 0"
        cleanup
        exit 0
    fi

    # Steam exited on its own (self-restart after update, or user quit).
    now=$(date +%s)
    if (( now - window_start > STEAM_RESTART_WINDOW )); then
        # Window elapsed without a crash-loop; reset the counter.
        window_start=${now}
        restart_count=0
    fi
    restart_count=$((restart_count + 1))

    if (( restart_count > STEAM_MAX_RESTARTS )); then
        warn "Steam exited ${restart_count} times within ${STEAM_RESTART_WINDOW}s (last code ${code}); treating as a crash-loop."
        cleanup
        exit "${code}"
    fi

    log "Steam exited (code ${code}); relaunching (${restart_count}/${STEAM_MAX_RESTARTS} within ${STEAM_RESTART_WINDOW}s)..."
    sleep 2
done
