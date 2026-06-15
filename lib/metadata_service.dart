import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'i18n.dart';

/// Метаданные изображения: размеры, EXIF (для фото) и параметры генерации
/// нейросетью (Stable Diffusion / A1111 / ComfyUI / NovelAI).
///
/// Парсинг ручной по контейнеру (PNG-чанки, JPEG-маркеры) — без декодирования
/// пикселей, поэтому быстро даже на больших файлах.
class PhotoMeta {
  final int? width;
  final int? height;

  /// Инструмент генерации, если распознан ('Stable Diffusion', 'ComfyUI',
  /// 'NovelAI'); null — обычное фото/картинка.
  final String? aiTool;
  final String? prompt; // позитивный промпт
  final String? negative; // негативный промпт

  /// Ключевые параметры генерации (Steps, Sampler, CFG, Seed, Model…) по порядку.
  final List<MapEntry<String, String>> aiParams;

  /// Поля EXIF (камера, дата, выдержка…) по порядку.
  final List<MapEntry<String, String>> exif;

  const PhotoMeta({
    this.width,
    this.height,
    this.aiTool,
    this.prompt,
    this.negative,
    this.aiParams = const [],
    this.exif = const [],
  });

  bool get isAi => aiTool != null;
  bool get hasAnything =>
      isAi || exif.isNotEmpty || (width != null && height != null);

  static PhotoMeta fromMap(Map<String, dynamic> m) => PhotoMeta(
        width: m['width'] as int?,
        height: m['height'] as int?,
        aiTool: m['aiTool'] as String?,
        prompt: m['prompt'] as String?,
        negative: m['negative'] as String?,
        aiParams: [
          for (final e in (m['aiParams'] as List? ?? const []))
            MapEntry(e[0] as String, e[1] as String)
        ],
        exif: [
          for (final e in (m['exif'] as List? ?? const []))
            MapEntry(e[0] as String, e[1] as String)
        ],
      );
}

/// Прочитать и разобрать метаданные файла (в фоновом изоляте).
Future<PhotoMeta?> readMetadata(String path) async {
  try {
    // достаточно начала файла: PNG-параметры и EXIF лежат до данных пикселей.
    // читаем до 4 МБ — хватит даже для больших ComfyUI-воркфлоу.
    final f = File(path);
    final len = await f.length();
    final take = len < 4 * 1024 * 1024 ? len : 4 * 1024 * 1024;
    final raf = await f.open();
    Uint8List bytes;
    try {
      bytes = await raf.read(take);
    } finally {
      await raf.close();
    }
    final map = await compute(_parseMeta, bytes);
    if (map == null) return null;
    return PhotoMeta.fromMap(map);
  } catch (_) {
    return null;
  }
}

// ─────────────────────────── разбор (в изоляте) ───────────────────────────

Map<String, dynamic>? _parseMeta(Uint8List b) {
  if (b.length < 12) return null;
  // PNG?
  if (b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47) {
    return _parsePng(b);
  }
  // JPEG?
  if (b[0] == 0xFF && b[1] == 0xD8) {
    return _parseJpeg(b);
  }
  return null;
}

// ─── PNG ───
Map<String, dynamic>? _parsePng(Uint8List b) {
  int off = 8;
  int? w, h;
  final text = <String, String>{};
  final bd = ByteData.sublistView(b);
  while (off + 8 <= b.length) {
    final len = bd.getUint32(off);
    final type = String.fromCharCodes(b, off + 4, off + 8);
    final dataStart = off + 8;
    if (dataStart + len > b.length) break;
    if (type == 'IHDR') {
      w = bd.getUint32(dataStart);
      h = bd.getUint32(dataStart + 4);
    } else if (type == 'tEXt') {
      final z = _indexOf(b, 0, dataStart, dataStart + len);
      if (z > 0) {
        final key = latin1.decode(b.sublist(dataStart, z));
        final val = _safeLatin1(b.sublist(z + 1, dataStart + len));
        text[key] = val;
      }
    } else if (type == 'iTXt') {
      final parsed = _parseITxt(b, dataStart, dataStart + len);
      if (parsed != null) text[parsed.key] = parsed.value;
    } else if (type == 'zTXt') {
      final z = _indexOf(b, 0, dataStart, dataStart + len);
      if (z > 0 && z + 2 <= dataStart + len) {
        final key = latin1.decode(b.sublist(dataStart, z));
        try {
          final raw = b.sublist(z + 2, dataStart + len); // пропускаем method
          text[key] = utf8.decode(zlib.decode(raw), allowMalformed: true);
        } catch (_) {}
      }
    } else if (type == 'IDAT' || type == 'IEND') {
      break;
    }
    off = dataStart + len + 4; // + crc
  }
  final out = _interpretText(text);
  out['width'] = w;
  out['height'] = h;
  return out;
}

({String key, String value})? _parseITxt(Uint8List b, int start, int end) {
  final z = _indexOf(b, 0, start, end);
  if (z < 0 || z + 3 > end) return null;
  final key = latin1.decode(b.sublist(start, z));
  final compFlag = b[z + 1];
  // z+2 = compression method; далее langTag\0 transKeyword\0 text
  var p = z + 3;
  final langEnd = _indexOf(b, 0, p, end);
  if (langEnd < 0) return null;
  p = langEnd + 1;
  final transEnd = _indexOf(b, 0, p, end);
  if (transEnd < 0) return null;
  p = transEnd + 1;
  final raw = b.sublist(p, end);
  String value;
  try {
    value = compFlag == 1
        ? utf8.decode(zlib.decode(raw), allowMalformed: true)
        : utf8.decode(raw, allowMalformed: true);
  } catch (_) {
    value = _safeLatin1(raw);
  }
  return (key: key, value: value);
}

// ─── JPEG ───
Map<String, dynamic>? _parseJpeg(Uint8List b) {
  int off = 2;
  int? w, h;
  final exif = <MapEntry<String, String>>[];
  String? userComment;
  final bd = ByteData.sublistView(b);
  while (off + 4 <= b.length) {
    if (b[off] != 0xFF) {
      off++;
      continue;
    }
    final marker = b[off + 1];
    if (marker == 0xD8 || marker == 0xD9) {
      off += 2;
      continue;
    }
    if (marker == 0xDA) break; // начало данных
    final segLen = bd.getUint16(off + 2);
    final dataStart = off + 4;
    final dataEnd = dataStart + segLen - 2;
    if (dataEnd > b.length) break;
    // SOF маркеры (размер кадра)
    final isSof = (marker >= 0xC0 && marker <= 0xCF) &&
        marker != 0xC4 &&
        marker != 0xC8 &&
        marker != 0xCC;
    if (isSof && dataStart + 5 <= b.length) {
      h = bd.getUint16(dataStart + 1);
      w = bd.getUint16(dataStart + 3);
    } else if (marker == 0xE1) {
      // APP1: EXIF или XMP
      if (dataEnd - dataStart >= 6 &&
          b[dataStart] == 0x45 && // E
          b[dataStart + 1] == 0x78 && // x
          b[dataStart + 2] == 0x69 && // i
          b[dataStart + 3] == 0x66) {
        // f
        final block = Uint8List.sublistView(b, dataStart + 6, dataEnd);
        final r = _readExif(block);
        exif.addAll(r.fields);
        userComment ??= r.userComment;
      }
    }
    off = dataEnd;
  }
  Map<String, dynamic> out;
  // A1111 пишет параметры в UserComment
  if (userComment != null &&
      (userComment.contains('Negative prompt:') ||
          userComment.contains('Steps:'))) {
    out = _parseA1111(userComment);
  } else {
    out = {'aiTool': null};
  }
  out['width'] = w;
  out['height'] = h;
  // EXIF добавляем только если это не AI-картинка (или вдобавок к ней)
  if (out['exif'] == null) {
    out['exif'] = [
      for (final e in exif) [e.key, e.value]
    ];
  }
  return out;
}

({List<MapEntry<String, String>> fields, String? userComment}) _readExif(
    Uint8List block) {
  final fields = <MapEntry<String, String>>[];
  String? userComment;
  try {
    final exif = img.ExifData.fromInputBuffer(img.InputBuffer(block));
    // удобочитаемые поля по именам
    final wanted = <String, String>{
      'Make': tr('Камера', 'Camera', 'Cámara'),
      'Model': tr('Модель', 'Model', 'Modelo'),
      'LensModel': tr('Объектив', 'Lens', 'Objetivo'),
      'DateTimeOriginal': tr('Снято', 'Taken', 'Tomada'),
      'ExposureTime': tr('Выдержка', 'Exposure', 'Exposición'),
      'FNumber': tr('Диафрагма', 'Aperture', 'Apertura'),
      'ISO': 'ISO',
      'FocalLength': tr('Фокус', 'Focal length', 'Distancia focal'),
      'Software': tr('Софт', 'Software', 'Software'),
    };
    wanted.forEach((name, label) {
      final id = img.exifTagNameToID[name];
      if (id == null) return;
      final v = exif.getTag(id);
      if (v != null) {
        final s = v.toString().trim();
        if (s.isNotEmpty) fields.add(MapEntry(label, s));
      }
    });
    // UserComment (0x9286) — туда A1111 кладёт параметры
    final uc = exif.getTag(0x9286);
    if (uc != null) {
      var s = uc.toString();
      // префиксы кодировки EXIF: "UNICODE\0", "ASCII\0\0\0"
      s = s.replaceFirst(RegExp(r'^(UNICODE|ASCII|JIS)\x00*'), '');
      s = s.replaceAll('\x00', '').trim();
      if (s.isNotEmpty) userComment = s;
    }
  } catch (_) {}
  return (fields: fields, userComment: userComment);
}

// ─────────────────────────── интерпретация текста ───────────────────────────

Map<String, dynamic> _interpretText(Map<String, String> text) {
  // Stable Diffusion / Automatic1111
  if (text.containsKey('parameters')) {
    return _parseA1111(text['parameters']!);
  }
  // NovelAI
  final software = text['Software'] ?? '';
  if (software.contains('NovelAI') || text.containsKey('Comment')) {
    final r = _parseNovelAI(text);
    if (r != null) return r;
  }
  // ComfyUI
  if (text.containsKey('prompt') || text.containsKey('workflow')) {
    final r = _parseComfy(text);
    if (r != null) return r;
  }
  // прочие текстовые поля — показать как есть
  if (text.isNotEmpty) {
    return {
      'aiTool': null,
      'exif': [
        for (final e in text.entries) [e.key, _short(e.value)]
      ],
    };
  }
  return {'aiTool': null};
}

Map<String, dynamic> _parseA1111(String s) {
  String? prompt, negative;
  final lines = s.split('\n');
  // строка настроек — последняя, где есть "Steps:" или похожее key: value
  int settingsIdx = -1;
  for (var i = lines.length - 1; i >= 0; i--) {
    if (lines[i].contains('Steps:') ||
        RegExp(r'^[A-Za-z][\w ]*:\s').hasMatch(lines[i]) &&
            lines[i].contains(',')) {
      settingsIdx = i;
      break;
    }
  }
  final negMarker = s.indexOf('Negative prompt:');
  final paramsList = <List<String>>[];
  if (settingsIdx >= 0) {
    final head = lines.sublist(0, settingsIdx).join('\n');
    final ni = head.indexOf('Negative prompt:');
    if (ni >= 0) {
      prompt = head.substring(0, ni).trim();
      negative = head.substring(ni + 'Negative prompt:'.length).trim();
    } else {
      prompt = head.trim();
    }
    // разбор "Key: value, Key2: value2" — режем перед "Слово: "
    final settings = lines[settingsIdx];
    final parts = settings.split(RegExp(r',\s*(?=[A-Za-z][\w /]*:\s)'));
    for (final part in parts) {
      final ci = part.indexOf(':');
      if (ci > 0) {
        final k = part.substring(0, ci).trim();
        final v = part.substring(ci + 1).trim();
        if (k.isNotEmpty && v.isNotEmpty) paramsList.add([k, v]);
      }
    }
  } else if (negMarker >= 0) {
    prompt = s.substring(0, negMarker).trim();
    negative = s.substring(negMarker + 'Negative prompt:'.length).trim();
  } else {
    prompt = s.trim();
  }
  return {
    'aiTool': 'Stable Diffusion',
    'prompt': prompt,
    'negative': negative,
    'aiParams': paramsList,
  };
}

Map<String, dynamic>? _parseNovelAI(Map<String, String> text) {
  try {
    final comment = text['Comment'];
    final params = <List<String>>[];
    String? prompt = text['Description'];
    String? negative;
    if (comment != null) {
      final j = jsonDecode(comment);
      if (j is Map) {
        prompt ??= j['prompt']?.toString();
        negative = j['uc']?.toString();
        void add(String key, String label) {
          if (j[key] != null) params.add([label, j[key].toString()]);
        }

        add('steps', 'Steps');
        add('sampler', 'Sampler');
        add('scale', 'CFG');
        add('seed', 'Seed');
        add('noise_schedule', 'Noise');
      }
    }
    return {
      'aiTool': 'NovelAI',
      'prompt': prompt,
      'negative': negative,
      'aiParams': params,
    };
  } catch (_) {
    return null;
  }
}

Map<String, dynamic>? _parseComfy(Map<String, String> text) {
  try {
    final promptJson = text['prompt'];
    final params = <List<String>>[];
    final texts = <String>[];
    if (promptJson != null) {
      final graph = jsonDecode(promptJson);
      if (graph is Map) {
        for (final node in graph.values) {
          if (node is! Map) continue;
          final cls = node['class_type']?.toString() ?? '';
          final inputs = node['inputs'];
          if (inputs is! Map) continue;
          if (cls.contains('CLIPTextEncode')) {
            final t = inputs['text'];
            if (t is String && t.trim().isNotEmpty) texts.add(t.trim());
          } else if (cls.contains('KSampler')) {
            void add(String key, String label) {
              if (inputs[key] != null) {
                params.add([label, inputs[key].toString()]);
              }
            }

            add('steps', 'Steps');
            add('cfg', 'CFG');
            add('sampler_name', 'Sampler');
            add('scheduler', 'Scheduler');
            add('seed', 'Seed');
          }
        }
      }
    }
    return {
      'aiTool': 'ComfyUI',
      'prompt': texts.isNotEmpty ? texts.first : null,
      'negative': texts.length > 1 ? texts[1] : null,
      'aiParams': params,
    };
  } catch (_) {
    return null;
  }
}

// ─────────────────────────── мелочи ───────────────────────────

int _indexOf(Uint8List b, int byte, int start, int end) {
  for (var i = start; i < end && i < b.length; i++) {
    if (b[i] == byte) return i;
  }
  return -1;
}

String _safeLatin1(List<int> bytes) {
  try {
    return utf8.decode(bytes, allowMalformed: true);
  } catch (_) {
    return latin1.decode(bytes, allowInvalid: true);
  }
}

String _short(String s) => s.length > 300 ? '${s.substring(0, 300)}…' : s;
