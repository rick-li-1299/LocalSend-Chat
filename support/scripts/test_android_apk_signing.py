import base64
from datetime import datetime, timedelta, timezone
import hashlib
from pathlib import Path
import tempfile
import unittest
import zipfile

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding, rsa
from cryptography.x509.oid import NameOID

from android_apk_signing import assemble, canonical, prepare, sections


class ApkSigningTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, 'Synthetic test signer')])
        now = datetime.now(timezone.utc)
        self.cert = (x509.CertificateBuilder().subject_name(name).issuer_name(name).public_key(self.key.public_key())
                     .serial_number(1).not_valid_before(now - timedelta(days=1)).not_valid_after(now + timedelta(days=1))
                     .sign(self.key, hashes.SHA256()))
        self.certificate = self.root / 'cert.pem'
        self.certificate.write_bytes(self.cert.public_bytes(serialization.Encoding.PEM))
        self.apk = self.root / 'unsigned.apk'
        self.make_apk()
        self.request = prepare(self.apk, self.certificate, 'a' * 40, '123')
        self.response = {'request_sha256': hashlib.sha256(canonical(self.request)).hexdigest(),
                         'signature': base64.b64encode(self.key.sign(base64.b64decode(self.request['signed_data']), padding.PKCS1v15(), hashes.SHA256())).decode()}

    def make_apk(self, dex=b'x' * ((1 << 20) + 19)):
        with zipfile.ZipFile(self.apk, 'w') as output:
            output.writestr('AndroidManifest.xml', b'synthetic manifest')
            output.writestr('classes.dex', dex)
            output.writestr('lib/arm64-v8a/libflutter.so', b'synthetic library')

    def test_assembly_preserves_zip_entries_and_protected_content(self):
        result = self.root / 'signed.apk'
        original = sections(self.apk.read_bytes())
        assemble(self.apk, self.certificate, self.request, self.response, result)
        self.assertEqual(sections(result.read_bytes()), original)
        with zipfile.ZipFile(result) as archive:
            self.assertIsNone(archive.testzip())
            self.assertEqual(archive.read('classes.dex'), b'x' * ((1 << 20) + 19))

    def test_modified_apk_is_rejected(self):
        self.make_apk(b'changed application')
        with self.assertRaises(ValueError):
            assemble(self.apk, self.certificate, self.request, self.response, self.root / 'bad.apk')

    def test_signature_from_another_identity_is_rejected(self):
        another = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        response = dict(self.response, signature=base64.b64encode(another.sign(base64.b64decode(self.request['signed_data']), padding.PKCS1v15(), hashes.SHA256())).decode())
        with self.assertRaises(Exception):
            assemble(self.apk, self.certificate, self.request, response, self.root / 'bad.apk')

    def test_request_provenance_is_bound_to_response(self):
        with self.assertRaises(ValueError):
            assemble(self.apk, self.certificate, dict(self.request, workflow_run_id='456'), self.response, self.root / 'bad.apk')


if __name__ == '__main__':
    unittest.main()
