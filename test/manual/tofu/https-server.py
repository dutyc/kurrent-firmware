#!/usr/bin/env python3
# Minimal HTTPS server for TOFU verification rounds.
#
# Usage: https-server.py <port> <cert.pem> <key.pem> <directory>
#   Serves directory over TLS 1.2 (iPXE does not support TLS 1.3).
import http.server
import ssl
import sys

port = int(sys.argv[1])
cert = sys.argv[2]
key = sys.argv[3]
directory = sys.argv[4]

class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        # SimpleHTTPRequestHandler's __init__ overrides the class-level
        # directory with os.getcwd() unless passed explicitly.
        super().__init__(*args, directory=directory, **kwargs)

httpd = http.server.HTTPServer(("0.0.0.0", port), Handler)
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(cert, key)
ctx.maximum_version = ssl.TLSVersion.TLSv1_2
ctx.set_ciphers(
    "ECDHE-RSA-AES128-GCM-SHA256:"
    "ECDHE-RSA-AES256-GCM-SHA384:"
    "ECDHE-RSA-AES128-SHA256:"
    "ECDHE-RSA-AES256-SHA384"
)
httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)
print(f"HTTPS server on :{port} with {cert}", flush=True)
httpd.serve_forever()
