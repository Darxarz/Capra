import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

/// Одна коллекция: свой альбом пользователя либо серия из Goat Archive.
class CollectionInfo {
  final int id;
  final String name;
  final int count; // сколько фото внутри
  final DateTime created;

  /// true — это серия, которую ведёт Goat Archive: её состав и порядок страниц
  /// приходят из индекса библиотеки и обновляются при каждом импорте.
  final bool fromArchive;
  const CollectionInfo({
    required this.id,
    required this.name,
    required this.count,
    required this.created,
    this.fromArchive = false,
  });
}

const String _archiveSource = 'goat-archive';

bool _hasColumn(Database db, String table, String column) {
  for (final r in db.select('PRAGMA table_info($table)')) {
    if (r['name'] == column) return true;
  }
  return false;
}

/// Создать/обновить таблицы базы коллекций. Вынесено из [CollectionsService]:
/// ту же базу открывает фоновый импорт индекса Goat Archive.
///
/// Миграция: у элементов появился порядок (`position`). У своих коллекций он
/// пуст — они показываются как раньше, по дате добавления. У серий из Goat
/// Archive это номер страницы.
void ensureCollectionsSchema(Database db) {
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
  if (!_hasColumn(db, 'collection_items', 'position')) {
    db.execute('ALTER TABLE collection_items ADD COLUMN position INTEGER');
  }
  // откуда коллекция: NULL — своя; 'goat-archive' — серия из библиотеки
  // ext_library (корень) с идентификатором серии ext_id
  if (!_hasColumn(db, 'collections', 'source')) {
    db.execute('ALTER TABLE collections ADD COLUMN source TEXT');
  }
  if (!_hasColumn(db, 'collections', 'ext_library')) {
    db.execute('ALTER TABLE collections ADD COLUMN ext_library TEXT');
  }
  if (!_hasColumn(db, 'collections', 'ext_id')) {
    db.execute('ALTER TABLE collections ADD COLUMN ext_id TEXT');
  }
}

/// Локальное хранилище пользовательских коллекций (SQLite) — свои альбомы,
/// куда можно складывать фото из РАЗНЫХ папок, не перемещая файлы на диске.
/// Коллекция хранит просто список путей; сами файлы остаются на месте.
class CollectionsService {
  CollectionsService._();
  static final CollectionsService instance = CollectionsService._();

  Database? _db;
  bool get ready => _db != null;

  /// Файл базы — его же открывает фоновый импорт индекса Goat Archive.
  String? dbPath;

  Future<void> init() async {
    if (_db != null) return;
    final dir = await getApplicationSupportDirectory();
    openAt(p.join(dir.path, 'goat_collections.db'));
  }

  /// Открыть базу по явному пути (старт приложения и тесты).
  void openAt(String path) {
    close();
    final db = sqlite3.open(path);
    // фоновый импорт пишет в ту же базу — подождать, а не падать
    db.execute('PRAGMA busy_timeout = 8000');
    ensureCollectionsSchema(db);
    _db = db;
    dbPath = path;
  }

  void close() {
    try {
      _db?.dispose();
    } catch (_) {}
    _db = null;
    dbPath = null;
  }

  /// Коллекции со счётчиком фото. Свои — новые сверху; серии из Goat Archive
  /// — по названию. [archive]: null — все, false — только свои, true — только
  /// серии.
  List<CollectionInfo> list({bool? archive}) {
    final db = _db;
    if (db == null) return const [];
    final where = archive == null
        ? ''
        : (archive
            ? "WHERE c.source = '$_archiveSource'"
            : "WHERE c.source IS NOT '$_archiveSource'");
    final rows = db.select('''
      SELECT c.id AS id, c.name AS name, c.created AS created,
             c.source AS source, COUNT(i.path) AS n
      FROM collections c
      LEFT JOIN collection_items i ON i.collection_id = c.id
      $where
      GROUP BY c.id
      ORDER BY (c.source IS '$_archiveSource'),
               CASE WHEN c.source IS '$_archiveSource' THEN NULL ELSE c.created END DESC,
               c.name COLLATE NOCASE ASC
    ''');
    return [
      for (final r in rows)
        CollectionInfo(
          id: r['id'] as int,
          name: r['name'] as String,
          count: r['n'] as int,
          created: DateTime.fromMillisecondsSinceEpoch(r['created'] as int),
          fromArchive: r['source'] == _archiveSource,
        )
    ];
  }

  /// Серия Goat Archive, в которой лежит файл: название, номер страницы и
  /// сколько страниц. null — файл не из серии.
  ({String name, int page, int pages})? archiveSeriesOf(String path) {
    final db = _db;
    if (db == null) return null;
    final rows = db.select('''
      SELECT c.id AS id, c.name AS name, i.position AS pos
      FROM collection_items i JOIN collections c ON c.id = i.collection_id
      WHERE i.path = ? AND c.source = '$_archiveSource' AND i.position IS NOT NULL
      LIMIT 1
    ''', [path]);
    if (rows.isEmpty) return null;
    final id = rows.first['id'] as int;
    final n = db.select(
        'SELECT count(*) AS n FROM collection_items WHERE collection_id = ?',
        [id]).first['n'] as int;
    return (
      name: rows.first['name'] as String,
      page: rows.first['pos'] as int,
      pages: n
    );
  }

  /// Есть ли хоть одна серия из Goat Archive.
  bool get hasArchiveSeries {
    final db = _db;
    if (db == null) return false;
    return db
        .select(
            "SELECT 1 FROM collections WHERE source = '$_archiveSource' LIMIT 1")
        .isNotEmpty;
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

  /// Пути фото коллекции. Страницы серии (у них есть порядок) идут первыми,
  /// по номеру; остальное — как раньше, по убыванию даты добавления.
  List<String> pathsOf(int id) {
    final db = _db;
    if (db == null) return const [];
    final rows = db.select(
      'SELECT path FROM collection_items WHERE collection_id = ? '
      'ORDER BY (position IS NULL), position ASC, added DESC, path ASC',
      [id],
    );
    return [for (final r in rows) r['path'] as String];
  }

  /// Путь для обложки: первая страница серии, а у своей коллекции — первое
  /// добавленное фото. null, если пусто.
  String? coverPath(int id) {
    final db = _db;
    if (db == null) return null;
    final rows = db.select(
      'SELECT path FROM collection_items WHERE collection_id = ? '
      'ORDER BY (position IS NULL), position ASC, added ASC LIMIT 1',
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
