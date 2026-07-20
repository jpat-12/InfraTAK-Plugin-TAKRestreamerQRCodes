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
# The console's own gunicorn listens with a self-signed cert on :5001 (see
# this same function's other reverse_proxy 127.0.0.1:5001 blocks) — a bare
# reverse_proxy speaks plain HTTP to it and gets a TLS handshake back,
# surfacing as a 502. Match the transport block those use.
CADDY_MARKER = '# TAK Restreamer QR Codes — public /qr route'

def _render_caddy_block():
    return (
        '        lines.append(f"    ' + CADDY_MARKER + '")\n'
        '        lines.append(f"    handle /qr* {{")\n'
        '        lines.append(f"        reverse_proxy 127.0.0.1:5001 {{")\n'
        '        lines.append(f"            transport http {{")\n'
        '        lines.append(f"                tls")\n'
        '        lines.append(f"                tls_insecure_skip_verify")\n'
        '        lines.append(f"                read_timeout 1h")\n'
        '        lines.append(f"                write_timeout 1h")\n'
        '        lines.append(f"            }}")\n'
        '        lines.append(f"        }}")\n'
        '        lines.append(f"    }}")\n'
    )

CURRENT_CADDY_BLOCK = _render_caddy_block()

# Earlier installer versions wrote a bare `reverse_proxy 127.0.0.1:5001`
# (no TLS transport) via `route /qr /qr/*`. Self-heal it if present.
OLD_CADDY_BLOCK = (
    '        lines.append(f"    ' + CADDY_MARKER + '")\n'
    '        lines.append(f"    route /qr /qr/* {{")\n'
    '        lines.append(f"        reverse_proxy 127.0.0.1:5001")\n'
    '        lines.append(f"    }}")\n'
)

if CURRENT_CADDY_BLOCK in src:
    print("    = /qr Caddy route already present (current)")
elif OLD_CADDY_BLOCK in src:
    src = src.replace(OLD_CADDY_BLOCK, CURRENT_CADDY_BLOCK, 1)
    print("    + upgraded generate_caddyfile()'s /qr route to fix TLS transport")
else:
    anchor = '        lines.append(f"# MediaMTX Web Console")\n        lines.append(f"{mtx_host} {{")\n'
    if anchor not in src:
        print("ERROR: could not find MediaMTX site-block anchor in generate_caddyfile() — Caddy route NOT added", file=sys.stderr)
        sys.exit(1)
    src = src.replace(anchor, anchor + CURRENT_CADDY_BLOCK, 1)
    print("    + added /qr route to generate_caddyfile()'s MediaMTX block")

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

# --- 6. Patch the LIVE Caddyfile and reload now --------------------------
# generate_caddyfile() (patched in step 4) only takes effect on its next
# regen. Rather than importing app.py to call it directly — which would also
# fire its post-update auto-deploy machinery (Authentik compose healing, LDAP
# outpost recreation, etc.) as an uncontrolled side effect — this mirrors
# InfraTAK-Module-MigrateAuthentik/scripts/authentik-repoint-caddy.sh: edit
# the live file textually, validate, reload, roll back on failure. The two
# writers (generator patch + this direct edit) stay in sync because both
# produce the identical block; the next real regen just overwrites this one
# with the same content.
CADDYFILE=/etc/caddy/Caddyfile
if [ ! -f "$CADDYFILE" ]; then
    echo "==> No $CADDYFILE yet — Caddy not deployed. Deploy Caddy from the"
    echo "    console once, then re-run this script (or install.sh --sync) to"
    echo "    add the /qr route."
else
    CADDY_MARKER='# TAK Restreamer QR Codes — public /qr route'
    CADDY_BAK="$CADDYFILE.bak-$(date +%Y%m%d-%H%M%S)"
    cp -a "$CADDYFILE" "$CADDY_BAK"
    PATCH_RESULT="$(python3 - "$CADDYFILE" "$CADDY_MARKER" <<'PYEOF'
import re, sys

path, marker = sys.argv[1], sys.argv[2]
with open(path, 'r', encoding='utf-8') as f:
    src = f.read()

# The console's own gunicorn listens with a self-signed cert on :5001 (see
# generate_caddyfile()'s other reverse_proxy 127.0.0.1:5001 blocks) — a bare
# reverse_proxy speaks plain HTTP to it and Caddy gets a TLS handshake back,
# which surfaces as a 502. Match the transport block those use.
def render(marker):
    return (
        f'    {marker}\n'
        '    handle /qr* {\n'
        '        reverse_proxy 127.0.0.1:5001 {\n'
        '            transport http {\n'
        '                tls\n'
        '                tls_insecure_skip_verify\n'
        '                read_timeout 1h\n'
        '                write_timeout 1h\n'
        '            }\n'
        '        }\n'
        '    }\n'
    )

CURRENT_BLOCK = render(marker)

# Older versions of this installer wrote a bare `reverse_proxy 127.0.0.1:5001`
# (no TLS transport, causes a 502) using either `route /qr /qr/*` or
# `handle /qr*`. Detect and self-heal either shape in place.
OLD_BLOCKS = [
    f'    {marker}\n    route /qr /qr/* {{\n        reverse_proxy 127.0.0.1:5001\n    }}\n',
    f'    {marker}\n    handle /qr* {{\n        reverse_proxy 127.0.0.1:5001\n    }}\n',
]

if CURRENT_BLOCK in src:
    print("unchanged")
    sys.exit(0)

healed = False
for old in OLD_BLOCKS:
    if old in src:
        src = src.replace(old, CURRENT_BLOCK, 1)
        healed = True
        break

if not healed:
    # Anchor on the streaming site's header comment + host-open line. Tried
    # in order: a hand-added "TAK Video Restreamer" block (confirmed the
    # real shape on ILWG's server — tak-video-restreamer's own Flask app on
    # :3100, fronted directly by Caddy, not generated by infra-TAK's
    # generate_caddyfile()) falling back to infra-TAK's generic "MediaMTX
    # Web Console" block for setups that use that instead. Either way we
    # don't need to know the literal host.
    ANCHOR_PATTERNS = [
        r'# TAK Video Restreamer[^\n]*\n[^\n]+\{\n',
        r'# MediaMTX Web Console\n[^\n]+\{\n',
    ]
    m = None
    for pat in ANCHOR_PATTERNS:
        m = re.search(pat, src)
        if m:
            break
    if not m:
        print("ERROR: could not find the streaming site's block in live Caddyfile (looked for a "
              "'TAK Video Restreamer' or 'MediaMTX Web Console' header) — is it deployed under a "
              "different name?", file=sys.stderr)
        sys.exit(1)
    src = src[:m.end()] + CURRENT_BLOCK + src[m.end():]

with open(path, 'w', encoding='utf-8') as f:
    f.write(src)
print("healed" if healed else "inserted")
PYEOF
)"
    PATCH_OK=$?
    if [ "$PATCH_RESULT" = "unchanged" ]; then
        echo "==> Live Caddyfile already has the current /qr route — nothing to patch"
        rm -f "$CADDY_BAK"
    elif [ "$PATCH_OK" -ne 0 ]; then
        echo "    ⚠ Could not patch live Caddyfile — left unchanged. Add the /qr" >&2
        echo "      route manually or via the console's Caddy > Deploy button." >&2
        rm -f "$CADDY_BAK"
    elif command -v caddy >/dev/null 2>&1 && ! caddy validate --config "$CADDYFILE" --adapter caddyfile >/dev/null 2>&1; then
        echo "ERROR: caddy validate failed after patch — restoring previous Caddyfile" >&2
        cp -a "$CADDY_BAK" "$CADDYFILE"
    else
        [ "$PATCH_RESULT" = "healed" ] && echo "    + upgraded existing /qr route to fix TLS transport (was causing 502s)"
        [ "$PATCH_RESULT" = "inserted" ] && echo "    + inserted /qr route into live Caddyfile"
        echo "    ✓ Caddyfile validates (backup: $CADDY_BAK)"
        if systemctl reload caddy 2>/dev/null || systemctl restart caddy 2>/dev/null; then
            echo "    ✓ Caddy reloaded"
        else
            echo "    ⚠ Could not reload Caddy via systemctl — reload it manually" >&2
        fi
    fi
fi

echo ""
echo "✓ TAK Restreamer QR Codes module installed."
echo "  Page should now be public at https://<mediamtx-domain>/qr"
echo "  (e.g. stream.prod.ilwg.us/qr). If Caddy wasn't deployed yet, or the"
echo "  live-Caddyfile patch above reported a warning, open the Caddy page in"
echo "  the console and click Deploy once to pick it up."
