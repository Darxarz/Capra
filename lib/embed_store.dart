import 'dart:io';
import 'dart:typed_data';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

/// Хранилище векторов-эмбеддингов картинок (для поиска «похожих» и будущего
/// семантического поиска). Всё локально, ничего не уходит в сеть.
///
/// ВЕКТОРЫ ХРАНЯТСЯ В INT8. Эмбеддинги нормализованы (каждая компонента в
/// пределах −1..1), поэтому их можно записать одним байтом на число вместо
/// четырёх — память падает в 4 раза (на 100к фото ≈ 75 МБ вместо ≈ 300 МБ),
/// а на качестве сравнения это почти не сказывается: для ранжирования
/// важен порядок, а не последний знак после запятой.
class EmbedStore {
  EmbedStore._();
  static final EmbedStore instance = EmbedStore._();

  Database? _db;
  bool get ready => _db != null;

  // Индекс векторов в памяти. Собирается ОДИН раз при первом поиске: иначе
  // каждый «Похожие» заново читал и декодировал всю таблицу на UI-потоке
  // (на 100к это заморозка на секунды).
  Map<String, Int8List>? _index;

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
    final idx = _index;
    if (idx != null) return idx.containsKey(path);
    final db = _db;
    if (db == null) return false;
    final r = db.select('SELECT 1 FROM emb WHERE path = ? LIMIT 1', [path]);
    return r.isNotEmpty;
  }

  /// Только пути уже посчитанных (без тяжёлых BLOB-ов). Для пакетной
  /// индексации: одним запросом вместо 100к отдельных проверок.
  Set<String> embeddedPaths() {
    final db = _db;
    if (db == null) return const {};
    return {
      for (final r in db.select('SELECT path FROM emb')) r['path'] as String
    };
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
    final q = quantize(vec);
    db.execute('INSERT OR REPLACE INTO emb(path, dim, vec) VALUES (?, ?, ?)',
        [path, vec.length, q.buffer.asUint8List(q.offsetInBytes, q.length)]);
    _index?[path] = q; // держим индекс в актуальном состоянии
  }

  void remove(String path) {
    _db?.execute('DELETE FROM emb WHERE path = ?', [path]);
    _index?.remove(path);
  }

  /// Вектор одной картинки в обычном float-виде (для запроса поиска).
  Float32List? vectorOf(String path) {
    final q = _quantizedOf(path);
    return q == null ? null : dequantize(q);
  }

  Int8List? _quantizedOf(String path) {
    final idx = _index;
    if (idx != null) return idx[path];
    final db = _db;
    if (db == null) return null;
    final r =
        db.select('SELECT dim, vec FROM emb WHERE path = ? LIMIT 1', [path]);
    if (r.isEmpty) return null;
    return _decode(r.first['vec'] as Uint8List, r.first['dim'] as int);
  }

  /// Весь индекс для косинусного поиска. Читаем из БД один раз, дальше — из
  /// памяти. Освободить можно через [releaseIndex].
  Map<String, Int8List> all() {
    final cached = _index;
    if (cached != null) return cached;
    final db = _db;
    if (db == null) return const {};
    final out = <String, Int8List>{};
    for (final row in db.select('SELECT path, dim, vec FROM emb')) {
      out[row['path'] as String] =
          _decode(row['vec'] as Uint8List, row['dim'] as int);
    }
    _index = out;
    return out;
  }

  /// Отпустить индекс из памяти (экран поиска закрыт / мало памяти).
  void releaseIndex() => _index = null;

  // ─── упаковка векторов ───

  /// float (−1..1) → int8 (−127..127).
  static Int8List quantize(Float32List v) {
    final out = Int8List(v.length);
    for (var i = 0; i < v.length; i++) {
      final x = (v[i] * 127).round();
      out[i] = x < -127 ? -127 : (x > 127 ? 127 : x);
    }
    return out;
  }

  /// int8 → float (обратно в −1..1).
  static Float32List dequantize(Int8List q) {
    final out = Float32List(q.length);
    for (var i = 0; i < q.length; i++) {
      out[i] = q[i] / 127.0;
    }
    return out;
  }

  /// Читаем BLOB. Формат определяем по длине: dim байт — уже int8,
  /// dim×4 — старый float32 (с первых сборок), ужимаем на лету.
  static Int8List _decode(Uint8List bytes, int dim) {
    if (dim > 0 && bytes.length == dim * 4) {
      final f = bytes.buffer.asFloat32List(bytes.offsetInBytes, dim);
      return quantize(f);
    }
    return Int8List.view(bytes.buffer, bytes.offsetInBytes, bytes.length);
  }
}
