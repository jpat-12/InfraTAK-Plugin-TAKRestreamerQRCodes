# InfraTAK-Plugin-TAKRestreamerQRCodes

A one-page tool that turns a video stream's protocol/address/port/path into a scannable
QR code — instead of hand-typing an RTSP/RTMP/SRT URL on a phone, point a camera at the
QR code. Built to match the connection format served by
[raytheonbbn/tak-video-restreamer](https://github.com/raytheonbbn/tak-video-restreamer).

Static HTML/CSS/JS, no build step, no server-side component, no network calls at
runtime — everything (including QR generation) happens in the browser. That makes it
safe to host anywhere, including as a public path off the restreamer's own domain, e.g.
`stream.prod.ilwg.us/qr`.

## Run it standalone

Open [index.html](index.html) directly in a browser, or serve the repo root with any
static file server:

```
npx serve .
```

## Install as an infra-TAK module

If your restreamer's console is [infra-TAK](https://github.com/jpat-12/infra-TAK), the
files in this repo double as an installable module (`restreamer_qr.py`, `install.sh`,
`uninstall.sh`) — same convention as
[InfraTAK-Module-MigrateAuthentik](https://github.com/jpat-12/InfraTAK-Module-MigrateAuthentik).
On the infra-TAK console host, as root:

```bash
git clone https://github.com/jpat-12/InfraTAK-Plugin-TAKRestreamerQRCodes.git
cd InfraTAK-Plugin-TAKRestreamerQRCodes
sudo bash install.sh
```

This:
1. Copies itself to a canonical checkout at `~/.infra-tak-modules/restreamer-qr`.
2. Copies `restreamer_qr.py` and the static page into the console's
   `modules/restreamer_qr/` directory.
3. Patches `app.py` (idempotent — safe to re-run) to register the `/qr` route at
   startup, and adds a `route /qr /qr/*` block to MediaMTX's Caddy site inside
   `generate_caddyfile()`.
4. Restarts `takwerx-console`.

**One manual step after installing**: open the Caddy page in the console and click
**Deploy** (or save any setting that already triggers a Caddy regen) — `install.sh`
patches the *generator function*, not the live `/etc/caddy/Caddyfile`, so the new `/qr`
route only reaches the actual config on the next regen. Once deployed, the page is
public at `https://<mediamtx-domain>/qr` (e.g. `stream.prod.ilwg.us/qr`) — no console
login required, matching the rest of MediaMTX's public HLS/viewer routes.

To uninstall:

```bash
sudo bash ~/.infra-tak-modules/restreamer-qr/uninstall.sh
```

Reverses the `app.py` patch and deletes the synced files, then click **Deploy** on the
Caddy page again so the `/qr` route actually drops out of the live config.

## How it works

1. Pick a protocol (RTSP, RTMP, or SRT).
2. Enter the server address, port (pre-filled with the restreamer's default for that
   protocol — 8554 / 1935 / 8890), and stream name/path.
3. For SRT, choose `read` (viewer) or `publish` (encoder) stream-ID mode and optionally
   add a passphrase.
4. The stream URL and its QR code update live. Copy the URL or download the QR as a PNG.

URL shapes generated (matching tak-video-restreamer's conventions):

| Protocol | Shape |
|---|---|
| RTSP | `rtsp://{address}:{port}/{path}` |
| RTMP | `rtmp://{address}:{port}/{path}` |
| SRT  | `srt://{address}:{port}?streamid={mode}:{path}[&passphrase=...]` |

## File tree

```
index.html           — page structure and form
css/style.css         — dark-theme styling, responsive two-column layout
js/app.js             — form → URL logic, QR rendering, PNG download, clipboard copy
js/vendor/qrcode.js   — vendored QR encoder (kazuhikoarase/qrcode-generator, MIT)
js/vendor/README.md   — vendoring note: why it's here instead of a CDN import
restreamer_qr.py      — infra-TAK module: registers the public /qr Flask route
install.sh            — infra-TAK module installer (patches app.py, syncs static files)
uninstall.sh          — reverses install.sh
```

## Status

| Feature | State |
|---|---|
| Protocol/address/port/path form | ✅ Working |
| Live URL + QR generation | ✅ Working |
| Copy URL / download QR as PNG | ✅ Working |
| ATAK video-alias XML / `tak://` auto-import | ⬜ Not built — out of scope for this tool; QR payload is the raw stream URL only |
| infra-TAK module install/uninstall | ✅ Working — verified against a copy of infra-TAK's `app.py`: patch applies cleanly, is idempotent, and round-trips (install then uninstall reproduces the original file byte-for-byte) |

## Deviations / notes

- Port field auto-fills the protocol's default (8554/1935/8890) until the user edits it
  manually, then stops overriding on protocol switches.
- Leading slashes on the path field are stripped before building the URL.
