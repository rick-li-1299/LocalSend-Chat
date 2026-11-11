"""Prepare/assemble APK v2 signatures; private signing keys never enter CI.

Format: https://source.android.com/docs/security/features/apksigning/v2
Verify the final APK independently using Android SDK apksigner and zipalign.
"""
import argparse
import base64
import hashlib
import json
from pathlib import Path
import re
import struct
import zipfile

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding

ALGORITHM = 0x0103
MAGIC = b'APK Sig Block 42'
PACKAGE = 'org.localsendchat.app'
VERSION = '1.0.0'


def lp(data):
    return struct.pack('<I', len(data)) + data


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':')).encode()


def sections(data):
    for pos in range(len(data) - 22, max(-1, len(data) - 65558), -1):
        if data[pos:pos + 4] == b'PK\x05\x06' and pos + 22 + struct.unpack_from('<H', data, pos + 20)[0] == len(data):
            break
    else:
        raise ValueError('Missing ZIP end record')
    disk, cd_disk, disk_entries, entries, cd_size, cd_offset = struct.unpack_from('<4H2I', data, pos + 4)
    if disk or cd_disk or disk_entries != entries or entries == 65535 or cd_offset + cd_size != pos:
        raise ValueError('Unsupported ZIP layout')
    start = cd_offset
    if data[cd_offset - 16:cd_offset] == MAGIC:
        size = struct.unpack_from('<Q', data, cd_offset - 24)[0]
        start = cd_offset - size - 8
        if start < 0 or struct.unpack_from('<Q', data, start)[0] != size:
            raise ValueError('Invalid existing signing block')
    footer = bytearray(data[pos:])
    struct.pack_into('<I', footer, 16, start)
    return data[:start], data[cd_offset:pos], bytes(footer)


def apk_digest(parts):
    digests = []
    for part in parts:
        for offset in range(0, len(part), 1 << 20):
            chunk = part[offset:offset + (1 << 20)]
            digests.append(hashlib.sha256(b'\xa5' + struct.pack('<I', len(chunk)) + chunk).digest())
    return hashlib.sha256(b'\x5a' + struct.pack('<I', len(digests)) + b''.join(digests)).digest()


def signed_data(digest, certificate):
    return lp(lp(struct.pack('<I', ALGORITHM) + lp(digest))) + lp(lp(certificate)) + lp(b'')


def prepare(apk, certificate, source_commit, run_id):
    if not re.fullmatch('[0-9a-f]{40}', source_commit) or not str(run_id).isdigit():
        raise ValueError('Invalid source provenance')
    parts = sections(apk.read_bytes())
    apk.write_bytes(b''.join(parts))
    with zipfile.ZipFile(apk) as archive:
        if archive.testzip() is not None or not {'AndroidManifest.xml', 'classes.dex', 'lib/arm64-v8a/libflutter.so'}.issubset(archive.namelist()):
            raise ValueError('Incomplete ARM64 Android application')
        if any(re.fullmatch(r'META-INF/[^/]+\.(SF|RSA|DSA|EC)', name, re.I) for name in archive.namelist()):
            raise ValueError('Unexpected old JAR signature')
    cert = x509.load_pem_x509_certificate(certificate.read_bytes())
    der = cert.public_bytes(serialization.Encoding.DER)
    digest = apk_digest(parts)
    return {
        'schema': 1, 'algorithm': 'apk-v2-rsa-pkcs1-sha256', 'package': PACKAGE, 'version': VERSION,
        'min_sdk': 27, 'abi': 'arm64-v8a', 'source_commit': source_commit, 'workflow_run_id': str(run_id),
        'unsigned_apk_sha256': hashlib.sha256(b''.join(parts)).hexdigest(),
        'certificate_sha256': hashlib.sha256(der).hexdigest(),
        'content_digest': base64.b64encode(digest).decode(),
        'signed_data': base64.b64encode(signed_data(digest, der)).decode(),
    }


def assemble(apk, certificate, request, response, output):
    actual = prepare(apk, certificate, request['source_commit'], request['workflow_run_id'])
    if actual != request or response['request_sha256'] != hashlib.sha256(canonical(request)).hexdigest():
        raise ValueError('APK or signing request changed')
    cert = x509.load_pem_x509_certificate(certificate.read_bytes())
    data = base64.b64decode(request['signed_data'], validate=True)
    signature = base64.b64decode(response['signature'], validate=True)
    cert.public_key().verify(signature, data, padding.PKCS1v15(), hashes.SHA256())
    public = cert.public_key().public_bytes(serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo)
    signer = lp(data) + lp(lp(struct.pack('<I', ALGORITHM) + lp(signature))) + lp(public)
    v2 = lp(lp(signer))
    pair = struct.pack('<Q', 4 + len(v2)) + struct.pack('<I', 0x7109871a) + v2
    size = len(pair) + 24
    block = struct.pack('<Q', size) + pair + struct.pack('<Q', size) + MAGIC
    body, central, footer = sections(apk.read_bytes())
    footer = bytearray(footer)
    struct.pack_into('<I', footer, 16, len(body) + len(block))
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_bytes(body + block + central + footer)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('command', choices=['prepare', 'assemble'])
    parser.add_argument('--apk', type=Path, required=True)
    parser.add_argument('--certificate', type=Path, required=True)
    parser.add_argument('--request', type=Path, required=True)
    parser.add_argument('--source-commit')
    parser.add_argument('--run-id')
    parser.add_argument('--response', type=Path)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    if args.command == 'prepare':
        result = prepare(args.apk, args.certificate, args.source_commit, args.run_id)
        args.request.write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')
        print('Prepared signing request; no private key needed in CI.')
    else:
        assemble(args.apk, args.certificate, json.loads(args.request.read_text()), json.loads(args.response.read_text()), args.output)
        print('Signature assembled; verify independently with Android SDK apksigner.')
