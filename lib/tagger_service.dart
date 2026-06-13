import 'dart:io';
import 'dart:math' as math;
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:onnxruntime/onnxruntime.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'tag_service.dart';

const int _kInputSize = 448; // вход модели 448×448

/// Авто-тегирование изображений локальной ONNX-моделью (WD danbooru-таггер v3).
/// Модель скачивается один раз, дальше работает офлайн.
class Tagger {
  Tagger._();
  static final Tagger instance = Tagger._();

  // wd-vit-tagger-v3 (SmilingWolf): danbooru/аниме/арт-теги, 10861 тег, вход
  // 448×448. Требует ONNX Runtime ≥1.16 — в сборке onnxruntime.dll подменяется
  // на свежий официальный (см. workflow), поэтому v3 грузится.
  static const _modelUrl =
      'https://huggingface.co/SmilingWolf/wd-vit-tagger-v3/resolve/main/model.onnx';
  static const _csvUrl =
      'https://huggingface.co/SmilingWolf/wd-vit-tagger-v3/resolve/main/selected_tags.csv';
  static const source = 'wd-v3';

  OrtSession? _session;
  String _inputName = 'input';
  List<String> _tagNames = const [];
  List<int> _tagCats = const []; // 0=general, 4=character, 9=rating

  bool get loaded => _session != null && _tagNames.isNotEmpty;

  Future<Directory> _modelsDir() async {
    final base = await getApplicationSupportDirectory();
    final d = Directory(p.join(base.path, 'models'));
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  // имена файлов как в build-17 — чтобы переиспользовать уже скачанную модель
  Future<File> _modelFile() async =>
      File(p.join((await _modelsDir()).path, 'wd-vit-v3.onnx'));
  Future<File> _csvFile() async =>
      File(p.join((await _modelsDir()).path, 'wd-vit-v3-tags.csv'));

  Future<bool> isDownloaded() async =>
      (await _modelFile()).existsSync() && (await _csvFile()).existsSync();

  /// Скачать модель и словарь тегов (с прогрессом 0..1).
  Future<void> download({void Function(double)? onProgress}) async {
    // убрать промежуточную v2-модель, если кто-то успел её скачать
    final dir = (await _modelsDir()).path;
    for (final name in ['wd-moat-v2.onnx', 'wd-moat-v2-tags.csv']) {
      final old = File(p.join(dir, name));
      if (old.existsSync()) {
        try {
          old.deleteSync();
        } catch (_) {}
      }
    }
    final cf = await _csvFile();
    if (!cf.existsSync()) {
      final r = await http
          .get(Uri.parse(_csvUrl), headers: {'User-Agent': 'Capra'});
      if (r.statusCode != 200) {
        throw HttpException('Словарь тегов: код ${r.statusCode}');
      }
      await cf.writeAsBytes(r.bodyBytes);
    }
    final mf = await _modelFile();
    if (!mf.existsSync()) {
      final client = http.Client();
      try {
        final req = http.Request('GET', Uri.parse(_modelUrl))
          ..headers['User-Agent'] = 'Capra';
        final resp = await client.send(req);
        if (resp.statusCode != 200) {
          throw HttpException('Модель: код ${resp.statusCode}');
        }
        final total = resp.contentLength ?? -1;
        var got = 0;
        final part = File('${mf.path}.part');
        final sink = part.openWrite();
        await for (final chunk in resp.stream) {
          sink.add(chunk);
          got += chunk.length;
          if (total > 0) onProgress?.call(got / total);
        }
        await sink.close();
        await part.rename(mf.path);
      } finally {
        client.close();
      }
    }
  }

  /// Загрузить модель в память (ленивая инициализация).
  Future<void> load() async {
    if (loaded) return;
    OrtEnv.instance.init();
    final mf = await _modelFile();
    final cf = await _csvFile();
    // грузим из байтов, а не по пути: OrtSession.fromFile на Windows портит
    // путь (ASCII читается как UTF-16) и не находит файл — проверено.
    _session = OrtSession.fromBuffer(await mf.readAsBytes(), OrtSessionOptions());
    final ins = _session!.inputNames;
    if (ins.isNotEmpty) _inputName = ins.first;

    final lines = await cf.readAsLines();
    final names = <String>[];
    final cats = <int>[];
    for (var i = 1; i < lines.length; i++) {
      // selected_tags.csv: tag_id,name,category,count
      final parts = lines[i].split(',');
      if (parts.length < 3) continue;
      names.add(parts[1]);
      cats.add(int.tryParse(parts[2]) ?? 0);
    }
    _tagNames = names;
    _tagCats = cats;
  }

  /// Синхронный инференс на одном файле (для одиночного тегирования).
  Future<List<({String tag, int category, double conf})>> infer(
    String path, {
    double generalThreshold = 0.35,
    double characterThreshold = 0.75,
  }) async {
    await load();
    final bytes = await File(path).readAsBytes();
    _storeSha(path, bytes);
    final input = preprocessBytes(bytes);
    if (input == null) return const [];
    final tensor = OrtValueTensor.createTensorWithDataList(
        input, [1, _kInputSize, _kInputSize, 3]);
    final runOptions = OrtRunOptions();
    List<OrtValue?> outputs;
    try {
      outputs = _session!.run(runOptions, {_inputName: tensor});
    } finally {
      tensor.release();
      runOptions.release();
    }
    final probs = _flatten(outputs.isNotEmpty ? outputs.first?.value : null);
    for (final o in outputs) {
      o?.release();
    }
    return _mapProbs(probs, generalThreshold, characterThreshold);
  }

  /// Асинхронный инференс: декод картинки — в фоновом изоляте (compute),
  /// инференс — в фоновом изоляте движка (runAsync). UI не подвисает.
  Future<List<({String tag, int category, double conf})>> inferAsync(
    String path, {
    double generalThreshold = 0.35,
    double characterThreshold = 0.75,
  }) async {
    await load();
    final bytes = await File(path).readAsBytes();
    _storeSha(path, bytes);
    final input = await compute(preprocessBytes, bytes);
    if (input == null) return const [];
    final tensor = OrtValueTensor.createTensorWithDataList(
        input, [1, _kInputSize, _kInputSize, 3]);
    final runOptions = OrtRunOptions();
    List<OrtValue?> outputs;
    try {
      outputs =
          await _session!.runAsync(runOptions, {_inputName: tensor}) ?? const [];
    } finally {
      tensor.release();
      runOptions.release();
    }
    final probs = _flatten(outputs.isNotEmpty ? outputs.first?.value : null);
    for (final o in outputs) {
      o?.release();
    }
    return _mapProbs(probs, generalThreshold, characterThreshold);
  }

  /// Синхронно прогнать и записать в базу (одиночное тегирование).
  Future<int> tagAndStore(String path, {double generalThreshold = 0.35}) async {
    final tags = await infer(path, generalThreshold: generalThreshold);
    _store(path, tags);
    return tags.length;
  }

  /// Асинхронно прогнать и записать в базу (для пакетного тегирования).
  Future<int> tagAndStoreAsync(String path,
      {double generalThreshold = 0.35}) async {
    final tags = await inferAsync(path, generalThreshold: generalThreshold);
    _store(path, tags);
    return tags.length;
  }

  // сохранить точный хеш файла при тегировании — чтобы теги можно было
  // перепривязать, если файл потом переименуют/переместят
  void _storeSha(String path, Uint8List bytes) {
    try {
      final sha = sha256.convert(bytes).toString();
      final mtime = File(path).lastModifiedSync().millisecondsSinceEpoch;
      TagService.instance.storeShaOnly(path, bytes.length, mtime, sha);
    } catch (_) {}
  }

  // признаки «реалистичности»/3D в словаре danbooru — для роутера типа
  static const _photoMarkers = {
    'realistic', 'photorealistic', 'photo', 'photo_(medium)', 'real_life',
  };

  /// Роутер типа изображения (1-й этап конвейера автотегов). Сейчас тип
  /// выводится из тегов WD-модели; в будущем сюда встанет CLIP/SigLIP-роутер,
  /// направляющий фото в RAM++, а арт — в WD/JoyTag (см. дорожную карту).
  String _deriveType(List<({String tag, int category, double conf})> tags) {
    final general = {for (final t in tags) if (t.category == 0) t.tag};
    if (general.intersection(_photoMarkers).isNotEmpty) return 'фото';
    if (general.contains('3d')) return '3d';
    if (general.contains('comic') || general.contains('screenshot')) {
      return 'скриншот';
    }
    return 'рисунок';
  }

  void _store(
      String path, List<({String tag, int category, double conf})> tags) {
    for (final t in tags) {
      final cat = t.category == 4
          ? 'character'
          : t.category == 9
              ? 'rating'
              : 'general';
      TagService.instance.addTag(path, t.tag,
          category: cat, source: source, confidence: t.conf);
    }
    if (tags.isNotEmpty) {
      TagService.instance.addTag(path, 'тип:${_deriveType(tags)}',
          category: 'type', source: source, confidence: 1.0);
    }
  }

  List<({String tag, int category, double conf})> _mapProbs(
      List<double> probs, double generalThreshold, double characterThreshold) {
    if (probs.isEmpty) return const [];
    var maxv = 0.0;
    for (final v in probs) {
      if (v > maxv) maxv = v;
    }
    final needSigmoid = maxv > 1.0; // если вышли логиты — применим сигмоиду
    final res = <({String tag, int category, double conf})>[];
    String? bestRating;
    var bestRatingConf = 0.0;
    final n = math.min(probs.length, _tagNames.length);
    for (var i = 0; i < n; i++) {
      var v = probs[i];
      if (needSigmoid) v = 1.0 / (1.0 + math.exp(-v));
      final cat = _tagCats[i];
      if (cat == 9) {
        if (v > bestRatingConf) {
          bestRatingConf = v;
          bestRating = _tagNames[i];
        }
      } else {
        final th = cat == 4 ? characterThreshold : generalThreshold;
        if (v >= th) {
          res.add((tag: _tagNames[i], category: cat, conf: v));
        }
      }
    }
    if (bestRating != null) {
      res.add((tag: 'rating:$bestRating', category: 9, conf: bestRatingConf));
    }
    res.sort((a, b) => b.conf.compareTo(a.conf));
    return res;
  }

  List<double> _flatten(dynamic raw) {
    if (raw is List) {
      if (raw.isNotEmpty && raw.first is List) {
        return [for (final e in (raw.first as List)) (e as num).toDouble()];
      }
      return [for (final e in raw) (e as num).toDouble()];
    }
    return const [];
  }
}

/// Подготовка картинки (top-level — чтобы гонять в `compute`): композит на
/// белом, паддинг до квадрата, ресайз 448, порядок BGR, 0..255, NHWC.
Float32List? preprocessBytes(Uint8List bytes) {
  final decoded = img.decodeImage(bytes);
  if (decoded == null) return null;

  final base = img.Image(width: decoded.width, height: decoded.height);
  img.fill(base, color: img.ColorRgb8(255, 255, 255));
  img.compositeImage(base, decoded);

  final side = math.max(base.width, base.height);
  final square = img.Image(width: side, height: side);
  img.fill(square, color: img.ColorRgb8(255, 255, 255));
  img.compositeImage(square, base,
      dstX: (side - base.width) ~/ 2, dstY: (side - base.height) ~/ 2);

  final resized = img.copyResize(square,
      width: _kInputSize,
      height: _kInputSize,
      interpolation: img.Interpolation.cubic);

  final out = Float32List(_kInputSize * _kInputSize * 3);
  var idx = 0;
  for (var y = 0; y < _kInputSize; y++) {
    for (var x = 0; x < _kInputSize; x++) {
      final px = resized.getPixel(x, y);
      out[idx++] = px.b.toDouble();
      out[idx++] = px.g.toDouble();
      out[idx++] = px.r.toDouble();
    }
  }
  return out;
}
