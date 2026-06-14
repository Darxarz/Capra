import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:archive/archive.dart';
import 'package:image/image.dart' as img;

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
  ImageStreamCompleter loadImage(ProjectImageKey key, ImageDecoderCallback decode) {
    return MultiFrameImageStreamCompleter(
      codec: _codec(key, decode),
      scale: 1.0,
      debugLabel: key.path,
    );
  }

  Future<ui.Codec> _codec(ProjectImageKey key, ImageDecoderCallback decode) async {
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
