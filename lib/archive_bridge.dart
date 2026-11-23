import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/sqlite3.dart';
import 'collections_service.dart';
import 'tag_service.dart';

// Связка галереи с Goat Archive (сортировщиком). Приложения не зависят друг
// от друга и встречаются только в обычных файлах — договор лежит в репозитории
// сортировщика: docs/GALLERY_BRIDGE.md. Здесь вся галерейная сторона:
//   1) узнать папку-библиотеку, которую ведёт сортировщик;
//   2) забрать из её индекса теги, рейтинг, авторов, хеши и серии;
//   3) запускать друг друга (Windows).

/// Файл-метка в корне библиотеки: «эту папку ведёт Goat Archive».
const String kArchiveMarker = '.goat-archive-export-marker';

/// Служебная папка сортировщика. В ней НЕТ содержимого коллекции — галерея
/// не должна её ни показывать, ни сканировать, ни трогать.
const String kArchiveDir = '.goat-archive-export';

/// Индекс библиотеки внутри служебной папки.
const String kArchiveIndexName = 'library-index.sqlite3';

// ───────────────────────── пути ─────────────────────────

bool get _caseBlind => Platform.isWindows;

/// Ключ сравнения путей: на Windows — без учёта регистра и вида разделителя.
String archivePathKey(String path) {
  if (!_caseBlind) return path;
  return path.replaceAll('/', '\\').toLowerCase();
}

String _stripSep(String path) {
  var s = path;
  while (s.length > 1 && (s.endsWith('\\') || s.endsWith('/'))) {
    // «D:\» оставляем как есть — это корень диска
    if (s.length == 3 && s[1] == ':') break;
    s = s.substring(0, s.length - 1);
  }
  return s;
}

/// Лежит ли [path] внутри папки [root] (или это она сама).
bool isSameOrUnder(String path, String root) {
  final a = archivePathKey(_stripSep(path));
  final b = archivePathKey(_stripSep(root));
  if (a == b) return true;
  if (b.endsWith('\\') || b.endsWith('/')) return a.startsWith(b);
  return a.startsWith('$b\\') || a.startsWith('$b/');
}

/// Путь проходит через служебную папку сортировщика?
bool isInsideArchiveDir(String path) {
  if (!path.contains(kArchiveDir)) return false; // быстрый отсев
  for (final seg in path.split(RegExp(r'[\\/]'))) {
    if (seg == kArchiveDir) return true;
  }
  return false;
}

/// Абсолютный путь файла библиотеки: корень так, как его пишет галерея, плюс
/// относительный путь из индекса (в индексе разделитель всегда «/»).
String archiveJoin(String root, String relative) {
  final sep = Platform.pathSeparator;
  final rel = sep == '/' ? relative : relative.replaceAll('/', sep);
  if (root.endsWith('/') || root.endsWith('\\')) return '$root$rel';
  return '$root$sep$rel';
}

String archiveIndexPath(String root) =>
    archiveJoin(root, '$kArchiveDir/$kArchiveIndexName');

/// Общая папка-родитель для набора папок (для «Влить» из выделения).
/// null — общего нет (разные диски) или остался один корень диска.
String? commonParentFolder(Iterable<String> folders) {
  List<String>? common;
  String? first;
  for (final f in folders) {
    final segs = _stripSep(f).split(RegExp(r'[\\/]'));
    if (common == null) {
      common = segs;
      first = f;
      continue;
    }
    var n = 0;
    while (n < common.length &&
        n < segs.length &&
        archivePathKey(common[n]) == archivePathKey(segs[n])) {
      n++;
    }
    common = common.sublist(0, n);
    if (common.isEmpty) return null;
  }
  if (common == null || first == null) return null;
  // «D:» или пустой корень — это уже не папка, а весь диск
  if (common.length == 1) return null;
  if (common.length == 2 && common[0].isEmpty && common[1].isEmpty) return null;
  final sep = first.contains('\\') ? '\\' : '/';
  return common.join(sep);
}

// ───────────────────────── поиск библиотек ─────────────────────────

/// Корни библиотек Goat Archive среди [folders] и их родителей. Путь корня
/// возвращается в том же написании, что и у папок галереи (это его начало),
/// чтобы пути файлов из индекса совпали с ключами базы галереи.
/// Выполняется в фоне (через `compute`): на каждую папку — проверка файла-метки.
List<String> findArchiveLibraries(List<String> folders) {
  final memo = <String, String?>{};
  String? lookup(String dir) {
    if (memo.containsKey(dir)) return memo[dir];
    String? found;
    try {
      if (File(archiveJoin(dir, kArchiveMarker)).existsSync()) found = dir;
    } catch (_) {}
    if (found == null) {
      final parent = p.dirname(dir);
      if (parent != dir && parent.isNotEmpty && parent != '.') {
        found = lookup(parent);
      }
    }
    memo[dir] = found;
    return found;
  }

  final out = <String>{};
  for (final f in folders) {
    if (f.isEmpty) continue;
    final root = lookup(_stripSep(f));
    if (root != null) out.add(root);
  }
  return out.toList()..sort();
}

// ───────────────────────── индекс ─────────────────────────

/// Шапка индекса (таблица `meta`).
class ArchiveIndexInfo {
  final int generatedAtMs;
  final int fileCount;
  final String appVersion;
  const ArchiveIndexInfo({
    required this.generatedAtMs,
    required this.fileCount,
    required this.appVersion,
  });
}

Map<String, String> _readMeta(Database db) {
  final out = <String, String>{};
  for (final r in db.select('SELECT key, value FROM meta')) {
    out['${r['key']}'] = '${r['value']}';
  }
  return out;
}

ArchiveIndexInfo? _infoFromMeta(Map<String, String> meta) {
  if (meta['format'] != 'goat-library-index') return null;
  final version = int.tryParse(meta['version'] ?? '');
  if (version != 1) return null; // незнакомую версию не читаем
  final at = int.tryParse(meta['generated_at_ms'] ?? '');
  if (at == null) return null;
  return ArchiveIndexInfo(
    generatedAtMs: at,
    fileCount: int.tryParse(meta['file_count'] ?? '') ?? 0,
    appVersion: meta['app_version'] ?? '',
  );
}

/// Прочитать шапку индекса библиотеки [root]. null — индекса нет, он занят
/// или это не индекс версии 1. Открывается только на чтение и сразу закрывается.
ArchiveIndexInfo? readArchiveIndexInfo(String root) {
  final path = archiveIndexPath(root);
  Database? db;
  try {
    if (!File(path).existsSync()) return null;
    db = sqlite3.open(path, mode: OpenMode.readOnly);
    return _infoFromMeta(_readMeta(db));
  } catch (_) {
    return null;
  } finally {
    try {
      db?.dispose();
    } catch (_) {}
  }
}

// ───────────────────────── импорт ─────────────────────────

/// Что импортировать. Передаётся в фоновый изолят.
class ArchiveImportRequest {
  final String root; // корень библиотеки в написании галереи
  final String tagsDbPath;
  final String collectionsDbPath;

  /// Уже известные размеры и даты файлов (путь → [размер, mtime мс]) — из
  /// скана галереи. Чего здесь нет, спросим у диска.
  final Map<String, List<int>>? known;
  final SendPort? progress; // сообщения [готово, всего]
  final String? tempDir;
  final int batchFiles; // файлов в одной транзакции
  const ArchiveImportRequest({
    required this.root,
    required this.tagsDbPath,
    required this.collectionsDbPath,
    this.known,
    this.progress,
    this.tempDir,
    this.batchFiles = 1000,
  });
}

/// Итог импорта.
class ArchiveImportReport {
  final String root;
  final String? error; // null — успех
  final int generatedAtMs;
  final int files; // файлов в индексе
  final int onDisk; // из них найдено на диске
  final int tagRows; // записано тегов (с рейтингом и автором)
  final int taggedFiles; // файлов с хотя бы одним тегом
  final int rated;
  final int withArtist;
  final int signatures; // хешей передано менеджеру дублей
  final int series;
  final int seriesPages;
  final int staleFiles; // исчезли из индекса — их теги сортировщика убраны
  const ArchiveImportReport({
    required this.root,
    this.error,
    this.generatedAtMs = 0,
    this.files = 0,
    this.onDisk = 0,
    this.tagRows = 0,
    this.taggedFiles = 0,
    this.rated = 0,
    this.withArtist = 0,
    this.signatures = 0,
    this.series = 0,
    this.seriesPages = 0,
    this.staleFiles = 0,
  });

  bool get ok => error == null;
}

/// Имя автора → часть тега `artist:<имя>` (как в поиске сортировщика:
/// нижний регистр, пробелы заменены подчёркиванием).
String artistTagName(String name) =>
    name.trim().toLowerCase().replaceAll(RegExp(r'\s+'), '_');

const Set<String> _ratings = {'general', 'sensitive', 'questionable', 'explicit'};

Database _openIndexCopy(String path) {
  try {
    final db = sqlite3.open(path, mode: OpenMode.readOnly);
    db.select('SELECT count(*) FROM meta');
    return db;
  } on SqliteException {
    // индекс мог быть записан в режиме WAL: частную копию читаем как неизменную
    return sqlite3.open('${Uri.file(path)}?immutable=1',
        uri: true, mode: OpenMode.readOnly);
  }
}

/// Импорт индекса библиотеки в базы галереи. Синхронный и долгий (сотни тысяч
/// файлов, миллионы тегов) — запускать ТОЛЬКО в фоновом изоляте, см.
/// [ArchiveBridge.sync]. Индекс читается потоком, запись идёт пачками: одна
/// транзакция на [ArchiveImportRequest.batchFiles] файлов.
ArchiveImportReport runArchiveImport(ArchiveImportRequest req) {
  final root = req.root;
  final source = File(archiveIndexPath(root));
  if (!source.existsSync()) {
    return ArchiveImportReport(root: root, error: 'no-index');
  }
  // Сортировщик заменяет индекс переименованием. Пока файл открыт, Windows
  // не даст его заменить — поэтому читаем частную копию, а оригинал занят
  // лишь на время копирования.
  final tmp = File(p.join(
      req.tempDir ?? Directory.systemTemp.path,
      'goat-library-index-$pid-${DateTime.now().microsecondsSinceEpoch}.sqlite3'));
  try {
    source.copySync(tmp.path);
  } catch (_) {
    return ArchiveImportReport(root: root, error: 'busy');
  }

  Database? idx;
  Database? tags;
  Database? coll;
  try {
    try {
      idx = _openIndexCopy(tmp.path);
    } catch (_) {
      return ArchiveImportReport(root: root, error: 'bad-index');
    }
    final info = _infoFromMeta(_readMeta(idx));
    if (info == null) {
      return ArchiveImportReport(root: root, error: 'bad-index');
    }
    final epoch = info.generatedAtMs;

    tags = sqlite3.open(req.tagsDbPath);
    tags.execute('PRAGMA busy_timeout = 15000');
    // большой кэш: транзакция пачки не «проливается» на диск раньше времени и
    // не запирает базу для чтения из интерфейса
    tags.execute('PRAGMA cache_size = -65536');
    ensureTagSchema(tags);

    // словарь тегов индекса целиком (десятки тысяч строк) — чтобы не делать
    // JOIN на каждую из миллионов связей
    final tagName = <int, String>{};
    final tagCat = <int, String>{};
    for (final r in idx.select('SELECT id, name, category FROM tags')) {
      final name = '${r['name']}'.trim().toLowerCase();
      final cat = '${r['category']}'.trim().toLowerCase();
      // рейтинг приходит отдельным полем файла; дубль-тегом его не заводим
      if (name.isEmpty || cat == 'rating') continue;
      final id = r['id'] as int;
      tagName[id] = name;
      tagCat[id] = cat.isEmpty ? 'general' : cat;
    }

    final total = (idx.select('SELECT count(*) AS n FROM files').first['n'] as int);
    req.progress?.send([0, total]);

    final delOld = tags.prepare(
        "DELETE FROM tags WHERE path = ?1 AND (source = '$kArchiveSource' "
        "OR (?2 = 1 AND category = 'rating' AND source IS NOT NULL "
        "AND source NOT IN ('manual', 'import')))");
    // вручную набранное (manual) и принесённое из копии (import) — не трогаем
    final insTag = tags.prepare(
        'INSERT INTO tags(path, tag, category, source, confidence) '
        "VALUES(?1, ?2, ?3, '$kArchiveSource', ?4) "
        'ON CONFLICT(path, tag) DO UPDATE SET category = excluded.category, '
        'source = excluded.source, confidence = excluded.confidence '
        "WHERE tags.source IS NOT NULL AND tags.source NOT IN ('manual', 'import')");
    final insInfo = tags.prepare(
        'INSERT OR REPLACE INTO archive_files'
        '(path, library, artist, source_url, series_id, series_page, epoch) '
        'VALUES(?,?,?,?,?,?,?)');
    // хеш кладём рядом с размером и датой файла; чужой перцептивный хеш и
    // размеры картинки сохраняем, только если файл с тех пор не менялся
    final insSig = tags.prepare(
        'INSERT INTO file_sig(path, size, mtime, sha) VALUES(?1, ?2, ?3, ?4) '
        'ON CONFLICT(path) DO UPDATE SET sha = excluded.sha, '
        'phash = CASE WHEN file_sig.size = excluded.size AND file_sig.mtime = excluded.mtime THEN file_sig.phash ELSE NULL END, '
        'width = CASE WHEN file_sig.size = excluded.size AND file_sig.mtime = excluded.mtime THEN file_sig.width ELSE NULL END, '
        'height = CASE WHEN file_sig.size = excluded.size AND file_sig.mtime = excluded.mtime THEN file_sig.height ELSE NULL END, '
        'status = CASE WHEN file_sig.size = excluded.size AND file_sig.mtime = excluded.mtime THEN file_sig.status ELSE NULL END, '
        'size = excluded.size, mtime = excluded.mtime');

    final fileStmt = idx.prepare(
        'SELECT id, path, sha256, size, rating, artist, source_url, '
        'series_id, series_page FROM files ORDER BY id');
    final tagStmt = idx.prepare(
        'SELECT file_id, tag_id, confidence FROM file_tags ORDER BY file_id');
    final files = fileStmt.selectCursor();
    final links = tagStmt.selectCursor();
    var haveLink = links.moveNext();

    var nFiles = 0, nOnDisk = 0, nTagRows = 0, nTagged = 0;
    var nRated = 0, nArtist = 0, nSig = 0;
    final pages = <String, List<(int?, String)>>{}; // серия → (страница, путь)

    var inBatch = 0;
    tags.execute('BEGIN IMMEDIATE');
    try {
      while (files.moveNext()) {
        final f = files.current;
        final id = f['id'] as int;
        final rel = f['path'] as String;
        final abs = archiveJoin(root, rel);
        nFiles++;
        // на всякий случай: служебную папку не трогаем, даже если она в индексе
        if (isInsideArchiveDir(abs)) continue;

        final rating = (f['rating'] as String?)?.trim().toLowerCase();
        final hasRating = rating != null && _ratings.contains(rating);
        delOld.execute([abs, hasRating ? 1 : 0]);

        var rows = 0;
        while (haveLink && (links.current['file_id'] as int) < id) {
          haveLink = links.moveNext(); // связь без файла — пропуск
        }
        while (haveLink && (links.current['file_id'] as int) == id) {
          final l = links.current;
          final tid = l['tag_id'] as int;
          final name = tagName[tid];
          if (name != null) {
            insTag.execute([
              abs,
              name,
              tagCat[tid],
              (l['confidence'] as num?)?.toDouble() ?? 1.0,
            ]);
            rows++;
          }
          haveLink = links.moveNext();
        }
        if (hasRating) {
          insTag.execute([abs, 'rating:$rating', 'rating', 1.0]);
          rows++;
          nRated++;
        }
        final artist = (f['artist'] as String?)?.trim();
        final hasArtist = artist != null && artist.isNotEmpty;
        if (hasArtist) {
          insTag.execute([abs, 'artist:${artistTagName(artist)}', 'artist', 1.0]);
          rows++;
          nArtist++;
        }
        if (rows > 0) nTagged++;
        nTagRows += rows;

        final url = (f['source_url'] as String?)?.trim();
        final seriesId = f['series_id'] as String?;
        final page = f['series_page'] as int?;
        insInfo.execute([
          abs,
          root,
          hasArtist ? artist : null,
          (url == null || url.isEmpty) ? null : url,
          seriesId,
          page,
          epoch,
        ]);
        if (seriesId != null && seriesId.isNotEmpty) {
          pages.putIfAbsent(seriesId, () => []).add((page, abs));
        }

        // размер и дата файла: из скана галереи, иначе с диска
        int? size, mtime;
        final k = req.known?[abs];
        if (k != null && k.length >= 2) {
          size = k[0];
          mtime = k[1];
        } else {
          try {
            final st = File(abs).statSync();
            if (st.type == FileSystemEntityType.file) {
              size = st.size;
              mtime = st.modified.millisecondsSinceEpoch;
            }
          } catch (_) {}
        }
        if (size != null && mtime != null) {
          nOnDisk++;
          final sha = (f['sha256'] as String?)?.trim().toLowerCase();
          // хеш верен только для тех же байтов: размер обязан совпасть
          if (sha != null && sha.length == 64 && size == (f['size'] as int?)) {
            insSig.execute([abs, size, mtime, sha]);
            nSig++;
          }
        }

        if (++inBatch >= req.batchFiles) {
          tags.execute('COMMIT');
          inBatch = 0;
          req.progress?.send([nFiles, total]);
          tags.execute('BEGIN IMMEDIATE');
        }
      }

      // файлы, которых больше нет в индексе: их теги сортировщика уходят
      final stale = tags.select(
          'SELECT count(*) AS n FROM archive_files WHERE library = ? AND epoch <> ?',
          [root, epoch]).first['n'] as int;
      if (stale > 0) {
        tags.execute(
            "DELETE FROM tags WHERE source = '$kArchiveSource' AND path IN "
            '(SELECT path FROM archive_files WHERE library = ? AND epoch <> ?)',
            [root, epoch]);
        tags.execute(
            'DELETE FROM archive_files WHERE library = ? AND epoch <> ?',
            [root, epoch]);
      }
      tags.execute('COMMIT');

      // ── серии → коллекции (страницы по порядку) ──
      coll = sqlite3.open(req.collectionsDbPath);
      coll.execute('PRAGMA busy_timeout = 15000');
      ensureCollectionsSchema(coll);
      final titles = <String, String>{};
      for (final r in idx.select('SELECT id, title FROM series')) {
        titles['${r['id']}'] = '${r['title']}'.trim();
      }
      final seriesStats = _writeSeries(coll, root, pages, titles);

      req.progress?.send([total, total]);
      delOld.dispose();
      insTag.dispose();
      insInfo.dispose();
      insSig.dispose();
      fileStmt.dispose();
      tagStmt.dispose();
      return ArchiveImportReport(
        root: root,
        generatedAtMs: epoch,
        files: nFiles,
        onDisk: nOnDisk,
        tagRows: nTagRows,
        taggedFiles: nTagged,
        rated: nRated,
        withArtist: nArtist,
        signatures: nSig,
        series: seriesStats.$1,
        seriesPages: seriesStats.$2,
        staleFiles: stale,
      );
    } catch (e) {
      try {
        tags.execute('ROLLBACK');
      } catch (_) {}
      return ArchiveImportReport(root: root, error: 'failed: $e');
    }
  } catch (e) {
    return ArchiveImportReport(root: root, error: 'failed: $e');
  } finally {
    for (final db in [idx, tags, coll]) {
      try {
        db?.dispose();
      } catch (_) {}
    }
    try {
      tmp.deleteSync();
    } catch (_) {}
  }
}

/// Записать серии библиотеки как коллекции: одна на серию, страницы по
/// порядку. Свои коллекции пользователя и добавленное им вручную не трогаем.
/// Возвращает (серий, страниц).
(int, int) _writeSeries(Database coll, String root,
    Map<String, List<(int?, String)>> pages, Map<String, String> titles) {
  var nSeries = 0, nPages = 0;
  final now = DateTime.now().millisecondsSinceEpoch;
  coll.execute('BEGIN IMMEDIATE');
  try {
    final seen = <int>{};
    for (final e in pages.entries) {
      final list = e.value
        ..sort((a, b) {
          final pa = a.$1, pb = b.$1;
          if (pa != null && pb != null && pa != pb) return pa.compareTo(pb);
          if (pa == null && pb != null) return 1;
          if (pa != null && pb == null) return -1;
          return a.$2.toLowerCase().compareTo(b.$2.toLowerCase());
        });
      final title =
          (titles[e.key] == null || titles[e.key]!.isEmpty) ? e.key : titles[e.key]!;
      final found = coll.select(
          "SELECT id, name FROM collections WHERE source = '$kArchiveSource' "
          'AND ext_library = ? AND ext_id = ?',
          [root, e.key]);
      int id;
      if (found.isEmpty) {
        coll.execute(
            'INSERT INTO collections(name, created, source, ext_library, ext_id) '
            "VALUES(?, ?, '$kArchiveSource', ?, ?)",
            [title, now, root, e.key]);
        id = coll.lastInsertRowId;
      } else {
        id = found.first['id'] as int;
        if (found.first['name'] != title) {
          coll.execute(
              'UPDATE collections SET name = ? WHERE id = ?', [title, id]);
        }
      }
      seen.add(id);
      // прежние страницы серии заменяем; добавленное руками (без номера) остаётся
      coll.execute(
          'DELETE FROM collection_items WHERE collection_id = ? '
          'AND position IS NOT NULL',
          [id]);
      var pos = 0;
      for (final (_, path) in list) {
        pos++;
        coll.execute(
            'INSERT OR REPLACE INTO collection_items'
            '(collection_id, path, added, position) VALUES(?, ?, ?, ?)',
            [id, path, now, pos]);
      }
      nSeries++;
      nPages += pos;
    }
    // серии, которых в индексе больше нет
    final old = coll.select(
        "SELECT id FROM collections WHERE source = '$kArchiveSource' "
        'AND ext_library = ?',
        [root]);
    for (final r in old) {
      final id = r['id'] as int;
      if (seen.contains(id)) continue;
      coll.execute(
          'DELETE FROM collection_items WHERE collection_id = ? '
          'AND position IS NOT NULL',
          [id]);
      final left = coll.select(
          'SELECT count(*) AS n FROM collection_items WHERE collection_id = ?',
          [id]).first['n'] as int;
      if (left == 0) {
        coll.execute('DELETE FROM collections WHERE id = ?', [id]);
      } else {
        // в серию что-то добавили руками — оставляем как обычную коллекцию
        coll.execute(
            'UPDATE collections SET source = NULL, ext_library = NULL, '
            'ext_id = NULL WHERE id = ?',
            [id]);
      }
    }
    coll.execute('COMMIT');
  } catch (_) {
    coll.execute('ROLLBACK');
    rethrow;
  }
  return (nSeries, nPages);
}

// ───────────────────────── запуск друг друга (Windows) ─────────────────────────

enum HandoffResult { sent, notInstalled, failed }

/// Файлы в `%APPDATA%\Goat`, через которые приложения семейства находят и
/// запускают друг друга (договор, §3). Только Windows.
class GoatApps {
  /// Папка `%APPDATA%\Goat`. [base] — подмена `%APPDATA%` (для тестов).
  static String? goatDir({String? base}) {
    final root = base ?? Platform.environment['APPDATA'];
    if (root == null || root.isEmpty) return null;
    return p.join(root, 'Goat');
  }

  static void _writeAtomic(String path, String text) {
    final tmp = File('${p.withoutExtension(path)}.tmp');
    tmp.parent.createSync(recursive: true);
    tmp.writeAsStringSync(text, flush: true);
    final dst = File(path);
    try {
      tmp.renameSync(path);
    } on FileSystemException {
      if (dst.existsSync()) dst.deleteSync();
      tmp.renameSync(path);
    }
  }

  /// Записать «где стоит галерея» — чтобы сортировщик мог её открыть.
  static bool writeGalleryJson(
      {String? base, String? exe, required String version}) {
    final dir = goatDir(base: base);
    if (dir == null) return false;
    try {
      _writeAtomic(
          p.join(dir, 'apps', 'gallery.json'),
          jsonEncode({
            'exe': exe ?? Platform.resolvedExecutable,
            'version': version,
          }));
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Путь к программе сортировщика из `archive.json`. null — сортировщик на
  /// этом компьютере ещё не запускали (или его с тех пор удалили).
  static String? archiveExe({String? base}) {
    final dir = goatDir(base: base);
    if (dir == null) return null;
    try {
      final f = File(p.join(dir, 'apps', 'archive.json'));
      if (!f.existsSync()) return null;
      final data = jsonDecode(f.readAsStringSync());
      final exe = data is Map ? data['exe'] : null;
      if (exe is! String || exe.isEmpty) return null;
      return File(exe).existsSync() ? exe : null;
    } catch (_) {
      return null;
    }
  }

  static int _seq = 0;

  /// Положить сортировщику просьбу «добавь папку в список на слияние».
  /// Возвращает путь файла-просьбы.
  static String writeAddSource(String folder, {String? base}) {
    final dir = goatDir(base: base);
    if (dir == null) throw StateError('no APPDATA');
    final name =
        'gallery-${DateTime.now().millisecondsSinceEpoch}-$pid-${_seq++}.json';
    final path = p.join(dir, 'inbox', 'archive', name);
    _writeAtomic(path, jsonEncode({'action': 'add-source', 'path': folder}));
    return path;
  }

  /// «Влить в коллекцию»: просьба в ящик + запуск сортировщика с `--handoff`.
  /// Сам сортировщик только добавит папку в список; слияние начнёт владелец.
  static Future<HandoffResult> mergeFolder(String folder,
      {String? base, bool launch = true}) async {
    final exe = archiveExe(base: base);
    if (exe == null) return HandoffResult.notInstalled;
    try {
      writeAddSource(folder, base: base);
      if (launch) {
        await Process.start(exe, const ['--handoff'],
            workingDirectory: p.dirname(exe), mode: ProcessStartMode.detached);
      }
      return HandoffResult.sent;
    } catch (_) {
      return HandoffResult.failed;
    }
  }

  /// Открыть Goat Archive.
  static Future<HandoffResult> openArchive({String? base}) async {
    final exe = archiveExe(base: base);
    if (exe == null) return HandoffResult.notInstalled;
    try {
      await Process.start(exe, const [],
          workingDirectory: p.dirname(exe), mode: ProcessStartMode.detached);
      return HandoffResult.sent;
    } catch (_) {
      return HandoffResult.failed;
    }
  }

  /// Путь из `--open <путь>` командной строки (так галерею открывает сортировщик).
  static String? openPathFromArgs(List<String> args) {
    for (var i = 0; i < args.length; i++) {
      final a = args[i];
      if (a == '--open' && i + 1 < args.length) return args[i + 1];
      if (a.startsWith('--open=')) return a.substring('--open='.length);
    }
    return null;
  }
}

/// Куда вести галерею по `--open <путь>`.
class OpenPlan {
  final String folder; // папка, которую показать как текущую
  final String? file; // файл, который открыть в просмотрщике
  final String? addRoot; // папку нужно добавить в библиотеку галереи
  const OpenPlan({required this.folder, this.file, this.addRoot});
}

/// Разобрать путь из `--open`: папка открывается как текущая, для файла
/// открывается его папка и сам файл. Если папка не лежит ни в одном из
/// [roots], её нужно добавить к ним (прежние корни остаются). null — такого
/// пути на диске нет.
OpenPlan? planOpen(String path, List<String> roots) {
  var target = path.trim();
  if (target.length >= 2 && target.startsWith('"') && target.endsWith('"')) {
    target = target.substring(1, target.length - 1);
  }
  target = _stripSep(target);
  if (target.isEmpty) return null;
  FileSystemEntityType type;
  try {
    type = FileSystemEntity.typeSync(target);
  } catch (_) {
    return null;
  }
  String folder;
  String? file;
  if (type == FileSystemEntityType.directory) {
    folder = target;
  } else if (type == FileSystemEntityType.file) {
    file = target;
    folder = p.dirname(target);
  } else {
    return null;
  }
  final covered = roots.any((r) => isSameOrUnder(folder, r));
  return OpenPlan(folder: folder, file: file, addRoot: covered ? null : folder);
}

// ───────────────────────── состояние связки ─────────────────────────

/// Что галерея сейчас знает о Goat Archive: какие папки — его библиотеки, идёт
/// ли импорт индекса, чем он кончился. Слушатели — главный экран.
class ArchiveBridge extends ChangeNotifier {
  ArchiveBridge._();
  static final ArchiveBridge instance = ArchiveBridge._();

  static const _prefPrefix = 'goat_archive_index_at::';

  /// Путь, с которым галерею запустил сортировщик (`--open`). Забирается один раз.
  static String? launchOpenPath;

  List<String> libraries = const []; // корни библиотек (написание галереи)
  bool archiveInstalled = false; // сортировщик уже запускали на этом ПК

  bool importing = false;
  String importRoot = '';
  int done = 0;
  int total = 0;
  ArchiveImportReport? lastReport; // последний завершившийся импорт
  int reportSerial = 0; // растёт с каждым завершённым импортом

  /// Корень библиотеки, внутри которой лежит [path] (или это он сам).
  String? libraryOf(String path) {
    for (final root in libraries) {
      if (isSameOrUnder(path, root)) return root;
    }
    return null;
  }

  bool inLibrary(String path) => libraryOf(path) != null;

  bool isLibraryRoot(String path) {
    final k = archivePathKey(_stripSep(path));
    return libraries.any((r) => archivePathKey(_stripSep(r)) == k);
  }

  /// Сколько из [paths] лежит в библиотеках Goat Archive.
  int countInLibrary(Iterable<String> paths) {
    if (libraries.isEmpty) return 0;
    var n = 0;
    for (final path in paths) {
      if (inLibrary(path)) n++;
    }
    return n;
  }

  /// Найти библиотеки среди папок с фото и корней галереи (в фоне).
  Future<void> detect(Iterable<String> folders) async {
    final list = {...folders}.toList();
    List<String> found;
    try {
      found = await compute(findArchiveLibraries, list);
    } catch (_) {
      found = const [];
    }
    final installed = Platform.isWindows && GoatApps.archiveExe() != null;
    if (!listEquals(found, libraries) || installed != archiveInstalled) {
      libraries = found;
      archiveInstalled = installed;
      notifyListeners();
    }
  }

  Future<int?> _rememberedAt(String root) async {
    final prefs = await SharedPreferences.getInstance();
    return int.tryParse(prefs.getString('$_prefPrefix$root') ?? '');
  }

  /// Индекс библиотеки [root] новее того, что уже забрали?
  Future<bool> needsImport(String root) async {
    final info = readArchiveIndexInfo(root);
    if (info == null) return false;
    return info.generatedAtMs != await _rememberedAt(root);
  }

  /// Забрать индексы библиотек. Без [force] — только изменившиеся. Работает в
  /// фоне: запись идёт в отдельном изоляте, интерфейс остаётся живым.
  /// [known] — размеры и даты файлов из скана (путь → [размер, mtime мс]).
  Future<List<ArchiveImportReport>> sync({
    bool force = false,
    Map<String, List<int>>? known,
    Iterable<String>? only,
  }) async {
    if (importing) return const [];
    final tagsDb = TagService.instance.dbPath;
    final collDb = CollectionsService.instance.dbPath;
    if (tagsDb == null || collDb == null) return const [];
    final reports = <ArchiveImportReport>[];
    for (final root in (only ?? libraries).toList()) {
      final info = readArchiveIndexInfo(root);
      if (info == null) {
        if (force) {
          reports.add(ArchiveImportReport(root: root, error: 'no-index'));
        }
        continue;
      }
      if (!force && info.generatedAtMs == await _rememberedAt(root)) continue;

      importing = true;
      importRoot = root;
      done = 0;
      total = info.fileCount;
      notifyListeners();

      final port = ReceivePort();
      final sub = port.listen((m) {
        if (m is List && m.length == 2) {
          done = m[0] as int;
          total = m[1] as int;
          notifyListeners();
        }
      });
      ArchiveImportReport report;
      try {
        final req = ArchiveImportRequest(
          root: root,
          tagsDbPath: tagsDb,
          collectionsDbPath: collDb,
          known: known == null
              ? null
              : {
                  for (final e in known.entries)
                    if (isSameOrUnder(e.key, root)) e.key: e.value
                },
          progress: port.sendPort,
        );
        // через compute: замыкание в этой области утащило бы в изолят порт
        report = await compute(runArchiveImport, req);
      } catch (e) {
        report = ArchiveImportReport(root: root, error: 'failed: $e');
      } finally {
        await sub.cancel();
        port.close();
      }
      if (report.ok) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(
            '$_prefPrefix$root', '${report.generatedAtMs}');
      }
      reports.add(report);
      TagService.instance.invalidateCaches();
      lastReport = report;
      reportSerial++;
      importing = false;
      notifyListeners();
    }
    return reports;
  }
}
