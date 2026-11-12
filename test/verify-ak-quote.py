#!/usr/bin/env python3
"""Verify a TPM quote captured by test/ak-test.ipxe.

Reads the serial log, extracts ak-public / ak-name / ak-type / quote /
quote-sig, and checks the quotation the same way the control plane
does: TPMS_ATTEST structure, extraData == nonce, PCR 0/2/4/7 SHA-256
selection, and the AK signature.  Optionally compares the PCR digest
with a baseline digest.

This is a stand-alone check for boot-time acceptance; the authoritative
implementation is the control plane's attestation module.

Usage:
  python3 test/verify-ak-quote.py LOG NONCE [--baseline HEX]

Output: one "OK ..." or "FAIL ..." line per check; exit status 1 on the
first failure.
"""
import re
import sys

from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import ec, padding, rsa
from cryptography.hazmat.primitives.serialization import load_der_public_key

MAGIC = 0xFF544347
TYPE_QUOTE = 0x8018
ALG_SHA256 = 0x000B
PCR_BITMAP = bytes([0x95, 0x00, 0x00])


class Fail(Exception):
    pass


def field(log, name):
    m = re.search(r"^%s: (\S*)\r?$" % re.escape(name), log, re.M)
    if not m:
        raise Fail("missing %s in log" % name)
    return m.group(1)


class Reader:
    def __init__(self, data):
        self.data = data
        self.pos = 0

    def take(self, n):
        if self.pos + n > len(self.data):
            raise Fail("truncated TPMS_ATTEST")
        out = self.data[self.pos:self.pos + n]
        self.pos += n
        return out

    def u16(self):
        return int.from_bytes(self.take(2), "big")

    def u32(self):
        return int.from_bytes(self.take(4), "big")

    def u64(self):
        return int.from_bytes(self.take(8), "big")

    def tpm2b(self):
        return self.take(self.u16())


def parse_quote(blob):
    r = Reader(blob)
    if r.u32() != MAGIC:
        raise Fail("bad TPMS_ATTEST magic")
    if r.u16() != TYPE_QUOTE:
        raise Fail("bad TPMS_ATTEST type")
    signer = r.tpm2b()
    extra = r.tpm2b()
    clock = r.take(17)
    fw = r.u64()
    count = r.u32()
    if count != 1:
        raise Fail("expected one PCR selection, got %d" % count)
    if r.u16() != ALG_SHA256:
        raise Fail("PCR selection is not SHA-256")
    size = r.take(1)[0]
    select = r.take(size)
    if select != PCR_BITMAP:
        raise Fail("PCR selection bitmap is %s, expected %s"
                   % (select.hex(), PCR_BITMAP.hex()))
    digest = r.tpm2b()
    if len(digest) != 32:
        raise Fail("PCR digest length %d" % len(digest))
    if r.pos != len(blob):
        raise Fail("trailing bytes in TPMS_ATTEST")
    return {"signer": signer, "extra": extra, "pcr_digest": digest}


def verify(log, nonce, baseline):
    ak_public = field(log, "ak-public")
    ak_name = field(log, "ak-name")
    ak_type = field(log, "ak-type")
    quote = bytes.fromhex(field(log, "quote"))
    signature = bytes.fromhex(field(log, "quote-sig"))

    if len(ak_name) != 68 or not ak_name.startswith("000b"):
        raise Fail("ak-name is not a 68-hex SHA-256 TPM2B_NAME")
    print("OK   ak-name %s (%s)" % (ak_name, ak_type))

    parsed = parse_quote(quote)
    print("OK   TPMS_ATTEST: PCR 0/2/4/7 SHA-256, digest %s"
          % parsed["pcr_digest"].hex())

    if parsed["extra"] != nonce.encode():
        raise Fail("extraData does not match the nonce")
    print("OK   extraData == nonce (%d ASCII bytes)" % len(nonce))

    key = load_der_public_key(bytes.fromhex(ak_public))
    if ak_type == "ecc_p256":
        if not isinstance(key, ec.EllipticCurvePublicKey):
            raise Fail("ak-type says ecc_p256 but the key is not ECDSA")
        key.verify(signature, quote, ec.ECDSA(hashes.SHA256()))
    elif ak_type == "rsa2048":
        if not isinstance(key, rsa.RSAPublicKey):
            raise Fail("ak-type says rsa2048 but the key is not RSA")
        key.verify(signature, quote, padding.PKCS1v15(), hashes.SHA256())
    else:
        raise Fail("unknown ak-type %s" % ak_type)
    print("OK   signature over the TPMS_ATTEST bytes")

    if baseline is not None:
        if parsed["pcr_digest"].hex().lower() == baseline.lower():
            print("OK   PCR digest matches the baseline")
        else:
            raise Fail("PCR digest %s differs from baseline %s"
                       % (parsed["pcr_digest"].hex(), baseline))
    return parsed["pcr_digest"].hex()


def main():
    args = sys.argv[1:]
    baseline = None
    if "--baseline" in args:
        i = args.index("--baseline")
        baseline = args[i + 1]
        del args[i:i + 2]
    if len(args) != 2:
        sys.exit(__doc__)
    log = open(args[0], "rb").read().decode("utf-8", "replace")
    try:
        digest = verify(log, args[1], baseline)
    except Fail as exc:
        print("FAIL %s" % exc)
        sys.exit(1)
    print("digest=%s" % digest)


if __name__ == "__main__":
    main()
