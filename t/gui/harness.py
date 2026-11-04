#!/usr/bin/env python3
"""Build and run the real PVE 9.2 GUI smoke test inside Playwright."""

import http.server
import json
import os
import pathlib
import re
import shutil
import socketserver
import subprocess
import sys
import threading
import urllib.parse

REPO = pathlib.Path('/repo')
WORK = pathlib.Path('/work')
ASSETS = pathlib.Path(os.environ['MM_GUI_ASSETS'])
OLD_JS = os.environ.get('MM_GUI_OLD_JS', '')
VERSION = re.search(r'^mm-pve-tools \(([^)-]+)', (REPO / 'debian/changelog').read_text()).group(1)


def find_asset(name):
    matches = list(ASSETS.rglob(name))
    if not matches:
        raise RuntimeError(f'asset ausente: {name} em {ASSETS}')
    return matches[0]


def find_asset_optional(name):
    matches = list(ASSETS.rglob(name))
    return matches[0] if matches else None


def copy_versioned_libs():
    target = WORK / 'lib'
    shutil.copytree(REPO / 'lib', target)
    for path in target.rglob('*'):
        if path.is_file():
            data = path.read_text(encoding='utf-8')
            path.write_text(data.replace('@MM_PVE_VERSION@', VERSION), encoding='utf-8')


def build_js():
    output = WORK / 'mm-tools.js'
    if OLD_JS:
        shutil.copy2(OLD_JS, output)
        return output
    chunks = ['/* mm-tools.js — harness build */\n']
    for name in ('core.js', 'renumber.js', 'restore.js', 'branding.js'):
        source = (REPO / 'js/src' / name).read_text(encoding='utf-8')
        chunks.append(f'\n/* ===== js/src/{name} ===== */\n')
        chunks.append(source.replace('@MM_PVE_VERSION@', VERSION))
    output.write_text(''.join(chunks), encoding='utf-8')
    return output


def render_template(template):
    """Resolve only the Template Toolkit constructs in the captured index."""
    def choose(pattern, yes):
        nonlocal template
        match = re.search(pattern, template, re.S)
        if not match:
            return
        body = match.group(1) if yes else match.group(2)
        template = template[:match.start()] + body + template[match.end():]

    choose(r'\[%\s*-?\s*IF langfile\s*%\](.*?)\[%\s*-?\s*ELSE\s*%\](.*?)\[%\s*-?\s*END\s*-?\s*%\]', False)
    choose(r'\[%\s*-?\s*IF debug\s*%\](.*?)\[%\s*-?\s*ELSE\s*%\](.*?)\[%\s*-?\s*END\s*-?\s*%\]', False)
    template = re.sub(r'\[%\s*-?\s*IF theme != \'crisp\'\s*%\].*?\[%\s*-?\s*END\s*-?\s*%\]', '', template, flags=re.S)
    values = {
        'nodename': 'gui-harness', 'version': '9.2.24', 'wtversion': '3.0.0',
        'lang': 'en', 'i18n_js_mtime': '0', 'theme': 'crisp', 'arch': 'x86_64',
        'username': 'root@pam', 'token': 'harness-token', 'consenttext.squote': '',
    }
    for key, value in values.items():
        template = re.sub(r'\[%\s*' + re.escape(key) + r'\s*%\]', value, template)
    template = re.sub(r'\[%.*?%\]', '', template, flags=re.S)
    template = template.replace('Ext.create(\'PVE.StdWorkspace\');', 'window.__MM_HARNESS_READY__ = true;')
    return template


class Handler(http.server.BaseHTTPRequestHandler):
    index = ''
    mm_js = pathlib.Path()
    requests = []

    def log_message(self, fmt, *args):
        return

    def record(self, method, path):
        self.requests.append(f'{method} {path}')
        del self.requests[:-40]

    def send_json(self, value, status=200):
        raw = json.dumps({'data': value}).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self):
        path = urllib.parse.urlparse(self.path).path
        self.record('GET', path)
        if path in ('/', '/index.html'):
            raw = self.index.encode()
            self.send_response(200)
            self.send_header('Content-Type', 'text/html; charset=utf-8')
            self.send_header('Content-Length', str(len(raw)))
            self.end_headers()
            self.wfile.write(raw)
            return
        if path == '/pve2/js/mm-tools.js':
            self.serve(self.mm_js, 'application/javascript')
            return
        asset = self.asset(path)
        if asset is not None:
            self.serve(asset, self.content_type(path))
            return
        if path.startswith('/api2/'):
            self.api(path)
            return
        self.send_response(404)
        self.end_headers()

    def do_POST(self):
        path = urllib.parse.urlparse(self.path).path
        self.record('POST', path)
        self.api(path)

    @staticmethod
    def asset(path):
        if path == '/proxmoxlib.js':
            name = 'proxmoxlib.js'
        elif path == '/qrcode.min.js':
            name = 'qrcode.min.js'
        elif path.startswith(('/pve2/ext6/', '/pve2/js/', '/pve2/css/', '/pwt/')):
            name = pathlib.PurePosixPath(path).name
        else:
            return None
        return find_asset_optional(name)

    @staticmethod
    def content_type(path):
        if path.endswith('.js'):
            return 'application/javascript'
        if path.endswith('.css'):
            return 'text/css'
        return 'application/octet-stream'

    def serve(self, path, content_type):
        raw = pathlib.Path(path).read_bytes()
        self.send_response(200)
        self.send_header('Content-Type', content_type)
        self.send_header('Content-Length', str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def api(self, path):
        if path.endswith('/access/ticket'):
            self.send_json({'ticket': 'PVE:root@pam:harness', 'username': 'root@pam', 'cap': {
                'dc': {'Sys.Audit': 1, 'Sys.Modify': 1},
                'vms': {'VM.Audit': 1, 'VM.Backup': 1},
                'nodes': {'Sys.Audit': 1, 'Sys.Modify': 1},
            }})
        elif path.endswith('/cluster/status'):
            self.send_json([{'type': 'node', 'node': 'localhost', 'name': 'localhost', 'online': 1}])
        elif path.endswith('/cluster/resources'):
            self.send_json([{'type': 'node', 'node': 'localhost', 'status': 'online'},
                            {'type': 'qemu', 'vmid': 100, 'node': 'localhost', 'name': 'harness'}])
        elif path.endswith('/storage'):
            self.send_json([{'storage': 'pbs', 'type': 'pbs', 'content': 'backup'}])
        elif '/storage/pbs/content' in path:
            self.send_json([{'volid': 'pbs:backup/vm/100/2026-10-30T00:00:00Z',
                             'vmid': 100, 'format': 'pbs-vm', 'text': 'backup'}])
        elif path.endswith('/version'):
            self.send_json({'version': '9.2.24', 'release': '9.2'})
        elif path.endswith('/config'):
            self.send_json({'digest': 'sha256:' + '0' * 64, 'config': {'modules': {}}})
        elif path.endswith('/mm-tools/status'):
            self.send_json({'node': 'localhost', 'package_version': VERSION,
                            'pve_version': '9.2.24', 'applied': {'state': 'applied'}})
        elif path.endswith('/mm-tools/restore/sessions'):
            self.send_json([])
        else:
            self.send_json([])


def main():
    copy_versioned_libs()
    js = build_js()
    root = WORK / 'root'
    (root / 'usr/share/pve-manager').mkdir(parents=True)
    (root / 'usr/share/perl5/PVE/API2').mkdir(parents=True)
    shutil.copy2(find_asset('index.html.tpl'), root / 'usr/share/pve-manager/index.html.tpl')
    shutil.copy2(find_asset('Nodes.pm'), root / 'usr/share/perl5/PVE/API2/Nodes.pm')
    patch_cmd = [
        'perl', '-I' + str(WORK / 'lib'), '-I' + str(REPO / 'perl'),
        '-MMMPve::Core::Patch', '-e',
        'my $r=MMPve::Core::Patch->apply(no_restart=>1); exit($r->{ok} ? 0 : 1);',
    ]
    env = dict(os.environ, MM_PVE_ROOT=str(root))
    result = subprocess.run(patch_cmd, env=env, text=True, capture_output=True)
    if result.returncode != 0:
        print(result.stdout, result.stderr, file=sys.stderr)
        return result.returncode
    patched = (root / 'usr/share/pve-manager/index.html.tpl').read_text(encoding='utf-8')
    if '/pve2/js/mm-tools.js?ver=' not in patched:
        raise RuntimeError('apply-patches não inseriu o script na template real')
    Handler.index = render_template(patched)
    if '__MM_HARNESS_READY__' not in Handler.index:
        raise RuntimeError('renderização do index não encontrou o ponto de prontidão')
    Handler.mm_js = js
    class Server(socketserver.ThreadingTCPServer):
        allow_reuse_address = True
        daemon_threads = True

    with Server(('127.0.0.1', 0), Handler) as server:
        port = server.server_address[1]
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        print(f'GUI: server up at 127.0.0.1:{port}', flush=True)
        try:
            print('GUI: launching browser driver (timeout 180s)', flush=True)
            browser = subprocess.run([
                'node', str(REPO / 't/gui/browser.js'), str(port),
            ], env=dict(os.environ, NODE_PATH='/usr/local/lib/node_modules:/usr/lib/node_modules'),
                       capture_output=True, text=True, timeout=180)
        except subprocess.TimeoutExpired as error:
            print('GUI FAIL: browser driver timed out after 180s', file=sys.stderr)
            if error.stdout:
                print(error.stdout, file=sys.stderr, end='')
            if error.stderr:
                print(error.stderr, file=sys.stderr, end='')
            print('GUI: last server requests:', file=sys.stderr)
            print('\n'.join(Handler.requests), file=sys.stderr)
            return 124
        finally:
            server.shutdown()
        if browser.stdout:
            print(browser.stdout, end='')
        if browser.returncode != 0:
            if browser.stderr:
                print(browser.stderr, file=sys.stderr, end='')
            print('GUI: last server requests:', file=sys.stderr)
            print('\n'.join(Handler.requests), file=sys.stderr)
        print(f'GUI: browser exited rc={browser.returncode}', flush=True)
        return browser.returncode


if __name__ == '__main__':
    sys.exit(main())
