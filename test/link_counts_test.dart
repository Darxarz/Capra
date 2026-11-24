// Число рядом с тегом, автором и серией должно равняться тому, что покажет
// нажатие на них — в папке, на верхнем уровне и при любых фильтрах. И подписи
// в строке состояния: правильные формы слов, картинки и видео отдельно.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:goat/i18n.dart';
import 'package:goat/link_index.dart';
import 'package:goat/settings_service.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import 'fake_library.dart';

const _schema = '''
CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE files (id INTEGER PRIMARY KEY, path TEXT NOT NULL UNIQUE,
  sha256 TEXT NOT NULL, size INTEGER NOT NULL, rating TEXT, artist TEXT,
  source_url TEXT, series_id TEXT, series_page INTEGER);
CREATE TABLE tags (id INTEGER PRIMARY KEY, name TEXT NOT NULL,
  category TEXT NOT NULL, UNIQUE (name, category));
CREATE TABLE file_tags (file_id INTEGER NOT NULL, tag_id INTEGER NOT NULL,
  confidence REAL NOT NULL, origin TEXT NOT NULL,
  PRIMARY KEY (file_id, tag_id)) WITHOUT ROWID;
CREATE TABLE series (id TEXT PRIMARY KEY, title TEXT NOT NULL,
  page_count INTEGER NOT NULL, confirmed INTEGER NOT NULL);
''';

void _meta(Database db, int files) {
  for (final e in {
    'format': 'goat-library-index',
    'version': '1',
    'generated_at_ms': '1000',
    'file_count': '$files',
    'app_version': 'test',
  }.entries) {
    db.execute('INSERT INTO meta VALUES (?, ?)', [e.key, e.value]);
  }
}

/// Драконы — только в «Фэнтези»; в «Портретах» их нет. Один тег записан в двух
/// категориях, а проект (KRA) несёт теги, но в обычный список не входит.
void writeIndex(String path) {
  final db = sqlite3.open(path);
  db.execute(_schema);
  _meta(db, 14);
  var id = 0;
  void file(String rel, List<int> tags,
      {String? rating, String? artist, String? series, int? page}) {
    id++;
    db.execute('INSERT INTO files VALUES (?,?,?,?,?,?,?,?,?)', [
      id,
      rel,
      id.toRadixString(16).padLeft(64, 'b'),
      100 + id,
      rating,
      artist,
      null,
      series,
      page,
    ]);
    for (final t in tags) {
      db.execute("INSERT INTO file_tags VALUES (?,?,0.9,'wd-v3')", [id, t]);
    }
  }

  db.execute("INSERT INTO tags VALUES (1,'e2e_dragon','species'),"
      "(2,'solo','general'),(3,'both','general'),(4,'both','character'),"
      "(5,'ВОЛК','species'),(6,'only_project','meta'),(7,'pen_name','artist')");
  file('Фэнтези/d1.jpg', [1, 2], rating: 'explicit', artist: 'Иван Кистью');
  file('Фэнтези/d2.png', [1, 3, 4], rating: 'general', artist: 'Иван Кистью');
  file('Фэнтези/Глубже/d3.gif', [1, 2], artist: 'Ember');
  file('Фэнтези/clip.mp4', [1]);
  file('Портреты/p1.jpg', [2, 5], rating: 'questionable', artist: 'Ember');
  file('Портреты/p2.jpg', [2, 3], rating: 'general');
  file('Портреты/p3.webp', [5, 7]);
  file('Портреты/film.webm', [5]);
  file('Портреты/work.kra', [1, 6]);
  file('Комикс/1.jpg', [2], series: 's1', page: 1);
  file('Комикс/2.jpg', [2], series: 's1', page: 2);
  file('Комикс/3.jpg', [5], series: 's1', page: 3);
  file('Фэнтези/s.jpg', [1], series: 's2', page: 1);
  file('Портреты/s.jpg', [2], series: 's2', page: 2);
  db.execute("INSERT INTO series VALUES ('s1','Лесная сказка',3,1),('s2','Двое',2,0)");
  db.dispose();
}

void main() {
  useTestSqlite();

  late Directory tmp;
  late LinkDb link;
  late Database raw;

  setUpAll(() {
    tmp = Directory.systemTemp.createTempSync('goat_link_counts');
    final index = p.join(tmp.path, 'index.sqlite3');
    writeIndex(index);
    final out = p.join(tmp.path, 'link.sqlite3');
    final r = runLinkImport(LinkImportRequest(
        indexCopy: index, outPath: out, collectionId: 'c', indexVersion: '1:1'));
    expect(r.error, isNull);
    link = LinkDb.open(out, treeUri: 't', collectionId: 'c');
    raw = sqlite3.open(out, mode: OpenMode.readOnly);
  });

  tearDownAll(() {
    link.close();
    raw.dispose();
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  int folder(String name) => link.folders().firstWhere((f) => f.name == name).id;

  LinkFilter withTag(LinkFilter f, String tag) => LinkFilter(
        folderId: f.folderId,
        text: f.text,
        tags: {...f.tags, tag},
        kind: f.kind,
        nsfw: f.nsfw,
        seriesId: f.seriesId,
        artist: f.artist,
      );

  /// Главная проверка: каждая строка панели обещает ровно то, что покажет.
  void expectCountsMatch(LinkFilter f) {
    final side = link.side(f);
    for (final t in side.tags) {
      expect(selectLinkIds(raw, withTag(f, t.name)).length, t.count,
          reason: 'tag ${t.name}');
    }
    for (final a in side.artists) {
      final shown = selectLinkIds(
          raw,
          LinkFilter(
              folderId: f.folderId,
              text: f.text,
              tags: f.tags,
              kind: f.kind,
              nsfw: f.nsfw,
              artist: a.name));
      expect(shown.length, a.count, reason: 'artist ${a.name}');
    }
    for (final s in side.series) {
      final shown = selectLinkIds(
          raw,
          LinkFilter(
              text: f.text,
              tags: f.tags,
              kind: f.kind,
              nsfw: f.nsfw,
              seriesId: s.id));
      expect(shown.length, s.pages, reason: 'series ${s.title}');
    }
  }

  group('counts equal results', () {
    test('the reported bug: a tag absent from the folder is not offered there', () {
      final f = LinkFilter(folderId: folder('Портреты'));
      final names = link.side(f).tags.map((t) => t.name);
      expect(names, isNot(contains('e2e_dragon')),
          reason: 'its only file here is a project, hidden from the list');
      expect(selectLinkIds(raw, withTag(f, 'e2e_dragon')), isEmpty);
    });

    test('top level', () {
      final tags = link.side(const LinkFilter()).tags;
      expect(tags.firstWhere((t) => t.name == 'e2e_dragon').count, 5);
      expect(tags.map((t) => t.name), isNot(contains('only_project')));
      expectCountsMatch(const LinkFilter());
    });

    test('a folder with subfolders, and a leaf folder', () {
      final fantasy = LinkFilter(folderId: folder('Фэнтези'));
      expect(link.side(fantasy).tags.firstWhere((t) => t.name == 'e2e_dragon').count, 5);
      expectCountsMatch(fantasy);
      expectCountsMatch(LinkFilter(folderId: folder('Глубже')));
      expectCountsMatch(LinkFilter(folderId: folder('Портреты')));
      expectCountsMatch(LinkFilter(folderId: folder('Комикс')));
    });

    test('every combination of media kind, rating and folder', () {
      for (final fid in [null, folder('Фэнтези'), folder('Портреты')]) {
        for (final kind in [null, kKindImage, kKindGif, kKindVideo, kKindProject]) {
          for (final nsfw in [0, 1, 2]) {
            expectCountsMatch(LinkFilter(folderId: fid, kind: kind, nsfw: nsfw));
          }
        }
      }
    });

    test('with a chosen tag, artist, series or search text', () {
      final fid = folder('Портреты');
      expectCountsMatch(LinkFilter(folderId: fid, tags: const {'solo'}));
      expectCountsMatch(const LinkFilter(tags: {'solo', 'e2e_dragon'}));
      expectCountsMatch(LinkFilter(folderId: fid, artist: 'Ember'));
      expectCountsMatch(const LinkFilter(seriesId: 's1'));
      expectCountsMatch(const LinkFilter(text: 'solo -both'));
      expectCountsMatch(LinkFilter(folderId: fid, text: 'волк'));
    });

    test('a tag stored under two categories counts each file once', () {
      final both = link.side(const LinkFilter()).tags.firstWhere((t) => t.name == 'both');
      expect(both.count, 2);
      expect(selectLinkIds(raw, const LinkFilter(tags: {'both'})).length, 2);
    });

    test('a chosen tag stays listed so it can be switched off', () {
      final f = LinkFilter(folderId: folder('Комикс'), tags: const {'e2e_dragon'});
      final row = link.side(f).tags.firstWhere((t) => t.name == 'e2e_dragon');
      expect(row.count, 0);
      expect(selectLinkIds(raw, f), isEmpty);
    });

    test('Cyrillic: panel search and artist search ignore case', () {
      expect(link.side(const LinkFilter(), search: 'волк').tags.single.name, 'волк');
      expect(link.side(const LinkFilter(), search: 'иван').artists.single.name,
          'Иван Кистью');
      expect(link.side(const LinkFilter(), search: 'лесная').series.single.title,
          'Лесная сказка');
      expect(selectLinkIds(raw, const LinkFilter(text: 'artist:иван_кистью')).length, 2);
    });

    test('a query reports how many videos it found', () {
      final r = selectLinkRows(raw, const LinkFilter());
      expect(r.ids.length, 13);
      expect(r.videos, 2);
      final port = selectLinkRows(raw, LinkFilter(folderId: folder('Портреты')));
      expect(port.videos, 1);
      expect(LinkPhotoList(link, port.ids, videos: port.videos).pictures,
          port.ids.length - 1);
    });
  });

  group('wording', () {
    final s = SettingsService.instance;
    late AppLang before;
    setUp(() => before = s.appLang);
    tearDown(() => s.appLang = before);

    test('Russian plural forms', () {
      s.appLang = AppLang.ru;
      const cases = {
        0: '0 изображений',
        1: '1 изображение',
        2: '2 изображения',
        4: '4 изображения',
        5: '5 изображений',
        11: '11 изображений',
        12: '12 изображений',
        14: '14 изображений',
        21: '21 изображение',
        22: '22 изображения',
        25: '25 изображений',
        101: '101 изображение',
        111: '111 изображений',
        112: '112 изображений',
        1001: '1001 изображение',
        146620: '146620 изображений',
      };
      cases.forEach((n, text) => expect(picturesLabel(n), text));
      expect(filesLabel(1), '1 файл');
      expect(filesLabel(3), '3 файла');
      expect(filesLabel(11), '11 файлов');
      expect(videosLabel(1), '1 видео');
      expect(videosLabel(5), '5 видео');
    });

    test('English and Spanish', () {
      s.appLang = AppLang.en;
      expect(picturesLabel(1), '1 image');
      expect(picturesLabel(2), '2 images');
      expect(videosLabel(1), '1 video');
      expect(videosLabel(3), '3 videos');
      expect(filesLabel(1), '1 file');
      s.appLang = AppLang.es;
      expect(picturesLabel(1), '1 imagen');
      expect(picturesLabel(4), '4 imágenes');
      expect(videosLabel(1), '1 vídeo');
      expect(videosLabel(2), '2 vídeos');
      expect(filesLabel(2), '2 archivos');
    });

    test('pictures and videos are separate; an empty part is left out', () {
      s.appLang = AppLang.ru;
      expect(mediaCountLabel(4, 1), '4 изображения · 1 видео');
      expect(mediaCountLabel(1, 0), '1 изображение');
      expect(mediaCountLabel(0, 3), '3 видео');
      expect(mediaCountLabel(0, 0), '0 изображений');
    });
  });
}
