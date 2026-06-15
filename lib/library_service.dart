import 'dart:async';
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
  static Future<List<PhotoItem>> scan(String root) =>
      compute(_scanFolder, root);

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
  /// системные/служебные папки и отсеивая иконки/мелкие текстуры. Возвращает
  /// фото в фоне. [minDim] — минимальный размер картинки по стороне (px).
  static Future<List<PhotoItem>> scanWholePc({int minDim = 256}) =>
      compute(_scanWholePc, PcScanConfig(minDim: minDim));

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

  /// Все изображения и видео устройства через MediaStore (как в обычных галереях):
  /// без выбора папок и без доступа ко всем файлам. Внутренняя память + SD.
  static Future<List<PhotoItem>> scanDeviceMedia() async {
    final albums = await PhotoManager.getAssetPathList(
      onlyAll: true,
      type: RequestType.common,
    ).timeout(const Duration(seconds: 20), onTimeout: () => const []);
    if (albums.isEmpty) return const [];
    final all = albums.first;
    final count = await all.assetCountAsync
        .timeout(const Duration(seconds: 20), onTimeout: () => 0);
    if (count == 0) return const [];

    // 1) перечисляем ассеты постранично, восстанавливаем путь из relativePath+title
    const page = 1000;
    final candidates = <String, AssetEntity>{}; // путь → ассет
    final unresolved = <AssetEntity>[];
    for (var pg = 0; pg * page < count; pg++) {
      final assets = await all
          .getAssetListPaged(page: pg, size: page)
          .timeout(const Duration(seconds: 20), onTimeout: () => const []);
      if (assets.isEmpty) break;
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
    // На части телефонов этот вызов может зависать на отдельных файлах, поэтому
    // берём его маленькими порциями и с лимитом времени.
    final fallbackTimer = Stopwatch()..start();
    var emptyFallbackChunks = 0;
    for (var i = 0; i < unresolved.length; i += 24) {
      if (fallbackTimer.elapsed > const Duration(seconds: 60) ||
          emptyFallbackChunks >= 3) {
        break;
      }
      final chunk = unresolved.skip(i).take(24).toList();
      final files = await Future.wait(chunk.map(_assetFileFast));
      var foundInChunk = 0;
      for (var j = 0; j < chunk.length; j++) {
        final f = files[j];
        if (f == null) continue;
        try {
          if (f.existsSync()) {
            foundInChunk++;
            final st = f.statSync();
            out.add(_makePhoto(
                f.path, st.size, st.modified.millisecondsSinceEpoch,
                assetId: chunk[j].id));
          }
        } catch (_) {}
      }
      emptyFallbackChunks = foundInChunk == 0 ? emptyFallbackChunks + 1 : 0;
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
  var r = rel.replaceAll('\\', '/').trim();
  if (r.isEmpty || r.startsWith('content://')) return null;
  if (!r.endsWith('/')) r = '$r/';
  if (r.startsWith('file://')) r = r.substring(7);
  if (r.startsWith('/storage/') || r.startsWith('/sdcard/')) {
    return '$r$title';
  }
  if (r.startsWith('/')) r = r.substring(1);
  return '/storage/emulated/0/$r$title';
}

Future<File?> _assetFileFast(AssetEntity a) async {
  try {
    final f =
        await a.originFile.timeout(const Duration(seconds: 3), onTimeout: () {
      throw TimeoutException('originFile timeout');
    });
    return f;
  } catch (_) {
    try {
      return await a.file.timeout(const Duration(seconds: 3), onTimeout: () {
        throw TimeoutException('file timeout');
      });
    } catch (_) {
      return null;
    }
  }
}

String _extensionOf(String lowerPath) {
  final dot = lowerPath.lastIndexOf('.');
  return dot < 0 ? '' : lowerPath.substring(dot);
}

PhotoItem _makePhoto(String path, int size, int mtimeMs, {String? assetId}) {
  const sep = '/';
  final cut = path.lastIndexOf(sep);
  final folderPath = cut >= 0 ? path.substring(0, cut) : path;
  final segs = folderPath.split(sep).where((s) => s.isNotEmpty).toList();
  final lower = path.toLowerCase();
  return PhotoItem(
    path: path,
    isGif: lower.endsWith('.gif'),
    isVideo: kVideoExtensions.contains(_extensionOf(lower)),
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

/// Папки, которые НЕ обходим при поиске по всему ПК — системные, служебные,
/// а также типичные хранилища иконок/текстур/ассетов (игры, движки, кэши).
const Set<String> _skipDirs = {
  // системные
  'windows', 'program files', 'program files (x86)', 'programdata',
  r'$recycle.bin', 'system volume information', 'recovery', 'appdata',
  'windows.old', 'msocache', 'perflogs', 'boot', 'config.msi',
  // служебные/разработка
  'node_modules', '.git', '.svn', '.cache', 'temp', 'tmp', 'cache', 'caches',
  '__pycache__', '.gradle', '.nuget', 'obj', 'bin', 'venv', '.venv',
  // иконки/превью/ассеты
  '.thumbnails', 'thumbnails', 'thumbs', 'icons', 'icon', 'sprites',
  'textures', 'texture', 'materials', 'shaders', 'assets', 'asset', 'res',
  'drawable', 'mipmap', 'emoji', 'emoticons', 'stickers', 'cursors',
  // игры/движки/магазины
  'steamapps', 'steamlibrary', 'steam', 'epic games', 'gog galaxy', 'origin',
  'riot games', 'battle.net', 'unrealengine', 'unity', 'godot',
};

/// Параметры умного поиска по ПК (передаём в изолят).
class PcScanConfig {
  final int minBytes; // мельче — наверняка иконка
  final int minDim; // меньше N px по любой стороне — иконка/спрайт/текстура
  const PcScanConfig({this.minBytes = 20 * 1024, this.minDim = 256});
}

/// Обойти все диски (Windows) и собрать изображения, пропуская системные папки
/// и отсеивая иконки/мелкие текстуры (по размеру файла и размеру в пикселях).
/// Синхронный обход со стеком (без рекурсии) — устойчив к глубоким деревьям.
List<PhotoItem> _scanWholePc(PcScanConfig cfg) {
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
        final ext = lower.substring(dot);
        if (!kScanExtensions.contains(ext)) continue;
        if (!seen.add(ent.path)) continue;
        FileStat st;
        try {
          st = ent.statSync();
        } catch (_) {
          continue;
        }
        // 1) отсев по размеру файла — иконки крошечные
        if (st.size < cfg.minBytes) continue;
        // 2) отсев по размеру в пикселях (читаем только заголовок).
        //    проекты и видео не трогаем — у них нет обычного заголовка картинки.
        if (!kProjectExtensions.contains(ext) &&
            !kVideoExtensions.contains(ext)) {
          final dims = _quickDims(ent);
          if (dims != null && (dims[0] < cfg.minDim || dims[1] < cfg.minDim)) {
            continue;
          }
        }
        final folderPath = ent.parent.path;
        final segs = folderPath.split(sep).where((s) => s.isNotEmpty).toList();
        out.add(PhotoItem(
          path: ent.path,
          isGif: lower.endsWith('.gif'),
          isVideo: kVideoExtensions.contains(ext),
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

/// Быстро прочитать размеры картинки из заголовка (без полного декода).
/// null — формат не распознан (тогда не отсеиваем). Возвращает [w, h].
List<int>? _quickDims(File f) {
  RandomAccessFile? raf;
  try {
    raf = f.openSync();
    final len = raf.lengthSync();
    final n = len < 65536 ? len : 65536;
    final b = raf.readSync(n);
    if (b.length < 24) return null;

    // PNG
    if (b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47) {
      return [_b32(b, 16), _b32(b, 20)];
    }
    // GIF
    if (b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x38) {
      return [b[6] | (b[7] << 8), b[8] | (b[9] << 8)];
    }
    // BMP
    if (b[0] == 0x42 && b[1] == 0x4D) {
      return [_l32(b, 18), _l32(b, 22).abs()];
    }
    // WEBP (RIFF…WEBP)
    if (b[0] == 0x52 && b[1] == 0x49 && b[8] == 0x57 && b[9] == 0x45) {
      final fmt = String.fromCharCodes(b.sublist(12, 16));
      if (fmt == 'VP8 ') {
        for (var i = 16; i + 9 < b.length && i < 64; i++) {
          if (b[i] == 0x9D && b[i + 1] == 0x01 && b[i + 2] == 0x2A) {
            return [
              ((b[i + 4] << 8) | b[i + 3]) & 0x3FFF,
              ((b[i + 6] << 8) | b[i + 5]) & 0x3FFF
            ];
          }
        }
      } else if (fmt == 'VP8L' && b.length > 24 && b[20] == 0x2F) {
        final bits = b[21] | (b[22] << 8) | (b[23] << 16) | (b[24] << 24);
        return [(bits & 0x3FFF) + 1, ((bits >> 14) & 0x3FFF) + 1];
      } else if (fmt == 'VP8X' && b.length > 29) {
        return [
          (b[24] | (b[25] << 8) | (b[26] << 16)) + 1,
          (b[27] | (b[28] << 8) | (b[29] << 16)) + 1
        ];
      }
      return null;
    }
    // JPEG — ищем SOF-маркер
    if (b[0] == 0xFF && b[1] == 0xD8) {
      var i = 2;
      while (i + 9 < b.length) {
        if (b[i] != 0xFF) {
          i++;
          continue;
        }
        final m = b[i + 1];
        if (m >= 0xC0 && m <= 0xCF && m != 0xC4 && m != 0xC8 && m != 0xCC) {
          return [(b[i + 7] << 8) | b[i + 8], (b[i + 5] << 8) | b[i + 6]];
        }
        if (i + 3 >= b.length) break;
        final seg = (b[i + 2] << 8) | b[i + 3];
        if (seg < 2) break;
        i += 2 + seg;
      }
    }
    return null;
  } catch (_) {
    return null;
  } finally {
    try {
      raf?.closeSync();
    } catch (_) {}
  }
}

int _b32(List<int> b, int o) =>
    (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3];
int _l32(List<int> b, int o) =>
    b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24);

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
      if (!kScanExtensions.contains(lower.substring(dot))) continue;

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
        isVideo: kVideoExtensions.contains(lower.substring(dot)),
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
