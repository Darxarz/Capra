import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:permission_handler/permission_handler.dart';
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

  /// Запросить доступ к фото на устройстве (Android/iOS). Возвращает true,
  /// если доступ есть (полный или частичный).
  static Future<bool> requestMediaAccess() async {
    final ps = await PhotoManager.requestPermissionExtend();
    return ps.isAuth || ps.hasAccess;
  }

  /// «Доступ ко всем файлам» (Android) — нужен для секретных .nomedia-папок,
  /// которые система прячет от MediaStore. На ПК ограничений нет.
  static Future<bool> hasAllFilesAccess() async {
    if (!Platform.isAndroid) return true;
    return Permission.manageExternalStorage.isGranted;
  }

  /// Запросить «Доступ ко всем файлам» (открывает системный экран). true —
  /// если в итоге выдан.
  static Future<bool> requestAllFilesAccess() async {
    if (!Platform.isAndroid) return true;
    final s = await Permission.manageExternalStorage.request();
    return s.isGranted;
  }

  /// Просканировать конкретные папки по пути (для секретных .nomedia-папок,
  /// которых нет в MediaStore). Требует «Доступ ко всем файлам» на Android.
  static Future<List<PhotoItem>> scanFolders(List<String> paths) =>
      scanAll(paths);

  /// Найти все картинки на компьютере (Windows): обходит все диски, пропуская
  /// системные/служебные папки. Возвращает фото в фоне.
  static Future<List<PhotoItem>> scanWholePc() => compute(_scanWholePc, true);

  /// Минимальный набор «верхних» папок: убираем те, у кого предок уже в наборе
  /// (чтобы не сканировать одно и то же дважды).
  static List<String> topFolders(Set<String> dirs) {
    final sorted = dirs.toList()..sort((a, b) => a.length.compareTo(b.length));
    final res = <String>[];
    for (final d in sorted) {
      final sep = Platform.pathSeparator;
      if (!res.any((r) => d == r || d.startsWith('$r$sep'))) res.add(d);
    }
    return res;
  }

  /// Все изображения устройства через MediaStore (как в обычных галереях):
  /// без выбора папок и без доступа ко всем файлам. Внутренняя память + SD.
  static Future<List<PhotoItem>> scanDeviceMedia() async {
    final albums = await PhotoManager.getAssetPathList(
      onlyAll: true,
      type: RequestType.image,
    );
    if (albums.isEmpty) return const [];
    final all = albums.first;
    final count = await all.assetCountAsync;
    if (count == 0) return const [];

    // 1) перечисляем ассеты постранично, восстанавливаем путь из relativePath+title
    const page = 1000;
    final candidates = <String, AssetEntity>{}; // путь → ассет
    final unresolved = <AssetEntity>[];
    for (var pg = 0; pg * page < count; pg++) {
      final assets = await all.getAssetListPaged(page: pg, size: page);
      for (final a in assets) {
        final path = _reconstructPath(a);
        if (path != null) {
          candidates[path] = a;
        } else {
          unresolved.add(a);
        }
      }
    }

    // 2) stat путей в изоляте (существование/размер/дата) — UI не виснет
    final stats = await compute(_statPaths, candidates.keys.toList());
    final out = <PhotoItem>[];
    for (final s in stats) {
      final path = s[0] as String;
      final exists = s[1] as bool;
      if (exists) {
        out.add(_makePhoto(path, s[2] as int, s[3] as int,
            assetId: candidates[path]?.id));
      } else {
        final a = candidates[path];
        if (a != null) unresolved.add(a);
      }
    }

    // 3) то, что не удалось восстановить путём (например, SD) — через originFile
    for (final a in unresolved) {
      try {
        final f = await a.originFile;
        if (f != null && f.existsSync()) {
          final st = f.statSync();
          out.add(_makePhoto(
              f.path, st.size, st.modified.millisecondsSinceEpoch,
              assetId: a.id));
        }
      } catch (_) {}
    }

    out.sort((a, b) => b.modified.compareTo(a.modified));
    return out;
  }

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

/// Собрать абсолютный путь к ассету из relativePath + title (внутренняя память).
/// null — если данных не хватает (тогда путь добываем через originFile).
String? _reconstructPath(AssetEntity a) {
  final title = a.title;
  final rel = a.relativePath;
  if (title == null || title.isEmpty || rel == null) return null;
  final r = rel.endsWith('/') ? rel : '$rel/';
  return '/storage/emulated/0/$r$title';
}

PhotoItem _makePhoto(String path, int size, int mtimeMs, {String? assetId}) {
  const sep = '/';
  final cut = path.lastIndexOf(sep);
  final folderPath = cut >= 0 ? path.substring(0, cut) : path;
  final segs =
      folderPath.split(sep).where((s) => s.isNotEmpty).toList();
  final lower = path.toLowerCase();
  return PhotoItem(
    path: path,
    isGif: lower.endsWith('.gif'),
    folderPath: folderPath,
    folderName: segs.isNotEmpty ? segs.last : folderPath,
    modified: DateTime.fromMillisecondsSinceEpoch(mtimeMs),
    sizeBytes: size,
    assetId: assetId,
  );
}

/// stat списка путей в изоляте: [path, exists, size, mtimeMs].
List<List<dynamic>> _statPaths(List<String> paths) {
  final out = <List<dynamic>>[];
  for (final path in paths) {
    try {
      final f = File(path);
      if (f.existsSync()) {
        final st = f.statSync();
        out.add([path, true, st.size, st.modified.millisecondsSinceEpoch]);
      } else {
        out.add([path, false, 0, 0]);
      }
    } catch (_) {
      out.add([path, false, 0, 0]);
    }
  }
  return out;
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

/// Папки, которые НЕ обходим при поиске по всему ПК (системные/служебные).
const Set<String> _skipDirs = {
  'windows', 'program files', 'program files (x86)', 'programdata',
  r'$recycle.bin', 'system volume information', 'recovery', 'appdata',
  'node_modules', '.git', '.cache', 'temp', 'tmp', 'cache',
  'windows.old', 'msocache', 'perflogs',
};

/// Обойти все диски (Windows) и собрать изображения, пропуская системные папки.
/// Синхронный обход со стеком (без рекурсии) — устойчив к глубоким деревьям.
List<PhotoItem> _scanWholePc(bool _) {
  final out = <PhotoItem>[];
  final seen = <String>{};
  final sep = Platform.pathSeparator;

  // корни дисков: A:\ … Z:\ (существующие)
  final roots = <String>[];
  if (Platform.isWindows) {
    for (var ch = 'A'.codeUnitAt(0); ch <= 'Z'.codeUnitAt(0); ch++) {
      final root = '${String.fromCharCode(ch)}:$sep';
      try {
        if (Directory(root).existsSync()) roots.add(root);
      } catch (_) {}
    }
  } else {
    roots.add(sep); // на прочих ОС — от корня
  }

  final stack = <String>[...roots];
  while (stack.isNotEmpty) {
    final dirPath = stack.removeLast();
    List<FileSystemEntity> entries;
    try {
      entries = Directory(dirPath).listSync(followLinks: false);
    } catch (_) {
      continue; // нет доступа — пропускаем
    }
    for (final ent in entries) {
      final base = ent.path.split(sep).last;
      if (ent is Directory) {
        final low = base.toLowerCase();
        if (low.startsWith('.') || _skipDirs.contains(low)) continue;
        stack.add(ent.path);
      } else if (ent is File) {
        final lower = ent.path.toLowerCase();
        final dot = lower.lastIndexOf('.');
        if (dot < 0) continue;
        if (!kImageExtensions.contains(lower.substring(dot))) continue;
        if (!seen.add(ent.path)) continue;
        FileStat st;
        try {
          st = ent.statSync();
        } catch (_) {
          continue;
        }
        final folderPath = ent.parent.path;
        final segs =
            folderPath.split(sep).where((s) => s.isNotEmpty).toList();
        out.add(PhotoItem(
          path: ent.path,
          isGif: lower.endsWith('.gif'),
          folderPath: folderPath,
          folderName: segs.isNotEmpty ? segs.last : folderPath,
          modified: st.modified,
          sizeBytes: st.size,
        ));
      }
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
