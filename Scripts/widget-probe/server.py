# Local test server for the widget probe (ADR 0016): 127.0.0.1 only. Ports A (listed) and B (unlisted) take TCP and
# UDP (QUIC for WebTransport), port U takes UDP (STUN for WebRTC). Every TCP accept, request and datagram goes to the
# log file: the ground truth of what reached it.
import base64, hashlib, urllib.parse, socket, sys, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

A, B, U, LOG = int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
lock = threading.Lock()
PNG = base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")

def log(line):
    with lock, open(LOG, "a") as f:
        f.write(f"{time.time():.3f} {line}\n")

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass

    def reply(self, body=b"ok", ctype="text/plain", code=200, extra=None):
        self.send_response(code)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        for k, v in (extra or {}).items(): self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        port = self.server.server_address[1]
        tag = "A" if port == A else "B"
        upgrade = self.headers.get("Upgrade", "")
        log(f"HIT port={tag} method=GET upgrade={upgrade or '-'} path={self.path}")
        if upgrade.lower() == "websocket":
            key = self.headers["Sec-WebSocket-Key"]
            acc = base64.b64encode(hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()
            self.wfile.write(f"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {acc}\r\n\r\n".encode())
            self.wfile.flush(); time.sleep(1.5); return
        if self.path.startswith("/redirect"):
            to = urllib.parse.unquote(self.path.split("to=", 1)[1])
            self.reply(b"", code=302, extra={"Location": to}); return
        if self.path.startswith("/img"): self.reply(PNG, "image/png"); return
        if self.path.startswith("/script"): self.reply(b"window.__scriptRan = (window.__scriptRan||0)+1;", "text/javascript"); return
        self.reply()

    def do_POST(self):
        port = self.server.server_address[1]
        n = int(self.headers.get("Content-Length", "0") or 0)
        if n: self.rfile.read(n)
        log(f"HIT port={'A' if port == A else 'B'} method=POST upgrade=- path={self.path}")
        self.reply()

    def do_OPTIONS(self):
        log(f"HIT port={'A' if self.server.server_address[1] == A else 'B'} method=OPTIONS upgrade=- path={self.path}")
        self.reply(b"", extra={"Access-Control-Allow-Methods": "*", "Access-Control-Allow-Headers": "*"})

class Server(ThreadingHTTPServer):
    def get_request(self):
        sock, addr = super().get_request()
        log(f"ACCEPT port={'A' if self.server_address[1] == A else 'B'} from={addr[0]}:{addr[1]}")
        return sock, addr

def udp(port, tag):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.bind(("127.0.0.1", port))
    while True:
        data, addr = s.recvfrom(4096)
        log(f"UDP port={tag} bytes={len(data)} from={addr[0]}:{addr[1]}")

for p in (A, B):
    srv = Server(("127.0.0.1", p), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
for p, tag in ((A, "A"), (B, "B"), (U, "U")):
    threading.Thread(target=udp, args=(p, tag), daemon=True).start()
log(f"READY A={A} B={B} U={U}")
while True: time.sleep(3600)
