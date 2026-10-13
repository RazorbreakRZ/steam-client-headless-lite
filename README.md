# steam-client-headless-lite

A minimal, headless **Steam desktop client** in a Docker container, built for a
single job: **download a Steam game library and share it over the LAN** using
Steam's own native Local Network Game Transfers.

Think of it as a *light*, [linuxserver.io](https://www.linuxserver.io/)-style
image — but stripped down to the essentials for a download-and-share node.

## What it is — and what it is NOT

**It is:**

- A real Steam **desktop** client (not just `steamcmd`), running headless.
- A way to keep a persistent, logged-in Steam session that downloads games to a
  volume you control.
- A **native LAN content source**: other Steam clients on the same network can
  pull game content/updates from this node instead of re-downloading from the
  internet (Steam's *Local Network Game Transfers*).
- Operable entirely through a **web UI** (noVNC) — no local display needed.

**It is NOT:**

- A way to *play* games. It never launches titles.
- A GPU/streaming box. It ships **no GPU drivers**, **no Vulkan**, and **no
  desktop environment** — only Mesa **software** rendering (llvmpipe), which is
  the minimum needed for the Steam client's own UI to render into a virtual
  framebuffer.
- A LanCache replacement (see [LAN sharing](#lan-content-sharing) below).

## How it works

```
Xvfb  ->  Openbox  ->  x11vnc  ->  noVNC/websockify  ->  Steam client
(virtual   (minimal    (VNC        (web access on       (downloads to /data,
 display)   WM)         server)     WEB_PORT)             shares on the LAN)
```

- **Base:** `debian:bookworm-slim` with i386 multiarch (Steam needs 32-bit libs).
- **Steam:** Debian's `steam-installer` package (from `contrib`).
- **Rendering:** Mesa software only (`LIBGL_ALWAYS_SOFTWARE=1`, llvmpipe).
- **Init:** `tini` as PID 1, then `gosu` drops to a non-root `steam` user. A
  single bash supervisor (`run.sh`) starts the stack, forwards signals, and
  distinguishes a clean stop (exit 0) from a Steam crash (real exit code).
- **linuxserver-style** `PUID`/`PGID`/`UMASK` so files on the volumes get the
  ownership you want.

## Quick start

### With docker-compose (recommended)

1. Edit `docker-compose.yml`: set the `image:` namespace, `PUID`/`PGID`, `TZ`,
   and point the `steam-data` volume at your storage.
2. Start it:

   ```bash
   docker compose up -d
   ```

3. Open the web UI at `http://<host>:28080/` (it auto-connects, no "Connect"
   button) and follow [First-run setup](#first-run-setup).

### With docker run

```bash
docker run -d \
  --name steam-headless-lite \
  --network host \
  -e PUID=1000 -e PGID=1000 -e TZ=Europe/Madrid \
  -e WEB_PORT=28080 \
  -v steam-config:/config \
  -v /path/to/your/library:/data \
  razorbreak/steam-client-headless-lite:latest
```

> **Host networking is required** for native LAN sharing (see below). Make sure
> `WEB_PORT` is free on the host.

## First-run setup

Open `http://<host>:28080/` (the session auto-connects) and, **in this order**:

1. **Accept the Steam Subscriber Agreement.** On first launch the Steam client
   shows its license / Subscriber Agreement dialog in the noVNC window. This is
   normal — `steam-installer` does **not** accept any EULA at install time, so
   Steam presents it on first run. Accept it before anything else. (If the
   window looks plain, that's just llvmpipe software rendering — not a fault.)
2. **Log in.** Enter your Steam username, password, and Steam Guard code. The
   authenticated session is persisted to the `/config` volume, so you stay
   logged in across restarts.
3. **Add the library folder.** In Steam, go to *Settings → Storage*, add
   **`/data`** as a Steam library folder, and set it as the default download
   location.
4. **Download games.** Install the titles you want; they land in
   `/data/steamapps/`.

## Data persistence

| Volume    | Purpose                                                        |
|-----------|----------------------------------------------------------------|
| `/config` | `HOME` for the `steam` user: Steam session + client config. Keeps you logged in. Back this up to preserve your session. |
| `/data`   | The game library (`steamapps/`). Point this at your bulk storage. |

## LAN content sharing

This image relies on Steam's **native Local Network Game Transfers**: once two
Steam clients are logged in on the same LAN, one can serve game content and
updates to the other, avoiding a re-download from the internet.

- **Discovery is UDP broadcast (~27036); content transfer is TCP (~27040).**
  Broadcast discovery **cannot cross Docker's bridge NAT**, which is why this
  image is designed to run with **`network_mode: host`**. In bridge mode LAN
  peers will not discover this node.
- Relevant native Steam ports (used directly on the host under host networking):
  TCP/UDP `27015`–`27036`, UDP `27031`–`27036`, and the `~27036`/`~27040`
  discovery + transfer pair.
- **Web UI ports are deliberately uncommon.** Because host networking means the
  container binds the host's ports directly, the defaults avoid popular ports
  that commonly collide (8080, 5900, 9000, 8443, etc.): the web UI defaults to
  **`28080`** and the internal VNC port to **`28090`**. Both sit above Steam's
  native LAN port range, so there is no overlap. Override `WEB_PORT`/`VNC_PORT`
  if those are taken on your host.

> **LanCache alternative.** If native peer-to-peer sharing doesn't fit your
> setup (e.g. you can't use host networking, or you want to cache the Steam CDN
> for *all* devices transparently), consider running
> [LanCache](https://lancache.net/) alongside this container. LanCache is **not**
> bundled here — this image deliberately stays minimal.

## Environment variables

| Variable         | Default        | Description |
|------------------|----------------|-------------|
| `PUID`           | `1000`         | UID that owns files on the volumes. |
| `PGID`           | `1000`         | GID that owns files on the volumes. |
| `UMASK`          | `022`          | File-creation mask. |
| `TZ`             | `Etc/UTC`      | Timezone, e.g. `Europe/Madrid`. |
| `WEB_PORT`       | `28080`        | noVNC web UI port on the host. Deliberately uncommon to avoid clashes under host networking. |
| `VNC_PORT`       | `28090`        | Internal VNC (RFB) port. Deliberately uncommon (not the 5900 VNC default). |
| `DISPLAY_NUM`    | `99`           | X display number for Xvfb. |
| `SCREEN_RES`     | `1280x800x24`  | Virtual screen `WIDTHxHEIGHTxDEPTH`. |
| `VNC_PASSWORD`   | *(empty)*      | Optional VNC password. **Required** if `VNC_EXPOSE=true`. |
| `VNC_EXPOSE`     | `false`        | Expose the raw VNC port to the LAN. Requires a password or the container refuses to start. By default VNC binds to localhost and is reachable only through the web UI. |
| `CHOWN_ON_START` | `true`         | Fix ownership of `/config` (recursively) and `/data` (top level) at start. Set `false` on huge libraries where ownership is already correct. |
| `STEAM_ARGS`     | `-silent -no-browser` | Extra arguments passed to the Steam client. |

## CasaOS

The `docker-compose.yml` includes an `x-casaos` metadata block, so you can
import it as a CasaOS app:

1. In CasaOS, choose **Install a customized app** / import a compose file.
2. Paste or upload `docker-compose.yml`.
3. Set the image namespace, `WEB_PORT`, `TZ`, and the `/data` storage path.
4. Install, open the app's web UI, and follow [First-run setup](#first-run-setup).

The main entry point is the web UI on `WEB_PORT`. The CasaOS `index` opens noVNC
with `autoconnect=true`, so no "Connect" button is shown — the session connects
automatically. Opening the web root `/` works too: a bundled `index.html`
redirects into the client with the same autoconnect parameters.

## Building locally

```bash
docker build -t steam-client-headless-lite:local .
```

## GitHub Actions / publishing

Two workflows are provided:

- **`.github/workflows/docker-publish.yml`** — on every pushed **git tag**
  (`v*` or `*.*.*`), builds `linux/amd64` and **pushes** to Docker Hub, tagging
  the image with the version and `latest`.
- **`.github/workflows/docker-validate.yml`** — on pushes to the **`validate`**
  branch (and on pull requests), builds the image **without pushing**
  (`push: false`, `no-cache: true`) and runs `shellcheck` on the init scripts.
  Use this branch to validate intermediate changes before tagging a release.

### Required secrets

Add these in **GitHub → Settings → Secrets and variables → Actions**:

| Secret               | Value |
|----------------------|-------|
| `DOCKERHUB_USERNAME` | Your Docker Hub username (also used as the image namespace). |
| `DOCKERHUB_TOKEN`    | A Docker Hub **access token** (not your account password). |

### Changing the Docker Hub namespace / image name

The published image is
`${{ secrets.DOCKERHUB_USERNAME }}/steam-client-headless-lite`. The namespace
comes from the `DOCKERHUB_USERNAME` secret; to change the repository component,
edit the `images:` line in `docker-publish.yml`. Also update the `image:` field
in `docker-compose.yml` (replace `razorbreak`).

### Cutting a release

```bash
git tag v0.1.0
git push origin v0.1.0
```

This triggers `docker-publish.yml` and publishes
`<namespace>/steam-client-headless-lite:0.1.0` and `:latest`.

## License

MIT (add a `LICENSE` file). This project is not affiliated with Valve. Steam is
a trademark of Valve Corporation.
