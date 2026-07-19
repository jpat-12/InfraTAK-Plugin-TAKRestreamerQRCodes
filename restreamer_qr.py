"""InfraTAK module: TAK Restreamer QR Codes.

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

Reaching /qr from the outside requires a Caddy route in MediaMTX's site
block (install.sh does not touch the live Caddyfile — see this repo's
README for the one-line addition to generate_caddyfile() and the "Deploy"
click needed to apply it).
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
