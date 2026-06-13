import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'tag_service.dart';

/// Запись в корзине: откуда файл и где он сейчас лежит.
class TrashEntry {
  final String original; // исходный путь
  final String stored; // путь в корзине
  final int size;
  final DateTime when;
  const TrashEntry({
    required this.original,
    required this.stored,
    required this.size,
    required this.when,
  });

  String get fileName => p.basename(original);

  Map<String, dynamic> toJson() => {
        'original': original,
        'stored': stored,
        'size': size,
        'when': when.millisecondsSinceEpoch,
      };

  static TrashEntry fromJson(Map<String, dynamic> j) => TrashEntry(
        original: j['original'] as String,
        stored: j['stored'] as String,
        size: (j['size'] as int?) ?? 0,
        when: DateTime.fromMillisecondsSinceEpoch((j['when'] as int?) ?? 0),
      );
}

/// «Корзина GOAT»: безопасное удаление — файлы переносятся в служебную папку
/// и могут быть восстановлены. Кросс-платформенно (Windows/Android), переживает
/// перенос между дисками/разделами (rename → копия+удаление при отказе).
class TrashService {
  TrashService._();
  static final TrashService instance = TrashService._();

  Directory? _dir;
  List<TrashEntry> _entries = [];

  Future<Directory> _trashDir() async {
    if (_dir != null) return _dir!;
    final base = await getApplicationSupportDirectory();
    final d = Directory(p.join(base.path, 'trash'));
    if (!await d.exists()) await d.create(recursive: true);
    _dir = d;
    await _loadManifest();
    return d;
  }

  Future<File> _manifestFile() async =>
      File(p.join((await _trashDir()).path, 'manifest.json'));

  Future<void> _loadManifest() async {
    try {
      final f = File(p.join(_dir!.path, 'manifest.json'));
      if (await f.exists()) {
        final list = jsonDecode(await f.readAsString()) as List;
        _entries = [
          for (final e in list) TrashEntry.fromJson(e as Map<String, dynamic>)
        ];
      }
    } catch (_) {
      _entries = [];
    }
  }

  Future<void> _saveManifest() async {
    final f = await _manifestFile();
    await f.writeAsString(jsonEncode([for (final e in _entries) e.toJson()]));
  }

  Future<List<TrashEntry>> entries() async {
    await _trashDir();
    return List.unmodifiable(_entries.reversed);
  }

  int get count => _entries.length;
  int get totalBytes => _entries.fold(0, (s, e) => s + e.size);

  /// Перенести файлы в корзину. Возвращает сколько удалось.
  Future<int> trash(Iterable<String> paths) async {
    final dir = await _trashDir();
    var ok = 0;
    final stamp = DateTime.now().millisecondsSinceEpoch;
    var i = 0;
    for (final path in paths) {
      final src = File(path);
      if (!await src.exists()) continue;
      final stored = p.join(dir.path, '${stamp}_${i++}__${p.basename(path)}');
      try {
        final size = await src.length();
        await _move(src, stored);
        _entries.add(TrashEntry(
          original: path,
          stored: stored,
          size: size,
          when: DateTime.now(),
        ));
        ok++;
      } catch (_) {
        // не удалось перенести — пропускаем
      }
    }
    if (ok > 0) await _saveManifest();
    return ok;
  }

  /// Восстановить файл на исходное место (если там пусто).
  Future<bool> restore(TrashEntry e) async {
    await _trashDir();
    final stored = File(e.stored);
    if (!await stored.exists()) {
      _entries.removeWhere((x) => x.stored == e.stored);
      await _saveManifest();
      return false;
    }
    if (await File(e.original).exists()) return false; // занято
    try {
      await Directory(p.dirname(e.original)).create(recursive: true);
      await _move(stored, e.original);
      _entries.removeWhere((x) => x.stored == e.stored);
      await _saveManifest();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Безвозвратно удалить одну запись.
  Future<void> deleteForever(TrashEntry e) async {
    try {
      final f = File(e.stored);
      if (await f.exists()) await f.delete();
    } catch (_) {}
    TagService.instance.forgetPath(e.original);
    _entries.removeWhere((x) => x.stored == e.stored);
    await _saveManifest();
  }

  /// Очистить корзину полностью (безвозвратно).
  Future<void> empty() async {
    await _trashDir();
    for (final e in _entries) {
      try {
        final f = File(e.stored);
        if (await f.exists()) await f.delete();
      } catch (_) {}
      TagService.instance.forgetPath(e.original);
    }
    _entries = [];
    await _saveManifest();
  }

  /// Перенос с запасным вариантом копия+удаление (для разных дисков/разделов).
  /// Если оригинал не удаляется (например, Android scoped storage без права
  /// записи к медиа), убираем копию и пробрасываем ошибку — чтобы не плодить
  /// дубликаты (копия в корзине + оригинал на месте).
  Future<void> _move(File src, String dest) async {
    try {
      await src.rename(dest);
    } on FileSystemException {
      await src.copy(dest);
      try {
        await src.delete();
      } catch (e) {
        try {
          await File(dest).delete();
        } catch (_) {}
        rethrow;
      }
    }
  }
}
