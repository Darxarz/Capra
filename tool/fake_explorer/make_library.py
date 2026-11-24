"""Builds the synthetic library the fake Explorer serves. Nothing here touches real data.

The fake Explorer is a separate test app with the package name dev.filebridge.app, for EMULATORS
ONLY: never install it on a device that has the real Goat Explorer. The gallery's Gradle build does
not reference it, so it cannot end up in a release APK.

    python tool/fake_explorer/make_library.py
    android/gradlew -p tool/fake_explorer assembleDebug
    adb -e install -r tool/fake_explorer/app/build/outputs/apk/debug/app-debug.apk

Failure modes (ok, offline, moved, fail_index, no_pc, no_collection, decline), and pressing Explorer's Gallery button:

    adb -e shell am start -n dev.filebridge.app/.ControlActivity --es mode offline
    adb -e shell am start -n dev.filebridge.app/.ControlActivity --ez open true
"""
import hashlib
import os
import shutil
import sqlite3
import struct
import subprocess
import time
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, 'app', 'src', 'main', 'assets', 'library')


def png(path, w, h, a, b, mark):
    """A two-colour diagonal gradient with a light band, so tiles differ at a glance."""
    rows = bytearray()
    for y in range(h):
        rows.append(0)
        for x in range(w):
            t = (x + y) / (w + h)
            band = 40 if abs((x - y) % 97 - mark % 97) < 5 else 0
            for i in range(3):
                rows.append(min(255, int(a[i] + (b[i] - a[i]) * t) + band))

    def chunk(tag, data):
        return struct.pack('>I', len(data)) + tag + data + struct.pack('>I', zlib.crc32(tag + data))

    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'wb') as f:
        f.write(b'\x89PNG\r\n\x1a\n')
        f.write(chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0)))
        f.write(chunk(b'IDAT', zlib.compress(bytes(rows), 6)))
        f.write(chunk(b'IEND', b''))


PALETTE = [((35, 62, 92), (95, 214, 200)), ((92, 40, 60), (255, 154, 143)),
           ((40, 70, 45), (190, 220, 120)), ((60, 50, 110), (143, 166, 255)),
           ((100, 72, 30), (250, 205, 120)), ((30, 30, 45), (150, 150, 190))]

FILES = []


def add(rel, tags=(), rating='general', artist=None, url=None, series=None, page=None, size=(360, 280)):
    i = len(FILES)
    a, b = PALETTE[i % len(PALETTE)]
    png(os.path.join(OUT, *rel.split('/')), size[0], size[1], a, b, i * 13)
    FILES.append(dict(rel=rel, tags=tags, rating=rating, artist=artist, url=url, series=series, page=page))


def main():
    shutil.rmtree(OUT, ignore_errors=True)
    os.makedirs(OUT)
    for n in range(36):
        add(f'Furry/Wolves/wolf_{n:03}.png', ('wolf', 'solo' if n % 2 else 'duo', 'forest'),
            rating='explicit' if n % 5 == 0 else 'general', artist='Silver Fang',
            url=f'https://example.test/post/{n}')
    for n in range(24):
        add(f'Furry/Foxes/fox_{n:03}.png', ('fox', 'solo', 'snow'), artist='Red Tail')
    for n in range(30):
        add(f'Humans/Portraits/portrait_{n:03}.png', ('portrait', 'solo'), rating='sensitive')
    for n in range(18):
        add(f'Fantasy/Dragons/dragon_{n:03}.png', ('dragon', 'wings'), artist='Ember')
    for n in range(1, 13):
        add(f'Comics/Лесная сказка/page_{n:02}.png', ('comic', 'wolf'), artist='Silver Fang',
            series='story-1', page=n, size=(420, 600))

    video_dir = os.path.join(OUT, '_Other files', 'Video', 'Nature')
    os.makedirs(video_dir, exist_ok=True)
    video = os.path.join(video_dir, 'river.mp4')
    subprocess.run(['ffmpeg', '-y', '-loglevel', 'error', '-f', 'lavfi', '-i',
                    'testsrc2=size=640x360:rate=24:duration=40', '-f', 'lavfi', '-i',
                    'sine=frequency=330:duration=40', '-c:v', 'libx264', '-preset', 'veryfast',
                    '-b:v', '1800k', '-g', '48', '-pix_fmt', 'yuv420p', '-c:a', 'aac',
                    '-movflags', '+faststart', video], check=True)
    FILES.append(dict(rel='_Other files/Video/Nature/river.mp4', tags=('river', 'nature'),
                      rating='general', artist=None, url=None, series=None, page=None))

    meta = os.path.join(OUT, '.goat-archive-export')
    os.makedirs(meta)
    with open(os.path.join(OUT, '.goat-archive-export-marker'), 'w') as f:
        f.write('goat')
    db = sqlite3.connect(os.path.join(meta, 'library-index.sqlite3'))
    db.executescript('''
      CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
      CREATE TABLE files (id INTEGER PRIMARY KEY, path TEXT NOT NULL UNIQUE, sha256 TEXT NOT NULL,
        size INTEGER NOT NULL, rating TEXT, artist TEXT, source_url TEXT, series_id TEXT, series_page INTEGER);
      CREATE TABLE tags (id INTEGER PRIMARY KEY, name TEXT NOT NULL, category TEXT NOT NULL, UNIQUE (name, category));
      CREATE TABLE file_tags (file_id INTEGER NOT NULL, tag_id INTEGER NOT NULL, confidence REAL NOT NULL,
        origin TEXT NOT NULL, PRIMARY KEY (file_id, tag_id)) WITHOUT ROWID;
      CREATE TABLE series (id TEXT PRIMARY KEY, title TEXT NOT NULL, page_count INTEGER NOT NULL, confirmed INTEGER NOT NULL);
    ''')
    tag_ids = {}
    for i, f in enumerate(FILES, 1):
        path = os.path.join(OUT, *f['rel'].split('/'))
        with open(path, 'rb') as fh:
            sha = hashlib.sha256(fh.read()).hexdigest()
        db.execute('INSERT INTO files VALUES (?,?,?,?,?,?,?,?,?)',
                   (i, f['rel'], sha, os.path.getsize(path), f['rating'], f['artist'], f['url'], f['series'], f['page']))
        for t in f['tags']:
            tid = tag_ids.setdefault(t, len(tag_ids) + 1)
            db.execute("INSERT INTO file_tags VALUES (?,?,0.9,'wd-v3')", (i, tid))
    for name, tid in tag_ids.items():
        db.execute("INSERT INTO tags VALUES (?,?,'general')", (tid, name))
    db.execute("INSERT INTO series VALUES ('story-1','Лесная сказка',12,1)")
    for k, v in dict(format='goat-library-index', version='1', generated_at_ms=str(int(time.time() * 1000)),
                     file_count=str(len(FILES)), app_version='fixture').items():
        db.execute('INSERT INTO meta VALUES (?,?)', (k, v))
    db.commit()
    db.close()
    total = sum(os.path.getsize(os.path.join(r, n)) for r, _, ns in os.walk(OUT) for n in ns)
    print(f'{len(FILES)} files, {total / 1024 / 1024:.1f} MB')


if __name__ == '__main__':
    main()
