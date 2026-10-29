#!/usr/bin/env python3
"""Build the trust bundle of the board owner: one owner module with the cdhashes of the owner's own test programs, followed by the
two original Apple modules, byte for byte.

This is the extension point UniXNU itself uses for the code its owner adds to a device (scripts/make-owner-trust-bundle.py of UniXNU
puts the cdhashes of the Adreno Metal plugin into such a module; docs/zh/concepts/payload.md describes the bundle and the pins):

    u32 count (3), u32 offset of module 0 (16), of module 1, of module 2, module 0 (owner), module 1 (static), module 2 (system)

Nothing is re-signed and the original modules are not touched; only the cdhashes listed here are added. A cdhash is the hash of ONE
build of ONE binary: a different binary is not trusted. The bundle is only accepted by the payload step when its SHA-256 is in
[payload] trust_cache_sha256 of board.toml: this script prints the line to add.

    make-owner-trust-bundle.py [--original FILE] [--out FILE] [--cdhash HEX]... MACHO...

MACHO is a signed Mach-O (the cdhash is read from its signature, MaliMetal usertest/cdhash.py).
"""
import argparse
import hashlib
import os
import struct
import sys
import uuid

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.environ.get('MALIMETAL_DIR', os.path.join(HERE, '..', '..', '..', 'MaliMetal')), 'usertest'))
import cdhash as cdhash_tool  # noqa: E402

ARTIFACTS = os.environ.get('ARTIFACTS') or os.path.join(HERE, '..', '..', 'artifacts')
ORIGINAL_SHA256 = '7416ca4f8377146626bb284e2133c76bee6cb4e3ee0af5d648b186235a7323a7'


def valid_like_the_loader(data):
    """The structural checks of DarwinBoot's ValidTrustCaches (drivers/DarwinBoot/DarwinBootPkg/Driver/DarwinBoot.c)."""
    count = struct.unpack_from('<I', data)[0]
    if not 0 < count <= 128:
        return False
    for index in range(count):
        start = struct.unpack_from('<I', data, 4 + 4 * index)[0]
        end = struct.unpack_from('<I', data, 8 + 4 * index)[0] if index + 1 < count else len(data)
        if start < 4 + 4 * count or start & 3 or end > len(data) or end - start < 24 or struct.unpack_from('<I', data, start)[0] != 2:
            return False
        entries = struct.unpack_from('<I', data, start + 20)[0]
        if end - start != 24 + entries * 24:
            return False
        for entry in range(entries):
            at = start + 24 + entry * 24
            if not 1 <= data[at + 20] <= 4 or (entry and data[at - 24:at - 4] >= data[at:at + 20]):
                return False
    return True


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--original', default=os.path.join(ARTIFACTS, 'trust', 'original-static-system.bundle'))
    parser.add_argument('--out', default=os.path.join(ARTIFACTS, 'trust', 'owner-static-system.bundle'))
    parser.add_argument('--cdhash', action='append', default=[], help='a cdhash as 40 hex digits (repeatable)')
    parser.add_argument('macho', nargs='*')
    args = parser.parse_args()

    original = open(args.original, 'rb').read()
    if hashlib.sha256(original).hexdigest() != ORIGINAL_SHA256:
        raise SystemExit('%s is not the unchanged original static + SystemOS bundle (SHA-256 %s)' % (args.original, ORIGINAL_SHA256))
    if struct.unpack_from('<I', original)[0] != 2:
        raise SystemExit('the original bundle does not have exactly two modules')
    offsets = struct.unpack_from('<2I', original, 4)
    originals = [original[offsets[0]:offsets[1]], original[offsets[1]:]]

    found = {}
    for path in args.macho:
        entries = cdhash_tool.describe(path)
        if len(entries) != 1:
            raise SystemExit('%s: %d CodeDirectories (one is expected)' % (path, len(entries)))
        found[entries[0]['cdhash']] = path
    for value in args.cdhash:
        if len(value) != 40 or any(c not in '0123456789abcdef' for c in value.lower()):
            raise SystemExit('not a cdhash: %r' % value)
        found[value.lower()] = '(given)'
    if not found:
        raise SystemExit('no cdhash given')
    hashes = sorted(bytes.fromhex(h) for h in found)

    identifier = uuid.uuid5(uuid.NAMESPACE_URL, 'evb10-owner-trust:' + ''.join(h.hex() for h in hashes))
    own = struct.pack('<I16sI', 2, identifier.bytes, len(hashes)) + b''.join(h + bytes([2, 0, 0, 0]) for h in hashes)
    modules = [own, *originals]
    cursor, starts = 16, []
    for module in modules:
        starts.append(cursor)
        cursor += len(module)
    bundle = struct.pack('<4I', 3, *starts) + b''.join(modules)
    if not valid_like_the_loader(bundle):
        raise SystemExit('the bundle would be refused by the boot loader')
    if bundle[starts[1]:starts[1] + len(originals[0])] != originals[0] or bundle[starts[2]:] != originals[1]:
        raise SystemExit('internal error: an original module changed')

    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    open(args.out, 'wb').write(bundle)
    digest = hashlib.sha256(bundle).hexdigest()
    for h in hashes:
        print('owner cdhash %s  %s' % (h.hex(), found[h.hex()]))
    print('wrote %s (%d bytes): owner module + both original modules unchanged' % (args.out, len(bundle)))
    print('sha256 %s' % digest)
    print('board.toml: trust_cache_sha256 = ["%s", "%s"]' % (ORIGINAL_SHA256, digest))


if __name__ == '__main__':
    main()
