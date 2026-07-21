# InfraTAK-Plugin-TAKRestreamerQRCodes

A one-page tool that turns a video stream's protocol/address/port/path (plus an
optional human-readable name) into a scannable QR code — instead of hand-typing an
RTSP/RTMP/SRT URL on a phone, point a camera at the QR code. Built to match the
connection format served by
[raytheonbbn/tak-video-restreamer](https://github.com/raytheonbbn/tak-video-restreamer).

Static HTML/CSS/JS, no build step, no network calls at runtime — everything (including
QR generation) happens in the browser. That makes it safe to host anywhere. As an
infra-TAK module (see below) it gets its own public subdomain, e.g. `qr.prod.ilwg.us` —
it isn't a plugin for the tak-video-restreamer itself and doesn't share its domain or
Caddy site.

## Quick start

On an infra-TAK console host, as root:

```bash
git clone https://github.com/jpat-12/InfraTAK-Plugin-TAKRestreamerQRCodes.git
cd InfraTAK-Plugin-TAKRestreamerQRCodes
sudo bash install.sh
```

That's the whole install — it's live at `https://qr.<your-fqdn>` immediately, no
"Deploy" click needed. See [Install as an infra-TAK module](#install-as-an-infra-tak-module)
below for what it actually does, or [Run it standalone](#run-it-standalone) if you just
want to open the page locally without infra-TAK at all.

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

This is a standalone infra-TAK module — its own subdomain (`qr.<fqdn>` by default,
customizable via a `qr_domain` setting, same as every other module), not a path bolted
onto another service's site. `install.sh`:

1. Copies itself to a canonical checkout at `~/.infra-tak-modules/restreamer-qr`.
2. Copies `restreamer_qr.py` and the static page into the console's
   `modules/restreamer_qr/` directory.
3. Patches `app.py` (idempotent — safe to re-run) to:
   - register the module's Flask routes: the public `/qr`, `/qr/`, `/qr/<file>`, plus an
     authenticated `/admin/qr` settings page and `/api/restreamer_qr/uninstall`
   - add `'qr': 'qr'` to `SERVICE_DOMAIN_DEFAULTS` so it gets its own domain
   - add a `restreamer_qr` entry to `detect_modules()` (existence-based — it's static
     files bundled into the console, nothing to health-check) with `'route':
     '/admin/qr'`, so the module card in the console links to the settings page
   - add a public `qr.<fqdn>` site block to `generate_caddyfile()`, gated on that module
     being installed
4. Restarts `takwerx-console`.
5. Patches the **live** `/etc/caddy/Caddyfile` directly (backup → insert → `caddy
   validate` → reload, rolling back on failure) so the page is reachable immediately —
   no manual "Deploy" click needed. This mirrors
   `InfraTAK-Module-MigrateAuthentik/scripts/authentik-repoint-caddy.sh` rather than
   importing `app.py` to call `generate_caddyfile()` directly, which would also fire its
   post-update auto-deploy side effects (Authentik compose healing, LDAP outpost
   recreation) as an unwanted side effect.

Once installed, the public page is at `https://qr.<your-fqdn>` — no console login
required, same as MediaMTX's other public HLS/viewer routes. The **console-side**
settings page is at `/admin/qr` (behind the normal console login) — it shows the public
URL and has an **Uninstall** button with the same password-gated confirmation modal
every other infra-TAK module uses (mirrors MediaMTX's page). Confirming it re-checks
your admin password server-side, then runs `uninstall.sh` for you — no SSH needed.

To uninstall over SSH instead (does exactly what the console button does):

```bash
sudo bash ~/.infra-tak-modules/restreamer-qr/uninstall.sh
```

Reverses every patch above and deletes the synced files, then patches the live
Caddyfile to remove the `qr.<fqdn>` site and reloads Caddy — fully automatic, no manual
Deploy click needed either way.

## How it works

1. Pick a protocol (RTSP, RTMP, or SRT).
2. Enter the server address, port (pre-filled with the restreamer's default for that
   protocol — 8554 / 1935 / 8890), and stream path.
3. Optionally give it a human-readable Stream Name — sent as a `name=` query parameter
   for plugins that read it (see below); leaving it blank costs the QR nothing extra.
4. For SRT, choose `read` (viewer) or `publish` (encoder) stream-ID mode and optionally
   add a passphrase.
5. The stream URL and its QR code update live. Copy the URL or download the QR as a PNG.

URL shapes generated (matching tak-video-restreamer's conventions):

| Protocol | Shape |
|---|---|
| RTSP | `rtsp://{address}:{port}/{path}[?name=...]` |
| RTMP | `rtmp://{address}:{port}/{path}[?name=...]` |
| SRT  | `srt://{address}:{port}?streamid={mode}:{path}[&passphrase=...][&name=...]` |

`name` (URL-encoded) is only present when the Stream Name field is filled in.

## File tree

```
index.html           — page structure and form
css/style.css         — dark-theme styling, responsive two-column layout
js/app.js             — form → URL logic, QR rendering, PNG download, clipboard copy
js/vendor/qrcode.js   — vendored QR encoder (kazuhikoarase/qrcode-generator, MIT)
js/vendor/README.md   — vendoring note: why it's here instead of a CDN import
restreamer_qr.py      — infra-TAK module: registers the public /qr Flask routes plus
                        the authenticated /admin/qr settings page and uninstall API
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
| infra-TAK module install/uninstall | ✅ Working — verified against a copy of infra-TAK's `app.py` and a synthetic Caddyfile: all patches apply cleanly, are idempotent, self-heal earlier approaches (the `/qr`-on-restreamer's-domain bolt-on, the pre-uninstall-button 4-arg `register_routes()` call, the old display-name wording), and round-trip (install then uninstall reproduces the original files byte-for-byte) |
| `/admin/qr` console settings page + password-gated Uninstall button | ✅ Working — smoke-tested with a live Flask app: page renders with the correct public URL, wrong password is rejected with 403, correct password passes the check and invokes `uninstall.sh` |

## Deviations / notes

- Port field auto-fills the protocol's default (8554/1935/8890) until the user edits it
  manually, then stops overriding on protocol switches.
- Leading slashes on the path field are stripped before building the URL.
- On first visit, the server address guesses itself from the page's own hostname —
  `qr.<fqdn>` → `stream.<fqdn>`, matching infra-TAK's own domain convention — so a fresh
  visit needs zero typing to get a working default. Falls back to blank if the hostname
  doesn't start with `qr.`.
- Every field is remembered in `localStorage` between visits, so repeat use (same
  restreamer, a new camera each time) only needs the path field touched. On reload,
  focus jumps straight to the path field (with its text pre-selected) once address and
  port are already filled in; otherwise it goes to the address field.
- QR uses error-correction level `Q` (25%, up from the library's default `M`) since this
  is typically scanned straight off a screen rather than print, where glare/moire costs
  more resolution than the denser code loses.
