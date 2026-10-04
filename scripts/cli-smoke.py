#!/usr/bin/env python3
"""Exercise the shipping executable, including failures and no-clobber behavior."""
import hashlib, json, pathlib, struct, subprocess, sys, tempfile, zlib
exe = pathlib.Path(sys.argv[1]).resolve()
folder = pathlib.Path(tempfile.mkdtemp(prefix='FileOrbit-cli-'))

def chunk(kind, data):
    return struct.pack('!I', len(data)) + kind + data + struct.pack('!I', zlib.crc32(kind + data) & 0xffffffff)
image = folder / 'sample.png'
image.write_bytes(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('!IIBBBBB', 16, 8, 8, 2, 0, 0, 0)) + chunk(b'IDAT', zlib.compress((b'\x00' + b'\x10\x90\x70' * 16) * 8)) + chunk(b'IEND', b''))
original = hashlib.sha256(image.read_bytes()).hexdigest()

def call(*args, expect=0):
    result = subprocess.run([str(exe), *map(str, args)], capture_output=True, text=True, timeout=60)
    assert result.returncode == expect, (args, result.returncode, result.stdout, result.stderr)
    return result.stdout

report = json.loads(call('convert', image, '--to', 'jpg', '--json'))
assert report['succeededInputs'] == 1 and len(report['outputs']) == 1
first = pathlib.Path(report['outputs'][0]); before = first.read_bytes()
report = json.loads(call('convert', image, '--to', 'jpg', '--json'))
assert pathlib.Path(report['outputs'][0]) != first and first.read_bytes() == before
broken = folder / 'broken.png'; broken.write_text('broken')
report = json.loads(call('convert', image, broken, '--to', 'jpg', '--json', expect=1))
assert report['succeededInputs'] == 1 and len(report['failures']) == 1
resized = json.loads(call('tool', 'resize', image, '--width', '8', '--height', '4', '--json'))
assert resized['succeededInputs'] == 1
call('tool', 'resize', image, '--width', 'nonsense', expect=1)
call('tool', 'targetSize', image, '--target-mb', 'nan', expect=1)
call('convert', '--to', 'jpg', expect=1)
srt = folder / 'captions.srt'; srt.write_text('1\n00:00:00,500 --> 00:00:01,250\n你好 FileOrbit\n\n', encoding='utf8')
report = json.loads(call('convert', srt, '--to', 'vtt', '--json'))
assert '00:00:00.500 --> 00:00:01.250' in pathlib.Path(report['outputs'][0]).read_text()
assert hashlib.sha256(image.read_bytes()).hexdigest() == original
print('CLI smoke checks passed: conversion, collision, partial batch, parameters, invalid/empty input, subtitle timing, original preservation.')
print('Fixtures retained:', folder)
