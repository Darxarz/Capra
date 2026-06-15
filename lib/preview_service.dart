import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:crypto/crypto.dart';
import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:archive/archive.dart';
import 'package:image/image.dart' as img;
import 'package:win32/win32.dart' as win;
import 'settings_service.dart';

/// Извлечение и показ превью «проектных» форматов (KRA, PSD), которые Flutter
/// сам декодировать не умеет. Внутри KRA лежит готовый PNG (mergedimage/preview),
/// в PSD — встроенная JPEG-миниатюра (ресурс 1036). Достаём их в изоляте и
/// кэшируем на диск, поэтому повторный показ мгновенный.
class PreviewService {
  static Directory? _dir;

  static Future<Directory> _cacheDir() async {
    if (_dir != null) return _dir!;
    final base = await getTemporaryDirectory();
    final d = Directory(p.join(base.path, 'goat_previews'));
    if (!await d.exists()) await d.create(recursive: true);
    _dir = d;
    return d;
  }

  /// Байты превью (PNG/JPEG) для проекта. [full] — полноразмерное для
  /// просмотрщика, иначе миниатюра. Кэшируется по пути+дате.
  static Future<Uint8List?> bytesFor(String path, int mtime, bool full) async {
    try {
      final dir = await _cacheDir();
      final key = '${path.hashCode}_${mtime}_${full ? 'f' : 't'}';
      final cache = File(p.join(dir.path, '$key.img'));
      if (cache.existsSync()) {
        final b = cache.readAsBytesSync();
        if (b.isNotEmpty) return b;
      }
      final bytes = await compute(_extract, _ExtractReq(path, full));
      if (bytes != null && bytes.isNotEmpty) {
        try {
          cache.writeAsBytesSync(bytes);
        } catch (_) {}
      }
      return bytes;
    } catch (_) {
      return null;
    }
  }
}

/// Постоянный кэш обычных миниатюр. Он нужен для облачных дисков: если файл уже
/// был локально и GOAT сделал маленькую копию, сетка больше не трогает оригинал.
class ThumbnailCacheService {
  static Directory? _dir;
  static bool _windowsComInitialized = false;

  static Future<Directory> _cacheDir() async {
    if (_dir != null) return _dir!;
    final base = await getApplicationSupportDirectory();
    final d = Directory(p.join(base.path, 'thumbs'));
    if (!await d.exists()) await d.create(recursive: true);
    _dir = d;
    return d;
  }

  static Future<Uint8List?> bytesFor({
    required String path,
    required int mtime,
    required int cacheWidth,
    required bool avoidCloudDownload,
  }) async {
    try {
      final dir = await _cacheDir();
      final cache =
          File(p.join(dir.path, '${_key(path, mtime, cacheWidth)}.jpg'));
      final cached = _readNonEmpty(cache);
      if (cached != null) return cached;

      if (avoidCloudDownload) {
        final system = await _systemThumbnail(path, cacheWidth);
        if (system != null && system.isNotEmpty) {
          _writeQuiet(cache, system);
          return system;
        }
        if (_isCloudOffline(path)) return null;
      }

      // ограничиваем число одновременных декодов: каждый — это полный декод
      // файла в отдельном изоляте; десятки параллельно (особенно при быстрой
      // прокрутке) кладут слабый процессор. Очередь сглаживает нагрузку.
      await _acquireThumbSlot();
      Uint8List? generated;
      try {
        generated = await compute(_makeThumb, _ThumbReq(path, cacheWidth));
      } finally {
        _releaseThumbSlot();
      }
      if (generated != null && generated.isNotEmpty) {
        _writeQuiet(cache, generated);
      }
      return generated;
    } catch (_) {
      return null;
    }
  }

  // ─── ограничитель параллельной генерации миниатюр (семафор) ───
  static int _activeThumbs = 0;
  static final Queue<Completer<void>> _thumbWaiters = Queue();

  /// Сколько миниатюр генерировать одновременно: в режиме слабого устройства —
  /// одна, иначе половина ядер (но не больше 4), чтобы не забивать процессор.
  static int get _maxThumbJobs => SettingsService.instance.lowEndMode
      ? 1
      : (Platform.numberOfProcessors ~/ 2).clamp(2, 4);

  static Future<void> _acquireThumbSlot() async {
    while (_activeThumbs >= _maxThumbJobs) {
      final c = Completer<void>();
      _thumbWaiters.add(c);
      await c.future;
    }
    _activeThumbs++;
  }

  static void _releaseThumbSlot() {
    _activeThumbs--;
    if (_thumbWaiters.isNotEmpty) _thumbWaiters.removeFirst().complete();
  }

  static String _key(String path, int mtime, int cacheWidth) {
    final normalized = Platform.isWindows ? path.toLowerCase() : path;
    return md5
        .convert(utf8.encode('$normalized|$mtime|$cacheWidth'))
        .toString();
  }

  static Uint8List? _readNonEmpty(File f) {
    try {
      if (!f.existsSync()) return null;
      final b = f.readAsBytesSync();
      return b.isEmpty ? null : b;
    } catch (_) {
      return null;
    }
  }

  static void _writeQuiet(File f, Uint8List bytes) {
    try {
      f.writeAsBytesSync(bytes, flush: false);
    } catch (_) {}
  }

  static Future<Uint8List?> _systemThumbnail(
      String path, int cacheWidth) async {
    if (Platform.isWindows) return _windowsShellThumbnail(path, cacheWidth);
    if (Platform.isLinux) return _linuxFreedesktopThumbnail(path);
    return null;
  }

  static bool _isCloudOffline(String path) {
    if (!Platform.isWindows) return false;
    return _WindowsCloudAttributes.isOffline(path);
  }

  static Uint8List? _linuxFreedesktopThumbnail(String path) {
    try {
      final home = Platform.environment['HOME'];
      final cacheHome = Platform.environment['XDG_CACHE_HOME'] ??
          (home == null ? null : p.join(home, '.cache'));
      if (cacheHome == null || cacheHome.isEmpty) return null;
      final name = '${md5.convert(utf8.encode(Uri.file(path).toString()))}.png';
      for (final bucket in const ['xx-large', 'x-large', 'large', 'normal']) {
        final f = File(p.join(cacheHome, 'thumbnails', bucket, name));
        final b = _readNonEmpty(f);
        if (b != null) return b;
      }
    } catch (_) {}
    return null;
  }

  static Uint8List? _windowsShellThumbnail(String path, int cacheWidth) {
    _ensureWindowsCom();
    try {
      return using((arena) {
        final fileName = path.toNativeUtf16(allocator: arena);
        final iid = win.GUIDFromString(
          win.IID_IShellItemImageFactory,
          allocator: arena,
        );
        final item = arena<win.COMObject>();
        final hr = win.SHCreateItemFromParsingName(
          fileName,
          nullptr,
          iid,
          item.cast(),
        );
        if (win.FAILED(hr) || item.ref.isNull) return null;

        final factory = win.IShellItemImageFactory(item);
        try {
          final hBitmap = arena<IntPtr>();
          final size = arena<win.SIZE>();
          final side = cacheWidth.clamp(64, 1024);
          size.ref.cx = side;
          size.ref.cy = side;
          final imageHr = factory.getImage(
            size.ref,
            win.SIIGBF_INCACHEONLY | win.SIIGBF_THUMBNAILONLY,
            hBitmap,
          );
          if (win.FAILED(imageHr) || hBitmap.value == 0) return null;
          try {
            return _hBitmapToPng(hBitmap.value);
          } finally {
            win.DeleteObject(hBitmap.value);
          }
        } finally {
          factory.detach();
          factory.release();
        }
      });
    } catch (_) {
      return null;
    }
  }

  static void _ensureWindowsCom() {
    if (_windowsComInitialized) return;
    _windowsComInitialized = true;
    try {
      win.CoInitializeEx(nullptr, win.COINIT_APARTMENTTHREADED);
    } catch (_) {}
  }

  static Uint8List? _hBitmapToPng(int hBitmap) {
    final bitmap = calloc<win.BITMAP>();
    final info = calloc<win.BITMAPINFO>();
    Pointer<Uint8>? pixels;
    try {
      final got = win.GetObject(hBitmap, sizeOf<win.BITMAP>(), bitmap.cast());
      if (got == 0) return null;
      final width = bitmap.ref.bmWidth;
      final height = bitmap.ref.bmHeight.abs();
      if (width <= 0 || height <= 0) return null;

      info.ref.bmiHeader.biSize = sizeOf<win.BITMAPINFOHEADER>();
      info.ref.bmiHeader.biWidth = width;
      info.ref.bmiHeader.biHeight = -height; // top-down, без переворота строк
      info.ref.bmiHeader.biPlanes = 1;
      info.ref.bmiHeader.biBitCount = 32;
      info.ref.bmiHeader.biCompression = win.BI_RGB;

      final total = width * height * 4;
      pixels = calloc<Uint8>(total);
      final lines = win.GetDIBits(
        0,
        hBitmap,
        0,
        height,
        pixels.cast(),
        info,
        win.DIB_RGB_COLORS,
      );
      if (lines == 0) return null;

      final raw = pixels.asTypedList(total);
      final out = img.Image(width: width, height: height);
      for (var y = 0; y < height; y++) {
        for (var x = 0; x < width; x++) {
          final i = (y * width + x) * 4;
          final b = raw[i];
          final g = raw[i + 1];
          final r = raw[i + 2];
          final a = raw[i + 3] == 0 ? 255 : raw[i + 3];
          out.setPixelRgba(x, y, r, g, b, a);
        }
      }
      return Uint8List.fromList(img.encodePng(out));
    } catch (_) {
      return null;
    } finally {
      calloc.free(bitmap);
      calloc.free(info);
      if (pixels != null) calloc.free(pixels);
    }
  }
}

class _WindowsCloudAttributes {
  static const _invalid = 0xFFFFFFFF;
  static const _offline = 0x00001000;
  static const _recallOnOpen = 0x00040000;
  static const _recallOnDataAccess = 0x00400000;

  static bool isOffline(String path) {
    try {
      return using((arena) {
        final ptr = path.toNativeUtf16(allocator: arena);
        final attrs = win.GetFileAttributes(ptr);
        if (attrs == _invalid) return false;
        return (attrs & (_offline | _recallOnOpen | _recallOnDataAccess)) != 0;
      });
    } catch (_) {
      return false;
    }
  }
}

class _ThumbReq {
  final String path;
  final int cacheWidth;
  _ThumbReq(this.path, this.cacheWidth);
}

Uint8List? _makeThumb(_ThumbReq r) {
  try {
    final bytes = File(r.path).readAsBytesSync();
    final decoded = img.decodeImage(bytes);
    if (decoded == null) return null;
    final target = r.cacheWidth.clamp(64, 1024);
    final resized = decoded.width > target
        ? img.copyResize(decoded,
            width: target, interpolation: img.Interpolation.average)
        : decoded;
    return Uint8List.fromList(img.encodeJpg(resized, quality: 84));
  } catch (_) {
    return null;
  }
}

class _ExtractReq {
  final String path;
  final bool full;
  _ExtractReq(this.path, this.full);
}

/// Достать превью из файла (в изоляте).
Uint8List? _extract(_ExtractReq r) {
  final lower = r.path.toLowerCase();
  try {
    final data = File(r.path).readAsBytesSync();
    if (lower.endsWith('.kra')) return _fromKra(data, r.full);
    if (lower.endsWith('.psd')) return _fromPsd(data, r.full);
  } catch (_) {}
  return null;
}

/// KRA — это ZIP. Полноразмерное превью — mergedimage.png, миниатюра — preview.png.
Uint8List? _fromKra(Uint8List data, bool full) {
  try {
    final arch = ZipDecoder().decodeBytes(data);
    ArchiveFile? byName(String name) {
      for (final f in arch.files) {
        if (f.name == name || f.name.endsWith('/$name')) return f;
      }
      return null;
    }

    final merged = byName('mergedimage.png');
    final preview = byName('preview.png');
    final pick = full ? (merged ?? preview) : (preview ?? merged);
    return pick?.readBytes();
  } catch (_) {
    return null;
  }
}

/// PSD: для миниатюры — встроенный ресурс 1036 (JPEG). Для полноразмерного —
/// декодируем композит через image-пакет (медленнее, но один раз на просмотр).
Uint8List? _fromPsd(Uint8List b, bool full) {
  if (full) {
    try {
      final decoded = img.PsdDecoder().decode(b);
      if (decoded != null) {
        return Uint8List.fromList(img.encodePng(decoded));
      }
    } catch (_) {}
    // не вышло — отдадим встроенную миниатюру
  }
  return _psdThumbnail(b);
}

/// Извлечь встроенную JPEG-миниатюру PSD (image resource 1036/1033).
Uint8List? _psdThumbnail(Uint8List b) {
  // заголовок: '8BPS'(4) version(2) reserved(6) channels(2) height(4) width(4)
  //            depth(2) mode(2) = 26 байт
  if (b.length < 26 ||
      !(b[0] == 0x38 && b[1] == 0x42 && b[2] == 0x50 && b[3] == 0x53)) {
    return null;
  }
  var pos = 26;
  if (pos + 4 > b.length) return null;
  final cmLen = _be32(b, pos);
  pos += 4 + cmLen; // секция color mode data
  if (pos + 4 > b.length) return null;
  final irLen = _be32(b, pos);
  pos += 4;
  final irEnd = (pos + irLen).clamp(0, b.length);

  while (pos + 12 < irEnd) {
    if (!(b[pos] == 0x38 &&
        b[pos + 1] == 0x42 &&
        b[pos + 2] == 0x49 &&
        b[pos + 3] == 0x4D)) {
      break; // не '8BIM'
    }
    pos += 4;
    final id = (b[pos] << 8) | b[pos + 1];
    pos += 2;
    // имя ресурса (Pascal-строка), дополнено до чётного
    final nameLen = b[pos];
    var nameField = 1 + nameLen;
    if (nameField.isOdd) nameField++;
    pos += nameField;
    final size = _be32(b, pos);
    pos += 4;
    final dataStart = pos;
    if ((id == 1036 || id == 1033) && size > 28) {
      // thumbnail resource: 28 байт заголовка, дальше JPEG
      final jpegStart = dataStart + 28;
      final jpegEnd = (dataStart + size).clamp(0, b.length);
      if (jpegStart < jpegEnd) {
        return Uint8List.sublistView(b, jpegStart, jpegEnd);
      }
    }
    var adv = size;
    if (adv.isOdd) adv++; // данные дополнены до чётного
    pos = dataStart + adv;
  }
  return null;
}

int _be32(Uint8List b, int o) =>
    (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3];

// ───────────────────────── ImageProvider для проектов ─────────────────────────

@immutable
class ProjectImageKey {
  final String path;
  final int mtime;
  final bool full;
  final int cacheWidth;
  const ProjectImageKey(this.path, this.mtime, this.full, this.cacheWidth);

  @override
  bool operator ==(Object other) =>
      other is ProjectImageKey &&
      other.path == path &&
      other.mtime == mtime &&
      other.full == full &&
      other.cacheWidth == cacheWidth;

  @override
  int get hashCode => Object.hash(path, mtime, full, cacheWidth);
}

/// ImageProvider, который показывает превью KRA/PSD (через [PreviewService]).
class ProjectImage extends ImageProvider<ProjectImageKey> {
  final String path;
  final int mtime;
  final bool full;
  final int cacheWidth;
  const ProjectImage(this.path,
      {required this.mtime, this.full = false, this.cacheWidth = 0});

  @override
  Future<ProjectImageKey> obtainKey(ImageConfiguration configuration) async =>
      ProjectImageKey(path, mtime, full, cacheWidth);

  @override
  ImageStreamCompleter loadImage(
      ProjectImageKey key, ImageDecoderCallback decode) {
    return MultiFrameImageStreamCompleter(
      codec: _codec(key, decode),
      scale: 1.0,
      debugLabel: key.path,
    );
  }

  Future<ui.Codec> _codec(
      ProjectImageKey key, ImageDecoderCallback decode) async {
    final bytes = await PreviewService.bytesFor(key.path, key.mtime, key.full);
    if (bytes == null || bytes.isEmpty) {
      throw StateError('Нет превью для ${key.path}');
    }
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    if (!key.full && key.cacheWidth > 0) {
      return decode(buffer,
          getTargetSize: (w, h) => ui.TargetImageSize(width: key.cacheWidth));
    }
    return decode(buffer);
  }
}

@immutable
class CachedThumbImageKey {
  final String path;
  final int mtime;
  final int cacheWidth;
  final bool avoidCloudDownload;
  const CachedThumbImageKey(
    this.path,
    this.mtime,
    this.cacheWidth,
    this.avoidCloudDownload,
  );

  @override
  bool operator ==(Object other) =>
      other is CachedThumbImageKey &&
      other.path == path &&
      other.mtime == mtime &&
      other.cacheWidth == cacheWidth &&
      other.avoidCloudDownload == avoidCloudDownload;

  @override
  int get hashCode => Object.hash(path, mtime, cacheWidth, avoidCloudDownload);
}

/// ImageProvider для обычных фото в сетке: постоянный кэш GOAT + готовые
/// системные миниатюры, чтобы облачные placeholder-файлы не скачивались зря.
class CachedThumbImage extends ImageProvider<CachedThumbImageKey> {
  final String path;
  final int mtime;
  final int cacheWidth;
  final bool avoidCloudDownload;

  const CachedThumbImage(
    this.path, {
    required this.mtime,
    required this.cacheWidth,
    required this.avoidCloudDownload,
  });

  @override
  Future<CachedThumbImageKey> obtainKey(
          ImageConfiguration configuration) async =>
      CachedThumbImageKey(path, mtime, cacheWidth, avoidCloudDownload);

  @override
  ImageStreamCompleter loadImage(
    CachedThumbImageKey key,
    ImageDecoderCallback decode,
  ) {
    return MultiFrameImageStreamCompleter(
      codec: _codec(key, decode),
      scale: 1.0,
      debugLabel: key.path,
    );
  }

  Future<ui.Codec> _codec(
    CachedThumbImageKey key,
    ImageDecoderCallback decode,
  ) async {
    final bytes = await ThumbnailCacheService.bytesFor(
      path: key.path,
      mtime: key.mtime,
      cacheWidth: key.cacheWidth,
      avoidCloudDownload: key.avoidCloudDownload,
    );
    if (bytes == null || bytes.isEmpty) {
      throw StateError('Нет миниатюры для ${key.path}');
    }
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    return decode(buffer);
  }
}
