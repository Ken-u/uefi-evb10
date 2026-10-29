#!/usr/bin/env python3
"""apfs_ls.py [path]: list a directory of the SystemOS cryptex volume (window of userdata-root.img)."""
import sys
import os
sys.path.insert(0, os.environ.get('ULAND', '/tmp/uland') + '/pylib')
import pyfsapfs

IMG = os.environ.get('USERDATA_ROOT_IMG', 'userdata-root.img')
OFFSET = 0x16a600000
SIZE = 3303014400

class Window:
    def __init__(self, path, offset, size):
        self.f = open(path, 'rb'); self.offset = offset; self.size = size; self.pos = 0
    def read(self, n=-1):
        if n < 0 or self.pos + n > self.size: n = self.size - self.pos
        self.f.seek(self.offset + self.pos); b = self.f.read(n); self.pos += len(b); return b
    def seek(self, off, whence=0):
        self.pos = off if whence == 0 else self.pos + off if whence == 1 else self.size + off
    def tell(self): return self.pos
    def get_size(self): return self.size

def open_volume():
    w = Window(IMG, OFFSET, SIZE)
    c = pyfsapfs.container()
    c.open_file_object(w)
    v = c.get_volume(0)
    return c, v, w

if __name__ == '__main__':
    c, v, w = open_volume()
    print('volumes', c.number_of_volumes, 'name', v.name)
    path = sys.argv[1] if len(sys.argv) > 1 else '/'
    e = v.get_file_entry_by_path(path)
    for i in range(e.number_of_sub_file_entries):
        s = e.get_sub_file_entry(i)
        print('%10d %s' % (s.size, s.name))
