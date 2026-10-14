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
  desktop environment** — only Mesa **software** rendering (llvmpipe). The Steam
  client's own UI is drawn by `steamwebhelper` (a CEF/Chromium process) which
  renders in software on the CPU; no GPU is required (or used).
- A LanCache replacement (see [LAN sharing](#lan-content-sharing) below).

## How it works

```
Xvfb  ->  Openbox  ->  x11vnc  ->  noVNC/websockify  ->  Steam client
(virtual   (minimal    (VNC        (web access on       (downloads to /data,
 display)   WM)         server)     WEB_PORT)             shares on the LAN)
```

- **Base:** `debian:bookworm-slim` with i386 multiarch (Steam needs 32-bit libs).
- **Steam:** Debian's `steam-installer` package (from `contrib`). The real
  client is downloaded into `/config` on first run and persists there.
- **Rendering:** software only. The client UI (`steamwebhelper`, CEF/Chromium)
  rasterises on the CPU; Mesa/llvmpipe is present for the few GL bits that need
  it. No GPU is used.
- **Init:** `tini` as PID 1, then `gosu` drops to a non-root `steam` user. A
  single bash supervisor (`run.sh`) starts the stack and forwards signals. It
  **relaunches Steam** when it restarts itself (e.g. after a client update,
  which exits with code 71) instead of tearing the container down, and a
  watchdog triggers a clean container exit only if the core infrastructure
  (Xvfb/x11vnc/noVNC) dies.
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
  --shm-size=2g \
  --security-opt seccomp=unconfined \
  --security-opt apparmor=unconfined \
  --cap-add SYS_ADMIN \
  -e PUID=1000 -e PGID=1000 -e TZ=Europe/Madrid \
  -e WEB_PORT=28080 \
  -v steam-config:/config \
  -v /path/to/your/library:/data \
  razorbreak/steam-client-headless-lite:latest
```

> Three runtime options are **required** or the client won't start / stays
> black: `--shm-size=2g` (CEF renderer, see
> [Shared memory](#shared-memory-required)), the `--security-opt` /
> `--cap-add SYS_ADMIN` pair (Steam user namespaces, see
> [User namespaces](#user-namespaces-required)), and host networking (native LAN
> sharing). Make sure `WEB_PORT` is free on the host.

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

## User namespaces (required)

Modern Steam clients abort with **"Steam now requires user namespaces to be
enabled."** unless their runtime sandbox (bubblewrap / pressure-vessel) can
create nested user namespaces. Inside Docker two layers block this by default:

- **The container**: Docker's default `seccomp` and `AppArmor` profiles block
  the `clone`/`unshare` calls that create a user namespace. The provided compose
  files relax both and add `SYS_ADMIN`:

  ```yaml
  security_opt:
    - seccomp=unconfined
    - apparmor=unconfined
  cap_add:
    - SYS_ADMIN
  ```

- **The host**: unprivileged user namespaces must be allowed. On most kernels
  this is already the case. On Debian/Ubuntu, verify:

  ```bash
  sysctl kernel.unprivileged_userns_clone   # should be 1
  # if 0, enable it:
  echo 'kernel.unprivileged_userns_clone=1' | sudo tee /etc/sysctl.d/99-userns.conf
  sudo sysctl --system
  ```

These settings are a deliberate trade-off: this is a trusted, LAN-only download
node (and it already runs with host networking), so relaxing the container
sandbox is acceptable here. Do not copy these options onto untrusted workloads.

## Shared memory (required)

The Steam UI is rendered by `steamwebhelper` (CEF/Chromium). Chromium needs a
large `/dev/shm`; Docker's **64 MB default is too small** and makes the renderer
fail — the Steam window stays **completely black** even though the client is
running and the menus work. The compose files set a generous value:

```yaml
shm_size: "2gb"
```

With `docker run`, pass `--shm-size=2g`. If you ever see a black noVNC screen
with a logged-in-but-blank Steam window, this is the first thing to check.

> Note: a line like `Exiting GPU process due to errors during initialization`
> in the Steam logs is expected and harmless here — CEF's GPU process does not
> initialise under software rendering, so CEF falls back to CPU rasterisation,
> which works. The black screen is caused by `/dev/shm`, not by that message.

## Data persistence

| Volume    | Purpose                                                        |
|-----------|----------------------------------------------------------------|
| `/config` | `HOME` for the `steam` user: Steam session + client config. Keeps you logged in. Back this up to preserve your session. |
| `/data`   | The game library (`steamapps/`). Point this at your bulk storage. |

## Typical workflow

1. **Download / keep games on this node.** Install titles from the Steam library
   in the web UI; they land in `/data/steamapps/`. Updates that this node itself
   downloads are stored complete (with their depot manifests under
   `/config/.../depotcache`), so later verification and LAN transfers are optimal.
2. **The node acts as a backup.** The games stay on your bulk storage even if you
   uninstall them elsewhere.
3. **Seed other clients over the LAN.** With Local Network Game Transfers enabled
   on both ends, a Steam Deck (or any client) re-installs from this node instead
   of the internet.

### Importing an existing library (optional)

If you already have games downloaded elsewhere (e.g. a SteamCMD mirror), you can
drop them into `/data` so Steam picks them up as installed, instead of
re-downloading from scratch. The library must follow Steam's layout:

```
/data/
├── libraryfolder.vdf                 (created automatically on start)
└── steamapps/
    ├── appmanifest_<appid>.acf
    ├── depotcache/<depotid>_<manifest>.manifest   (if available — enables delta)
    └── common/<installdir>/
```

Notes and caveats:

- On start the node **auto-registers `/data`** in `libraryfolders.vdf`, so you do
  not need to add it through the UI (the headless GUI won't let you type a path).
- **Depot manifests matter.** If `steamapps/depotcache/<depotid>_<manifest>.manifest`
  is present, Steam can verify the local content and download only missing/changed
  chunks. Without it, Steam may re-download more (worst case, the whole depot),
  because it cannot verify what you already have. A plain file copy of a game
  usually does **not** include these manifests.
- **Platform.** Content is transferred per depot. A Windows build (run via Proton
  on Linux clients) is fine to store and seed; it matches what those clients
  download.
- A companion script, `revert-to-steamlibrary.sh` (in the `steam-games-downloader`
  project), rebuilds this layout from a SteamCMD mirror, copies any available depot
  manifests, and marks each game for a full validation so Steam reuses on-disk
  content where it can.

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

- **Enable it on both ends.** In Steam, *Settings → Downloads → Allow downloads
  on local network* must be on in this node **and** in the receiving client
  (e.g. a Steam Deck).
- **Sharing is per depot, not per OS label.** A game is transferred as its
  depot. A Windows-only title that a Steam Deck runs through Proton uses the
  **Windows depot** on both sides, so this node can seed that depot to the Deck
  over the LAN. In other words, storing the Windows build of a Proton game is
  useful: it is the same content the Deck downloads.

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
| `STEAM_ARGS`     | `-no-browser -cef-force-gpu-mesa` | Arguments passed to the Steam client. `-cef-force-gpu-mesa` points CEF at the software GL path for headless rendering. Do **not** add `-silent` (it minimises Steam to a nonexistent tray → black screen). |

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

For local build + startup testing there is a dedicated compose file
(`docker-compose.build.yml`) that builds from the local Dockerfile instead of
pulling from Docker Hub:

```bash
docker compose -f docker-compose.build.yml up --build
```

To clean up development leftovers (the test container, the `:local` image, and
optionally the build cache / `./.local` test data), use the helper script. It is
a dry-run by default and only acts with `--execute`:

```bash
./scripts/clean-local.sh                    # show what would be removed
./scripts/clean-local.sh --execute          # remove container + :local image
./scripts/clean-local.sh --execute --deep   # also prune the BuildKit cache
./scripts/clean-local.sh --execute --data   # also delete ./.local test data
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

## Troubleshooting

**Black noVNC screen, but the container is running.** The usual causes, in order
of likelihood:

1. **`/dev/shm` too small.** The most common cause. Set `shm_size: "2gb"`
   (compose) or `--shm-size=2g` (run). See [Shared memory](#shared-memory-required).
2. **Missing user-namespace options.** If the logs show *"Steam now requires
   user namespaces to be enabled"*, add the `security_opt` / `cap_add SYS_ADMIN`
   options. See [User namespaces](#user-namespaces-required).
3. **A blocking first-run dialog.** The Debian `steam-installer` shows a
   zenity "Install?" dialog on a fresh install; this image answers it
   automatically via a bundled `zenity` wrapper, so you shouldn't hit it, but if
   you replace that wrapper the dialog will block startup.

**"Steam now requires user namespaces to be enabled."** See
[User namespaces](#user-namespaces-required). The host must allow unprivileged
user namespaces and the container must relax seccomp/AppArmor + add `SYS_ADMIN`.

**Steam exits with code 71 and the container keeps running.** Expected. Steam
restarts itself after installing a client update ("Restarting Steam by
request..."); the supervisor relaunches it automatically and keeps the web
session alive. Only a genuine crash-loop (many restarts in a short window) is
treated as fatal.

**The Steam window is tiny / in a corner.** The UI window
(`steamwebhelper`) can open small; a background maximiser in `run.sh` resizes it
to fill the screen. If it misbehaves, the window class to target is
`steamwebhelper`.

**Some dialogs/dropdowns don't respond to the mouse** (e.g. a game's Properties
window, certain dropdowns). This is a known limitation of Steam's CEF/Chromium
UI under software rendering over noVNC — some modal widgets don't take mouse
input reliably. Workaround: **use the keyboard**. Tab / Shift+Tab to move between
fields, arrow keys to change dropdowns, Space/Enter to toggle/confirm, Esc to
close. The main library, install, and settings flows work fine with the mouse;
only a few nested modals need the keyboard.

## License

MIT — see the [`LICENSE`](LICENSE) file. This project is not affiliated with
Valve. Steam is a trademark of Valve Corporation.
