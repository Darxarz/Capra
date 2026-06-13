import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'model.dart';

/// Сканирование папок и работа с библиотекой.
class LibraryService {
  static const _prefKey = 'aurora_folder'; // старый одиночный (миграция)
  static const _foldersKey = 'aurora_folders'; // список папок библиотеки

  /// Рекурсивно собирает все изображения из папки [root] (один корень).
  static Future<List<PhotoItem>> scan(String root) => compute(_scanFolder, root);

  /// Сканирует несколько корней и объединяет (без дублей), в фоне.
  static Future<List<PhotoItem>> scanAll(List<String> roots) =>
      compute(_scanFolders, roots);

  /// Список папок библиотеки (с миграцией со старого одиночного ключа).
  static Future<List<String>> folders() async {
    final p = await SharedPreferences.getInstance();
    final list = p.getStringList(_foldersKey);
    if (list != null) return list;
    final old = p.getString(_prefKey);
    if (old != null && old.isNotEmpty) {
      await p.setStringList(_foldersKey, [old]);
      return [old];
    }
    return const [];
  }

  static Future<void> setFolders(List<String> list) async {
    final p = await SharedPreferences.getInstance();
    await p.setStringList(_foldersKey, list);
  }

  /// Группирует фото по папкам → список альбомов (по убыванию размера).
  static List<AlbumItem> albums(List<PhotoItem> photos) {
    final map = <String, List<PhotoItem>>{};
    for (final p in photos) {
      map.putIfAbsent(p.folderPath, () => []).add(p);
    }
    final list = map.entries.map((e) {
      final segs = e.key
          .split(Platform.pathSeparator)
          .where((s) => s.isNotEmpty)
          .toList();
      return AlbumItem(
        name: segs.isNotEmpty ? segs.last : e.key,
        folderPath: e.key,
        count: e.value.length,
        cover: e.value.first,
      );
    }).toList();
    list.sort((a, b) => b.count.compareTo(a.count));
    return list;
  }

}

/// Сканирует список корней в одном изоляте, объединяя без дублей по пути.
Future<List<PhotoItem>> _scanFolders(List<String> roots) async {
  final out = <PhotoItem>[];
  final seen = <String>{};
  for (final root in roots) {
    final part = await _scanFolder(root);
    for (final p in part) {
      if (seen.add(p.path)) out.add(p);
    }
  }
  out.sort((a, b) => b.modified.compareTo(a.modified));
  return out;
}

/// Тело сканирования — выполняется в отдельном изоляте через [compute].
Future<List<PhotoItem>> _scanFolder(String root) async {
  final dir = Directory(root);
  final out = <PhotoItem>[];
  if (!await dir.exists()) return out;

  try {
    await for (final ent in dir.list(recursive: true, followLinks: false)) {
      if (ent is! File) continue;
      final lower = ent.path.toLowerCase();
      final dot = lower.lastIndexOf('.');
      if (dot < 0) continue;
      if (!kImageExtensions.contains(lower.substring(dot))) continue;

      FileStat st;
      try {
        st = await ent.stat();
      } catch (_) {
        continue;
      }

      final folderPath = ent.parent.path;
      final segs = folderPath
          .split(Platform.pathSeparator)
          .where((s) => s.isNotEmpty)
          .toList();
      out.add(PhotoItem(
        path: ent.path,
        isGif: lower.endsWith('.gif'),
        folderPath: folderPath,
        folderName: segs.isNotEmpty ? segs.last : folderPath,
        modified: st.modified,
        sizeBytes: st.size,
      ));
    }
  } catch (_) {
    // папки без доступа просто пропускаем
  }

  out.sort((a, b) => b.modified.compareTo(a.modified));
  return out;
}
