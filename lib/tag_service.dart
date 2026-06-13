import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

/// Локальная база тегов (SQLite). Хранит теги по пути файла — тянет 100к+
/// изображений с быстрым поиском. Работает на Windows и Android.
class TagService {
  TagService._();
  static final TagService instance = TagService._();

  Database? _db;
  bool get ready => _db != null;

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
    final db = sqlite3.open(dbPath);
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
    _db = db;
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
    final rows = db.select(
        'SELECT path, tag, category, source, confidence FROM tags');
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
  }

  void removeTag(String path, String tag) {
    _db?.execute('DELETE FROM tags WHERE path = ? AND tag = ?', [path, tag]);
  }

  /// Пути файлов, у которых тег содержит подстроку [query] (для поиска).
  Set<String> pathsMatchingTag(String query) {
    final db = _db;
    final q = query.trim().toLowerCase();
    if (db == null || q.isEmpty) return const {};
    final rows = db.select(
      'SELECT DISTINCT path FROM tags WHERE tag LIKE ?',
      ['%$q%'],
    );
    return {for (final r in rows) r['path'] as String};
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
    final rows = db.select('SELECT DISTINCT path FROM tags');
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
    final rows = db.select(
      'SELECT tag, COUNT(*) AS n, MAX(category) AS cat FROM tags '
      'GROUP BY tag ORDER BY $order LIMIT ?',
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
