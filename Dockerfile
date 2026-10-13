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
# =============================================================================
FROM debian:bookworm-slim

LABEL org.opencontainers.image.title="Steam Headless Lite" \
      org.opencontainers.image.description="Headless Steam client for downloading and LAN-sharing a game library. No game execution, no GPU drivers." \
      org.opencontainers.image.source="https://github.com/RazorbreakRZ/steam-client-headless-lite" \
      org.opencontainers.image.licenses="MIT"

# Non-interactive apt is the real safety net here. steam-installer's only debconf
# templates are steam/need-nvidia-i386 (preinst note, emitted ONLY when an Nvidia
# kernel module is present — never in this driverless container) and steam/purge.
# It presents NO install-time EULA prompt, so there is nothing to pre-accept via
# debconf-set-selections. The Steam Subscriber Agreement is accepted by the user
# in the GUI on first launch (see README first-run flow).
ENV DEBIAN_FRONTEND=noninteractive \
    LIBGL_ALWAYS_SOFTWARE=1 \
    GALLIUM_DRIVER=llvmpipe \
    # steam-installer puts the launcher in /usr/games; make sure it's on PATH
    # (run.sh also resolves the binary explicitly as a belt-and-suspenders).
    PATH="/usr/games:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    # ----- Runtime defaults (overridable at `docker run`/compose) -----
    PUID=1000 \
    PGID=1000 \
    UMASK=022 \
    TZ=Etc/UTC \
    # High, uncommon defaults chosen so they don't collide with typical host
    # services under network_mode: host (8080/5900 clash with proxies, panels,
    # and real VNC servers; these also sit above Steam's native LAN port range).
    WEB_PORT=28080 \
    VNC_PORT=28090 \
    DISPLAY_NUM=99 \
    SCREEN_RES=1280x800x24 \
    VNC_PASSWORD="" \
    VNC_EXPOSE=false \
    CHOWN_ON_START=true \
    STEAM_ARGS="-silent -no-browser" \
    HOME=/config

# -----------------------------------------------------------------------------
# Single install layer. steam-installer lives in contrib, so we rewrite the
# deb822 sources to add contrib (anchored sed, guarded by a grep so we only
# touch it once), enable i386 multiarch for Steam's 32-bit libs, install the
# minimal GUI + VNC + Mesa-software + init stack, then purge apt lists.
#
# Versions are intentionally NOT pinned with `=`: xvfb, tzdata, websockify, tini
# and gosu carry point-release / binNMU churn in bookworm that would break an
# exact pin. We install by name and let apt resolve within the suite. Known-good
# versions at authoring time are noted in comments only.
# -----------------------------------------------------------------------------
RUN set -eux; \
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
        # noVNC web client. The `websockify` CLI (/usr/bin/websockify) is actually
        # shipped by python3-websockify, a hard dependency of the websockify pkg;
        # we install both explicitly so the dependency is obvious.
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
        procps \
        tzdata \
        dbus-x11 \
        curl \
        ca-certificates \
    ; \
    # noVNC ships vnc.html / vnc_lite.html / vnc_auto.html (vnc_auto.html is a
    # symlink to vnc.html). There is genuinely NO index.html, so create one so
    # the web root "/" and the HEALTHCHECK on /vnc.html both resolve cleanly.
    ln -sf vnc.html /usr/share/novnc/index.html; \
    # --- non-root runtime user; IDs are re-mapped at start by entrypoint.sh ---
    groupadd -g "${PGID}" steam; \
    useradd -u "${PUID}" -g "${PGID}" -d /config -s /usr/sbin/nologin -M steam; \
    mkdir -p /config /data; \
    chown -R steam:steam /config /data; \
    # X11 unix socket dir: pre-create with the sticky bit so Xvfb (running as the
    # non-root steam user) doesn't warn "euid != 0 ... /tmp/.X11-unix will not be
    # created" and so the socket lands in a dir everyone can use.
    mkdir -p /tmp/.X11-unix; \
    chmod 1777 /tmp/.X11-unix; \
    # --- slim down ---
    apt-get clean; \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* \
           /usr/share/man/* /usr/share/doc/* /usr/share/info/*

# Init scripts: COPY root/ / maps root/app/*.sh -> /app/*.sh
COPY root/ /
RUN chmod +x /app/*.sh

VOLUME ["/config", "/data"]

# Documentation only; actual published port is WEB_PORT (default 28080). Under the
# recommended network_mode: host these EXPOSE lines are informational.
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
