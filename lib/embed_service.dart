import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:onnxruntime/onnxruntime.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'embed_store.dart';
import 'i18n.dart';

/// Локальные эмбеддинги картинок (CLIP-энкодер, ONNX) для поиска «похожих» и
/// (в будущем) семантического поиска по тексту. Модель скачивается один раз,
/// дальше работает офлайн. Ничего не уходит в сеть.
class EmbedService {
  EmbedService._();
  static final EmbedService instance = EmbedService._();

  // Энкодер изображений CLIP ViT-B/32 (ONNX). Даёт вектор «смысла» картинки.
  // Для поиска ПОХОЖИХ (картинка→картинка) достаточно любого стабильного
  // выхода энкодера — совместное с текстом пространство тут не требуется.
  static const _visionUrl =
      'https://huggingface.co/Xenova/clip-vit-base-patch32/resolve/main/onnx/vision_model.onnx';
  static const _kSize = 224; // вход CLIP 224×224

  OrtSession? _session;
  String _inputName = 'pixel_values';

  bool get loaded => _session != null;

  Future<Directory> _modelsDir() async {
    final base = await getApplicationSupportDirectory();
    final d = Directory(p.join(base.path, 'models'));
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  Future<File> _visionFile() async =>
      File(p.join((await _modelsDir()).path, 'clip-vit-b32-vision.onnx'));

  Future<bool> isDownloaded() async => (await _visionFile()).existsSync();

  Future<void> download({void Function(double)? onProgress}) async {
    final mf = await _visionFile();
    if (mf.existsSync()) return;
    final client = http.Client();
    try {
      final req = http.Request('GET', Uri.parse(_visionUrl))
        ..headers['User-Agent'] = 'GOAT';
      final resp = await client.send(req);
      if (resp.statusCode != 200) {
        throw HttpException(
            '${tr('Модель', 'Model', 'Modelo')}: ${tr('код', 'code', 'código')} ${resp.statusCode}');
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

  Future<void> load() async {
    if (loaded) return;
    OrtEnv.instance.init();
    final mf = await _visionFile();
    _session =
        OrtSession.fromBuffer(await mf.readAsBytes(), OrtSessionOptions());
    final ins = _session!.inputNames;
    if (ins.isNotEmpty) _inputName = ins.first;
  }

  /// Вектор картинки из байтов (нормализованный L2). null — не удалось.
  Future<Float32List?> embedBytes(Uint8List bytes) async {
    await load();
    final input = await compute(_preprocessClip, bytes);
    if (input == null) return null;
    final tensor =
        OrtValueTensor.createTensorWithDataList(input, [1, 3, _kSize, _kSize]);
    final runOptions = OrtRunOptions();
    List<OrtValue?> outputs;
    try {
      outputs =
          await _session!.runAsync(runOptions, {_inputName: tensor}) ?? const [];
    } finally {
      tensor.release();
      runOptions.release();
    }
    // выбираем «сжатый» выход (pooler/embeds), а не последовательность токенов
    Float32List? best;
    for (final o in outputs) {
      final v = _flatten(o?.value);
      if (v != null && (best == null || v.length < best.length)) best = v;
    }
    for (final o in outputs) {
      o?.release();
    }
    if (best == null || best.isEmpty) return null;
    return _l2normalize(best);
  }

  /// Косинусная близость к запросу-вектору: топ-K путей (по убыванию). Векторы
  /// в базе уже нормализованы, поэтому косинус = скалярное произведение.
  List<String> searchSimilar(Float32List query, {int k = 200, String? exclude}) {
    final all = EmbedStore.instance.all();
    final scored = <(String, double)>[];
    for (final (path, vec) in all) {
      if (path == exclude) continue;
      if (vec.length != query.length) continue;
      var dot = 0.0;
      for (var i = 0; i < vec.length; i++) {
        dot += vec[i] * query[i];
      }
      scored.add((path, dot));
    }
    scored.sort((a, b) => b.$2.compareTo(a.$2));
    return [for (final s in scored.take(k)) s.$1];
  }

  static Float32List _l2normalize(Float32List v) {
    var sum = 0.0;
    for (final x in v) {
      sum += x * x;
    }
    final norm = math.sqrt(sum);
    if (norm <= 0) return v;
    final out = Float32List(v.length);
    for (var i = 0; i < v.length; i++) {
      out[i] = v[i] / norm;
    }
    return out;
  }

  static Float32List? _flatten(dynamic value) {
    if (value == null) return null;
    final flat = <double>[];
    void walk(dynamic x) {
      if (x is num) {
        flat.add(x.toDouble());
      } else if (x is List) {
        for (final e in x) {
          walk(e);
        }
      }
    }

    walk(value);
    return flat.isEmpty ? null : Float32List.fromList(flat);
  }
}

/// Препроцесс CLIP в изоляте: decode → resize по короткой стороне до 224 →
/// центральный кроп 224 → RGB [0..1] → нормализация → NCHW float32.
Float32List? _preprocessClip(Uint8List bytes) {
  final decoded = img.decodeImage(bytes);
  if (decoded == null) return null;
  const size = 224;
  // resize короткой стороны до 224, затем центральный кроп
  final scale = size / math.min(decoded.width, decoded.height);
  final rw = (decoded.width * scale).round();
  final rh = (decoded.height * scale).round();
  final resized = img.copyResize(decoded,
      width: rw, height: rh, interpolation: img.Interpolation.linear);
  final ox = ((rw - size) / 2).round().clamp(0, rw - size);
  final oy = ((rh - size) / 2).round().clamp(0, rh - size);
  final crop = img.copyCrop(resized, x: ox, y: oy, width: size, height: size);

  // нормализация CLIP
  const mean = [0.48145466, 0.4578275, 0.40821073];
  const std = [0.26862954, 0.26130258, 0.27577711];
  final out = Float32List(3 * size * size);
  const plane = size * size;
  for (var y = 0; y < size; y++) {
    for (var x = 0; x < size; x++) {
      final px = crop.getPixel(x, y);
      final idx = y * size + x;
      final r = px.r / 255.0;
      final g = px.g / 255.0;
      final b = px.b / 255.0;
      out[idx] = (r - mean[0]) / std[0];
      out[plane + idx] = (g - mean[1]) / std[1];
      out[2 * plane + idx] = (b - mean[2]) / std[2];
    }
  }
  return out;
}
