from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
import re, time, sys, threading, os, hashlib
COUNTS = {}
ACTIVE = {}
LOCK = threading.Lock()
PAYLOAD = bytes(range(256)) * (36 * 1024)  # 9 MiB, deterministic
BENCHMARK = os.environ.get('DOWNLOADJET_BENCHMARK') == '1'
LARGE = bytes(range(256)) * (256 * 1024) if BENCHMARK else PAYLOAD
SMALL = bytes(range(256)) * (8 * 1024)
TAIL_PAYLOAD = b''.join(hashlib.sha256(str(i).encode()).digest() * 2048 for i in range(144))
class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def setup(self):
        super().setup()
        if BENCHMARK: time.sleep(.08)
    @property
    def payload(self):
        if self.path.startswith('/tail-'): return TAIL_PAYLOAD
        if self.path.startswith('/benchmark/large'): return LARGE
        if self.path.startswith('/benchmark/small') or self.path == '/small': return SMALL
        return PAYLOAD
    def log_message(self, *args): pass
    def do_HEAD(self):
        with open(sys.argv[1], 'a') as log:
            log.write('HEAD ' + self.path + ' connection=' + str(self.client_address[1]) + '\n')
        if self.path == '/nohead':
            self.send_response(405); self.end_headers(); return
        self.headers_for(200, len(self.payload))
    def headers_for(self, status, length, content_range=None):
        self.send_response(status)
        self.send_header('Content-Length', str(length))
        if self.path not in ['/plain', '/nohead', '/retry', '/alwaysbusy', '/cancel-retry']:
            self.send_header('Accept-Ranges', 'bytes')
            self.send_header('ETag', '"version-1"')
        if self.path == '/tail-backoff' and status == 503: self.send_header('Retry-After', '1')
        if content_range: self.send_header('Content-Range', content_range)
        self.end_headers()
    def do_GET(self):
        with LOCK:
            ACTIVE[self.path] = ACTIVE.get(self.path, 0) + 1
            active = ACTIVE[self.path]
        try: self.serve_get(active)
        finally:
            with LOCK: ACTIVE[self.path] -= 1
    def serve_get(self, active):
        with open(sys.argv[1], 'a') as log:
            log.write(self.path + ' ' + self.headers.get('Range', 'full') + ' active=' + str(active) + ' connection=' + str(self.client_address[1]) + '\n')
        if self.path == '/missing':
            self.headers_for(404, 0); return
        key = (self.path, self.headers.get('Range', 'full'))
        with LOCK:
            COUNTS[key] = COUNTS.get(key, 0) + 1
            count = COUNTS[key]
        if self.path in ['/retry', '/retry-chunks', '/alwaysbusy', '/cancel-retry']:
            if self.path in ['/alwaysbusy', '/cancel-retry'] or count <= 2:
                self.headers_for(503, 0); return
        match = re.fullmatch(r'bytes=(\d+)-(\d+)', self.headers.get('Range', ''))
        if match and self.path not in ['/plain', '/retry', '/alwaysbusy', '/cancel-retry']:
            start, end = map(int, match.groups())
            if self.path == '/tail-backoff' and end == len(self.payload) - 1 and count == 1:
                self.headers_for(503, 0); return
            data = self.payload[start:end+1]
            invalid = self.path == '/bad' or (self.path == '/tail-invalid-backup' and count > 1 and end == len(self.payload) - 1)
            range_start = start + 1 if invalid else start
            self.headers_for(206, len(data), f'bytes {range_start}-{end}/{len(self.payload)}')
        else:
            data = self.payload
            self.headers_for(200, len(data))
        try:
            for offset in range(0, len(data), 65536):
                self.wfile.write(data[offset:offset+65536])
                if self.path == '/slow': time.sleep(.03)
                if self.path.startswith('/tail-') and match and end == len(self.payload) - 1:
                    if self.path == '/tail-backoff': time.sleep(.02)
                    elif count == 1 or self.path in ['/tail-norelief', '/tail-cancel']:
                        time.sleep(.18)
                if self.path.startswith('/workers-'): time.sleep(.002)
                if self.path.startswith('/benchmark/large'): time.sleep(.0005)
                if self.path.startswith('/benchmark/small'): time.sleep(.008)
        except (BrokenPipeError, ConnectionResetError): pass
server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
print(server.server_port, flush=True)
server.serve_forever()
