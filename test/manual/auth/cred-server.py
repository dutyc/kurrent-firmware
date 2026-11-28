#!/usr/bin/env python3
"""HTTP credential endpoint for NVMe-oF auth validation.

Emulates the control-plane /boot-vars endpoint: returns iPXE variable
assignments (the DH-HMAC-CHAP secret) keyed by client MAC/hostname.

The iPXE boot script does:
    chain --autofree http://<host>:8000/boot-vars?mac=${mac}&hostname=${hostname}
and the returned body ("set nbft-secret ...") is executed as an iPXE
script, making the secret available to the subsequent sanboot command.

NOTE: this is a test-only endpoint.  In the real architecture this
endpoint sits behind strict authentication (TLS/mTLS, client identity).

Usage: python3 test/manual/auth/cred-server.py [port]   (default port 8000)
"""
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

# DH-HMAC-CHAP key in "DHHC-1:XX:base64" format (NVMe base spec):
# XX = 01 (SHA256); base64 = 32-byte key + CRC32 little-endian.
# IMPORTANT: XX MUST be two digits -- both kernel sides (host
# nvme_auth_generate_key and target nvmet_setup_auth) hardcode a 10-byte
# prefix skip (secret+10), so a one-digit type silently truncates the
# first base64 character and fails with "base64 key decoding error -1".
# iPXE itself parses the prefix dynamically and accepts either format.
# IMPORTANT: the CRC32 must be the standard CRC-32 final value
# (zlib.crc32); nvmet verifies it in nvme_auth_extract_key() and rejects
# mismatches with "Failed to setup authentication, dhchap status 2".
# MUST match DHHCP_KEY in nvmet-setup.sh (both sides share the same key).
SECRET = "DHHC-1:01:MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWYOtVl3"


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if not self.path.startswith("/boot-vars"):
            self.send_error(404)
            return
        query = self.path.split("?", 1)[1] if "?" in self.path else ""
        print(f"==> boot-vars request: {query}", flush=True)
        body = (
            "#!ipxe\n"
            f"# credentials for {query}\n"
            f"set nbft-secret {SECRET}\n"
        ).encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        sys.stderr.write(f"[cred-server] {fmt % args}\n")


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8000
    print(f"==> credential endpoint on :{port}", flush=True)
    HTTPServer(("127.0.0.1", port), Handler).serve_forever()
