import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

/// Одна пользовательская коллекция («свой альбом»): id, название, дата создания.
class CollectionInfo {
  final int id;
  final String name;
  final int count; // сколько фото внутри
  final DateTime created;
  const CollectionInfo({
    required this.id,
    required this.name,
    required this.count,
    required this.created,
  });
}

/// Локальное хранилище пользовательских коллекций (SQLite) — свои альбомы,
/// куда можно складывать фото из РАЗНЫХ папок, не перемещая файлы на диске.
/// Коллекция хранит просто список путей; сами файлы остаются на месте.
class CollectionsService {
  CollectionsService._();
  static final CollectionsService instance = CollectionsService._();

  Database? _db;
  bool get ready => _db != null;

  Future<void> init() async {
    if (_db != null) return;
    final dir = await getApplicationSupportDirectory();
    final dbPath = p.join(dir.path, 'goat_collections.db');
    final db = sqlite3.open(dbPath);
    db.execute('''
      CREATE TABLE IF NOT EXISTS collections(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        created INTEGER NOT NULL
      );
    ''');
    db.execute('''
      CREATE TABLE IF NOT EXISTS collection_items(
        collection_id INTEGER NOT NULL,
        path TEXT NOT NULL,
        added INTEGER NOT NULL,
        PRIMARY KEY(collection_id, path)
      );
    ''');
    db.execute(
        'CREATE INDEX IF NOT EXISTS idx_ci_path ON collection_items(path);');
    db.execute(
        'CREATE INDEX IF NOT EXISTS idx_ci_coll ON collection_items(collection_id);');
    _db = db;
  }

  /// Все коллекции со счётчиком фото, новые сверху.
  List<CollectionInfo> list() {
    final db = _db;
    if (db == null) return const [];
    final rows = db.select('''
      SELECT c.id AS id, c.name AS name, c.created AS created,
             COUNT(i.path) AS n
      FROM collections c
      LEFT JOIN collection_items i ON i.collection_id = c.id
      GROUP BY c.id
      ORDER BY c.created DESC
    ''');
    return [
      for (final r in rows)
        CollectionInfo(
          id: r['id'] as int,
          name: r['name'] as String,
          count: r['n'] as int,
          created: DateTime.fromMillisecondsSinceEpoch(r['created'] as int),
        )
    ];
  }

  /// Создать коллекцию, вернуть её id.
  int create(String name) {
    final db = _db;
    final n = name.trim();
    if (db == null || n.isEmpty) return -1;
    db.execute('INSERT INTO collections(name, created) VALUES(?, ?)',
        [n, DateTime.now().millisecondsSinceEpoch]);
    return db.lastInsertRowId;
  }

  void rename(int id, String name) {
    final n = name.trim();
    if (n.isEmpty) return;
    _db?.execute('UPDATE collections SET name = ? WHERE id = ?', [n, id]);
  }

  void delete(int id) {
    _db?.execute(
        'DELETE FROM collection_items WHERE collection_id = ?', [id]);
    _db?.execute('DELETE FROM collections WHERE id = ?', [id]);
  }

  /// Пути фото коллекции (по убыванию даты добавления — новые сверху).
  List<String> pathsOf(int id) {
    final db = _db;
    if (db == null) return const [];
    final rows = db.select(
      'SELECT path FROM collection_items WHERE collection_id = ? '
      'ORDER BY added DESC',
      [id],
    );
    return [for (final r in rows) r['path'] as String];
  }

  /// Путь для обложки (первое добавленное фото) — или null, если пусто.
  String? coverPath(int id) {
    final db = _db;
    if (db == null) return null;
    final rows = db.select(
      'SELECT path FROM collection_items WHERE collection_id = ? '
      'ORDER BY added ASC LIMIT 1',
      [id],
    );
    return rows.isEmpty ? null : rows.first['path'] as String;
  }

  /// Добавить пути в коллекцию (без дублей). Возвращает число добавленных.
  int addPaths(int id, Iterable<String> paths) {
    final db = _db;
    if (db == null) return 0;
    final now = DateTime.now().millisecondsSinceEpoch;
    var n = 0;
    db.execute('BEGIN');
    try {
      for (final path in paths) {
        db.execute(
          'INSERT OR IGNORE INTO collection_items(collection_id, path, added) '
          'VALUES(?, ?, ?)',
          [id, path, now],
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

  void removePath(int id, String path) {
    _db?.execute(
        'DELETE FROM collection_items WHERE collection_id = ? AND path = ?',
        [id, path]);
  }

  /// В каких коллекциях лежит путь — для отметок «уже добавлено» в листе выбора.
  Set<int> collectionIdsOf(String path) {
    final db = _db;
    if (db == null) return const {};
    final rows = db.select(
      'SELECT collection_id FROM collection_items WHERE path = ?',
      [path],
    );
    return {for (final r in rows) r['collection_id'] as int};
  }
}
