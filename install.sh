#!/bin/bash
# install.sh — install/update the TAK Restreamer QR Codes module into a
# running infra-TAK console.
#
# What it does:
#   1. Makes sure this repo lives at a canonical checkout (~/.infra-tak-modules/
#      restreamer-qr) so the console's own update flow always knows where to
#      `git pull` from.
#   2. Copies restreamer_qr.py + the static QR page (index.html, css/, js/)
#      into the infra-TAK install directory, under modules/restreamer_qr/.
#   3. Patches app.py (idempotent — safe to re-run) to register the module's
#      routes at startup, same convention as migrate_authentik.py's
#      register_routes(app, login_required, load_settings, save_settings).
#   4. Adds the /qr route to MediaMTX's Caddy site block inside
#      generate_caddyfile() (idempotent), so the next Caddy deploy serves
#      /qr on MediaMTX's own domain (e.g. stream.prod.ilwg.us/qr).
#   5. Restarts the takwerx-console systemd service.
#
# This does NOT regenerate/reload the live Caddyfile — that only happens
# when infra-TAK itself calls generate_caddyfile() (e.g. Settings > Caddy >
# Deploy, or any settings save that already triggers a Caddy regen). Click
# Deploy on the Caddy page once after installing to pick up the new route.
#
# Usage:
#   sudo bash install.sh            # first-time install (or full re-install)
#   sudo bash install.sh --sync     # re-apply only (same as first-time here;
#                                    # flag accepted for symmetry with sibling
#                                    # InfraTAK-Module-* installers)

set -euo pipefail

MODULE_CHECKOUT_DIR="${MODULE_CHECKOUT_DIR:-$HOME/.infra-tak-modules/restreamer-qr}"
MODULE_REPO_URL="${MODULE_REPO_URL:-https://github.com/jpat-12/InfraTAK-Plugin-TAKRestreamerQRCodes.git}"
CONSOLE_SERVICE="${CONSOLE_SERVICE:-takwerx-console}"

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: run as root (sudo bash $0 $*)" >&2
    exit 1
fi

# --- 1. Canonical checkout -----------------------------------------------
if [ -d "$MODULE_CHECKOUT_DIR/.git" ]; then
    CURRENT_ORIGIN="$(git -C "$MODULE_CHECKOUT_DIR" remote get-url origin 2>/dev/null || true)"
    if [ "$CURRENT_ORIGIN" != "$MODULE_REPO_URL" ]; then
        echo "==> Module checkout's origin was '$CURRENT_ORIGIN' (not GitHub) — fixing..."
        git -C "$MODULE_CHECKOUT_DIR" remote set-url origin "$MODULE_REPO_URL"
    fi
    echo "==> Updating module checkout at $MODULE_CHECKOUT_DIR..."
    git -C "$MODULE_CHECKOUT_DIR" fetch origin
    git -C "$MODULE_CHECKOUT_DIR" reset --hard origin/main
else
    echo "==> No git checkout found — cloning $MODULE_REPO_URL into $MODULE_CHECKOUT_DIR..."
    mkdir -p "$(dirname "$MODULE_CHECKOUT_DIR")"
    git clone "$MODULE_REPO_URL" "$MODULE_CHECKOUT_DIR"
fi
SRC_DIR="$MODULE_CHECKOUT_DIR"

# --- 2. Locate the infra-TAK install (same search as sibling modules) ----
CONSOLE_DIR=""
for d in /opt/infra-TAK /opt/infra-tak /root/infra-TAK /root/infra-tak "$HOME/infra-TAK" "$HOME/infra-tak"; do
    if [ -f "$d/app.py" ]; then
        CONSOLE_DIR="$d"; break
    fi
done
if [ -z "$CONSOLE_DIR" ]; then
    CONSOLE_DIR="$(find /root /home /opt -maxdepth 3 -name app.py -path '*infra*' 2>/dev/null | head -1 | xargs -r dirname || true)"
fi
if [ -z "$CONSOLE_DIR" ]; then
    echo "ERROR: could not find an infra-TAK install (looked for app.py under /opt, /root, \$HOME)." >&2
    exit 1
fi
echo "==> infra-TAK console: $CONSOLE_DIR"

# --- 3. Sync module files into the console -------------------------------
cp -f "$SRC_DIR/restreamer_qr.py" "$CONSOLE_DIR/restreamer_qr.py"
mkdir -p "$CONSOLE_DIR/modules/restreamer_qr/css" "$CONSOLE_DIR/modules/restreamer_qr/js/vendor"
cp -f "$SRC_DIR/index.html" "$CONSOLE_DIR/modules/restreamer_qr/index.html"
cp -f "$SRC_DIR/css/style.css" "$CONSOLE_DIR/modules/restreamer_qr/css/style.css"
cp -f "$SRC_DIR/js/app.js" "$CONSOLE_DIR/modules/restreamer_qr/js/app.js"
cp -f "$SRC_DIR/js/vendor/qrcode.js" "$CONSOLE_DIR/modules/restreamer_qr/js/vendor/qrcode.js"
MODULE_VERSION="$(grep -m1 '^MODULE_VERSION' "$CONSOLE_DIR/restreamer_qr.py" | sed -E "s/.*= *'([^']+)'.*/\1/")"
echo "==> Synced restreamer_qr.py (v${MODULE_VERSION:-unknown}) + modules/restreamer_qr/{index.html,css/,js/}"

# --- 4. Patch app.py (idempotent) ----------------------------------------
python3 - "$CONSOLE_DIR/app.py" <<'PYEOF'
import sys

path = sys.argv[1]
with open(path, 'r', encoding='utf-8') as f:
    src = f.read()

# 4a. Register routes at startup.
REG_MARKER = '[restreamer_qr] Failed to register'
if REG_MARKER not in src:
    anchor = "# === Main Entry Point (fallback for direct python3 app.py) ===\n"
    if anchor not in src:
        print("ERROR: could not find main-entry-point anchor in app.py — module registration NOT applied", file=sys.stderr)
        sys.exit(1)
    block = (
        "try:\n"
        "    import restreamer_qr as _restreamer_qr_module\n"
        "    _restreamer_qr_module.register_routes(app, login_required, load_settings, save_settings)\n"
        "except Exception as _e:\n"
        "    print(f'[restreamer_qr] Failed to register TAK Restreamer QR Codes module: {_e}', flush=True)\n\n"
    )
    src = src.replace(anchor, block + anchor, 1)
    print("    + registered restreamer_qr.register_routes()")
else:
    print("    = module registration already present")

# 4b. Add the /qr route to MediaMTX's Caddy site block.
CADDY_MARKER = '# TAK Restreamer QR Codes — public /qr route'
if CADDY_MARKER not in src:
    anchor = '        lines.append(f"# MediaMTX Web Console")\n        lines.append(f"{mtx_host} {{")\n'
    if anchor not in src:
        print("ERROR: could not find MediaMTX site-block anchor in generate_caddyfile() — Caddy route NOT added", file=sys.stderr)
        sys.exit(1)
    caddy_block = (
        '        lines.append(f"    ' + CADDY_MARKER + '")\n'
        '        lines.append(f"    route /qr /qr/* {{")\n'
        '        lines.append(f"        reverse_proxy 127.0.0.1:5001")\n'
        '        lines.append(f"    }}")\n'
    )
    src = src.replace(anchor, anchor + caddy_block, 1)
    print("    + added /qr route to generate_caddyfile()'s MediaMTX block")
else:
    print("    = /qr Caddy route already present")

with open(path, 'w', encoding='utf-8') as f:
    f.write(src)
PYEOF

# --- 5. Restart the console service ---------------------------------------
# See InfraTAK-Module-MigrateAuthentik/install.sh for why this uses
# systemd-run --no-block rather than a direct `systemctl restart`: a direct
# restart kills this whole process tree (including whatever invoked this
# script) before it can finish or report back.
if command -v systemd-run >/dev/null 2>&1; then
    systemd-run --no-block --collect --quiet -- systemctl restart "$CONSOLE_SERVICE" 2>/dev/null \
        && echo "==> Restart of $CONSOLE_SERVICE scheduled (applies within a few seconds)" \
        || echo "    ⚠ Could not schedule restart of $CONSOLE_SERVICE — restart it manually" >&2
else
    (systemctl restart "$CONSOLE_SERVICE" 2>/dev/null &)
    echo "==> Restart of $CONSOLE_SERVICE requested (systemd-run unavailable, backgrounded instead)"
fi

echo ""
echo "✓ TAK Restreamer QR Codes module installed."
echo "  One more step: open the Caddy page in the console and click Deploy"
echo "  (or save any setting that triggers a Caddy regen) to pick up the new"
echo "  /qr route — install.sh patches generate_caddyfile() but does not"
echo "  touch the live Caddyfile itself."
echo "  Once deployed, the page is public at https://<mediamtx-domain>/qr"
