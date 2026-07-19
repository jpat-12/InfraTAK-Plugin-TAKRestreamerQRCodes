#!/bin/bash
# uninstall.sh — remove the TAK Restreamer QR Codes module from an infra-TAK
# console.
#
# Reverses exactly what install.sh applied:
#   1. Removes the restreamer_qr.register_routes() block from app.py
#   2. Removes the /qr route from generate_caddyfile()'s MediaMTX block
#   3. Deletes restreamer_qr.py and modules/restreamer_qr/ from the console
#   4. Restarts takwerx-console so the removal takes effect immediately
#
# Does NOT regenerate/reload the live Caddyfile — click Deploy on the Caddy
# page (or save any setting that triggers a regen) after uninstalling so the
# /qr route actually disappears from the served config.
#
# Safe to run even if the module was never installed (no-ops cleanly).
#
# Usage:
#   sudo bash uninstall.sh

set -euo pipefail

CONSOLE_SERVICE="${CONSOLE_SERVICE:-takwerx-console}"

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: run as root (sudo bash $0)" >&2
    exit 1
fi

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

python3 - "$CONSOLE_DIR/app.py" <<'PYEOF'
import sys

path = sys.argv[1]
with open(path, 'r', encoding='utf-8') as f:
    src = f.read()

REG_BLOCK = (
    "try:\n"
    "    import restreamer_qr as _restreamer_qr_module\n"
    "    _restreamer_qr_module.register_routes(app, login_required, load_settings, save_settings)\n"
    "except Exception as _e:\n"
    "    print(f'[restreamer_qr] Failed to register TAK Restreamer QR Codes module: {_e}', flush=True)\n\n"
)
if REG_BLOCK in src:
    src = src.replace(REG_BLOCK, '', 1)
    print("    - removed module registration")
else:
    print("    = module registration not present, nothing to remove")

CADDY_MARKER = '# TAK Restreamer QR Codes — public /qr route'
caddy_block = (
    '        lines.append(f"    ' + CADDY_MARKER + '")\n'
    '        lines.append(f"    route /qr /qr/* {{")\n'
    '        lines.append(f"        reverse_proxy 127.0.0.1:5001")\n'
    '        lines.append(f"    }}")\n'
)
if caddy_block in src:
    src = src.replace(caddy_block, '', 1)
    print("    - removed /qr route from generate_caddyfile()'s MediaMTX block")
else:
    print("    = /qr Caddy route not present, nothing to remove")

with open(path, 'w', encoding='utf-8') as f:
    f.write(src)
PYEOF

if [ -f "$CONSOLE_DIR/restreamer_qr.py" ]; then
    rm -f "$CONSOLE_DIR/restreamer_qr.py"
    echo "    - deleted restreamer_qr.py"
else
    echo "    = restreamer_qr.py not present, nothing to delete"
fi

if [ -d "$CONSOLE_DIR/modules/restreamer_qr" ]; then
    rm -rf "$CONSOLE_DIR/modules/restreamer_qr"
    echo "    - deleted modules/restreamer_qr/"
else
    echo "    = modules/restreamer_qr/ not present, nothing to delete"
fi

if command -v systemd-run >/dev/null 2>&1; then
    systemd-run --no-block --collect --quiet -- systemctl restart "$CONSOLE_SERVICE" 2>/dev/null \
        && echo "==> Restart of $CONSOLE_SERVICE scheduled (applies within a few seconds)" \
        || echo "    ⚠ Could not schedule restart of $CONSOLE_SERVICE — restart it manually" >&2
else
    (systemctl restart "$CONSOLE_SERVICE" 2>/dev/null &)
    echo "==> Restart of $CONSOLE_SERVICE requested (systemd-run unavailable, backgrounded instead)"
fi

echo ""
echo "✓ TAK Restreamer QR Codes module uninstalled. Click Deploy on the Caddy"
echo "  page (or save any setting that triggers a regen) so the /qr route"
echo "  actually drops out of the live Caddyfile."
