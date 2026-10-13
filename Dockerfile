# =============================================================================
# steam-client-headless-lite
# -----------------------------------------------------------------------------
# A minimal, headless Steam desktop client for DOWNLOADING a Steam game library
# and sharing it over the LAN via Steam's native Local Network Game Transfers.
# It never launches games, so it ships NO GPU/Vulkan drivers and NO desktop
# environment: only Mesa software rendering (llvmpipe) is installed so the Steam
# client's CEF/Chromium UI can render into a virtual framebuffer viewed over the
# web (noVNC).
#
# A light, linuxserver.io-style image: PUID/PGID/UMASK, tini as PID 1, gosu drop.
#
# -----------------------------------------------------------------------------
# LAYER ORDERING FOR BUILD CACHE
# -----------------------------------------------------------------------------
# Layers are ordered cheapest-to-invalidate LAST:
#   1. FROM + the single apt install (huge, ~hundreds of MB, rarely changes)
#   2. static tweaks that depend only on installed files (user, dirs, index.html)
#   3. init scripts (change often, but tiny)
#   4. runtime ENV defaults (ports, args — change often, zero-cost layers)
#   5. metadata (LABEL/EXPOSE/HEALTHCHECK/ENTRYPOINT)
# Nothing that changes frequently sits ABOVE the apt layer, so editing a port
# default or a script never re-triggers the expensive package download.
# =============================================================================
FROM debian:bookworm-slim

# Only the ENV that influences the apt install itself goes above the install
# layer. Everything else (ports, Mesa flags, PATH, HOME, PUID...) is set AFTER
# install so changing those values never invalidates the package layer.
ENV DEBIAN_FRONTEND=noninteractive

# -----------------------------------------------------------------------------
# Single install layer (the expensive one). steam-installer lives in contrib, so
# we rewrite the deb822 sources to add contrib (anchored sed, guarded by a grep),
# enable i386 multiarch for Steam's 32-bit libs, install the minimal
# GUI + VNC + Mesa-software + init stack, then purge apt lists.
#
# steam-installer's only debconf templates are steam/need-nvidia-i386 (preinst
# note, emitted ONLY when an Nvidia kernel module is present — never here) and
# steam/purge. It presents NO install-time EULA prompt, so there is nothing to
# pre-accept via debconf. DEBIAN_FRONTEND=noninteractive is the real safety net.
# The Steam Subscriber Agreement is accepted by the user in the GUI on first run.
#
# Versions are intentionally NOT pinned with `=`: xvfb, tzdata, websockify, tini
# and gosu carry point-release / binNMU churn in bookworm that would break an
# exact pin. We install by name and let apt resolve within the suite.
# -----------------------------------------------------------------------------
# The two cache mounts persist apt's package cache and lists across builds in the
# BuildKit builder (NOT in the final image). Even when this layer is invalidated,
# apt reuses already-downloaded .deb files instead of re-fetching them — a big
# saving on metered/limited connections. `sharing=locked` serialises concurrent
# builds. We must disable apt's own auto-clean (docker-clean) so the cache mount
# actually retains the .debs.
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    set -eux; \
    rm -f /etc/apt/apt.conf.d/docker-clean; \
    echo 'Binary::apt::APT::Keep-Downloaded-Packages "true";' > /etc/apt/apt.conf.d/keep-cache; \
    # --- enable contrib component (deb822 format in bookworm) ---
    if ! grep -q 'contrib' /etc/apt/sources.list.d/debian.sources; then \
        sed -i -E 's/^(Components:.*)$/\1 contrib/' /etc/apt/sources.list.d/debian.sources; \
    fi; \
    grep -q 'contrib' /etc/apt/sources.list.d/debian.sources; \
    # --- i386 multiarch for Steam ---
    dpkg --add-architecture i386; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        # Steam desktop client (contrib). Pulls steam-libs + steam-libs-i386,
        # zenity (first-run license/agreement dialog) and debconf.
        steam-installer \
        # Mesa software rendering only (llvmpipe) — NO GPU/Vulkan drivers.
        libgl1-mesa-dri \
        libgl1 \
        # Virtual framebuffer + minimal WM + VNC server.
        xvfb \
        openbox \
        x11vnc \
        # noVNC web client. The `websockify` CLI (/usr/bin/websockify) is
        # shipped by python3-websockify, a hard dependency of websockify; we
        # install both explicitly so the dependency is obvious.
        novnc \
        websockify \
        python3-websockify \
        # Init / privilege drop. gosu installs to /usr/sbin/gosu in bookworm.
        tini \
        gosu \
        # Supporting bits: X auth, xdpyinfo (readiness probe), ps, tz data,
        # dbus launcher for the Steam client, curl for HEALTHCHECK, CA certs.
        xauth \
        x11-utils \
        # wmctrl + xdotool: used by run.sh to force the steamwebhelper (CEF) UI
        # window to fill the screen (it opens tiny in the corner otherwise).
        wmctrl \
        xdotool \
        procps \
        tzdata \
        dbus-x11 \
        curl \
        ca-certificates \
    ; \
    # --- slim down the FINAL image ---
    # NOTE: with the apt cache mounts above, /var/cache/apt and /var/lib/apt are
    # build-time caches that are NOT written into the image layer, so there's no
    # need (and it would be counterproductive) to `apt-get clean` them here.
    # We only strip docs/man/info and temp dirs, which DO live in the layer.
    rm -rf /tmp/* /var/tmp/* \
           /usr/share/man/* /usr/share/doc/* /usr/share/info/*

# -----------------------------------------------------------------------------
# Static image setup that depends only on the installed packages. Kept in its
# own layer, AFTER the install, so it rebuilds cheaply and does not invalidate
# the package layer. The steam user is created with fixed 1000:1000; the real
# uid/gid remapping happens at runtime in entrypoint.sh from PUID/PGID, so the
# build-time values here are placeholders and intentionally NOT build args.
# -----------------------------------------------------------------------------
RUN set -eux; \
    groupadd -g 1000 steam; \
    useradd -u 1000 -g 1000 -d /config -s /usr/sbin/nologin -M steam; \
    mkdir -p /config /data; \
    chown -R steam:steam /config /data; \
    # X11 unix socket dir with sticky bit so Xvfb (as non-root) doesn't warn
    # "euid != 0 ... /tmp/.X11-unix will not be created".
    mkdir -p /tmp/.X11-unix; \
    chmod 1777 /tmp/.X11-unix
# noVNC ships vnc.html / vnc_lite.html / vnc_auto.html (vnc_auto.html -> vnc.html
# symlink). There is genuinely NO index.html; a custom one is provided by the
# COPY below (root/usr/share/novnc/index.html) that auto-redirects "/" into the
# client with autoconnect enabled. The HEALTHCHECK targets /vnc.html regardless.

# -----------------------------------------------------------------------------
# Bundled static assets that rarely change (noVNC landing page, Openbox config).
# Copied BEFORE the scripts so editing a script doesn't re-copy these.
# -----------------------------------------------------------------------------
COPY root/usr/ /usr/
COPY root/etc/ /etc/

# -----------------------------------------------------------------------------
# Init scripts (change often, but tiny). Copied LAST so a script edit only
# invalidates these two trailing layers.
# -----------------------------------------------------------------------------
COPY root/app/ /app/
RUN set -eux; \
    chmod +x /app/*.sh; \
    # Relocate the real zenity so our /usr/local/bin/zenity wrapper (copied via
    # root/usr/ above, and ahead of /usr/bin on PATH) can auto-accept Debian's
    # "Steam installer" confirmation dialog while passing every other zenity
    # call through to the real binary. steam-installer depends on zenity|yad so
    # the real binary is guaranteed present.
    if [ -x /usr/bin/zenity ] && [ ! -e /usr/bin/zenity.real ]; then \
        mv /usr/bin/zenity /usr/bin/zenity.real; \
    fi; \
    chmod +x /usr/local/bin/zenity

# -----------------------------------------------------------------------------
# Runtime ENV defaults (overridable at `docker run`/compose). These sit BELOW
# everything expensive, so editing a port or an arg produces a near-instant
# rebuild of only these trailing metadata layers.
# -----------------------------------------------------------------------------
ENV LIBGL_ALWAYS_SOFTWARE=1 \
    GALLIUM_DRIVER=llvmpipe \
    # steam-installer puts the launcher in /usr/games; make sure it's on PATH
    # (run.sh also resolves the binary explicitly as a belt-and-suspenders).
    PATH="/usr/games:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    HOME=/config \
    PUID=1000 \
    PGID=1000 \
    UMASK=022 \
    TZ=Etc/UTC \
    # High, uncommon defaults so they don't collide with typical host services
    # under network_mode: host (8080/5900 clash with proxies, panels, real VNC;
    # these also sit above Steam's native LAN port range).
    WEB_PORT=28080 \
    VNC_PORT=28090 \
    DISPLAY_NUM=99 \
    SCREEN_RES=1280x800x24 \
    VNC_PASSWORD="" \
    VNC_EXPOSE=false \
    CHOWN_ON_START=true \
    # STEAM_ARGS notes:
    #  -no-browser       : don't open the built-in web browser on launch.
    #  -cef-disable-gpu  : CRITICAL for headless. Under Xvfb + llvmpipe,
    #                      steamwebhelper's CEF renders its surfaces BLACK (the
    #                      window is up and menus work, but the UI never paints)
    #                      because ANGLE tries a GL backend that produces no
    #                      visible surface. Disabling CEF's GPU path forces a
    #                      software raster that actually paints. See Valve
    #                      steam-for-linux issue #10561.
    #  Do NOT use -silent: it minimises Steam to a (nonexistent) tray -> black.
    STEAM_ARGS="-no-browser -cef-disable-gpu"

LABEL org.opencontainers.image.title="Steam Headless Lite" \
      org.opencontainers.image.description="Headless Steam client for downloading and LAN-sharing a game library. No game execution, no GPU drivers." \
      org.opencontainers.image.source="https://github.com/RazorbreakRZ/steam-client-headless-lite" \
      org.opencontainers.image.licenses="MIT"

VOLUME ["/config", "/data"]

# Documentation only; actual published port is WEB_PORT (default 28080). Under
# the recommended network_mode: host these EXPOSE lines are informational.
EXPOSE 28080
EXPOSE 28090

# Web UI readiness. noVNC has no index.html of its own, hence the /vnc.html target.
HEALTHCHECK --interval=30s --timeout=5s --start-period=180s --retries=5 \
    CMD curl -fsS "http://127.0.0.1:${WEB_PORT}/vnc.html" >/dev/null || exit 1

# tini as PID 1 reaps zombies and forwards signals. entrypoint.sh fixes up the
# steam user's uid/gid from PUID/PGID, applies UMASK/TZ, then exec's gosu to drop
# to the steam user and run run.sh (the supervisor for Xvfb/Openbox/x11vnc/noVNC
# and the Steam client).
ENTRYPOINT ["/usr/bin/tini", "--", "/app/entrypoint.sh"]
