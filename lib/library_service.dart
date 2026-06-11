import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'model.dart';

/// Сканирование папок и работа с библиотекой.
class LibraryService {
  static const _prefKey = 'aurora_folder';

  /// Рекурсивно собирает все изображения из папки [root].
  /// Работает в отдельном изоляте (compute), чтобы интерфейс не подвисал
  /// даже на 100к+ файлов. Возвращает список от новых к старым.
  static Future<List<PhotoItem>> scan(String root) => compute(_scanFolder, root);

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

  static Future<String?> lastFolder() async {
    final p = await SharedPreferences.getInstance();
    return p.getString(_prefKey);
  }

  static Future<void> saveFolder(String path) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_prefKey, path);
  }
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
