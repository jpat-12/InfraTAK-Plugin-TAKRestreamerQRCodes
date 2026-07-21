"""InfraTAK module: TAK Video Stream QR Codes.

Registers a public (unauthenticated) /qr page into a running infra-TAK
console — the protocol/address/port/path form and QR generator from
index.html/css/js in this repo. Unauthenticated is intentional: anyone who
already knows the stream address can reach the stream itself, and the point
of this page is to be scannable without a console login.

install.sh copies this file plus the static assets (index.html, css/, js/)
into the console's modules/restreamer_qr/ directory and patches app.py to
call register_routes() at startup, following the same convention as
migrate_authentik.py's register_routes(app, login_required, load_settings,
save_settings).

This is a standalone infra-TAK module with its own subdomain (qr.<fqdn> by
default) — install.sh also patches SERVICE_DOMAIN_DEFAULTS, detect_modules(),
and generate_caddyfile() so it gets a public top-level Caddy site like every
other module, plus patches the live Caddyfile directly so it's reachable
immediately (no manual Deploy click needed). Caddy rewrites all requests on
that subdomain to /qr{uri} before proxying here, which is why every route
below still lives under the /qr prefix.

/admin/qr is the console-side (authenticated) settings page — mirrors the
mediamtx page's password-gated uninstall modal (see MEDIAMTX_TEMPLATE in
app.py) so removing this module works the same way as every other one,
instead of requiring SSH + manually running uninstall.sh.
"""
import os
import subprocess
from flask import send_from_directory, redirect, render_template_string, request, jsonify

MODULE_VERSION = '1.1.0'

_STATIC_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'modules', 'restreamer_qr')
_UNINSTALL_SCRIPT = os.path.expanduser('~/.infra-tak-modules/restreamer-qr/uninstall.sh')

_ADMIN_TEMPLATE = '''<!DOCTYPE html><html lang="en"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1.0">
<title>TAK Video Stream QR Codes</title>
<link rel="preconnect" href="https://fonts.googleapis.com"><link href="https://fonts.googleapis.com/css2?family=DM+Sans:wght@400;500;600;700&family=JetBrains+Mono:wght@400;500;600&display=swap" rel="stylesheet">
<link href="https://fonts.googleapis.com/css2?family=Material+Symbols+Outlined:opsz,wght,FILL,GRAD@24,400,0,0" rel="stylesheet">
<style>
:root{--bg-deep:#080b14;--bg-surface:#0f1219;--bg-card:#161b26;--border:#1e2736;--border-hover:#2a3548;--text-primary:#f1f5f9;--text-secondary:#cbd5e1;--text-dim:#94a3b8;--accent:#3b82f6;--cyan:#06b6d4;--green:#10b981;--red:#ef4444}
*{box-sizing:border-box;margin:0;padding:0}
body{background:var(--bg-deep);color:var(--text-primary);font-family:'DM Sans',sans-serif;min-height:100vh;display:flex;flex-direction:row}
.sidebar{width:220px;min-width:220px;background:var(--bg-surface);border-right:1px solid var(--border);padding:24px 0;display:flex;flex-direction:column;flex-shrink:0}
.material-symbols-outlined{font-family:'Material Symbols Outlined';font-weight:400;font-style:normal;font-size:20px;line-height:1;letter-spacing:normal;white-space:nowrap;direction:ltr;-webkit-font-smoothing:antialiased}
.nav-icon.material-symbols-outlined{font-size:22px;width:22px;text-align:center}
.sidebar-logo{padding:0 20px 24px;border-bottom:1px solid var(--border);margin-bottom:16px}
.sidebar-logo span{font-size:15px;font-weight:700;letter-spacing:.05em;color:var(--text-primary)}
.sidebar-logo small{display:block;font-size:10px;color:var(--text-dim);font-family:'JetBrains Mono',monospace;margin-top:2px}
.nav-item{display:flex;align-items:center;gap:10px;padding:9px 20px;color:var(--text-secondary);text-decoration:none;font-size:13px;font-weight:500;transition:all .15s;border-left:2px solid transparent}
.nav-item:hover{color:var(--text-primary);background:rgba(255,255,255,.03);border-left-color:var(--border-hover)}
.nav-item.active{color:var(--cyan);background:rgba(6,182,212,.06);border-left-color:var(--cyan)}
.nav-icon{font-size:15px;width:18px;text-align:center}
.main{flex:1;min-width:0;overflow-y:auto;padding:32px}
.page-header{margin-bottom:28px}.page-header h1{font-size:22px;font-weight:700}.page-header p{color:var(--text-secondary);font-size:13px;margin-top:4px}
.card{background:var(--bg-card);border:1px solid var(--border);border-radius:12px;padding:24px;margin-bottom:20px}
.card-title{font-size:13px;font-weight:600;color:var(--text-dim);text-transform:uppercase;letter-spacing:.08em;margin-bottom:16px}
.status-banner{display:flex;align-items:center;gap:12px;padding:14px 18px;border-radius:10px;margin-bottom:20px;font-size:13px;background:rgba(16,185,129,.08);border:1px solid rgba(16,185,129,.2);color:var(--green)}
.dot{width:8px;height:8px;border-radius:50%;background:currentColor}
.info-grid{display:grid;grid-template-columns:1fr 1fr;gap:8px}
.info-item{background:#0a0e1a;border-radius:8px;padding:12px 14px}
.info-label{font-size:11px;color:var(--text-dim);margin-bottom:3px;text-transform:uppercase}
.info-value{font-size:13px;font-family:'JetBrains Mono',monospace;word-break:break-all}
.btn{display:inline-flex;align-items:center;gap:8px;padding:10px 20px;border-radius:8px;font-size:13px;font-weight:600;cursor:pointer;border:none}
.btn-ghost{background:rgba(255,255,255,.05);color:var(--text-secondary);border:1px solid var(--border)}
.btn-danger{background:var(--red);color:#fff}
.control-btn{padding:10px 20px;border:1px solid var(--border);border-radius:8px;background:var(--bg-card);color:var(--text-secondary);font-family:'JetBrains Mono',monospace;font-size:13px;cursor:pointer;transition:all 0.2s}
.control-btn.btn-remove{border-color:rgba(239,68,68,0.2)}.control-btn.btn-remove:hover{background:rgba(239,68,68,0.1);color:var(--red)}
.section-title{font-family:'JetBrains Mono',monospace;font-size:12px;font-weight:600;color:var(--text-dim);letter-spacing:2px;text-transform:uppercase;margin-bottom:16px}
.modal-overlay{position:fixed;inset:0;background:rgba(0,0,0,.7);z-index:1000;display:none;align-items:center;justify-content:center}
.modal-overlay.open{display:flex}
.modal{background:var(--bg-card);border:1px solid var(--border);border-radius:14px;padding:28px;width:400px;max-width:90vw}
.modal h3{font-size:16px;margin-bottom:8px;color:var(--red)}
.modal p{font-size:13px;color:var(--text-secondary);margin-bottom:20px}
.modal-actions{display:flex;gap:10px;justify-content:flex-end}
.form-label{display:block;font-size:12px;font-weight:600;color:var(--text-secondary);margin-bottom:6px}
.form-input{width:100%;background:#0a0e1a;border:1px solid var(--border);border-radius:8px;padding:10px 14px;color:var(--text-primary);font-size:13px}
</style></head>
<body>
{{ sidebar_html }}
<div class="main">
  <div class="page-header"><h1>TAK Video Stream QR Codes</h1><p>Public QR code generator for RTMP/RTSP/SRT stream URLs</p></div>
  <div class="status-banner"><div class="dot"></div>Installed</div>
  <div class="card"><div class="card-title">Access</div><div class="info-grid">
    <div class="info-item"><div class="info-label">Public page</div><div class="info-value">{% if public_url %}<a href="{{ public_url }}" target="_blank" rel="noopener noreferrer" style="color:var(--cyan);text-decoration:none">{{ public_url }}</a> &#8599;{% else %}base FQDN not configured yet &mdash; set it up on the Caddy page{% endif %}</div></div>
    <div class="info-item"><div class="info-label">Install dir</div><div class="info-value">modules/restreamer_qr/</div></div>
  </div></div>
  <div class="section-title" style="margin-top:20px">Controls</div>
  <div style="background:var(--bg-card);border:1px solid var(--border);border-radius:12px;padding:16px 20px;margin-bottom:24px">
  <div style="display:flex;gap:10px;flex-wrap:wrap;align-items:center">
    <button class="control-btn btn-remove" onclick="document.getElementById('uninstall-modal').classList.add('open')">&#x1F5D1; Remove</button>
  </div>
  </div>
</div>
<div class="modal-overlay" id="uninstall-modal"><div class="modal">
  <h3>&#x26a0; Uninstall TAK Video Stream QR Codes?</h3>
  <p>Removes the module's routes and files from the console, its Caddy site, and restarts the console. The public page stops working immediately.</p>
  <div style="margin-bottom:16px"><label class="form-label">Admin password</label><input class="form-input" id="uninstall-password" type="password" placeholder="Confirm password"></div>
  <div class="modal-actions"><button class="btn btn-ghost" onclick="document.getElementById('uninstall-modal').classList.remove('open')">Cancel</button><button class="btn btn-danger" onclick="doUninstall()">Uninstall</button></div>
  <div id="uninstall-msg" style="margin-top:10px;font-size:12px;color:var(--red)"></div>
</div></div>
<script>
function doUninstall(){
  var pw = document.getElementById('uninstall-password').value;
  var msg = document.getElementById('uninstall-msg');
  msg.style.color = 'var(--text-dim)';
  msg.textContent = 'Uninstalling…';
  fetch('/api/restreamer_qr/uninstall', {method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify({password: pw})})
    .then(function(r){ return r.json().then(function(d){ return {ok: r.ok, data: d}; }); })
    .then(function(res){
      if (res.ok && res.data.success) {
        msg.style.color = 'var(--green)';
        msg.textContent = 'Uninstalled. Reloading…';
        setTimeout(function(){ window.location.href = '/'; }, 1500);
      } else {
        msg.style.color = 'var(--red)';
        msg.textContent = (res.data && res.data.error) || 'Uninstall failed';
      }
    })
    .catch(function(e){ msg.style.color = 'var(--red)'; msg.textContent = 'Request failed: ' + e; });
}
</script>
</body></html>'''


def register_routes(app, login_required, load_settings, save_settings, load_auth, check_password_hash):
    @app.route('/qr')
    def restreamer_qr_redirect():
        return redirect('/qr/')

    @app.route('/qr/')
    def restreamer_qr_index():
        return send_from_directory(_STATIC_DIR, 'index.html')

    @app.route('/qr/<path:filename>')
    def restreamer_qr_assets(filename):
        return send_from_directory(_STATIC_DIR, filename)

    @app.route('/admin/qr')
    @login_required
    def restreamer_qr_admin():
        settings = load_settings()
        fqdn = (settings.get('fqdn') or '').strip()
        custom = (settings.get('qr_domain') or '').strip()
        if custom:
            qr_host = custom if '.' in custom else f'{custom}.{fqdn}'
        elif fqdn:
            qr_host = f'qr.{fqdn}'
        else:
            qr_host = ''
        public_url = f'https://{qr_host}' if qr_host else ''
        return render_template_string(_ADMIN_TEMPLATE, public_url=public_url)

    @app.route('/api/restreamer_qr/uninstall', methods=['POST'])
    @login_required
    def restreamer_qr_uninstall():
        data = request.get_json(silent=True) or {}
        password = data.get('password', '')
        auth = load_auth()
        if not auth.get('password_hash') or not check_password_hash(auth['password_hash'], password):
            return jsonify({'error': 'Invalid admin password'}), 403
        if not os.path.exists(_UNINSTALL_SCRIPT):
            return jsonify({'error': f'uninstall.sh not found at {_UNINSTALL_SCRIPT}'}), 500
        try:
            result = subprocess.run(['bash', _UNINSTALL_SCRIPT], capture_output=True, text=True, timeout=180)
        except subprocess.TimeoutExpired:
            return jsonify({'error': 'uninstall.sh timed out after 180s'}), 500
        if result.returncode != 0:
            return jsonify({'error': (result.stderr or result.stdout or 'uninstall.sh failed')[-2000:]}), 500
        return jsonify({'success': True})
