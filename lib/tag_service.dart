import 'dart:async';
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
    final dbPath = p.join(dir.path, 'capra_tags.db');
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
    _db = db;
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
