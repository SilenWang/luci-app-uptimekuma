#!/usr/bin/env python3
"""Compile a gettext .po catalog into LuCI's .lmo format, and check one.

LuCI loads translations from /usr/lib/lua/luci/i18n/<package>.<lang>.lmo at
runtime, so the feed ships the compiled catalog next to its .po source. This
tool is the authoring-time converter (po2lmo from luci-base, reimplemented in
python so the feed does not need a C compiler or the 21.02 SDK); the build
itself only copies files.

    tools/po2lmo.py po/zh-cn/luci-app-uptime-kuma.zh-cn.po \
        root/usr/lib/lua/luci/i18n/luci-app-uptime-kuma.zh-cn.lmo

    tools/po2lmo.py --check po/...po root/.../x.zh-cn.lmo \
        htdocs/luci-static/resources/view/uptime-kuma/overview.js

The .lmo layout is the one luci-base's template_lmo.c reads:

    [msgstr bytes, each NUL padded to 4] [index entries, 16 bytes each,
    big endian: key_id, val_id, offset, length] [offset, big endian]

The index is sorted by key_id and searched with a binary search, so the sort
is not cosmetic. key_id is a hash of the msgid with whitespace runs collapsed
and the ends trimmed (lmo_canon_hash); val_id is the plain hash of msgstr.
"""

import struct
import sys


def sfh_hash(data):
    """Paul Hsieh's SuperFastHash, as used by template_lmo.c."""
    if not data:
        return 0

    h = len(data)
    blocks = len(data) >> 2
    rem = len(data) & 3
    pos = 0

    for _ in range(blocks):
        h = (h + struct.unpack_from('<H', data, pos)[0]) & 0xFFFFFFFF
        tmp = ((struct.unpack_from('<H', data, pos + 2)[0] << 11) ^ h) & 0xFFFFFFFF
        h = ((h << 16) ^ tmp) & 0xFFFFFFFF
        pos += 4
        h = (h + (h >> 11)) & 0xFFFFFFFF

    if rem == 3:
        h = (h + struct.unpack_from('<H', data, pos)[0]) & 0xFFFFFFFF
        h ^= (h << 16) & 0xFFFFFFFF
        ch = data[pos + 2]
        if ch >= 0x80:          # `(signed char)` in template_lmo.c
            ch -= 0x100
        h ^= (ch << 18) & 0xFFFFFFFF
        h = (h + (h >> 11)) & 0xFFFFFFFF
    elif rem == 2:
        h = (h + struct.unpack_from('<H', data, pos)[0]) & 0xFFFFFFFF
        h ^= (h << 11) & 0xFFFFFFFF
        h = (h + (h >> 17)) & 0xFFFFFFFF
    elif rem == 1:
        ch = data[pos]
        if ch >= 0x80:          # `(signed char)` in template_lmo.c
            ch -= 0x100
        h = (h + ch) & 0xFFFFFFFF
        h ^= (h << 10) & 0xFFFFFFFF
        h = (h + (h >> 1)) & 0xFFFFFFFF

    h ^= (h << 3) & 0xFFFFFFFF
    h = (h + (h >> 5)) & 0xFFFFFFFF
    h ^= (h << 4) & 0xFFFFFFFF
    h = (h + (h >> 17)) & 0xFFFFFFFF
    h ^= (h << 25) & 0xFFFFFFFF
    h = (h + (h >> 6)) & 0xFFFFFFFF

    return h


def canon_hash(text):
    """Hash of a msgid: whitespace runs collapse, both ends are trimmed."""
    out = []
    prev_space = True

    for ch in text:
        if ch.isspace():
            if not prev_space:
                out.append(' ')
            prev_space = True
        else:
            out.append(ch)
            prev_space = False

    s = ''.join(out)

    if s.endswith(' '):
        s = s[:-1]

    return sfh_hash(s.encode('utf-8'))


def _unquote(raw):
    raw = raw.strip()

    if raw.startswith('"'):
        raw = raw[1:]
    if raw.endswith('"'):
        raw = raw[:-1]

    out = []
    esc = False

    for ch in raw:
        if esc:
            out.append({'n': '\n', 't': '\t', '"': '"', '\\': '\\'}.get(ch, ch))
            esc = False
        elif ch == '\\':
            esc = True
        else:
            out.append(ch)

    return ''.join(out)


def parse_po(path):
    """Return a list of (msgid, msgstr) pairs, header entry included."""
    entries = []
    cur = {'id': None, 'str': None}
    field = None

    def flush():
        if cur['id'] is not None or cur['str'] is not None:
            entries.append((cur['id'] or '', cur['str'] or ''))
        cur['id'] = cur['str'] = None

    with open(path, encoding='utf-8') as fh:
        for raw in fh:
            line = raw.rstrip('\n')

            if not line.strip():
                flush()
                field = None
            elif line.startswith('#'):
                continue
            elif line.startswith('msgctxt '):
                raise SystemExit('%s: msgctxt is not supported' % path)
            elif line.startswith('msgid_plural '):
                raise SystemExit('%s: plurals are not supported' % path)
            elif line.startswith('msgid '):
                if cur['str'] is not None:
                    flush()
                field = 'id'
                cur['id'] = _unquote(line[6:])
            elif line.startswith('msgstr '):
                field = 'str'
                cur['str'] = _unquote(line[7:])
            elif line.startswith('"'):
                if field:
                    cur[field] = (cur[field] or '') + _unquote(line)

    flush()

    return entries


def compile_po(po_path, lmo_path):
    blob = bytearray()
    index = []
    offset = 0

    for msgid, msgstr in parse_po(po_path):
        if msgid == '':
            # header: only the plural formula is kept, as a zero key
            for line in msgstr.split('\n'):
                if line.startswith('Plural-Forms: '):
                    value = line[len('Plural-Forms: '):].encode('utf-8')
                    pad = (4 - len(value) % 4) % 4
                    index.append((0, 0, offset, len(value)))
                    blob += value + b'\0' * pad
                    offset += len(value) + pad
            continue

        if msgstr == '':
            continue

        value = msgstr.encode('utf-8')
        key_id = canon_hash(msgid)
        val_id = sfh_hash(value)

        if key_id == val_id:
            # identity translation: nothing to store, the msgid is the text
            continue

        pad = (4 - len(value) % 4) % 4
        index.append((key_id, 1, offset, len(value)))
        blob += value + b'\0' * pad
        offset += len(value) + pad

    index.sort(key=lambda e: e[0])

    for key_id, val_id, off, length in index:
        blob += struct.pack('>IIII', key_id, val_id, off, length)

    blob += struct.pack('>I', offset)

    with open(lmo_path, 'wb') as fh:
        fh.write(blob)


def read_lmo(path):
    """Return {key_id: msgstr} for a compiled catalog."""
    data = open(path, 'rb').read()

    if len(data) < 8:
        raise SystemExit('%s: truncated catalog' % path)

    idx_off = struct.unpack('>I', data[-4:])[0]

    if idx_off >= len(data) or (len(data) - idx_off - 4) % 16:
        raise SystemExit('%s: malformed catalog index' % path)

    out = {}

    for pos in range(idx_off, len(data) - 4, 16):
        key_id, val_id, off, length = struct.unpack('>IIII', data[pos:pos + 16])

        if key_id == 0:
            continue
        if off + length > idx_off:
            raise SystemExit('%s: catalog entry out of range' % path)

        out[key_id] = data[off:off + length].decode('utf-8')

    return out


def msgids_in_js(paths):
    """Extract every _('...') msgid from LuCI view sources."""
    import re

    pattern = re.compile(r"_\(\s*'((?:[^'\\]|\\.)*)'\s*\)")
    found = []

    for path in paths:
        src = open(path, encoding='utf-8').read()

        for m in pattern.finditer(src):
            text = m.group(1).replace("\\'", "'").replace('\\\\', '\\')

            if text not in found:
                found.append(text)

    return found


def check(po_path, lmo_path, js_paths):
    entries = dict(parse_po(po_path))
    catalog = read_lmo(lmo_path)
    errors = []

    for msgid, msgstr in entries.items():
        if msgid == '' or msgstr == '':
            continue

        key_id = canon_hash(msgid)

        if key_id == sfh_hash(msgstr.encode('utf-8')):
            continue

        if key_id not in catalog:
            errors.append('missing in catalog: %r' % msgid)
        elif catalog[key_id] != msgstr:
            errors.append('catalog stale for %r: %r' % (msgid, catalog[key_id]))

    known = set(canon_hash(k) for k in entries if k)
    for key_id in catalog:
        if key_id not in known:
            errors.append('catalog has an entry with no .po source: %08x' % key_id)

    for msgid in msgids_in_js(js_paths):
        if msgid not in entries:
            errors.append('untranslated msgid in %s: %r' % (js_paths[0], msgid))

    if errors:
        for err in errors:
            print('FAIL: %s' % err, file=sys.stderr)
        return 1

    print('i18n OK: %d msgids, %d catalog entries'
          % (len([k for k in entries if k]), len(catalog)))
    return 0


if __name__ == '__main__':
    if len(sys.argv) >= 2 and sys.argv[1] == '--check':
        if len(sys.argv) < 5:
            raise SystemExit('usage: po2lmo.py --check <po> <lmo> <js>...')
        sys.exit(check(sys.argv[2], sys.argv[3], sys.argv[4:]))

    if len(sys.argv) != 3:
        raise SystemExit('usage: po2lmo.py <po> <lmo> | --check <po> <lmo> <js>...')

    compile_po(sys.argv[1], sys.argv[2])
