import 'dart:io';
import 'package:flutter/foundation.dart';
import 'model.dart';
import 'tag_service.dart';

/// Кэш размеров изображений (ширина×высота) для мозаичной сетки. Размеры
/// нужны, чтобы подобрать форму плитки под пропорции фото. Читаются ТОЛЬКО
/// заголовки файлов (несколько КБ) — это быстро даже на 100к. Результат
/// хранится в БД (file_sig) навсегда, так что повторный запуск — мгновенный.
class DimsService extends ChangeNotifier {
  DimsService._();
  static final DimsService instance = DimsService._();

  final Map<String, double> _ratio = {}; // path → width/height
  bool _loaded = false;
  bool _filling = false;
  int _rev = 0;

  /// Счётчик изменений (растёт при пополнении размеров) — для пересчёта мозаики.
  int get rev => _rev;

  /// Пропорция (ширина/высота) или null, если ещё неизвестна.
  double? ratioOf(String path) => _ratio[path];

  /// Подтянуть из БД уже известные размеры (один раз за сессию).
  void _loadFromDb() {
    if (_loaded) return;
    _loaded = true;
    try {
      final dims = TagService.instance.loadAllDims();
      dims.forEach((path, wh) {
        final w = wh[0], h = wh[1];
        if (w > 0 && h > 0) _ratio[path] = w / h;
      });
    } catch (_) {}
  }

  /// Дозаполнить размеры для фото, у которых их ещё нет. Идёт батчами в
  /// изоляте, чтобы UI не подмерзал; после каждого батча — notifyListeners,
  /// чтобы мозаика постепенно «устаканивалась».
  Future<void> ensureFilled(List<PhotoItem> photos) async {
    _loadFromDb();
    if (_filling) return;

    // что ещё не знаем (и это локальные файлы — у удалённых размеров нет)
    final todo = <String>[];
    for (final ph in photos) {
      if (ph.isRemote) continue;
      if (!_ratio.containsKey(ph.path)) todo.add(ph.path);
    }
    if (todo.isEmpty) {
      _rev++;
      notifyListeners();
      return;
    }

    _filling = true;
    try {
      const batch = 400;
      for (var i = 0; i < todo.length; i += batch) {
        final slice = todo.sublist(i, (i + batch).clamp(0, todo.length));
        final results = await compute(_readDimsBatch, slice);
        for (final r in results) {
          final path = r[0] as String;
          final w = r[1] as int;
          final h = r[2] as int;
          final size = r[3] as int;
          final mtime = r[4] as int;
          if (w > 0 && h > 0) {
            _ratio[path] = w / h;
            try {
              TagService.instance.storeDimsOnly(path, size, mtime, w, h);
            } catch (_) {}
          } else {
            // не смогли прочитать — помечаем как 1:1, чтобы не долбить снова
            _ratio[path] = 1.0;
          }
        }
        _rev++;
        notifyListeners();
      }
    } finally {
      _filling = false;
    }
  }
}

/// Прочитать размеры пачки файлов (в изоляте). Возвращает строки
/// [path, width, height, size, mtimeMs].
List<List<dynamic>> _readDimsBatch(List<String> paths) {
  final out = <List<dynamic>>[];
  for (final path in paths) {
    var w = 0, h = 0, size = 0, mtime = 0;
    try {
      final f = File(path);
      final st = f.statSync();
      size = st.size;
      mtime = st.modified.millisecondsSinceEpoch;
      // читаем только заголовок — для размеров больше не нужно
      final raf = f.openSync();
      try {
        final len = st.size < 65536 ? st.size : 65536;
        final head = raf.readSync(len);
        final dims = _dimsFromHeader(head);
        if (dims != null) {
          w = dims[0];
          h = dims[1];
        }
      } finally {
        raf.closeSync();
      }
    } catch (_) {}
    out.add([path, w, h, size, mtime]);
  }
  return out;
}

/// Достать ширину/высоту из заголовка по сигнатуре формата.
List<int>? _dimsFromHeader(Uint8List b) {
  if (b.length < 24) return null;

  // PNG: 89 50 4E 47 ... IHDR (ширина/высота — big-endian с offset 16)
  if (b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47) {
    final w = _be32(b, 16);
    final h = _be32(b, 20);
    if (w > 0 && h > 0) return [w, h];
    return null;
  }

  // GIF: 'GIF8' — ширина/высота little-endian с offset 6
  if (b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x38) {
    final w = b[6] | (b[7] << 8);
    final h = b[8] | (b[9] << 8);
    if (w > 0 && h > 0) return [w, h];
    return null;
  }

  // BMP: 'BM' — int32 LE ширина(offset 18)/высота(offset 22)
  if (b[0] == 0x42 && b[1] == 0x4D) {
    final w = _le32(b, 18);
    final h = _le32(b, 22).abs();
    if (w > 0 && h > 0) return [w, h];
    return null;
  }

  // WEBP: 'RIFF'....'WEBP'
  if (b[0] == 0x52 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x46 &&
      b[8] == 0x57 && b[9] == 0x45 && b[10] == 0x42 && b[11] == 0x50) {
    return _webpDims(b);
  }

  // JPEG: FF D8 ... ищем SOF-маркер
  if (b[0] == 0xFF && b[1] == 0xD8) {
    return _jpegDims(b);
  }

  return null;
}

/// JPEG: пройти по маркерам до SOF0..SOF15 (кроме DHT/JPG/DAC) и взять размеры.
List<int>? _jpegDims(Uint8List b) {
  var i = 2;
  while (i + 9 < b.length) {
    if (b[i] != 0xFF) {
      i++;
      continue;
    }
    final marker = b[i + 1];
    // SOF0..SOF15: C0..CF, кроме C4(DHT), C8(JPG), CC(DAC)
    if (marker >= 0xC0 &&
        marker <= 0xCF &&
        marker != 0xC4 &&
        marker != 0xC8 &&
        marker != 0xCC) {
      final h = (b[i + 5] << 8) | b[i + 6];
      final w = (b[i + 7] << 8) | b[i + 8];
      if (w > 0 && h > 0) return [w, h];
      return null;
    }
    // иначе пропускаем сегмент по его длине
    if (i + 3 >= b.length) break;
    final segLen = (b[i + 2] << 8) | b[i + 3];
    if (segLen < 2) break;
    i += 2 + segLen;
  }
  return null;
}

/// WEBP: три подформата — VP8 (lossy), VP8L (lossless), VP8X (extended).
List<int>? _webpDims(Uint8List b) {
  if (b.length < 30) return null;
  final fmt = String.fromCharCodes(b.sublist(12, 16));
  if (fmt == 'VP8 ') {
    // ключевой кадр: после 0x9D 0x01 0x2A — 14-битные ширина/высота
    for (var i = 16; i + 9 < b.length && i < 64; i++) {
      if (b[i] == 0x9D && b[i + 1] == 0x01 && b[i + 2] == 0x2A) {
        final w = ((b[i + 4] << 8) | b[i + 3]) & 0x3FFF;
        final h = ((b[i + 6] << 8) | b[i + 5]) & 0x3FFF;
        if (w > 0 && h > 0) return [w, h];
        return null;
      }
    }
    return null;
  }
  if (fmt == 'VP8L') {
    // сигнатура 0x2F, затем 14-битные (w-1) и (h-1)
    if (b.length < 25 || b[20] != 0x2F) return null;
    final bits = b[21] | (b[22] << 8) | (b[23] << 16) | (b[24] << 24);
    final w = (bits & 0x3FFF) + 1;
    final h = ((bits >> 14) & 0x3FFF) + 1;
    if (w > 0 && h > 0) return [w, h];
    return null;
  }
  if (fmt == 'VP8X') {
    // расширенный: canvas size — 24-битные (w-1)/(h-1) little-endian с offset 24
    final w = (b[24] | (b[25] << 8) | (b[26] << 16)) + 1;
    final h = (b[27] | (b[28] << 8) | (b[29] << 16)) + 1;
    if (w > 0 && h > 0) return [w, h];
    return null;
  }
  return null;
}

int _be32(Uint8List b, int o) =>
    (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3];

int _le32(Uint8List b, int o) =>
    b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24);
