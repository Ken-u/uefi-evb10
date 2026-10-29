#!/usr/bin/env python3
"""Build the original static + SystemOS trust-cache bundle of the iPad7,1 17.7.11 (21H461) IPSW.

The two inputs are the IM4P files `unixnu fetch` leaves in out/ipsw/21H461/ (StaticTrustCache =
044-76040-038.dmg.trustcache, Cryptex1,SystemTrustCache = 044-76034-038.dmg.trustcache). The
payload of each is one version-2 trust-cache module, unchanged. The bundle layout is the one
DarwinBoot validates (docs/zh/concepts/payload.md, "trust cache") and the same one UniXNU's own
scripts/build-original-system-trust.py writes:

    u32 count (2), u32 offset of module 0 (12), u32 offset of module 1, module 0, module 1

This script only re-does that, from the files this tree has, with the same exact-digest checks, so
nothing but the two original modules ever enters the bundle (no own entries, no re-signing).

    make-trust-bundle.py [--ipsw DIR] [--out FILE]

Prints the SHA-256 of the bundle: that is the value `[payload] trust_cache_sha256` has to allow.
"""
import argparse
import hashlib
import os
import struct
import sys

# From UniXNU's scripts/build-original-system-trust.py: the exact original modules.
STATIC_SHA256 = 'da88460e6e513438d5307e5c526f76497a74754476a24da29f239f0c90120fc2'
SYSTEM_SHA256 = 'd121ba89167e03aafd00fa687c30cd8ebc4ccafd10c1408adb2ba3de12403651'
ARTIFACTS = os.environ.get('ARTIFACTS') or os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'artifacts')
DEFAULT_IPSW = os.path.join(os.environ.get('UNIXNU', '.'), 'out/ipsw/21H461')


def der(data, at):
    if at + 2 > len(data):
        raise ValueError('truncated DER')
    tag, size = data[at:at + 2]
    at += 2
    if size & 128:
        count = size & 127
        if not 0 < count <= 4 or at + count > len(data):
            raise ValueError('invalid DER length')
        size = int.from_bytes(data[at:at + count], 'big')
        at += count
    if at + size > len(data):
        raise ValueError('DER exceeds the input')
    return tag, data[at:at + size], at + size


def im4p_payload(blob, kind):
    tag, sequence, end = der(blob, 0)
    fields, cursor = [], 0
    while cursor < len(sequence):
        field_tag, data, cursor = der(sequence, cursor)
        fields.append((field_tag, data))
    if tag != 0x30 or end != len(blob) or [t for t, _ in fields] != [0x16, 0x16, 0x16, 4] \
            or fields[0][1] != b'IM4P' or fields[1][1] != kind:
        raise ValueError('not an IM4P of type %r' % kind)
    return fields[3][1]


def module_ok(module, expected):
    return (hashlib.sha256(module).hexdigest() == expected and struct.unpack_from('<I', module)[0] == 2
            and len(module) == 24 + struct.unpack_from('<I', module, 20)[0] * 24)


def build(ipsw):
    static = im4p_payload(open(os.path.join(ipsw, '044-76040-038.dmg.trustcache'), 'rb').read(), b'trst')
    system = im4p_payload(open(os.path.join(ipsw, '044-76034-038.dmg.trustcache'), 'rb').read(), b'trcs')
    for name, module, expected in (('static', static, STATIC_SHA256), ('system', system, SYSTEM_SHA256)):
        if not module_ok(module, expected):
            raise SystemExit('the %s trust-cache module is not the exact original version-2 module' % name)
    return struct.pack('<3I', 2, 12, 12 + len(static)) + static + system


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--ipsw', default=DEFAULT_IPSW, help='directory with the fetched IPSW pieces')
    parser.add_argument('--out', default=os.path.join(ARTIFACTS, 'trust',
                                                      'original-static-system.bundle'))
    args = parser.parse_args()
    bundle = build(args.ipsw)
    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    open(args.out, 'wb').write(bundle)
    print('%s: %d bytes, sha256 %s' % (args.out, len(bundle), hashlib.sha256(bundle).hexdigest()))


if __name__ == '__main__':
    sys.exit(main())
