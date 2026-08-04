import 'dart:io';
import 'dart:typed_data';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

/// Хранилище векторов-эмбеддингов картинок (для семантического поиска и
/// «похожих»). Вектор — Float32List, кладём как BLOB. Отдельная БД, чтобы не
/// мешать базе тегов. Всё локально, ничего не уходит в сеть.
class EmbedStore {
  EmbedStore._();
  static final EmbedStore instance = EmbedStore._();

  Database? _db;
  bool get ready => _db != null;

  Future<void> init() async {
    if (_db != null) return;
    final base = await getApplicationSupportDirectory();
    final file = File(p.join(base.path, 'goat_embeddings.db'));
    final db = sqlite3.open(file.path);
    db.execute('''
      CREATE TABLE IF NOT EXISTS emb(
        path TEXT PRIMARY KEY,
        dim  INTEGER NOT NULL,
        vec  BLOB NOT NULL
      );
    ''');
    _db = db;
  }

  bool has(String path) {
    final db = _db;
    if (db == null) return false;
    final r = db.select('SELECT 1 FROM emb WHERE path = ? LIMIT 1', [path]);
    return r.isNotEmpty;
  }

  int get count {
    final db = _db;
    if (db == null) return 0;
    final r = db.select('SELECT COUNT(*) AS c FROM emb');
    return r.isEmpty ? 0 : (r.first['c'] as int);
  }

  void put(String path, Float32List vec) {
    final db = _db;
    if (db == null) return;
    db.execute('INSERT OR REPLACE INTO emb(path, dim, vec) VALUES (?, ?, ?)',
        [path, vec.length, vec.buffer.asUint8List()]);
  }

  void remove(String path) => _db?.execute('DELETE FROM emb WHERE path = ?', [path]);

  Float32List? vectorOf(String path) {
    final db = _db;
    if (db == null) return null;
    final r = db.select('SELECT vec FROM emb WHERE path = ? LIMIT 1', [path]);
    if (r.isEmpty) return null;
    return _decode(r.first['vec'] as Uint8List);
  }

  /// Все векторы (путь → вектор). Для поиска: держим в памяти и считаем косинус.
  /// На 100к × 512 float ≈ 200 МБ — приемлемо; при нужде вынесем в mmap/ANN.
  List<(String, Float32List)> all() {
    final db = _db;
    if (db == null) return const [];
    final out = <(String, Float32List)>[];
    for (final row in db.select('SELECT path, vec FROM emb')) {
      out.add((row['path'] as String, _decode(row['vec'] as Uint8List)));
    }
    return out;
  }

  static Float32List _decode(Uint8List bytes) =>
      bytes.buffer.asFloat32List(bytes.offsetInBytes, bytes.length ~/ 4);
}
