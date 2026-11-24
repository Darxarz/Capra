import 'dart:collection';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import 'archive_bridge.dart';
import 'model.dart';
import 'search_query.dart';

// Коллекция с ПК (Goat Link) в своей отдельной базе. Здесь нет ни путей ПК, ни
// обращений к базам планшета: файлы известны только относительным путём внутри
// коллекции. База пересобирается целиком из копии индекса и подменяется разом.

const int kLinkSchema = 2;

/// Показывать ли файл индекса в галерее: только картинки, видео и проекты, и
/// не служебное. `_Damaged` — карантин сортировщика: эти файлы заведомо битые,
/// и незачем дёргать за ними диск ПК при каждой прокрутке.
bool linkShowable(String rel) {
  if (rel.isEmpty || rel.startsWith('/') || rel.contains('\\')) return false;
  final parts = rel.split('/');
  if (parts.any((s) => s.isEmpty || s == '.' || s == '..')) return false;
  if (parts.first == '_Damaged') return false;
  for (var i = 0; i < parts.length - 1; i++) {
    final s = parts[i];
    if (s == kArchiveDir || s.toLowerCase() == '.thumbnails') return false;
  }
  final name = parts.last;
  final dot = name.lastIndexOf('.');
  if (dot < 0) return false;
  return kScanExtensions.contains(name.substring(dot).toLowerCase());
}

const _linkTables = '''
CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE folders (
  id INTEGER PRIMARY KEY,
  parent_id INTEGER,
  name TEXT NOT NULL,
  path TEXT NOT NULL,
  direct_count INTEGER NOT NULL,
  total_count INTEGER NOT NULL
);
CREATE TABLE files (
  id INTEGER PRIMARY KEY,
  rel TEXT NOT NULL,
  lc TEXT NOT NULL,
  folder_id INTEGER NOT NULL,
  sha TEXT NOT NULL,
  size INTEGER NOT NULL,
  kind INTEGER NOT NULL,
  rating TEXT,
  artist TEXT,
  artist_key TEXT,
  source_url TEXT,
  series_id TEXT,
  series_page INTEGER
);
CREATE TABLE tags (
  id INTEGER PRIMARY KEY,
  name TEXT NOT NULL,
  category TEXT NOT NULL,
  file_count INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE file_tags (
  tag_id INTEGER NOT NULL,
  file_id INTEGER NOT NULL,
  PRIMARY KEY (tag_id, file_id)
) WITHOUT ROWID;
CREATE TABLE folder_tags (
  folder_id INTEGER NOT NULL,
  kind INTEGER NOT NULL,
  adult INTEGER NOT NULL,
  tag_id INTEGER NOT NULL,
  n INTEGER NOT NULL,
  PRIMARY KEY (folder_id, kind, adult, tag_id)
) WITHOUT ROWID;
CREATE TABLE series (
  id TEXT PRIMARY KEY,
  title TEXT NOT NULL,
  page_count INTEGER NOT NULL,
  confirmed INTEGER NOT NULL,
  cover_id INTEGER
) WITHOUT ROWID;
''';

const _linkIndexes = '''
CREATE INDEX files_folder ON files(folder_id);
CREATE INDEX files_lc ON files(lc, kind);
CREATE INDEX files_size ON files(size DESC, id, kind);
CREATE INDEX files_series ON files(series_id, series_page);
CREATE INDEX files_artist ON files(artist);
CREATE INDEX file_tags_file ON file_tags(file_id);
CREATE UNIQUE INDEX tags_name ON tags(name);
CREATE INDEX folders_parent ON folders(parent_id);
''';

const int kKindImage = 0, kKindGif = 1, kKindVideo = 2, kKindProject = 3;

int _kindOf(String lowerName) {
  final dot = lowerName.lastIndexOf('.');
  final ext = dot < 0 ? '' : lowerName.substring(dot);
  if (ext == '.gif') return kKindGif;
  if (kVideoExtensions.contains(ext)) return kKindVideo;
  if (kProjectExtensions.contains(ext)) return kKindProject;
  return kKindImage;
}

class LinkImportRequest {
  final String indexCopy; // частная копия индекса в кэше приложения
  final String outPath; // куда собрать новую базу (потом её подменят)
  final String collectionId;
  final String indexVersion;
  final SendPort? progress; // сообщения [готово, всего]
  const LinkImportRequest({
    required this.indexCopy,
    required this.outPath,
    required this.collectionId,
    required this.indexVersion,
    this.progress,
  });
}

class LinkImportReport {
  final String? error;
  final int files;
  final int skipped;
  final int tagLinks;
  final int series;
  final int generatedAtMs;
  const LinkImportReport({
    this.error,
    this.files = 0,
    this.skipped = 0,
    this.tagLinks = 0,
    this.series = 0,
    this.generatedAtMs = 0,
  });
  bool get ok => error == null;
}

/// Собрать базу коллекции из копии индекса. Долго — только в фоновом изоляте.
LinkImportReport runLinkImport(LinkImportRequest r) {
  Database? idx;
  Database? out;
  final outFile = File(r.outPath);
  void dropOut() {
    for (final suffix in const ['', '-journal', '-wal', '-shm']) {
      try {
        File('${r.outPath}$suffix').deleteSync();
      } catch (_) {}
    }
  }

  try {
    dropOut();
    outFile.parent.createSync(recursive: true);
    // на Android у SQLite нет своей папки для временных файлов большой сортировки
    sqlite3.tempDirectory = outFile.parent.path;
    try {
      idx = openArchiveIndexCopy(r.indexCopy);
    } catch (_) {
      return const LinkImportReport(error: 'bad-index');
    }
    final info = archiveIndexInfoOf(idx);
    if (info == null) return const LinkImportReport(error: 'bad-index');

    final db = out = sqlite3.open(r.outPath);
    db.execute('PRAGMA journal_mode = OFF');
    db.execute('PRAGMA synchronous = OFF');
    db.execute('PRAGMA locking_mode = EXCLUSIVE');
    db.execute('PRAGMA cache_size = -65536');
    db.execute(_linkTables);

    final total =
        idx.select('SELECT count(*) AS n FROM files').first['n'] as int;
    r.progress?.send([0, total]);

    // ── файлы и дерево папок ──
    final folderIds = <String, int>{'': 1};
    final parents = <int, int?>{1: null};
    final direct = <int, int>{};
    int folderOf(String dir) {
      final known = folderIds[dir];
      if (known != null) return known;
      final cut = dir.lastIndexOf('/');
      final parent = folderOf(cut < 0 ? '' : dir.substring(0, cut));
      final id = folderIds.length + 1;
      folderIds[dir] = id;
      parents[id] = parent;
      return id;
    }

    final insFile = db.prepare(
        'INSERT INTO files(id, rel, lc, folder_id, sha, size, kind, rating, '
        'artist, artist_key, source_url, series_id, series_page) '
        'VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)');
    final cursor = idx
        .prepare('SELECT id, path, sha256, size, rating, artist, source_url, '
            'series_id, series_page FROM files ORDER BY id')
        .selectCursor();
    var seen = 0, kept = 0;
    db.execute('BEGIN');
    while (cursor.moveNext()) {
      final f = cursor.current;
      seen++;
      if (seen % 2000 == 0) r.progress?.send([seen, total]);
      final rel = f['path'] as String;
      if (!linkShowable(rel)) continue;
      final cut = rel.lastIndexOf('/');
      final folder = folderOf(cut < 0 ? '' : rel.substring(0, cut));
      direct[folder] = (direct[folder] ?? 0) + 1;
      final lc = rel.toLowerCase();
      final rating = (f['rating'] as String?)?.trim().toLowerCase();
      final artist = (f['artist'] as String?)?.trim();
      final url = (f['source_url'] as String?)?.trim();
      final sid = f['series_id'] as String?;
      insFile.execute([
        f['id'],
        rel,
        lc,
        folder,
        '${f['sha256']}'.trim().toLowerCase(),
        f['size'],
        _kindOf(lc),
        (rating == null || rating.isEmpty) ? null : rating,
        (artist == null || artist.isEmpty) ? null : artist,
        // SQLite понижает регистр только у латиницы, поэтому ключ готовим здесь
        (artist == null || artist.isEmpty) ? null : artistTagName(artist),
        (url == null || url.isEmpty) ? null : url,
        (sid == null || sid.isEmpty) ? null : sid,
        f['series_page'],
      ]);
      kept++;
    }
    insFile.dispose();

    final totals = <int, int>{};
    direct.forEach((id, n) {
      int? at = id;
      while (at != null) {
        totals[at] = (totals[at] ?? 0) + n;
        at = parents[at];
      }
    });
    final insFolder = db.prepare(
        'INSERT INTO folders(id, parent_id, name, path, direct_count, total_count) '
        'VALUES(?,?,?,?,?,?)');
    folderIds.forEach((path, id) {
      final cut = path.lastIndexOf('/');
      insFolder.execute([
        id,
        parents[id],
        cut < 0 ? path : path.substring(cut + 1),
        path,
        direct[id] ?? 0,
        totals[id] ?? 0,
      ]);
    });
    insFolder.dispose();
    db.execute('COMMIT');
    r.progress?.send([total, total]);

    // ── теги, авторы, серии: читаем копию индекса напрямую ──
    db.execute('ATTACH DATABASE ? AS src', [r.indexCopy]);
    db.execute('BEGIN');
    // одно имя — одна запись, даже если в индексе оно есть в двух категориях:
    // иначе файл с обоими тегами считался бы дважды
    final canon = <String, (int, String)>{};
    final tagIds = <int, String>{};
    for (final t
        in db.select('SELECT id, name, category FROM src.tags ORDER BY id')) {
      final name = '${t['name']}'.trim().toLowerCase();
      var cat = '${t['category']}'.trim().toLowerCase();
      if (name.isEmpty || cat == 'rating') continue;
      if (cat.isEmpty) cat = 'general';
      final seen = canon[name];
      if (seen == null) {
        canon[name] = (t['id'] as int, cat);
      } else if (seen.$2 == 'artist' && cat != 'artist') {
        canon[name] = (seen.$1, cat); // авторы живут своим списком
      }
      tagIds[t['id'] as int] = name;
    }
    final insTagRow =
        db.prepare('INSERT INTO tags(id, name, category) VALUES(?, ?, ?)');
    canon.forEach((name, v) => insTagRow.execute([v.$1, name, v.$2]));
    insTagRow.dispose();
    db.execute('CREATE TEMP TABLE tag_map '
        '(src INTEGER PRIMARY KEY, id INTEGER NOT NULL) WITHOUT ROWID');
    final insMap = db.prepare('INSERT INTO temp.tag_map(src, id) VALUES(?, ?)');
    tagIds.forEach((src, name) => insMap.execute([src, canon[name]!.$1]));
    insMap.dispose();
    db.execute('INSERT OR IGNORE INTO file_tags(tag_id, file_id) '
        'SELECT m.id, l.file_id FROM src.file_tags l '
        'JOIN temp.tag_map m ON m.src = l.tag_id '
        'JOIN files f ON f.id = l.file_id ORDER BY 1, 2');
    db.execute('DROP TABLE temp.tag_map');
    db.execute('UPDATE tags SET file_count = '
        '(SELECT count(*) FROM file_tags l WHERE l.tag_id = tags.id)');
    db.execute('DELETE FROM tags WHERE file_count = 0');
    // готовые счётчики «папка вместе с подпапками + вид файла + 18+ + тег»:
    // панель тегов не перебирает миллионы связей. Папка 1 — вся коллекция.
    db.execute('CREATE TEMP TABLE folder_up (folder INTEGER NOT NULL, '
        'up INTEGER NOT NULL, PRIMARY KEY (folder, up)) WITHOUT ROWID');
    final insUp = db.prepare('INSERT INTO temp.folder_up VALUES(?, ?)');
    for (final id in parents.keys) {
      int? at = id;
      while (at != null) {
        insUp.execute([id, at]);
        at = parents[at];
      }
    }
    insUp.dispose();
    db.execute('CREATE TEMP TABLE direct_tags AS '
        'SELECT f.folder_id AS folder_id, f.kind AS kind, '
        'ifnull(f.rating IN $_adultRatings, 0) AS adult, '
        'l.tag_id AS tag_id, count(*) AS n '
        'FROM file_tags l JOIN files f ON f.id = l.file_id GROUP BY 1, 2, 3, 4');
    db.execute('INSERT INTO folder_tags(folder_id, kind, adult, tag_id, n) '
        'SELECT u.up, d.kind, d.adult, d.tag_id, sum(d.n) '
        'FROM temp.direct_tags d JOIN temp.folder_up u ON u.folder = d.folder_id '
        'GROUP BY 1, 2, 3, 4');
    db.execute('DROP TABLE temp.direct_tags');
    db.execute('DROP TABLE temp.folder_up');
    db.execute('INSERT INTO series(id, title, page_count, confirmed, cover_id) '
        'SELECT s.id, s.title, count(f.id), s.confirmed, '
        '(SELECT c.id FROM files c WHERE c.series_id = s.id '
        ' ORDER BY c.series_page IS NULL, c.series_page, c.lc LIMIT 1) '
        'FROM src.series s JOIN files f ON f.series_id = s.id GROUP BY s.id');
    db.execute('COMMIT');
    db.execute('DETACH DATABASE src');
    db.execute(_linkIndexes);

    final insMeta = db.prepare('INSERT INTO meta(key, value) VALUES(?, ?)');
    for (final e in {
      'schema': '$kLinkSchema',
      'collection_id': r.collectionId,
      'index_version': r.indexVersion,
      'generated_at_ms': '${info.generatedAtMs}',
      'file_count': '$kept',
    }.entries) {
      insMeta.execute([e.key, e.value]);
    }
    insMeta.dispose();
    final links =
        db.select('SELECT count(*) AS n FROM file_tags').first['n'] as int;
    final nSeries =
        db.select('SELECT count(*) AS n FROM series').first['n'] as int;
    db.dispose();
    out = null;
    return LinkImportReport(
      files: kept,
      skipped: seen - kept,
      tagLinks: links,
      series: nSeries,
      generatedAtMs: info.generatedAtMs,
    );
  } catch (e) {
    try {
      out?.dispose();
    } catch (_) {}
    out = null;
    dropOut();
    return LinkImportReport(error: 'failed: $e');
  } finally {
    try {
      idx?.dispose();
    } catch (_) {}
    try {
      out?.dispose();
    } catch (_) {}
  }
}

/// Версия индекса, из которого собрана база. null — базы нет или она чужая.
String? readLinkDbVersion(String dbPath, String collectionId) {
  if (!File(dbPath).existsSync()) return null;
  Database? db;
  try {
    db = sqlite3.open(dbPath, mode: OpenMode.readOnly);
    final m = <String, String>{
      for (final r in db.select('SELECT key, value FROM meta'))
        '${r['key']}': '${r['value']}'
    };
    if (m['schema'] != '$kLinkSchema' || m['collection_id'] != collectionId) {
      return null;
    }
    return m['index_version'];
  } catch (_) {
    return null;
  } finally {
    try {
      db?.dispose();
    } catch (_) {}
  }
}

// ───────────────────────── запросы ─────────────────────────

/// Что показать. Передаётся в фоновый изолят.
class LinkFilter {
  final int? folderId;
  final bool deep;
  final String text;
  final Set<String> tags;
  final int? kind; // kKind…; null — всё, кроме проектов
  final int nsfw; // 0 все, 1 только 18+, 2 без 18+
  final String? seriesId;
  final String? artist;
  final int sort; // 0 имя, 1 размер, 2 случайно
  final int seed;
  const LinkFilter({
    this.folderId,
    this.deep = true,
    this.text = '',
    this.tags = const {},
    this.kind,
    this.nsfw = 0,
    this.seriesId,
    this.artist,
    this.sort = 0,
    this.seed = 0,
  });
}

const _adultRatings = "('questionable','explicit')";

/// Условие на папку. null — папка не ограничивает выборку.
(String, List<Object?>)? _folderClause(
    Database db, LinkFilter f, String column) {
  if (f.folderId == null) return null;
  if (!f.deep) return ('$column = ?', [f.folderId]);
  final row = db.select('SELECT path FROM folders WHERE id = ?', [f.folderId]);
  final path = row.isEmpty ? '' : row.first['path'] as String;
  if (path.isEmpty) return null; // корень коллекции
  return (
    '$column IN (SELECT id FROM folders WHERE id = ? '
        'OR substr(path, 1, ?) = ?)',
    [f.folderId, path.length + 1, '$path/'],
  );
}

/// Условия фильтра на таблицу files. Один источник и для списка, и для
/// счётчиков: поэтому число рядом с тегом всегда равно тому, что он покажет.
(List<String>, List<Object?>) _linkWhere(Database db, LinkFilter f) {
  final where = <String>[];
  final args = <Object?>[];

  if (f.seriesId != null) {
    where.add('series_id = ?');
    args.add(f.seriesId);
  }
  if (f.artist != null) {
    where.add('artist = ?');
    args.add(f.artist);
  }
  final folder = _folderClause(db, f, 'folder_id');
  if (folder != null) {
    where.add(folder.$1);
    args.addAll(folder.$2);
  }
  if (f.kind == null) {
    where.add('kind <> $kKindProject');
  } else {
    where.add('kind = ?');
    args.add(f.kind);
  }
  if (f.nsfw == 1) where.add('rating IN $_adultRatings');
  if (f.nsfw == 2) {
    where.add('(rating IS NULL OR rating NOT IN $_adultRatings)');
  }

  for (final t in f.tags) {
    if (t.startsWith('rating:')) {
      where.add('rating = ?');
      args.add(t.substring(7));
    } else if (t.startsWith('artist:')) {
      where.add('artist_key = ?');
      args.add(t.substring(7));
    } else {
      where.add('id IN (SELECT l.file_id FROM file_tags l JOIN tags t '
          'ON t.id = l.tag_id WHERE t.name = ?)');
      args.add(t);
    }
  }

  // тот же синтаксис поиска, что в локальной галерее и в Goat Archive
  final q = SearchQuery.parse(f.text);
  for (final a in q.artists) {
    where.add("instr(ifnull(artist_key, ''), ?) > 0");
    args.add(a);
  }
  for (final t in q.excluded) {
    where.add('id NOT IN (SELECT l.file_id FROM file_tags l JOIN tags t '
        'ON t.id = l.tag_id WHERE t.name = ?)');
    args.add(t);
  }
  for (final t in q.terms) {
    if (t.startsWith('rating:')) {
      where.add('rating = ?');
      args.add(t.substring(7));
    } else if (t.length < 2) {
      where.add('instr(lc, ?) > 0');
      args.add(t);
    } else {
      where.add('(instr(lc, ?) > 0 OR id IN (SELECT l.file_id FROM file_tags l '
          'WHERE l.tag_id IN (SELECT id FROM tags WHERE instr(name, ?) > 0)))');
      args
        ..add(t)
        ..add(t);
    }
  }
  return (where, args);
}

String _whereSql(List<String> where, [String? extra]) {
  final all = [...where, if (extra != null) extra];
  return all.isEmpty ? '' : ' WHERE ${all.join(' AND ')}';
}

/// Результат запроса: номера файлов по порядку и сколько среди них видео.
class LinkSelection {
  final Int32List ids;
  final int videos;
  const LinkSelection(this.ids, this.videos);
}

/// Номера файлов под фильтр, в нужном порядке. Лёгкий список чисел вместо самих
/// записей: сами записи подтягиваются страницами при прокрутке.
LinkSelection selectLinkRows(Database db, LinkFilter f) {
  final (where, args) = _linkWhere(db, f);
  final order = f.seriesId != null
      ? 'series_page IS NULL, series_page, lc'
      : switch (f.sort) {
          1 => 'size DESC, id',
          _ => 'lc',
        };
  final sql = 'SELECT id, kind FROM files${_whereSql(where)} ORDER BY $order';
  final stmt = db.prepare(sql);
  final cursor = stmt.selectCursor(args);
  var out = Int32List(1024);
  var n = 0, videos = 0;
  while (cursor.moveNext()) {
    if (n == out.length) {
      out = Int32List(out.length * 2)..setRange(0, n, out);
    }
    out[n++] = cursor.current.columnAt(0) as int;
    if (cursor.current.columnAt(1) == kKindVideo) videos++;
  }
  stmt.dispose();
  final ids = Int32List.sublistView(out, 0, n);
  if (f.sort == 2 && f.seriesId == null) {
    final rnd = math.Random(f.seed);
    for (var i = ids.length - 1; i > 0; i--) {
      final j = rnd.nextInt(i + 1);
      final tmp = ids[i];
      ids[i] = ids[j];
      ids[j] = tmp;
    }
  }
  return LinkSelection(ids, videos);
}

Int32List selectLinkIds(Database db, LinkFilter f) => selectLinkRows(db, f).ids;

/// Списки боковой панели. Число в строке — сколько файлов покажет нажатие на
/// неё при текущих папке, фильтрах и поиске.
enum LinkSideList { tags, artists, series }

class LinkSide {
  final List<LinkTagRow> tags;
  final List<LinkTagRow> artists;
  final List<LinkSeriesRow> series;
  const LinkSide(this.tags, this.artists, this.series);
  static const empty = LinkSide([], [], []);
}

List<LinkTagRow> _sideTags(
    Database db, LinkFilter f, String search, int limit) {
  // папка, вид файла и 18+ — берём готовые счётчики, это мгновенно даже на
  // всей коллекции; любой другой фильтр считается по подходящим файлам
  final simple = f.deep &&
      SearchQuery.parse(f.text).isEmpty &&
      f.tags.isEmpty &&
      f.artist == null &&
      f.seriesId == null;
  final String counts;
  final List<Object?> args;
  if (simple) {
    final inner = <String>[
      'c.folder_id = ?',
      f.kind == null ? 'c.kind <> $kKindProject' : 'c.kind = ?',
      if (f.nsfw == 1) 'c.adult = 1',
      if (f.nsfw == 2) 'c.adult = 0',
    ];
    counts = 'SELECT c.tag_id AS id, sum(c.n) AS n FROM folder_tags c '
        'WHERE ${inner.join(' AND ')} GROUP BY c.tag_id';
    args = [f.folderId ?? 1, if (f.kind != null) f.kind];
  } else {
    final (where, whereArgs) = _linkWhere(db, f);
    // от подходящих файлов к их тегам: так читаются только нужные связи
    counts = 'SELECT l.tag_id AS id, count(*) AS n '
        'FROM (SELECT id AS fid FROM files${_whereSql(where)}) s '
        'CROSS JOIN file_tags l INDEXED BY file_tags_file ON l.file_id = s.fid '
        'GROUP BY l.tag_id';
    args = whereArgs;
  }
  final rows = [
    for (final r in db.select(
        'SELECT t.name AS name, t.category AS category, x.n AS n '
        'FROM ($counts) x JOIN tags t ON t.id = x.id '
        "WHERE x.n > 0 AND t.category <> 'artist' "
        "AND (? = '' OR instr(t.name, ?) > 0) "
        'ORDER BY x.n DESC, t.name LIMIT ?',
        [...args, search, search, limit]))
      LinkTagRow(r['name'] as String, r['category'] as String, r['n'] as int)
  ];
  // выбранный тег остаётся в списке, даже если здесь ему ничего не подходит:
  // иначе его нельзя было бы снять отсюда
  final have = {for (final r in rows) r.name};
  final missing = [
    for (final t in f.tags)
      if (!have.contains(t) && (search.isEmpty || t.contains(search))) t
  ];
  if (missing.isEmpty) return rows;
  final (where, whereArgs) = _linkWhere(db, f);
  final total = db
      .select('SELECT count(*) AS n FROM files${_whereSql(where)}', whereArgs)
      .first['n'] as int;
  return [for (final t in missing) LinkTagRow(t, 'general', total), ...rows];
}

List<LinkTagRow> _sideArtists(
    Database db, LinkFilter f, String search, int limit) {
  // нажатие на автора заменяет автора и снимает серию
  final forArtists = LinkFilter(
    folderId: f.folderId,
    deep: f.deep,
    text: f.text,
    tags: f.tags,
    kind: f.kind,
    nsfw: f.nsfw,
  );
  final (aw, aa) = _linkWhere(db, forArtists);
  var artists = <LinkTagRow>[
    for (final r in db.select(
        'SELECT artist, count(*) AS n FROM files'
        '${_whereSql(aw, 'artist IS NOT NULL')} '
        'GROUP BY artist ORDER BY n DESC, artist',
        aa))
      LinkTagRow(r['artist'] as String, 'artist', r['n'] as int)
  ];
  if (search.isNotEmpty) {
    artists = [
      for (final a in artists)
        if (a.name.toLowerCase().contains(search)) a
    ];
  }
  if (artists.length > limit) artists = artists.sublist(0, limit);
  final chosen = f.artist;
  if (chosen != null &&
      (search.isEmpty || chosen.toLowerCase().contains(search)) &&
      !artists.any((a) => a.name == chosen)) {
    artists = [LinkTagRow(chosen, 'artist', 0), ...artists];
  }
  return artists;
}

LinkSide selectLinkSide(Database db, LinkFilter f,
    {String search = '', int limit = 400, LinkSideList? only}) {
  final tags = only == null || only == LinkSideList.tags
      ? _sideTags(db, f, search, limit)
      : const <LinkTagRow>[];
  if (only == LinkSideList.tags) return LinkSide(tags, const [], const []);

  var artists = const <LinkTagRow>[];
  if (only == null || only == LinkSideList.artists) {
    artists = _sideArtists(db, f, search, limit);
  }
  if (only == LinkSideList.artists) return LinkSide(tags, artists, const []);

// нажатие на серию снимает папку и автора
  final forSeries = LinkFilter(
    text: f.text,
    tags: f.tags,
    kind: f.kind,
    nsfw: f.nsfw,
  );
  final (sw, sa) = _linkWhere(db, forSeries);
  var series = [
    for (final r in db.select(
        'SELECT s.id AS id, s.title AS title, x.n AS n, s.cover_id AS cover '
        'FROM (SELECT series_id AS sid, count(*) AS n FROM files'
        '${_whereSql(sw, 'series_id IS NOT NULL')} GROUP BY series_id) x '
        'JOIN series s ON s.id = x.sid ORDER BY s.title COLLATE NOCASE',
        sa))
      LinkSeriesRow(r['id'] as String, r['title'] as String, r['n'] as int,
          r['cover'] as int?)
  ];
  if (search.isNotEmpty) {
    series = [
      for (final x in series)
        if (x.title.toLowerCase().contains(search)) x
    ];
  }
  final open = f.seriesId;
  if (open != null && !series.any((x) => x.id == open)) {
    final row = db
        .select('SELECT id, title, cover_id FROM series WHERE id = ?', [open]);
    if (row.isNotEmpty &&
        (search.isEmpty ||
            (row.first['title'] as String).toLowerCase().contains(search))) {
      series = [
        LinkSeriesRow(open, row.first['title'] as String, 0,
            row.first['cover_id'] as int?),
        ...series
      ];
    }
  }
  return LinkSide(tags, artists, series);
}

Database _openRead(String dbPath) {
  final db = sqlite3.open(dbPath, mode: OpenMode.readOnly);
  db.execute('PRAGMA query_only = ON');
  // на Android у SQLite нет папки для временных файлов сортировки
  db.execute('PRAGMA temp_store = MEMORY');
  return db;
}

Future<LinkSelection> queryLinkRows(String dbPath, LinkFilter f) async {
  final (data, videos) = await Isolate.run(() {
    final db = _openRead(dbPath);
    try {
      final r = selectLinkRows(db, f);
      return (TransferableTypedData.fromList([r.ids]), r.videos);
    } finally {
      db.dispose();
    }
  });
  return LinkSelection(data.materialize().asInt32List(), videos);
}

Future<Int32List> queryLinkIds(String dbPath, LinkFilter f) async =>
    (await queryLinkRows(dbPath, f)).ids;

Future<LinkSide> queryLinkSide(String dbPath, LinkFilter f,
    {String search = '', LinkSideList? only}) {
  return Isolate.run(() {
    final db = _openRead(dbPath);
    try {
      return selectLinkSide(db, f, search: search, only: only);
    } finally {
      db.dispose();
    }
  });
}

class LinkFolder {
  final int id;
  final int? parentId;
  final String name;
  final int direct;
  final int total;
  const LinkFolder(this.id, this.parentId, this.name, this.direct, this.total);
}

class LinkTagRow {
  final String name;
  final String category;
  final int count;
  const LinkTagRow(this.name, this.category, this.count);
}

class LinkSeriesRow {
  final String id;
  final String title;
  final int pages;
  final int? coverId;
  const LinkSeriesRow(this.id, this.title, this.pages, this.coverId);
}

class LinkFileInfo {
  final String? artist;
  final String? sourceUrl;
  final String? rating;
  final String? seriesTitle;
  final int? seriesPage;
  final int? seriesPages;
  final List<String> tags;
  const LinkFileInfo({
    this.artist,
    this.sourceUrl,
    this.rating,
    this.seriesTitle,
    this.seriesPage,
    this.seriesPages,
    this.tags = const [],
  });
}

/// Подключение к базе коллекции только на чтение.
class LinkDb {
  final String path;
  final String treeUri;
  final String collectionId;
  final Database _db;
  LinkDb._(this.path, this.treeUri, this.collectionId, this._db);

  static LinkDb open(String path,
          {required String treeUri, required String collectionId}) =>
      LinkDb._(path, treeUri, collectionId, _openRead(path));

  bool _closed = false;

  /// После подмены базы старый список на экране ещё может просить страницы:
  /// он получит заглушки и тут же будет заменён новым.
  bool get isClosed => _closed;

  void close() {
    if (_closed) return;
    _closed = true;
    try {
      _db.dispose();
    } catch (_) {}
  }

  int get fileCount => _closed
      ? 0
      : _db
          .select("SELECT count(*) AS n FROM files WHERE kind <> $kKindProject")
          .first['n'] as int;

  List<LinkFolder> folders() => _closed
      ? const []
      : [
          for (final r in _db.select(
              'SELECT id, parent_id, name, direct_count, total_count FROM folders'))
            LinkFolder(
                r['id'] as int,
                r['parent_id'] as int?,
                r['name'] as String,
                r['direct_count'] as int,
                r['total_count'] as int)
        ];

  List<LinkSeriesRow> series() => _closed
      ? const []
      : [
          for (final r in _db
              .select('SELECT id, title, page_count, cover_id FROM series '
                  'ORDER BY title COLLATE NOCASE'))
            LinkSeriesRow(r['id'] as String, r['title'] as String,
                r['page_count'] as int, r['cover_id'] as int?)
        ];

  /// Списки боковой панели для фильтра [f] (синхронно; в интерфейсе —
  /// через [queryLinkSide]).
  LinkSide side(LinkFilter f, {String search = ''}) =>
      _closed ? LinkSide.empty : selectLinkSide(_db, f, search: search);

  LinkFileInfo info(int fileId) {
    if (_closed) return const LinkFileInfo();
    final f = _db.select(
        'SELECT f.artist, f.source_url, f.rating, f.series_page, s.title, s.page_count '
        'FROM files f LEFT JOIN series s ON s.id = f.series_id WHERE f.id = ?',
        [fileId]);
    if (f.isEmpty) return const LinkFileInfo();
    final r = f.first;
    return LinkFileInfo(
      artist: r['artist'] as String?,
      sourceUrl: r['source_url'] as String?,
      rating: r['rating'] as String?,
      seriesTitle: r['title'] as String?,
      seriesPage: r['series_page'] as int?,
      seriesPages: r['page_count'] as int?,
      tags: [
        for (final t in _db.select(
            'SELECT t.name FROM file_tags l JOIN tags t ON t.id = l.tag_id '
            'WHERE l.file_id = ? ORDER BY t.category, t.name',
            [fileId]))
          t['name'] as String
      ],
    );
  }

  /// Записи по номерам: порядок ответа — как в [ids].
  List<PhotoItem> photos(List<int> ids) {
    if (ids.isEmpty) return const [];
    if (_closed) return [for (final id in ids) _missing(id)];
    final marks = List.filled(ids.length, '?').join(',');
    final rows = _db.select(
        'SELECT id, rel, sha, size, kind FROM files WHERE id IN ($marks)', ids);
    final byId = <int, PhotoItem>{};
    for (final r in rows) {
      final id = r['id'] as int;
      byId[id] = linkPhoto(
        treeUri: treeUri,
        collectionId: collectionId,
        fileId: id,
        rel: r['rel'] as String,
        sha: r['sha'] as String,
        size: r['size'] as int,
        kind: r['kind'] as int,
      );
    }
    return [for (final id in ids) byId[id] ?? _missing(id)];
  }

  PhotoItem _missing(int id) => linkPhoto(
      treeUri: treeUri,
      collectionId: collectionId,
      fileId: id,
      rel: 'missing-$id.jpg',
      sha: '',
      size: 0,
      kind: kKindImage);
}

/// Запись коллекции с ПК. Вместо пути файла — виртуальный адрес: он нужен лишь
/// как ключ внутри интерфейса и никогда не указывает на настоящий диск.
PhotoItem linkPhoto({
  required String treeUri,
  required String collectionId,
  required int fileId,
  required String rel,
  required String sha,
  required int size,
  required int kind,
}) {
  final cut = rel.lastIndexOf('/');
  final dir = cut < 0 ? '' : rel.substring(0, cut);
  final base = 'goat-link://$collectionId';
  return PhotoItem(
    path: '$base/$rel',
    isGif: kind == kKindGif,
    isVideo: kind == kKindVideo,
    folderPath: dir.isEmpty ? base : '$base/$dir',
    folderName: dir.isEmpty ? '' : p.posix.basename(dir),
    modified: DateTime.fromMillisecondsSinceEpoch(0),
    sizeBytes: size,
    link: LinkRef(treeUri: treeUri, fileId: fileId, rel: rel, sha: sha),
  );
}

/// Список фото коллекции: длина известна сразу, сами записи читаются из базы
/// страницами по мере прокрутки. Поэтому экран работает с обычным `List`, а в
/// памяти лежит лишь несколько страниц из 146 тысяч.
class LinkPhotoList extends ListBase<PhotoItem> {
  static const int pageSize = 120;
  static const int maxPages = 32;

  final LinkDb db;
  final Int32List ids;
  final int videos; // сколько среди них видео
  // LinkedHashMap помнит порядок: первый ключ — самая давно нужная страница
  final LinkedHashMap<int, List<PhotoItem>> _pages =
      LinkedHashMap<int, List<PhotoItem>>();

  LinkPhotoList(this.db, this.ids, {this.videos = 0});

  int get pictures => ids.length - videos;

  int get loadedPages => _pages.length;

  @override
  int get length => ids.length;

  @override
  set length(int value) => throw UnsupportedError('read-only');

  @override
  void operator []=(int index, PhotoItem value) =>
      throw UnsupportedError('read-only');

  @override
  PhotoItem operator [](int index) {
    RangeError.checkValidIndex(index, this);
    final page = index ~/ pageSize;
    var items = _pages.remove(page);
    if (items == null) {
      final end = math.min((page + 1) * pageSize, ids.length);
      items = db.photos(ids.sublist(page * pageSize, end));
      while (_pages.length >= maxPages) {
        _pages.remove(_pages.keys.first);
      }
    }
    _pages[page] = items;
    return items[index - page * pageSize];
  }
}
