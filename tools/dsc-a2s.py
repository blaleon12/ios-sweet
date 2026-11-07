#!/usr/bin/env python3
"""Symbolize addresses against an iOS dyld shared cache (split cache, iOS 15+).

  dsc-a2s.py CACHE_DIR [--slide 0xSLIDE] ADDR [ADDR ...]
  dsc-a2s.py CACHE_DIR --slide 0xSLIDE --log SWEETLOG.txt [--proc NAME]

CACHE_DIR holds dyld_shared_cache_arm64 (main), its .01/.02/... sub-caches and
.symbols (all local symbols). Addresses are runtime addresses; --slide is the
shared-cache slide the SWEET sampler/crash lines print ("slide 0x...").
With --log, every "SMP"/"CRASH" pc/lr/bt address of the process is resolved.

Image lookup: imagesText (load address + __TEXT size per dylib). Symbol
lookup: the nearest preceding symbol among the dylib's local symbols from
.symbols and its own LC_SYMTAB (globals), both as unslid vm addresses.
Pure Python, reads only.
"""
import bisect, glob, os, re, struct, sys


class Cache:
    def __init__(self, d):
        main = os.path.join(d, 'dyld_shared_cache_arm64')
        if not os.path.exists(main):
            cands = sorted(glob.glob(os.path.join(d, 'dyld_shared_cache_arm64*')))
            sys.exit(f'no dyld_shared_cache_arm64 in {d} ({cands[:4]})')
        self.files = {}
        self.maps = []          # (vmaddr, size, fileoff, path)
        for p in sorted(glob.glob(main + '*')):
            if p.endswith('.map') or p.endswith('.atlas'):
                continue
            f = open(p, 'rb')
            self.files[p] = f
            h = f.read(0x200)
            if not h.startswith(b'dyld_v1'):
                continue
            moff, mcnt = struct.unpack_from('<II', h, 0x10)
            f.seek(moff)
            for _ in range(mcnt):
                a, s, o, _mx, _ix = struct.unpack('<QQQII', f.read(32))
                self.maps.append((a, s, o, p))
        self.maps.sort()
        m = self.files[main]
        m.seek(0)
        h = m.read(0x200)
        self.base = struct.unpack_from('<Q', h, 0xe0)[0]          # sharedRegionStart
        toff, tcnt = struct.unpack_from('<QQ', h, 0x88)           # imagesText
        m.seek(toff)
        raw = m.read(tcnt * 32)
        imgs = []
        for i in range(tcnt):
            _uuid, addr, size, poff = struct.unpack_from('<16sQII', raw, i * 32)
            m.seek(poff)
            path = m.read(512).split(b'\0', 1)[0].decode(errors='replace')
            imgs.append((addr, size, path))
        imgs.sort()
        self.imgs = imgs
        self.img_addrs = [i[0] for i in imgs]
        self.symcache = {}
        self.locals = self._load_locals(main + '.symbols')

    def read_vm(self, addr, n):
        for a, s, o, p in self.maps:
            if a <= addr < a + s:
                f = self.files[p]
                f.seek(o + addr - a)
                return f.read(n)
        return None

    def _load_locals(self, path):
        """{dylib text offset: (nlist index, count)} plus the nlist/string blobs."""
        if path not in self.files:
            return None
        f = self.files[path]
        f.seek(0)
        h = f.read(0x200)
        off, size = struct.unpack_from('<QQ', h, 0x48)            # localSymbolsOffset/Size
        f.seek(off)
        info = f.read(size)
        nlo, nlc, so, ss, eo, ec = struct.unpack_from('<6I', info, 0)
        ents = {}
        for i in range(ec):
            dyoff, start, cnt = struct.unpack_from('<QII', info, eo + 16 * i)
            ents[dyoff] = (start, cnt)
        return (info, nlo, so, ss, ents)

    def image(self, addr):
        i = bisect.bisect_right(self.img_addrs, addr) - 1
        if i >= 0:
            a, s, p = self.imgs[i]
            if a <= addr < a + s:
                return a, s, p
        return None

    def symbols(self, img):
        a, _s, path = img
        if a in self.symcache:
            return self.symcache[a]
        syms = []
        # locals from .symbols
        if self.locals:
            info, nlo, so, _ss, ents = self.locals
            e = ents.get(a - self.base)
            if e:
                start, cnt = e
                for k in range(start, start + cnt):
                    strx, typ, _sect, _desc, val = struct.unpack_from('<IBBHQ', info, nlo + 16 * k)
                    if typ & 0x0e == 0x0e and val:
                        end = info.index(b'\0', so + strx)
                        syms.append((val, info[so + strx:end].decode(errors='replace')))
        # globals from the dylib's own LC_SYMTAB (linkedit is shared, map via vm)
        hdr = self.read_vm(a, 0x8000)
        if hdr and struct.unpack_from('<I', hdr, 0)[0] == 0xfeedfacf:
            ncmds = struct.unpack_from('<I', hdr, 16)[0]
            p = 32
            le = None
            st = None
            for _ in range(ncmds):
                cmd, csz = struct.unpack_from('<II', hdr, p)
                if cmd == 0x19 and hdr[p + 8:p + 24].rstrip(b'\0') == b'__LINKEDIT':
                    le = struct.unpack_from('<QQQQ', hdr, p + 24)   # vmaddr vmsize fileoff filesize
                elif cmd == 0x2:
                    st = struct.unpack_from('<IIII', hdr, p + 8)    # symoff nsyms stroff strsize
                p += csz
            if le and st:
                vm = lambda fo: le[0] + fo - le[2]
                symoff, nsyms, stroff, strsize = st
                nl = self.read_vm(vm(symoff), nsyms * 16) or b''
                strs = self.read_vm(vm(stroff), strsize) or b''
                for k in range(len(nl) // 16):
                    strx, typ, _sect, _desc, val = struct.unpack_from('<IBBHQ', nl, 16 * k)
                    if typ & 0x0e == 0x0e and val and strx < len(strs):
                        end = strs.find(b'\0', strx)
                        syms.append((val, strs[strx:end].decode(errors='replace')))
        syms.sort()
        self.symcache[a] = ([s[0] for s in syms], syms)
        return self.symcache[a]

    def a2s(self, addr):
        img = self.image(addr)
        if img is None:
            return '?'
        name = os.path.basename(img[2])
        addrs, syms = self.symbols(img)
        i = bisect.bisect_right(addrs, addr) - 1
        if i < 0:
            return f'{name}+{addr - img[0]:#x}'
        return f'{name}`{syms[i][1]}+{addr - syms[i][0]:#x}'


def main():
    args = sys.argv[1:]
    if not args:
        sys.exit(__doc__)
    c = Cache(args.pop(0))
    slide, log, proc = 0, None, None
    addrs = []
    while args:
        a = args.pop(0)
        if a == '--slide':
            slide = int(args.pop(0), 16)
        elif a == '--log':
            log = args.pop(0)
        elif a == '--proc':
            proc = args.pop(0)
        else:
            addrs.append(int(a, 16))
    for a in addrs:
        print(f'{a:#x}  {c.a2s(a - slide)}')
    if log:
        for line in open(log, errors='replace'):
            m = re.match(r'(SMP|CRASH) ([^\s\[(]+)\S* (t\d+ )?(pc|bt) ', line)
            if not m or (proc and m.group(2) != proc):
                continue
            print(line.rstrip()[:72])
            for h in re.findall(r'0x[0-9a-f]+', line):
                v = int(h, 16) - slide
                if c.base <= v < c.base + 0x180000000:     # shared region only (not stack/heap)
                    print(f'    {h}  {c.a2s(v)}')


if __name__ == '__main__':
    main()
