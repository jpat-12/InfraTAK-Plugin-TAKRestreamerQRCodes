#!/bin/bash
# install.sh — install/update the TAK Video Stream QR Codes module into a
# running infra-TAK console.
#
# This is a standalone infra-TAK module (its own subdomain, e.g.
# qr.prod.ilwg.us) — not a plugin bolted onto the tak-video-restreamer's own
# site. It follows the same "each service gets its own domain" pattern as
# every other infra-TAK module (nodered, webodm, mediamtx, ...).
#
# What it does:
#   1. Makes sure this repo lives at a canonical checkout (~/.infra-tak-modules/
#      restreamer-qr) so the console's own update flow always knows where to
#      `git pull` from.
#   2. Copies restreamer_qr.py + the static QR page (index.html, css/, js/)
#      into the infra-TAK install directory, under modules/restreamer_qr/.
#   3. Patches app.py (idempotent — safe to re-run) to:
#        a. register the module's Flask routes at startup (same convention as
#           migrate_authentik.py's register_routes(app, login_required,
#           load_settings, save_settings))
#        b. add 'qr': 'qr' to SERVICE_DOMAIN_DEFAULTS, so it gets its own
#           customizable subdomain (qr.<fqdn> by default) like every other
#           module
#        c. add a 'restreamer_qr' entry to detect_modules() (existence-based
#           — it's static files bundled into the console, nothing to
#           health-check, same pattern as the cesium_tiles module)
#        d. add a public, standalone qr.<fqdn> site block to
#           generate_caddyfile(), gated on that module being installed
#   4. Restarts the takwerx-console systemd service.
#   5. Patches the LIVE Caddyfile directly (backup, insert, validate,
#      reload) so the new domain is live immediately, and removes any
#      leftover /qr-path block from an earlier version of this installer
#      that bolted /qr onto the streaming site's domain instead of giving it
#      its own.
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
import re, sys

path = sys.argv[1]
with open(path, 'r', encoding='utf-8') as f:
    src = f.read()

# 4a. Register routes at startup.
REG_MARKER = '[restreamer_qr] Failed to register'
OLD_REG_TAIL = "TAK Restreamer QR Codes module: {_e}', flush=True)\n\n"
NEW_REG_TAIL = "TAK Video Stream QR Codes module: {_e}', flush=True)\n\n"
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
        "    print(f'[restreamer_qr] Failed to register " + NEW_REG_TAIL
    )
    src = src.replace(anchor, block + anchor, 1)
    print("    + registered restreamer_qr.register_routes()")
elif OLD_REG_TAIL in src:
    src = src.replace(OLD_REG_TAIL, NEW_REG_TAIL, 1)
    print("    + renamed display text in registration failure message")
else:
    print("    = module registration already present")

# 4b. Give it its own subdomain via SERVICE_DOMAIN_DEFAULTS (qr.<fqdn> by
# default, customizable from settings like every other service).
if "'qr': 'qr'," not in src:
    m = re.search(r"(SERVICE_DOMAIN_DEFAULTS\s*=\s*\{)(.*?)(\n\})", src, re.DOTALL)
    if not m:
        print("ERROR: could not find SERVICE_DOMAIN_DEFAULTS in app.py — Caddy route NOT added", file=sys.stderr)
        sys.exit(1)
    src = src[:m.start(3)] + "\n    'qr': 'qr'," + src[m.start(3):]
    print("    + added 'qr': 'qr' to SERVICE_DOMAIN_DEFAULTS")
else:
    print("    = SERVICE_DOMAIN_DEFAULTS already has 'qr'")

# 4c. Register with detect_modules() — existence-based, no health check
# needed since it's just static files bundled into the console (same
# pattern as the cesium_tiles module).
DETECT_ANCHOR = "    return dict(sorted(modules.items(), key=lambda x: x[1].get('priority', 99)))"

def _detect_block(display_name):
    return (
        "    # " + display_name + " — public, static QR generator page; always\n"
        "    # available once installed since it's just files bundled into the console,\n"
        "    # no separate process to health-check.\n"
        "    qr_installed = os.path.exists(os.path.join(BASE_DIR, 'modules', 'restreamer_qr', 'index.html'))\n"
        "    modules['restreamer_qr'] = {'name': '" + display_name + "', 'installed': qr_installed, 'running': qr_installed,\n"
        "        'description': 'Public QR code generator for RTMP/RTSP/SRT stream URLs', 'icon': '\U0001F4F1', 'route': '/qr', 'priority': 13}\n"
    )

DETECT_BLOCK = _detect_block('TAK Video Stream QR Codes')
OLD_DETECT_BLOCK = _detect_block('TAK Restreamer QR Codes')
if "modules['restreamer_qr']" not in src:
    if DETECT_ANCHOR not in src:
        print("ERROR: could not find detect_modules() return anchor in app.py — module NOT registered", file=sys.stderr)
        sys.exit(1)
    src = src.replace(DETECT_ANCHOR, DETECT_BLOCK + DETECT_ANCHOR, 1)
    print("    + added restreamer_qr entry to detect_modules()")
elif OLD_DETECT_BLOCK in src:
    src = src.replace(OLD_DETECT_BLOCK, DETECT_BLOCK, 1)
    print("    + renamed display name in detect_modules()")
else:
    print("    = detect_modules() already has restreamer_qr")

# 4d. Add its own public site block to generate_caddyfile(). The console's
# own gunicorn listens with a self-signed cert on :5001 (see this function's
# other reverse_proxy 127.0.0.1:5001 blocks) — a bare reverse_proxy speaks
# plain HTTP to it and gets a TLS handshake back (502), so match the
# transport block those use. `rewrite * /qr{uri}` maps the subdomain's own
# root to the Flask blueprint's /qr/* routes.
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

CADDY_QR_BLOCK = _caddy_qr_block("TAK Video Stream QR Codes — public stream QR generator")
OLD_CADDY_QR_BLOCK = _caddy_qr_block("TAK Restreamer QR Codes — public stream QR generator")
GEN_ANCHOR = "\n    caddyfile = '\\n'.join(lines)\n"
if "qr_svc = modules.get('restreamer_qr'" not in src:
    if GEN_ANCHOR not in src:
        print("ERROR: could not find generate_caddyfile() assembly anchor in app.py — Caddy route NOT added", file=sys.stderr)
        sys.exit(1)
    src = src.replace(GEN_ANCHOR, "\n" + CADDY_QR_BLOCK + "    caddyfile = '\\n'.join(lines)\n", 1)
    print("    + added qr.<fqdn> site block to generate_caddyfile()")
elif OLD_CADDY_QR_BLOCK in src:
    src = src.replace(OLD_CADDY_QR_BLOCK, CADDY_QR_BLOCK, 1)
    print("    + renamed Caddy comment in generate_caddyfile()")
else:
    print("    = generate_caddyfile() already emits the qr site block")

# 4e. Clean up an earlier version of this installer's approach: it bolted a
# /qr path onto MediaMTX's Caddy site block instead of giving this module
# its own domain. Remove that dead code if present.
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
for old in OLD_CADDY_BLOCKS:
    if old in src:
        src = src.replace(old, '', 1)
        print("    - removed old /qr-on-MediaMTX-block code from generate_caddyfile()")
        break

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
SETTINGS="$CONSOLE_DIR/.config/settings.json"
if [ ! -f "$CADDYFILE" ]; then
    echo "==> No $CADDYFILE yet — Caddy not deployed. Deploy Caddy from the"
    echo "    console once, then re-run this script (or install.sh --sync) to"
    echo "    add the qr.<fqdn> site."
elif [ ! -f "$SETTINGS" ]; then
    echo "==> No $SETTINGS yet — base FQDN not configured. Set it up on the"
    echo "    Caddy page, then re-run this script."
else
    CADDY_BAK="$CADDYFILE.bak-$(date +%Y%m%d-%H%M%S)"
    cp -a "$CADDYFILE" "$CADDY_BAK"
    PATCH_RESULT="$(python3 - "$CADDYFILE" "$SETTINGS" <<'PYEOF'
import json, re, sys

caddyfile_path, settings_path = sys.argv[1], sys.argv[2]
with open(caddyfile_path, 'r', encoding='utf-8') as f:
    src = f.read()
with open(settings_path, 'r', encoding='utf-8') as f:
    settings = json.load(f)

fqdn = (settings.get('fqdn') or '').strip()
if not fqdn:
    print("ERROR: no fqdn set in settings.json", file=sys.stderr)
    sys.exit(1)

# Mirrors app.py's _get_service_domain(settings, 'qr'): custom qr_domain
# override (bare label gets the base fqdn appended, a dotted value is used
# as-is), else the "qr" subdomain of the base fqdn.
custom = (settings.get('qr_domain') or '').strip()
if custom:
    qr_host = custom if '.' in custom else f'{custom}.{fqdn}'
else:
    qr_host = f'qr.{fqdn}'

def render(host):
    return (
        f'# TAK Video Stream QR Codes — public stream QR generator\n'
        f'{host} {{\n'
        '    route {\n'
        '        rewrite * /qr{uri}\n'
        '        reverse_proxy 127.0.0.1:5001 {\n'
        '            transport http {\n'
        '                tls\n'
        '                tls_insecure_skip_verify\n'
        '                read_timeout 1h\n'
        '                write_timeout 1h\n'
        '            }\n'
        '        }\n'
        '    }\n'
        '}\n'
        '\n'
    )

CURRENT_BLOCK = render(qr_host)

# Remove any previously-inserted block for THIS module regardless of which
# host it names — a changed qr_domain override means the host in the file
# won't match qr_host anymore, and anchoring on the marker comment (not the
# host) is what lets us find and replace it instead of leaving a duplicate.
# The "Restreamer|Video Stream" alternation also self-heals the module's
# 2026-07 display-name rename: this matches whichever wording is already
# live on disk from an earlier install.
HOST_BLOCK_RE = re.compile(
    r'# TAK (?:Restreamer|Video Stream) QR Codes — public stream QR generator\n' +
    r'[^\n]+\{.*?\n\}\n\n?',
    re.DOTALL,
)
existing = HOST_BLOCK_RE.search(src)
if existing and existing.group(0) == CURRENT_BLOCK:
    print("unchanged")
    sys.exit(0)

changed = False
if existing:
    src = src[:existing.start()] + src[existing.end():]
    changed = True

# Also strip the old /qr-path-on-the-streaming-site approach from an
# earlier version of this installer, if still present.
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
        print(f"    - removed old /qr-on-streaming-site block", file=sys.stderr)

# Insert the new top-level site block right after the auto-generated
# header (position doesn't matter functionally — distinct hostnames are
# independent — this just keeps it readable near the top).
HEADER_RE = re.compile(r'^# infra-TAK - Auto-generated Caddyfile\n# Base Domain: [^\n]*\n\n', re.MULTILINE)
hm = HEADER_RE.match(src)
insert_at = hm.end() if hm else 0
src = src[:insert_at] + CURRENT_BLOCK + src[insert_at:]

with open(caddyfile_path, 'w', encoding='utf-8') as f:
    f.write(src)
print("changed")
PYEOF
)"
    PATCH_OK=$?
    if [ "$PATCH_RESULT" = "unchanged" ]; then
        echo "==> Live Caddyfile already has the current qr.<fqdn> site — nothing to patch"
        rm -f "$CADDY_BAK"
    elif [ "$PATCH_OK" -ne 0 ]; then
        echo "    ⚠ Could not patch live Caddyfile — left unchanged: $PATCH_RESULT" >&2
        rm -f "$CADDY_BAK"
    elif command -v caddy >/dev/null 2>&1 && ! caddy validate --config "$CADDYFILE" --adapter caddyfile >/dev/null 2>&1; then
        echo "ERROR: caddy validate failed after patch — restoring previous Caddyfile" >&2
        cp -a "$CADDY_BAK" "$CADDYFILE"
    else
        echo "    + added/updated qr.<fqdn> site in live Caddyfile"
        echo "    ✓ Caddyfile validates (backup: $CADDY_BAK)"
        if systemctl reload caddy 2>/dev/null || systemctl restart caddy 2>/dev/null; then
            echo "    ✓ Caddy reloaded"
        else
            echo "    ⚠ Could not reload Caddy via systemctl — reload it manually" >&2
        fi
    fi
fi

echo ""
echo "✓ TAK Video Stream QR Codes module installed."
echo "  Public page: https://qr.<your-fqdn> (customizable via a 'qr_domain'"
echo "  setting, same as every other infra-TAK service). If Caddy wasn't"
echo "  deployed yet, or the live-Caddyfile patch above reported a warning,"
echo "  open the Caddy page in the console and click Deploy once to pick it up."
