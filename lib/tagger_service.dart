import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:onnxruntime/onnxruntime.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'tag_service.dart';

/// Авто-тегирование изображений локальной ONNX-моделью (WD danbooru-таггер v3).
/// Модель скачивается один раз, дальше работает офлайн.
class Tagger {
  Tagger._();
  static final Tagger instance = Tagger._();

  // wd-vit-tagger-v3 (SmilingWolf): danbooru/аниме/арт-теги, вход 448×448.
  static const _modelUrl =
      'https://huggingface.co/SmilingWolf/wd-vit-tagger-v3/resolve/main/model.onnx';
  static const _csvUrl =
      'https://huggingface.co/SmilingWolf/wd-vit-tagger-v3/resolve/main/selected_tags.csv';
  static const _inputSize = 448;
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

  Future<File> _modelFile() async =>
      File(p.join((await _modelsDir()).path, 'wd-vit-v3.onnx'));
  Future<File> _csvFile() async =>
      File(p.join((await _modelsDir()).path, 'wd-vit-v3-tags.csv'));

  Future<bool> isDownloaded() async =>
      (await _modelFile()).existsSync() && (await _csvFile()).existsSync();

  /// Скачать модель и словарь тегов (с прогрессом 0..1).
  Future<void> download({void Function(double)? onProgress}) async {
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

  /// Прогнать модель на одном файле → список (тег, категория, уверенность).
  Future<List<({String tag, int category, double conf})>> infer(
    String path, {
    double generalThreshold = 0.35,
    double characterThreshold = 0.75,
  }) async {
    await load();
    final Float32List? input = _preprocess(await File(path).readAsBytes());
    if (input == null) return const [];

    final tensor = OrtValueTensor.createTensorWithDataList(
        input, [1, _inputSize, _inputSize, 3]);
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

  /// Прогнать и записать теги в базу. Возвращает число тегов.
  Future<int> tagAndStore(String path, {double generalThreshold = 0.35}) async {
    final tags = await infer(path, generalThreshold: generalThreshold);
    for (final t in tags) {
      final cat = t.category == 4
          ? 'character'
          : t.category == 9
              ? 'rating'
              : 'general';
      TagService.instance.addTag(path, t.tag,
          category: cat, source: source, confidence: t.conf);
    }
    return tags.length;
  }

  /// Подготовка картинки: композит на белом, паддинг до квадрata, ресайз 448,
  /// порядок BGR, значения 0..255, формат NHWC.
  Float32List? _preprocess(Uint8List bytes) {
    final decoded = img.decodeImage(bytes);
    if (decoded == null) return null;

    // на белый фон (убираем альфу)
    var base = img.Image(width: decoded.width, height: decoded.height);
    img.fill(base, color: img.ColorRgb8(255, 255, 255));
    img.compositeImage(base, decoded);

    // паддинг до квадрата
    final side = math.max(base.width, base.height);
    final square = img.Image(width: side, height: side);
    img.fill(square, color: img.ColorRgb8(255, 255, 255));
    img.compositeImage(square, base,
        dstX: (side - base.width) ~/ 2, dstY: (side - base.height) ~/ 2);

    final resized = img.copyResize(square,
        width: _inputSize,
        height: _inputSize,
        interpolation: img.Interpolation.cubic);

    final out = Float32List(_inputSize * _inputSize * 3);
    var idx = 0;
    for (var y = 0; y < _inputSize; y++) {
      for (var x = 0; x < _inputSize; x++) {
        final px = resized.getPixel(x, y);
        out[idx++] = px.b.toDouble();
        out[idx++] = px.g.toDouble();
        out[idx++] = px.r.toDouble();
      }
    }
    return out;
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
