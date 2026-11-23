// Поддельная библиотека Goat Archive для тестов: метка, служебная папка,
// индекс по договору (docs/GALLERY_BRIDGE.md сортировщика, §2) и несколько PNG.
// Настоящую библиотеку тесты не трогают.
import 'dart:ffi';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:sqlite3/open.dart';
import 'package:sqlite3/sqlite3.dart';

/// В `flutter test` нет плагина с sqlite3.dll — берём её из сборки приложения
/// или из установленного Python.
void useTestSqlite() {
  if (!Platform.isWindows) return;
  for (final c in [
    r'build\windows\x64\runner\Release\sqlite3.dll',
    r'C:\Python313\DLLs\sqlite3.dll',
  ]) {
    final f = File(c);
    if (f.existsSync()) {
      final path = f.absolute.path;
      open.overrideFor(OperatingSystem.windows, () => DynamicLibrary.open(path));
      return;
    }
  }
}

class FakeTag {
  final String name;
  final String category;
  final double confidence;
  final String origin;
  const FakeTag(this.name,
      {this.category = 'general', this.confidence = 0.9, this.origin = 'wd-v3'});
}

class FakeFile {
  final String rel; // относительный путь, разделитель «/»
  final List<FakeTag> tags;
  final String? rating;
  final String? artist;
  final String? sourceUrl;
  final String? seriesId;
  final int? seriesPage;
  final bool wrongSize; // в индексе записан не тот размер
  final bool onDisk; // false — файл есть в индексе, но не на диске
  const FakeFile(
    this.rel, {
    this.tags = const [],
    this.rating,
    this.artist,
    this.sourceUrl,
    this.seriesId,
    this.seriesPage,
    this.wrongSize = false,
    this.onDisk = true,
  });
}

class FakeSeries {
  final String id;
  final String title;
  final bool confirmed;
  const FakeSeries(this.id, this.title, {this.confirmed = true});
}

String abs(Directory root, String rel) =>
    p.join(root.path, rel.replaceAll('/', Platform.pathSeparator));

List<int> _png(int seed) {
  final image = img.Image(width: 6, height: 6);
  img.fill(image,
      color: img.ColorRgb8(seed * 37 % 256, seed * 91 % 256, seed * 13 % 256));
  image.setPixelRgb(seed % 6, (seed ~/ 6) % 6, 255, 255, 255);
  return img.encodePng(image);
}

/// Создать файлы библиотеки, метку и служебную папку (с «приманкой» внутри —
/// картинкой, которую галерея не должна ни показать, ни тронуть).
void writeFakeLibraryFiles(Directory root, List<FakeFile> files) {
  root.createSync(recursive: true);
  File(p.join(root.path, '.goat-archive-export-marker'))
      .writeAsStringSync('goat-archive\n');
  final book = Directory(p.join(root.path, '.goat-archive-export'));
  Directory(p.join(book.path, 'staging')).createSync(recursive: true);
  File(p.join(book.path, 'staging', 'decoy.png')).writeAsBytesSync(_png(999));
  File(p.join(book.path, 'journal.log')).writeAsStringSync('journal\n');
  var seed = 1;
  for (final f in files) {
    seed++;
    if (!f.onDisk) continue;
    final file = File(abs(root, f.rel));
    file.parent.createSync(recursive: true);
    if (!file.existsSync()) file.writeAsBytesSync(_png(seed));
  }
}

/// Записать индекс библиотеки так же, как это делает сортировщик: во
/// временный файл, затем переименованием на место.
void writeFakeIndex(
  Directory root,
  List<FakeFile> files, {
  List<FakeSeries> series = const [],
  required int generatedAtMs,
  String format = 'goat-library-index',
  String version = '1',
}) {
  final book = Directory(p.join(root.path, '.goat-archive-export'))
    ..createSync(recursive: true);
  final tmp = File(p.join(book.path, 'library-index.sqlite3.tmp'));
  if (tmp.existsSync()) tmp.deleteSync();
  final db = sqlite3.open(tmp.path);
  db.execute('''
    CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
    CREATE TABLE files (
      id          INTEGER PRIMARY KEY,
      path        TEXT NOT NULL UNIQUE,
      sha256      TEXT NOT NULL,
      size        INTEGER NOT NULL,
      rating      TEXT,
      artist      TEXT,
      source_url  TEXT,
      series_id   TEXT,
      series_page INTEGER
    );
    CREATE TABLE tags (
      id       INTEGER PRIMARY KEY,
      name     TEXT NOT NULL,
      category TEXT NOT NULL,
      UNIQUE (name, category)
    );
    CREATE TABLE file_tags (
      file_id    INTEGER NOT NULL,
      tag_id     INTEGER NOT NULL,
      confidence REAL NOT NULL,
      origin     TEXT NOT NULL,
      PRIMARY KEY (file_id, tag_id)
    ) WITHOUT ROWID;
    CREATE TABLE series (
      id         TEXT PRIMARY KEY,
      title      TEXT NOT NULL,
      page_count INTEGER NOT NULL,
      confirmed  INTEGER NOT NULL
    );
  ''');
  db.execute('BEGIN');
  final meta = {
    'format': format,
    'version': version,
    'generated_at_ms': '$generatedAtMs',
    'file_count': '${files.length}',
    'app_version': 'test',
  };
  for (final e in meta.entries) {
    db.execute('INSERT INTO meta(key, value) VALUES(?, ?)', [e.key, e.value]);
  }
  final tagIds = <String, int>{};
  final insFile = db.prepare('INSERT INTO files'
      '(id, path, sha256, size, rating, artist, source_url, series_id, series_page) '
      'VALUES(?,?,?,?,?,?,?,?,?)');
  final insTag =
      db.prepare('INSERT INTO tags(id, name, category) VALUES(?,?,?)');
  final insLink = db.prepare(
      'INSERT INTO file_tags(file_id, tag_id, confidence, origin) VALUES(?,?,?,?)');
  var id = 0;
  for (final f in files) {
    id++;
    final file = File(abs(root, f.rel));
    final bytes = file.existsSync() ? file.readAsBytesSync() : <int>[1, 2, 3];
    insFile.execute([
      id,
      f.rel,
      sha256.convert(bytes).toString(),
      f.wrongSize ? bytes.length + 7 : bytes.length,
      f.rating,
      f.artist,
      f.sourceUrl,
      f.seriesId,
      f.seriesPage,
    ]);
    for (final t in f.tags) {
      final key = '${t.name}\n${t.category}';
      var tid = tagIds[key];
      if (tid == null) {
        tid = tagIds.length + 1;
        tagIds[key] = tid;
        insTag.execute([tid, t.name, t.category]);
      }
      insLink.execute([id, tid, t.confidence, t.origin]);
    }
  }
  for (final s in series) {
    final n = files.where((f) => f.seriesId == s.id).length;
    db.execute(
        'INSERT INTO series(id, title, page_count, confirmed) VALUES(?,?,?,?)',
        [s.id, s.title, n, s.confirmed ? 1 : 0]);
  }
  db.execute('COMMIT');
  insFile.dispose();
  insTag.dispose();
  insLink.dispose();
  db.dispose();
  final dst = File(p.join(book.path, 'library-index.sqlite3'));
  if (dst.existsSync()) dst.deleteSync();
  tmp.renameSync(dst.path);
}
