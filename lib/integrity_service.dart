import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'model.dart';
import 'tag_service.dart';
import 'i18n.dart';

/// Состояние файла по целостности.
/// 0 — целый, 1 — обрезан (нет хвоста контейнера, но открывается),
/// 2 — битый (не декодируется).
const int kOk = 0;
const int kTruncated = 1;
const int kBroken = 2;

/// Один файл в результатах поиска дубликатов.
class DupFile {
  final String path;
  final String folderPath;
  final String fileName;
  final int size;
  final int width;
  final int height;
  final int status;
  const DupFile({
    required this.path,
    required this.folderPath,
    required this.fileName,
    required this.size,
    this.width = 0,
    this.height = 0,
    this.status = kOk,
  });

  int get pixels => width * height;
  bool get ok => status == kOk;
}

/// Группа дубликатов (точные — идентичные байты; похожие — близкий вид).
class DupGroup {
  final bool exact;
  final List<DupFile> files;
  const DupGroup({required this.exact, required this.files});

  /// Рекомендуемый «лучший» файл: целый, максимальное разрешение, затем
  /// больший размер файла, затем более короткий путь.
  DupFile get best {
    final sorted = [...files]..sort((a, b) {
        if (a.ok != b.ok) return a.ok ? -1 : 1;
        if (a.pixels != b.pixels) return b.pixels.compareTo(a.pixels);
        if (a.size != b.size) return b.size.compareTo(a.size);
        return a.path.length.compareTo(b.path.length);
      });
    return sorted.first;
  }

  /// Сколько места освободится, если оставить только «лучший».
  int get reclaimable => files.fold(0, (s, f) => s + f.size) - best.size;
}

class DupResult {
  final List<DupGroup> groups;
  final List<DupFile> corrupt; // повреждённые/обрезанные (по всей библиотеке)
  const DupResult({required this.groups, required this.corrupt});

  int get totalDuplicates => groups.fold(0, (s, g) => s + g.files.length - 1);
  int get reclaimableBytes => groups.fold(0, (s, g) => s + g.reclaimable);
}

/// Фоновый поиск дубликатов и проверка целостности. Останавливаемый,
/// прогресс через [ChangeNotifier]; тяжёлая работа — в изолятах (UI не виснет).
class DupScanner extends ChangeNotifier {
  DupScanner._();
  static final DupScanner instance = DupScanner._();

  bool running = false;
  bool _stop = false;
  String phase = '';
  int done = 0;
  int total = 0;
  String? error;
  DupResult? result;

  /// path → id в MediaStore (Android) — для удаления через систему.
  final Map<String, String?> idByPath = {};
  String? assetIdFor(String path) => idByPath[path];

  static const _chunk = 48; // файлов на изолят-вызов
  static const _hammingThreshold = 6; // близость перцептивных хешей

  double get progress => total == 0 ? 0 : done / total;
  void stop() => _stop = true;

  Future<void> scan(List<PhotoItem> photos, {required bool similar}) async {
    if (running) return;
    running = true;
    _stop = false;
    error = null;
    result = null;
    done = 0;
    total = photos.length;
    idByPath.clear();
    for (final p in photos) {
      idByPath[p.path] = p.assetId;
    }
    notifyListeners();

    try {
      if (similar) {
        await _scanSimilar(photos);
      } else {
        await _scanExact(photos);
      }
    } catch (e) {
      error = '$e';
    }
    running = false;
    notifyListeners();
  }

  // ── Точные дубли: дешёвая проверка хвоста + хеш только для коллизий размера ──
  Future<void> _scanExact(List<PhotoItem> photos) async {
    phase = tr('Проверка целостности…', 'Checking integrity…',
        'Comprobando integridad…');
    notifyListeners();

    final corrupt = <DupFile>[];
    // 1) дешёвый проб (голова+хвост) — целостность для всех
    final statusByPath = <String, int>{};
    for (var i = 0; i < photos.length && !_stop; i += _chunk) {
      final slice = photos.sublist(i, (i + _chunk).clamp(0, photos.length));
      final res = await compute(_probeChunk, [for (final p in slice) p.path]);
      for (final r in res) {
        statusByPath[r[0] as String] = r[1] as int;
      }
      done = (i + slice.length);
      notifyListeners();
    }
    if (_stop) return;

    // 2) группировка кандидатов по размеру
    final bySize = <int, List<PhotoItem>>{};
    for (final p in photos) {
      bySize.putIfAbsent(p.sizeBytes, () => []).add(p);
    }
    final candidates = [
      for (final e in bySize.entries)
        if (e.value.length > 1) ...e.value
    ];

    phase =
        tr('Поиск одинаковых…', 'Finding exact matches…', 'Buscando iguales…');
    done = 0;
    total = candidates.length;
    notifyListeners();

    // 3) хеш кандидатов (с кэшем)
    final shaByPath = <String, String>{};
    final toHash = <PhotoItem>[];
    for (final p in candidates) {
      final mtime = p.modified.millisecondsSinceEpoch;
      final cached = TagService.instance.sigFor(p.path, p.sizeBytes, mtime);
      if (cached?.sha != null) {
        shaByPath[p.path] = cached!.sha!;
      } else {
        toHash.add(p);
      }
    }
    done = candidates.length - toHash.length;
    notifyListeners();
    for (var i = 0; i < toHash.length && !_stop; i += _chunk) {
      final slice = toHash.sublist(i, (i + _chunk).clamp(0, toHash.length));
      final res = await compute(_shaChunk, [for (final p in slice) p.path]);
      for (final r in res) {
        final path = r[0] as String;
        final sha = r[1] as String?;
        if (sha != null) {
          shaByPath[path] = sha;
          final ph = _photoByPath(slice, path);
          if (ph != null) {
            TagService.instance.storeSig(
                path, ph.sizeBytes, ph.modified.millisecondsSinceEpoch,
                sha: sha, status: statusByPath[path] ?? kOk);
          }
        }
      }
      done += slice.length;
      notifyListeners();
    }
    if (_stop) return;

    // 4) сборка групп по хешу
    final bySha = <String, List<PhotoItem>>{};
    for (final p in candidates) {
      final sha = shaByPath[p.path];
      if (sha != null) bySha.putIfAbsent(sha, () => []).add(p);
    }
    final groups = <DupGroup>[];
    for (final list in bySha.values) {
      if (list.length < 2) continue;
      groups.add(DupGroup(
        exact: true,
        files: [
          for (final p in list) _toDupFile(p, statusByPath[p.path] ?? kOk)
        ],
      ));
    }

    // повреждённые по всей библиотеке
    for (final p in photos) {
      final st = statusByPath[p.path] ?? kOk;
      if (st != kOk) corrupt.add(_toDupFile(p, st));
    }
    _finish(groups, corrupt);
  }

  // ── Похожие: декод+перцептивный хеш для всех, кластеризация ──
  Future<void> _scanSimilar(List<PhotoItem> photos) async {
    phase =
        tr('Анализ изображений…', 'Analyzing images…', 'Analizando imágenes…');
    notifyListeners();

    final sha = <String, String>{};
    final phash = <String, int>{};
    final dims = <String, ({int w, int h})>{};
    final status = <String, int>{};

    final toScan = <PhotoItem>[];
    for (final p in photos) {
      final mtime = p.modified.millisecondsSinceEpoch;
      final c = TagService.instance.sigFor(p.path, p.sizeBytes, mtime);
      if (c != null && c.phash != null) {
        if (c.sha != null) sha[p.path] = c.sha!;
        phash[p.path] = c.phash!;
        dims[p.path] = (w: c.width, h: c.height);
        status[p.path] = c.status;
      } else {
        toScan.add(p);
      }
    }
    done = photos.length - toScan.length;
    notifyListeners();

    for (var i = 0; i < toScan.length && !_stop; i += _chunk) {
      final slice = toScan.sublist(i, (i + _chunk).clamp(0, toScan.length));
      final res = await compute(_deepChunk, [for (final p in slice) p.path]);
      for (final r in res) {
        final path = r[0] as String;
        final s = r[1] as String?;
        final ph = r[2] as int?;
        final w = r[3] as int;
        final h = r[4] as int;
        final st = r[5] as int;
        if (s != null) sha[path] = s;
        if (ph != null) phash[path] = ph;
        dims[path] = (w: w, h: h);
        status[path] = st;
        final src = _photoByPath(slice, path);
        if (src != null) {
          TagService.instance.storeSig(
              path, src.sizeBytes, src.modified.millisecondsSinceEpoch,
              sha: s, phash: ph, width: w, height: h, status: st);
        }
      }
      done += slice.length;
      notifyListeners();
    }
    if (_stop) return;

    phase = tr('Группировка похожих…', 'Grouping similar images…',
        'Agrupando imágenes similares…');
    notifyListeners();

    // кластеризация по перцептивному хешу (union-find через бэндинг)
    final paths = phash.keys.toList();
    final idx = {for (var i = 0; i < paths.length; i++) paths[i]: i};
    final uf = _UnionFind(paths.length);

    // точное равенство phash → один кластер
    final byPhash = <int, List<int>>{};
    for (final path in paths) {
      byPhash.putIfAbsent(phash[path]!, () => []).add(idx[path]!);
    }
    for (final list in byPhash.values) {
      for (var i = 1; i < list.length; i++) {
        uf.union(list[0], list[i]);
      }
    }
    // близкие (Hamming ≤ порог) среди различных хешей — бэндинг по 8×8 бит
    final distinct = byPhash.keys.toList();
    if (distinct.length < 20000) {
      final bands = <int, List<int>>{}; // ключ band → индексы в distinct
      for (var di = 0; di < distinct.length; di++) {
        final h = distinct[di];
        for (var b = 0; b < 8; b++) {
          final byte = (h >> (b * 8)) & 0xFF;
          bands.putIfAbsent((b << 8) | byte, () => []).add(di);
        }
      }
      final checked = <int>{};
      for (final bucket in bands.values) {
        if (bucket.length < 2 || bucket.length > 400) continue;
        for (var a = 0; a < bucket.length; a++) {
          for (var b = a + 1; b < bucket.length; b++) {
            final ha = distinct[bucket[a]];
            final hb = distinct[bucket[b]];
            final key = bucket[a] < bucket[b]
                ? bucket[a] * distinct.length + bucket[b]
                : bucket[b] * distinct.length + bucket[a];
            if (!checked.add(key)) continue;
            if (_hamming(ha, hb) <= _hammingThreshold) {
              uf.union(byPhash[ha]!.first, byPhash[hb]!.first);
            }
          }
        }
      }
    }

    // сбор кластеров
    final clusters = <int, List<String>>{};
    for (final path in paths) {
      clusters.putIfAbsent(uf.find(idx[path]!), () => []).add(path);
    }
    final groups = <DupGroup>[];
    for (final list in clusters.values) {
      if (list.length < 2) continue;
      final files = [
        for (final path in list)
          DupFile(
            path: path,
            folderPath: _folderOf(path),
            fileName: _nameOf(path),
            size: _sizeByPath(photos, path),
            width: dims[path]?.w ?? 0,
            height: dims[path]?.h ?? 0,
            status: status[path] ?? kOk,
          )
      ];
      // точная или похожая? все одинаковые sha → точная
      final shas = files.map((f) => sha[f.path]).toSet();
      final exact = shas.length == 1 && shas.first != null;
      groups.add(DupGroup(exact: exact, files: files));
    }

    final corrupt = <DupFile>[];
    for (final p in photos) {
      final st = status[p.path] ?? kOk;
      if (st != kOk) corrupt.add(_toDupFile(p, st));
    }
    _finish(groups, corrupt);
  }

  void _finish(List<DupGroup> groups, List<DupFile> corrupt) {
    // крупные группы и больше освобождаемого места — выше
    groups.sort((a, b) => b.reclaimable.compareTo(a.reclaimable));
    result = DupResult(groups: groups, corrupt: corrupt);
    phase = tr('Готово', 'Done', 'Listo');
    notifyListeners();
  }

  // helpers
  PhotoItem? _photoByPath(List<PhotoItem> list, String path) {
    for (final p in list) {
      if (p.path == path) return p;
    }
    return null;
  }

  int _sizeByPath(List<PhotoItem> list, String path) {
    for (final p in list) {
      if (p.path == path) return p.sizeBytes;
    }
    return 0;
  }

  DupFile _toDupFile(PhotoItem p, int status,
          {int width = 0, int height = 0}) =>
      DupFile(
        path: p.path,
        folderPath: p.folderPath,
        fileName: p.fileName,
        size: p.sizeBytes,
        width: width,
        height: height,
        status: status,
      );

  String _folderOf(String path) {
    final i = path.lastIndexOf(Platform.pathSeparator);
    return i >= 0 ? path.substring(0, i) : path;
  }

  String _nameOf(String path) {
    final i = path.lastIndexOf(Platform.pathSeparator);
    return i >= 0 ? path.substring(i + 1) : path;
  }
}

// ─────────────────────── union-find ───────────────────────
class _UnionFind {
  final List<int> _p;
  _UnionFind(int n) : _p = List<int>.generate(n, (i) => i);
  int find(int x) {
    while (_p[x] != x) {
      _p[x] = _p[_p[x]];
      x = _p[x];
    }
    return x;
  }

  void union(int a, int b) {
    final ra = find(a), rb = find(b);
    if (ra != rb) _p[ra] = rb;
  }
}

int _hamming(int a, int b) {
  var x = a ^ b;
  var c = 0;
  while (x != 0) {
    c += x & 1;
    x = x >>> 1;
  }
  return c;
}

// ─────────────────────── изолят-функции ───────────────────────

/// Дешёвая проверка целостности по голове+хвосту контейнера (без декода).
/// Возвращает [path, status] для каждого файла.
List<List<dynamic>> _probeChunk(List<String> paths) {
  final out = <List<dynamic>>[];
  for (final path in paths) {
    out.add([path, _probeOne(path)]);
  }
  return out;
}

int _probeOne(String path) {
  RandomAccessFile? raf;
  try {
    final f = File(path);
    final len = f.lengthSync();
    if (len < 12) return kBroken;
    raf = f.openSync();
    final head = raf.readSync(16);
    raf.setPositionSync(len - 16);
    final tail = raf.readSync(16);
    raf.closeSync();
    raf = null;
    // JPEG
    if (head[0] == 0xFF && head[1] == 0xD8) {
      return (tail[14] == 0xFF && tail[15] == 0xD9) ? kOk : kTruncated;
    }
    // PNG
    if (head[0] == 0x89 && head[1] == 0x50) {
      // хвост должен заканчиваться IEND + его постоянный CRC AE 42 60 82
      final ok = tail[8] == 0x49 &&
          tail[9] == 0x45 &&
          tail[10] == 0x4E &&
          tail[11] == 0x44 &&
          tail[12] == 0xAE &&
          tail[13] == 0x42 &&
          tail[14] == 0x60 &&
          tail[15] == 0x82;
      return ok ? kOk : kTruncated;
    }
    // GIF
    if (head[0] == 0x47 && head[1] == 0x49 && head[2] == 0x46) {
      return tail[15] == 0x3B ? kOk : kTruncated;
    }
    return kOk; // прочие форматы — хвост не проверяем
  } catch (_) {
    try {
      raf?.closeSync();
    } catch (_) {}
    return kBroken;
  }
}

/// SHA-256 файла. Возвращает [path, sha|null].
List<List<dynamic>> _shaChunk(List<String> paths) {
  final out = <List<dynamic>>[];
  for (final path in paths) {
    try {
      final bytes = File(path).readAsBytesSync();
      out.add([path, sha256.convert(bytes).toString()]);
    } catch (_) {
      out.add([path, null]);
    }
  }
  return out;
}

/// Глубокий анализ: sha + перцептивный хеш + размеры + целостность за одно
/// чтение. Возвращает [path, sha|null, phash|null, w, h, status].
List<List<dynamic>> _deepChunk(List<String> paths) {
  final out = <List<dynamic>>[];
  for (final path in paths) {
    try {
      final bytes = File(path).readAsBytesSync();
      final sha = sha256.convert(bytes).toString();
      final trunc = _trailerStatus(bytes);
      final im = img.decodeImage(bytes);
      if (im == null) {
        out.add([path, sha, null, 0, 0, kBroken]);
      } else {
        out.add([
          path,
          sha,
          _dhash(im),
          im.width,
          im.height,
          trunc,
        ]);
      }
    } catch (_) {
      out.add([path, null, null, 0, 0, kBroken]);
    }
  }
  return out;
}

int _trailerStatus(Uint8List b) {
  final n = b.length;
  if (n < 16) return kBroken;
  if (b[0] == 0xFF && b[1] == 0xD8) {
    return (b[n - 2] == 0xFF && b[n - 1] == 0xD9) ? kOk : kTruncated;
  }
  if (b[0] == 0x89 && b[1] == 0x50) {
    final ok = b[n - 8] == 0x49 &&
        b[n - 7] == 0x45 &&
        b[n - 6] == 0x4E &&
        b[n - 5] == 0x44;
    return ok ? kOk : kTruncated;
  }
  if (b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46) {
    return b[n - 1] == 0x3B ? kOk : kTruncated;
  }
  return kOk;
}

/// dHash 8×8: сравнение соседних пикселей по горизонтали → 64-битный хеш.
int _dhash(img.Image src) {
  final small = img.copyResize(src, width: 9, height: 8);
  var bits = 0;
  var idx = 0;
  for (var y = 0; y < 8; y++) {
    for (var x = 0; x < 8; x++) {
      final l = small.getPixel(x, y);
      final r = small.getPixel(x + 1, y);
      final ll = 0.299 * l.r + 0.587 * l.g + 0.114 * l.b;
      final lr = 0.299 * r.r + 0.587 * r.g + 0.114 * r.b;
      if (ll < lr) bits |= (1 << idx);
      idx++;
    }
  }
  return bits;
}
