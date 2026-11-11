"""Windows-local Android signing. Private key is protected with user-scoped DPAPI."""
import argparse
import base64
import ctypes
from ctypes import wintypes
from datetime import datetime, timedelta, timezone
import hashlib
import json
from pathlib import Path

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding, rsa
from cryptography.x509.oid import NameOID

from android_apk_signing import PACKAGE, VERSION, canonical, signed_data


class Blob(ctypes.Structure):
    _fields_ = [('size', wintypes.DWORD), ('data', ctypes.POINTER(ctypes.c_ubyte))]


def dpapi(value, decrypt=False):
    buffer = (ctypes.c_ubyte * len(value)).from_buffer_copy(value)
    source = Blob(len(value), buffer)
    output = Blob()
    library = ctypes.WinDLL('crypt32', use_last_error=True)
    if decrypt:
        ok = library.CryptUnprotectData(ctypes.byref(source), None, None, None, None, 1, ctypes.byref(output))
    else:
        ok = library.CryptProtectData(ctypes.byref(source), 'LocalSend Chat Android release key', None, None, None, 1, ctypes.byref(output))
    if not ok:
        raise ctypes.WinError(ctypes.get_last_error())
    try:
        return ctypes.string_at(output.data, output.size)
    finally:
        free = ctypes.WinDLL('kernel32').LocalFree
        free.argtypes = [ctypes.c_void_p]
        free(output.data)


def load_key(directory):
    private = directory / 'release-key.dpapi'
    cert_file = directory / 'release-certificate.pem'
    if private.exists():
        return serialization.load_der_private_key(dpapi(private.read_bytes(), decrypt=True), password=None), cert_file.read_bytes()
    if cert_file.exists():
        raise ValueError('Certificate exists without its private key; do not replace the signing identity.')
    directory.mkdir(parents=True, exist_ok=True)
    key = rsa.generate_private_key(public_exponent=65537, key_size=4096)
    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, 'LocalSend Chat Android Release')])
    now = datetime.now(timezone.utc)
    cert = (x509.CertificateBuilder().subject_name(name).issuer_name(name).public_key(key.public_key())
            .serial_number(x509.random_serial_number()).not_valid_before(now - timedelta(days=1))
            .not_valid_after(now + timedelta(days=10000)).sign(key, hashes.SHA256()))
    protected = dpapi(key.private_bytes(serialization.Encoding.DER, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))
    with private.open('xb') as stream:
        stream.write(protected)
    pem = cert.public_bytes(serialization.Encoding.PEM)
    cert_file.write_bytes(pem)
    return key, pem


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('command', choices=['init', 'sign'])
    parser.add_argument('--key-dir', type=Path, required=True)
    parser.add_argument('--certificate', type=Path)
    parser.add_argument('--request', type=Path)
    parser.add_argument('--response', type=Path)
    parser.add_argument('--expected-commit')
    args = parser.parse_args()
    key, pem = load_key(args.key_dir)
    certificate = x509.load_pem_x509_certificate(pem)
    assert certificate.public_key().public_numbers() == key.public_key().public_numbers(), 'Signing identity mismatch'
    der = certificate.public_bytes(serialization.Encoding.DER)
    fingerprint = hashlib.sha256(der).hexdigest()
    if args.command == 'init':
        if args.certificate.exists() and args.certificate.read_bytes() != pem:
            raise ValueError('Existing release certificate differs; restore the original signing-key directory rather than replacing its identity.')
        args.certificate.parent.mkdir(parents=True, exist_ok=True)
        args.certificate.write_bytes(pem)
        print('Android signing identity ready. Public certificate SHA-256: ' + fingerprint)
    else:
        request = json.loads(args.request.read_text(encoding='utf-8'))
        assert request['schema'] == 1 and request['algorithm'] == 'apk-v2-rsa-pkcs1-sha256'
        assert request['package'] == PACKAGE and request['version'] == VERSION and request['min_sdk'] == 27
        assert request['abi'] == 'arm64-v8a' and request['source_commit'] == args.expected_commit
        assert request['certificate_sha256'] == fingerprint
        digest = base64.b64decode(request['content_digest'], validate=True)
        assert len(digest) == 32
        data = signed_data(digest, der)
        assert data == base64.b64decode(request['signed_data'], validate=True)
        signature = key.sign(data, padding.PKCS1v15(), hashes.SHA256())
        result = {'schema': 1, 'request': request, 'request_sha256': hashlib.sha256(canonical(request)).hexdigest(),
                  'signature': base64.b64encode(signature).decode()}
        args.response.write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')
        print('Signed approved APK digest locally; private key remains DPAPI-protected on this computer.')
