import http.server
import json
import socket
import sys
import threading
import time


class Origin(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith('/missing'):
            self.send_response(404)
            self.end_headers()
            return
        if self.path.startswith('/large'):
            body = b'x' * 8192
        elif self.path.startswith('/subscription'):
            body = b'proxies: [{name: Local, type: socks5, server: localhost, port: 1080}]'
        else:
            body = b'DIRECT'
        self.send_response(200)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


class Upstream(Origin):
    def do_CONNECT(self):
        self.send_response(200, 'Connection established')
        self.end_headers()
        self.rfile.readline()
        while self.rfile.readline() not in (b'\r\n', b'\n', b''):
            pass
        self.wfile.write(b'HTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnection: close\r\n\r\nPROXY')
        self.wfile.flush()
        self.close_connection = True

    def do_GET(self):
        self.send_response(200)
        self.send_header('Content-Length', '5')
        self.end_headers()
        self.wfile.write(b'PROXY')


servers = []
for handler in (Origin, Upstream):
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    servers.append(server)
with socket.socket() as reservation:
    reservation.bind(('127.0.0.1', 0))
    proxy_port = reservation.getsockname()[1]
with open(sys.argv[1], 'w') as output:
    json.dump({'origin': servers[0].server_port, 'upstream': servers[1].server_port,
               'proxy': proxy_port}, output)
while True:
    time.sleep(1)
