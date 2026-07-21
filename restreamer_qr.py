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
"""
import os
from flask import send_from_directory, redirect

MODULE_VERSION = '1.0.0'

_STATIC_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'modules', 'restreamer_qr')


def register_routes(app, login_required, load_settings, save_settings):
    @app.route('/qr')
    def restreamer_qr_redirect():
        return redirect('/qr/')

    @app.route('/qr/')
    def restreamer_qr_index():
        return send_from_directory(_STATIC_DIR, 'index.html')

    @app.route('/qr/<path:filename>')
    def restreamer_qr_assets(filename):
        return send_from_directory(_STATIC_DIR, filename)
