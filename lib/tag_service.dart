import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

/// Источник тегов, пришедших из индекса Goat Archive (см. archive_bridge.dart).
const String kArchiveSource = 'goat-archive';

/// Создать таблицы базы тегов, если их ещё нет. Вынесено из [TagService],
/// потому что ту же базу открывает фоновый импорт индекса Goat Archive.
void ensureTagSchema(Database db) {
  db.execute('''
    CREATE TABLE IF NOT EXISTS tags(
      path TEXT NOT NULL,
      tag TEXT NOT NULL,
      category TEXT,
      source TEXT,
      confidence REAL,
      PRIMARY KEY(path, tag)
    );
  ''');
  db.execute('CREATE INDEX IF NOT EXISTS idx_tags_tag ON tags(tag);');
  db.execute('CREATE INDEX IF NOT EXISTS idx_tags_path ON tags(path);');
  // сигнатуры файлов: точный хеш (дубли/перепривязка тегов), перцептивный
  // хеш (похожие), размеры и состояние целостности. Кэш по mtime+size.
  db.execute('''
    CREATE TABLE IF NOT EXISTS file_sig(
      path TEXT PRIMARY KEY,
      size INTEGER,
      mtime INTEGER,
      sha TEXT,
      phash INTEGER,
      width INTEGER,
      height INTEGER,
      status INTEGER
    );
  ''');
  db.execute('CREATE INDEX IF NOT EXISTS idx_sig_sha ON file_sig(sha);');
  // что Goat Archive знает о файле своей библиотеки: автор, страница-источник,
  // серия. epoch — отметка индекса, из которого запись пришла.
  db.execute('''
    CREATE TABLE IF NOT EXISTS archive_files(
      path TEXT PRIMARY KEY,
      library TEXT NOT NULL,
      artist TEXT,
      source_url TEXT,
      series_id TEXT,
      series_page INTEGER,
      epoch INTEGER
    );
  ''');
  db.execute('CREATE INDEX IF NOT EXISTS idx_archive_files_library '
      'ON archive_files(library, epoch);');
}

/// Сведения Goat Archive о файле (для инфопанели просмотрщика).
class ArchiveFileInfo {
  final String library;
  final String? artist;
  final String? sourceUrl;
  final String? seriesId;
  final int? seriesPage;
  const ArchiveFileInfo({
    required this.library,
    this.artist,
    this.sourceUrl,
    this.seriesId,
    this.seriesPage,
  });
}

/// Локальная база тегов (SQLite). Хранит теги по пути файла — тянет 100к+
/// изображений с быстрым поиском. Работает на Windows и Android.
class TagService {
  TagService._();
  static final TagService instance = TagService._();

  Database? _db;
  bool get ready => _db != null;

  /// Файл базы — его же открывает фоновый импорт индекса Goat Archive.
  String? dbPath;

  Future<void> init() async {
    if (_db != null) return;
    final dir = await getApplicationSupportDirectory();
    final dbPath = p.join(dir.path, 'goat_tags.db');
    // одноразовая миграция со старого имени БД (Capra → GOAT)
    final oldDb = File(p.join(dir.path, 'capra_tags.db'));
    if (!File(dbPath).existsSync() && oldDb.existsSync()) {
      try {
        oldDb.renameSync(dbPath);
      } catch (_) {/* если переезд не удался — стартуем с пустой БД */}
    }
    openAt(dbPath);
  }

  /// Открыть базу по явному пути (старт приложения и тесты).
  void openAt(String path) {
    close();
    final db = sqlite3.open(path);
    // фоновый импорт пишет в ту же базу пачками — подождать, а не падать
    db.execute('PRAGMA busy_timeout = 8000');
    ensureTagSchema(db);
    _db = db;
    dbPath = path;
  }

  void close() {
    try {
      _db?.dispose();
    } catch (_) {}
    _db = null;
    dbPath = null;
    invalidateCaches();
  }

  // ───────────────────────── словарь тегов ─────────────────────────

  List<String>? _vocab;

  /// Сбросить кэши, зависящие от содержимого базы (после записи тегов).
  void invalidateCaches() => _vocab = null;

  /// Все различные теги. Берутся «прыжками» по индексу тегов (один поиск на
  /// каждый различный тег), а не перебором миллионов строк; держатся в памяти
  /// до следующей записи.
  List<String> vocabulary() {
    final cached = _vocab;
    if (cached != null) return cached;
    final db = _db;
    if (db == null) return const [];
    final rows = db.select('''
      WITH RECURSIVE t(tag) AS (
        SELECT min(tag) FROM tags
        UNION ALL
        SELECT (SELECT min(tag) FROM tags WHERE tag > t.tag)
        FROM t WHERE t.tag IS NOT NULL
      )
      SELECT tag FROM t WHERE tag IS NOT NULL
    ''');
    return _vocab = [for (final r in rows) r['tag'] as String];
  }

  /// Пути файлов, у которых есть хотя бы один из [tags] (точное совпадение,
  /// по индексу тегов).
  Set<String> pathsWithAnyTag(Iterable<String> tags) {
    final db = _db;
    final list = tags.toSet().toList();
    if (db == null || list.isEmpty) return const {};
    final out = <String>{};
    const chunk = 400;
    for (var i = 0; i < list.length; i += chunk) {
      final part = list.sublist(i, (i + chunk).clamp(0, list.length));
      final ph = List.filled(part.length, '?').join(',');
      final rows =
          db.select('SELECT DISTINCT path FROM tags WHERE tag IN ($ph)', part);
      for (final r in rows) {
        out.add(r['path'] as String);
      }
    }
    return out;
  }

  /// Пути с точным тегом [tag]. Как в Goat Archive, «_» и пробел равнозначны.
  Set<String> pathsWithTag(String tag) => pathsWithAnyTag(tagSpellings(tag));

  /// Написания тега, которые считаются одним и тем же: `long_hair` / `long hair`.
  static List<String> tagSpellings(String tag) {
    final t = tag.trim().toLowerCase();
    if (t.isEmpty) return const [];
    return {t, t.replaceAll('_', ' '), t.replaceAll(' ', '_')}.toList();
  }

  /// Теги словаря, содержащие [fragment] (без учёта «_»/пробела). Сначала
  /// точное совпадение, потом начинающиеся с фрагмента, потом остальные; не
  /// больше [limit] — слишком общий фрагмент всё равно совпал бы почти со всем.
  List<String> tagsContaining(String fragment, {int limit = 400}) {
    final q = fragment.trim().toLowerCase().replaceAll(' ', '_');
    if (q.isEmpty) return const [];
    final exact = <String>[], prefix = <String>[], inner = <String>[];
    for (final tag in vocabulary()) {
      final t = tag.replaceAll(' ', '_');
      final at = t.indexOf(q);
      if (at < 0) continue;
      if (t.length == q.length) {
        exact.add(tag);
      } else if (at == 0) {
        prefix.add(tag);
      } else {
        inner.add(tag);
      }
    }
    final out = [...exact, ...prefix, ...inner];
    return out.length > limit ? out.sublist(0, limit) : out;
  }

  /// Пути с автором [name] — тегом `artist:<имя>` (его ставит импорт из Goat
  /// Archive; можно набрать и руками). Как в сортировщике: имя ищется как
  /// часть, а буквы и цифры сравниваются без регистра и знаков.
  Set<String> pathsWithArtist(String name) {
    final q = name.trim().toLowerCase().replaceAll(' ', '_');
    if (q.isEmpty) return const {};
    final key = _artistKey(q);
    final hits = <String>[];
    for (final tag in vocabulary()) {
      if (!tag.startsWith('artist:')) continue;
      final a = tag.substring(7).replaceAll(' ', '_');
      if (a.contains(q) || (key.isNotEmpty && _artistKey(a) == key)) {
        hits.add(tag);
      }
    }
    return pathsWithAnyTag(hits);
  }

  static final RegExp _notAlnum = RegExp(r'[^\p{L}\p{N}]', unicode: true);
  static String _artistKey(String s) => s.replaceAll(_notAlnum, '');

  /// Сведения Goat Archive о файле: автор, страница-источник, серия.
  ArchiveFileInfo? archiveInfo(String path) {
    final db = _db;
    if (db == null) return null;
    final rows = db.select(
        'SELECT library, artist, source_url, series_id, series_page '
        'FROM archive_files WHERE path = ? LIMIT 1',
        [path]);
    if (rows.isEmpty) return null;
    final r = rows.first;
    return ArchiveFileInfo(
      library: r['library'] as String,
      artist: r['artist'] as String?,
      sourceUrl: r['source_url'] as String?,
      seriesId: r['series_id'] as String?,
      seriesPage: r['series_page'] as int?,
    );
  }

  // ───────────────────────── сигнатуры файлов ─────────────────────────

  /// Кэшированная сигнатура, если она актуальна (совпадают size и mtime).
  ({String? sha, int? phash, int width, int height, int status})? sigFor(
      String path, int size, int mtime) {
    final db = _db;
    if (db == null) return null;
    final rows = db.select(
      'SELECT sha, phash, width, height, status FROM file_sig '
      'WHERE path = ? AND size = ? AND mtime = ?',
      [path, size, mtime],
    );
    if (rows.isEmpty) return null;
    final r = rows.first;
    return (
      sha: r['sha'] as String?,
      phash: r['phash'] as int?,
      width: (r['width'] as int?) ?? 0,
      height: (r['height'] as int?) ?? 0,
      status: (r['status'] as int?) ?? 0,
    );
  }

  void storeSig(String path, int size, int mtime,
      {String? sha, int? phash, int width = 0, int height = 0, int status = 0}) {
    _db?.execute(
      'INSERT OR REPLACE INTO file_sig'
      '(path, size, mtime, sha, phash, width, height, status) '
      'VALUES(?,?,?,?,?,?,?,?)',
      [path, size, mtime, sha, phash, width, height, status],
    );
  }

  /// Записать только точный хеш (не затирая perceptual-хеш/размеры, если есть).
  void storeShaOnly(String path, int size, int mtime, String sha) {
    _db?.execute(
      'INSERT INTO file_sig(path, size, mtime, sha) VALUES(?,?,?,?) '
      'ON CONFLICT(path) DO UPDATE SET sha=excluded.sha, '
      'size=excluded.size, mtime=excluded.mtime',
      [path, size, mtime, sha],
    );
  }

  /// Записать только размеры (для мозаичной сетки), не трогая хеши.
  void storeDimsOnly(String path, int size, int mtime, int width, int height) {
    _db?.execute(
      'INSERT INTO file_sig(path, size, mtime, width, height) VALUES(?,?,?,?,?) '
      'ON CONFLICT(path) DO UPDATE SET width=excluded.width, '
      'height=excluded.height, size=excluded.size, mtime=excluded.mtime',
      [path, size, mtime, width, height],
    );
  }

  /// Все известные размеры: path → (width, height). Только заполненные.
  Map<String, List<int>> loadAllDims() {
    final db = _db;
    if (db == null) return {};
    final rows = db.select(
        'SELECT path, width, height FROM file_sig '
        'WHERE width IS NOT NULL AND width > 0 AND height > 0');
    final out = <String, List<int>>{};
    for (final r in rows) {
      out[r['path'] as String] = [r['width'] as int, r['height'] as int];
    }
    return out;
  }

  /// Пути с заданным точным хешем (для перепривязки тегов после переноса).
  List<String> pathsWithSha(String sha) {
    final db = _db;
    if (db == null) return const [];
    final rows = db.select('SELECT path FROM file_sig WHERE sha = ?', [sha]);
    return [for (final r in rows) r['path'] as String];
  }

  /// Перенести теги (и сигнатуру) со старого пути на новый — для перепривязки
  /// после переименования/перемещения файла. Возвращает число перенесённых тегов.
  int movePath(String from, String to) {
    final db = _db;
    if (db == null || from == to) return 0;
    final n = tagsFor(from).length;
    db.execute('UPDATE OR IGNORE tags SET path = ? WHERE path = ?', [to, from]);
    db.execute('DELETE FROM tags WHERE path = ?', [from]);
    db.execute(
        'UPDATE OR REPLACE file_sig SET path = ? WHERE path = ?', [to, from]);
    return n;
  }

  /// Удалить все записи о файле (теги + сигнатуру) — при удалении файла.
  void forgetPath(String path) {
    _db?.execute('DELETE FROM tags WHERE path = ?', [path]);
    _db?.execute('DELETE FROM file_sig WHERE path = ?', [path]);
    _db?.execute('DELETE FROM archive_files WHERE path = ?', [path]);
    invalidateCaches();
  }

  /// Точный хеш файла из кэша (без проверки актуальности) — для перепривязки.
  String? shaForPath(String path) {
    final db = _db;
    if (db == null) return null;
    final rows =
        db.select('SELECT sha FROM file_sig WHERE path = ? LIMIT 1', [path]);
    return rows.isEmpty ? null : rows.first['sha'] as String?;
  }

  /// Перепривязать теги после переименования/перемещения файлов: для каждого
  /// помеченного пути, которого больше нет среди текущих файлов, ищем файл с
  /// тем же содержимым (по SHA) и переносим теги на него. Возвращает число
  /// перепривязанных файлов.
  int relink(Set<String> currentPaths) {
    final db = _db;
    if (db == null) return 0;
    var moved = 0;
    final tagged = taggedPaths();
    for (final old in tagged) {
      if (currentPaths.contains(old)) continue; // файл на месте
      final sha = shaForPath(old);
      if (sha == null) continue;
      // среди файлов с тем же содержимым ищем существующий и ещё не помеченный
      String? target;
      for (final cand in pathsWithSha(sha)) {
        if (cand == old) continue;
        if (!currentPaths.contains(cand)) continue;
        target = cand;
        if (tagsFor(cand).isEmpty) break; // предпочитаем без тегов
      }
      if (target != null) {
        movePath(old, target);
        moved++;
      }
    }
    return moved;
  }

  /// Экспорт всех тегов в JSON (бэкап/перенос между устройствами).
  String exportJson() {
    final db = _db;
    if (db == null) return '{"version":1,"tags":[]}';
    // теги из индекса Goat Archive в копию не идут: их миллионы, и они в любой
    // момент заново берутся из самой библиотеки
    final rows = db.select(
        'SELECT path, tag, category, source, confidence FROM tags '
        "WHERE source IS NOT '$kArchiveSource'");
    final list = [
      for (final r in rows)
        {
          'path': r['path'],
          'tag': r['tag'],
          'category': r['category'],
          'source': r['source'],
          'confidence': r['confidence'],
        }
    ];
    return jsonEncode({
      'version': 1,
      'exported': DateTime.now().toIso8601String(),
      'tags': list,
    });
  }

  /// Импорт тегов из JSON (слияние; существующие перезаписываются).
  /// Возвращает число импортированных тегов.
  int importJson(String json) {
    final db = _db;
    if (db == null) return 0;
    final data = jsonDecode(json);
    final list = (data is Map ? data['tags'] : data) as List?;
    if (list == null) return 0;
    var n = 0;
    invalidateCaches();
    db.execute('BEGIN');
    try {
      for (final e in list) {
        if (e is! Map) continue;
        final path = e['path'] as String?;
        final tag = e['tag'] as String?;
        if (path == null || tag == null) continue;
        db.execute(
          'INSERT OR REPLACE INTO tags(path, tag, category, source, confidence) '
          'VALUES(?,?,?,?,?)',
          [
            path,
            tag,
            e['category'] ?? 'manual',
            e['source'] ?? 'import',
            (e['confidence'] as num?)?.toDouble() ?? 1.0,
          ],
        );
        n++;
      }
      db.execute('COMMIT');
    } catch (_) {
      db.execute('ROLLBACK');
      return 0;
    }
    return n;
  }

  /// Теги конкретного файла (по убыванию уверенности, потом по алфавиту).
  List<String> tagsFor(String path) {
    final db = _db;
    if (db == null) return const [];
    final rows = db.select(
      'SELECT tag FROM tags WHERE path = ? ORDER BY confidence DESC, tag ASC',
      [path],
    );
    return [for (final r in rows) r['tag'] as String];
  }

  void addTag(
    String path,
    String tag, {
    String category = 'manual',
    String source = 'manual',
    double confidence = 1.0,
  }) {
    final db = _db;
    final t = tag.trim().toLowerCase();
    if (db == null || t.isEmpty) return;
    db.execute(
      'INSERT OR REPLACE INTO tags(path, tag, category, source, confidence) '
      'VALUES(?, ?, ?, ?, ?)',
      [path, t, category, source, confidence],
    );
    _vocabAdd(t);
  }

  // новый для словаря тег должен находиться поиском сразу; словарь отсортирован
  // так же, как индекс базы (по байтам), поэтому вставляем на своё место
  void _vocabAdd(String tag) {
    final v = _vocab;
    if (v == null) return;
    var lo = 0, hi = v.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (v[mid].compareTo(tag) < 0) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    if (lo < v.length && v[lo] == tag) return;
    // порядок сравнения строк в Dart и в SQLite может разойтись на редких
    // символах — тогда просто перечитаем словарь при следующем поиске
    if (v.contains(tag)) return;
    v.insert(lo, tag);
  }

  void removeTag(String path, String tag) {
    _db?.execute('DELETE FROM tags WHERE path = ? AND tag = ?', [path, tag]);
  }

  /// Пути файлов, у которых тег содержит подстроку [query] (для поиска).
  /// Подстрока ищется в словаре тегов, а пути берутся по индексу — без
  /// перебора всей таблицы (в ней бывают миллионы строк).
  Set<String> pathsMatchingTag(String query) {
    final q = query.trim().toLowerCase();
    if (_db == null || q.isEmpty) return const {};
    return pathsWithAnyTag(tagsContaining(q));
  }

  /// Все различные теги с количеством (для будущего обзора тегов).
  List<({String tag, int count})> allTags({int limit = 500}) {
    final db = _db;
    if (db == null) return const [];
    final rows = db.select(
      'SELECT tag, COUNT(*) AS n FROM tags GROUP BY tag ORDER BY n DESC LIMIT ?',
      [limit],
    );
    return [
      for (final r in rows) (tag: r['tag'] as String, count: r['n'] as int)
    ];
  }

  /// Все пути, у которых уже есть хоть один тег (для пропуска при пакетном).
  Set<String> taggedPaths() {
    final db = _db;
    if (db == null) return const {};
    // «прыжками» по индексу путей: один поиск на файл, а не на каждый тег
    final rows = db.select('''
      WITH RECURSIVE t(path) AS (
        SELECT min(path) FROM tags
        UNION ALL
        SELECT (SELECT min(path) FROM tags WHERE path > t.path)
        FROM t WHERE t.path IS NOT NULL
      )
      SELECT path FROM t WHERE path IS NOT NULL
    ''');
    return {for (final r in rows) r['path'] as String};
  }

  /// Пути фото, у которых есть ВСЕ указанные теги (фильтр И).
  Set<String> pathsWithAllTags(Iterable<String> tags) {
    final db = _db;
    final list = tags.toList();
    if (db == null || list.isEmpty) return const {};
    final ph = List.filled(list.length, '?').join(',');
    final rows = db.select(
      'SELECT path FROM tags WHERE tag IN ($ph) '
      'GROUP BY path HAVING COUNT(DISTINCT tag) = ?',
      [...list, list.length],
    );
    return {for (final r in rows) r['path'] as String};
  }

  /// Все теги с количеством и категорией (для обзора/группировки/сортировки).
  /// [byCount] — сортировать по количеству, иначе по алфавиту.
  List<({String tag, int count, String category})> tagList({
    bool byCount = true,
    int limit = 4000,
  }) {
    final db = _db;
    if (db == null) return const [];
    final order = byCount ? 'n DESC, tag ASC' : 'tag ASC';
    // счёт идёт по одному индексу тегов; категорию дочитываем только для
    // попавших в список — иначе на миллионах строк панель тегов замирает
    final rows = db.select(
      'SELECT t.tag AS tag, t.n AS n, '
      '(SELECT x.category FROM tags x WHERE x.tag = t.tag LIMIT 1) AS cat '
      'FROM (SELECT tag, COUNT(*) AS n FROM tags GROUP BY tag '
      'ORDER BY $order LIMIT ?) t',
      [limit],
    );
    return [
      for (final r in rows)
        (
          tag: r['tag'] as String,
          count: r['n'] as int,
          category: (r['cat'] as String?) ?? 'general',
        )
    ];
  }
}
