#!/bin/bash
# uninstall.sh — remove the TAK Video Stream QR Codes module from an infra-TAK
# console.
#
# Reverses exactly what install.sh applied:
#   1. Removes the restreamer_qr.register_routes() block from app.py
#   2. Removes 'qr': 'qr' from SERVICE_DOMAIN_DEFAULTS
#   3. Removes the restreamer_qr entry from detect_modules()
#   4. Removes the qr.<fqdn> site-block code from generate_caddyfile()
#   5. Deletes restreamer_qr.py and modules/restreamer_qr/ from the console
#   6. Restarts takwerx-console so the removal takes effect immediately
#   7. Removes the qr.<fqdn> site block from the LIVE Caddyfile and reloads
#      Caddy (also cleans up the older /qr-on-streaming-site approach if
#      it's still present from an earlier version of this installer)
#
# Safe to run even if the module was never installed (no-ops cleanly).
#
# This is the same script the console's /admin/qr settings page runs (via
# subprocess, after re-checking the admin password) when you click its
# Uninstall button — running it directly over SSH does the same thing.
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
import re, sys

path = sys.argv[1]
with open(path, 'r', encoding='utf-8') as f:
    src = f.read()

# 1. Route registration — regex so it deletes regardless of which
# display-name wording or register_routes() arg count (4-arg pre-uninstall-
# button vs 6-arg with load_auth/check_password_hash) is currently deployed.
REG_BLOCK_RE = re.compile(
    r"try:\n"
    r"    import restreamer_qr as _restreamer_qr_module\n"
    r"    _restreamer_qr_module\.register_routes\([^\n]*\)\n"
    r"except Exception as _e:\n"
    r"    print\(f'\[restreamer_qr\] Failed to register [^\n]*', flush=True\)\n\n"
)
src, n = REG_BLOCK_RE.subn('', src, count=1)
if n:
    print("    - removed module registration")
else:
    print("    = module registration not present, nothing to remove")

# 2. SERVICE_DOMAIN_DEFAULTS entry
if "\n    'qr': 'qr'," in src:
    src = src.replace("\n    'qr': 'qr',", "", 1)
    print("    - removed 'qr': 'qr' from SERVICE_DOMAIN_DEFAULTS")
else:
    print("    = SERVICE_DOMAIN_DEFAULTS has no 'qr' entry, nothing to remove")

# 3. detect_modules() entry — regex so it deletes regardless of which
# display-name wording or 'route' value ('/qr' pre-admin-page vs
# '/admin/qr') is currently deployed.
DETECT_BLOCK_RE = re.compile(
    r"    # [^\n]* — public, static QR generator page; always\n"
    r"    # available once installed since it's just files bundled into the console,\n"
    r"    # no separate process to health-check\.\n"
    r"    qr_installed = os\.path\.exists\(os\.path\.join\(BASE_DIR, 'modules', 'restreamer_qr', 'index\.html'\)\)\n"
    r"    modules\['restreamer_qr'\] = \{'name': '[^']*', 'installed': qr_installed, 'running': qr_installed,\n"
    r"        'description': 'Public QR code generator for RTMP/RTSP/SRT stream URLs', 'icon': '[^']*', 'route': '[^']*', 'priority': 13\}\n"
)
src, n = DETECT_BLOCK_RE.subn('', src, count=1)
if n:
    print("    - removed restreamer_qr entry from detect_modules()")
else:
    print("    = detect_modules() has no restreamer_qr entry, nothing to remove")

# 4. generate_caddyfile() site-block code (current shape, either display-name
# wording in the Caddy comment)
def _caddy_qr_block(comment):
    return (
        "    qr_svc = modules.get('restreamer_qr', {})\n"
        "    if qr_svc.get('installed'):\n"
        "        qr_host = sd['qr']\n"
        "        lines.append(f\"# " + comment + "\")\n"
        "        lines.append(f\"{qr_host} {{\")\n"
        "        lines.append(f\"    route {{\")\n"
        "        lines.append(f\"        rewrite * /qr{{uri}}\")\n"
        "        lines.append(f\"        reverse_proxy 127.0.0.1:5001 {{\")\n"
        "        lines.append(f\"            transport http {{\")\n"
        "        lines.append(f\"                tls\")\n"
        "        lines.append(f\"                tls_insecure_skip_verify\")\n"
        "        lines.append(f\"                read_timeout 1h\")\n"
        "        lines.append(f\"                write_timeout 1h\")\n"
        "        lines.append(f\"            }}\")\n"
        "        lines.append(f\"        }}\")\n"
        "        lines.append(f\"    }}\")\n"
        "        lines.append(f\"}}\")\n"
        "        lines.append(\"\")\n"
        "        _emit_alias_redirect(_get_service_alias(settings, 'qr'), qr_host)\n"
        "\n"
    )
CADDY_QR_BLOCKS = [
    _caddy_qr_block("TAK Video Stream QR Codes — public stream QR generator"),
    _caddy_qr_block("TAK Restreamer QR Codes — public stream QR generator"),
]
# Earlier (pre-migration) shape: /qr bolted onto MediaMTX's own site block.
OLD_CADDY_MARKER = '# TAK Restreamer QR Codes — public /qr route'
OLD_CADDY_BLOCKS = [
    (
        '        lines.append(f"    ' + OLD_CADDY_MARKER + '")\n'
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
    ),
    (
        '        lines.append(f"    ' + OLD_CADDY_MARKER + '")\n'
        '        lines.append(f"    route /qr /qr/* {{")\n'
        '        lines.append(f"        reverse_proxy 127.0.0.1:5001")\n'
        '        lines.append(f"    }}")\n'
    ),
]
removed = False
for block in CADDY_QR_BLOCKS:
    if block in src:
        src = src.replace(block, '', 1)
        removed = True
        break
for old in OLD_CADDY_BLOCKS:
    if old in src:
        src = src.replace(old, '', 1)
        removed = True
if removed:
    print("    - removed qr site-block code from generate_caddyfile()")
else:
    print("    = generate_caddyfile() has no qr site-block code, nothing to remove")

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

# Remove the qr.<fqdn> block (and any leftover old-style /qr-on-streaming-site
# block) from the LIVE Caddyfile too, then reload.
CADDYFILE=/etc/caddy/Caddyfile
if [ -f "$CADDYFILE" ]; then
    CADDY_BAK="$CADDYFILE.bak-$(date +%Y%m%d-%H%M%S)"
    cp -a "$CADDYFILE" "$CADDY_BAK"
    PATCH_RESULT="$(python3 - "$CADDYFILE" <<'PYEOF'
import re, sys

path = sys.argv[1]
with open(path, 'r', encoding='utf-8') as f:
    src = f.read()

changed = False

# Current shape: standalone "qr.<fqdn> { ... }" site, found by marker
# comment regardless of which host it names. The alternation also covers
# either display-name wording (the module was renamed from "Restreamer" to
# "Video Stream").
HOST_BLOCK_RE = re.compile(
    r'# TAK (?:Restreamer|Video Stream) QR Codes — public stream QR generator\n' +
    r'[^\n]+\{.*?\n\}\n\n?',
    re.DOTALL,
)
new_src, n = HOST_BLOCK_RE.subn('', src)
if n:
    src = new_src
    changed = True

# Earlier shape: /qr bolted onto the streaming site's own block.
OLD_MARKER = '# TAK Restreamer QR Codes — public /qr route'
OLD_BLOCKS = [
    (
        f'    {OLD_MARKER}\n'
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
    ),
    (
        f'    {OLD_MARKER}\n'
        '    handle /qr* {\n'
        '        reverse_proxy 127.0.0.1:5001\n'
        '    }\n'
    ),
    (
        f'    {OLD_MARKER}\n'
        '    route /qr /qr/* {\n'
        '        reverse_proxy 127.0.0.1:5001\n'
        '    }\n'
    ),
]
for old in OLD_BLOCKS:
    if old in src:
        src = src.replace(old, '', 1)
        changed = True

with open(path, 'w', encoding='utf-8') as f:
    f.write(src)
print("changed" if changed else "unchanged")
PYEOF
)"
    if [ "$PATCH_RESULT" = "unchanged" ]; then
        echo "==> Live Caddyfile has no qr route to remove"
        rm -f "$CADDY_BAK"
    elif command -v caddy >/dev/null 2>&1 && ! caddy validate --config "$CADDYFILE" --adapter caddyfile >/dev/null 2>&1; then
        echo "ERROR: caddy validate failed after removal — restoring previous Caddyfile" >&2
        cp -a "$CADDY_BAK" "$CADDYFILE"
    else
        echo "    - removed qr route(s) from live Caddyfile"
        echo "    ✓ Caddyfile validates (backup: $CADDY_BAK)"
        if systemctl reload caddy 2>/dev/null || systemctl restart caddy 2>/dev/null; then
            echo "    ✓ Caddy reloaded"
        else
            echo "    ⚠ Could not reload Caddy via systemctl — reload it manually" >&2
        fi
    fi
else
    echo "==> No $CADDYFILE — nothing to patch"
fi

echo ""
echo "✓ TAK Video Stream QR Codes module uninstalled."
