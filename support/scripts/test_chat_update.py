"""Windows updater regression using isolated fixtures and Windows' whoami.exe.

No real application installation or user profile is modified. Fixtures remain in
the supplied test output directory for inspection.
"""
from pathlib import Path
from zipfile import ZipFile
import ctypes
import hashlib
import os
import subprocess
import sys
import uuid

repo = Path(__file__).resolve().parents[2]
output = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else repo / 'app/build/update-tests'
output.mkdir(parents=True, exist_ok=True)
helper = repo / 'app/assets/update/Apply-ChatUpdate.ps1'
system = Path(os.environ['SystemRoot']) / 'System32'
powershell = system / 'WindowsPowerShell/v1.0/powershell.exe'
executable = (system / 'whoami.exe').read_bytes()


def fixture(name, extra=(), omit=()):
    work = output / (name + '-' + uuid.uuid4().hex)
    target = work / 'app'
    (target / 'data').mkdir(parents=True)
    old = {'localsend_app.exe': executable, 'flutter_windows.dll': b'old-dll', 'data/app.so': b'old-code',
           'settings.json': b'{"keep":"history and identity"}', 'received.txt': b'user file'}
    for name, content in old.items():
        (target / name).write_bytes(content)
    payload = {'localsend_app.exe': executable, 'flutter_windows.dll': b'new-dll', 'data/app.so': b'new-code',
               'data/flutter_assets/AssetManifest.bin': b'new-assets', 'settings.json': b'{}', 'new_plugin.dll': b'new-plugin'}
    archive = work / 'update.zip'
    with ZipFile(archive, 'w') as zip_file:
        for name, content in payload.items():
            if name not in omit:
                zip_file.writestr(name, content)
        for name, content in extra:
            zip_file.writestr(name, content)
    return work, target, archive, old


def run(case, *, prepare=False, bad_hash=False):
    work, target, archive, old = case
    digest = '0' * 64 if bad_hash else hashlib.sha256(archive.read_bytes()).hexdigest()
    result = subprocess.run([str(powershell), '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
                             '-File', str(helper), '-Archive', str(archive), '-ExpectedSha256', digest,
                             '-TargetDir', str(target), '-AppProcessId', '2147483647', *(['-PrepareOnly'] if prepare else [])],
                            capture_output=True, timeout=45)
    return result.returncode


def unchanged(case):
    work, target, archive, old = case
    for name, content in old.items():
        assert (target / name).read_bytes() == content, name


case = fixture('apply')
assert run(case) == 0
assert (case[1] / 'data/app.so').read_bytes() == b'new-code'
assert (case[1] / 'settings.json').read_bytes() == case[3]['settings.json']
assert (case[1] / 'received.txt').read_bytes() == b'user file'
assert list(case[1].glob('.chat-update-backup-*/data/app.so'))[0].read_bytes() == b'old-code'
print('PASS: apply, backup and preserve settings/history/user files')

case = fixture('prepare')
assert run(case, prepare=True) == 0
assert (case[0] / 'ready').exists()
unchanged(case)
print('PASS: verify and stage before app exit')

case = fixture('bad-hash')
assert run(case, bad_hash=True) != 0
unchanged(case)
print('PASS: reject corrupted download')

case = fixture('traversal', extra=[('../escaped.txt', b'bad')])
assert run(case) != 0
assert not (case[0] / 'escaped.txt').exists()
unchanged(case)
print('PASS: reject path traversal')

case = fixture('duplicate', extra=[('DATA/app.so', b'bad')])
assert run(case) != 0
unchanged(case)
print('PASS: reject case-insensitive duplicate paths')

case = fixture('incomplete', omit=['data/app.so'])
assert run(case) != 0
unchanged(case)
print('PASS: reject incomplete application')

case = fixture('collision')
(case[1] / 'new_plugin.dll').mkdir()
assert run(case) != 0
unchanged(case)
print('PASS: reject file/directory collisions before exit')

case = fixture('rollback')
kernel = ctypes.WinDLL('kernel32', use_last_error=True)
kernel.CreateFileW.argtypes = [ctypes.c_wchar_p, ctypes.c_uint32, ctypes.c_uint32, ctypes.c_void_p,
                              ctypes.c_uint32, ctypes.c_uint32, ctypes.c_void_p]
kernel.CreateFileW.restype = ctypes.c_void_p
kernel.CloseHandle.argtypes = [ctypes.c_void_p]
# Allow backup reads, deny replacement writes. The old file itself is not changed.
handle = kernel.CreateFileW(str(case[1] / 'data/app.so'), 0x80000000, 1, None, 3, 0, None)
assert handle != ctypes.c_void_p(-1).value
try:
    assert run(case) != 0
finally:
    kernel.CloseHandle(handle)
unchanged(case)
assert not (case[1] / 'new_plugin.dll').exists()
assert (case[0] / 'failed').exists()
print('PASS: failed replacement restores old files and removes newly created files')
print('All 8 Windows updater checks passed.')
