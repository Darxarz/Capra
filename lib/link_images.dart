import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:goat_link/goat_link.dart';

// Картинки коллекции с ПК. Миниатюру делает ПК, файл читается через Goat
// Explorer. Плитка, ушедшая с экрана, отменяет свою загрузку: при быстрой
// прокрутке 146 тысяч файлов сеть занята только тем, что сейчас видно.

/// Где лежит файл коллекции. Только относительный путь, никаких путей ПК.
class LinkRef {
  final String treeUri;
  final int fileId;
  final String rel;
  final String sha;
  const LinkRef({
    required this.treeUri,
    required this.fileId,
    required this.rel,
    required this.sha,
  });

  /// Имя в дисковом кэше: по содержимому, так что заменённый файл не покажет
  /// старую миниатюру, а одинаковые файлы делят одну.
  String get cacheKey => sha.length >= 32 ? sha.substring(0, 32) : 'id$fileId';
}

class _Load {
  final String key;
  final Future<String> Function(int id) start;
  final Completer<String> done = Completer<String>();
  int? nativeId;
  _Load(this.key, this.start);
}

/// Очередь загрузок: не больше [maxRunning] разом, свежие запросы — первыми.
class LinkLoads {
  LinkLoads._();
  static final LinkLoads instance = LinkLoads._();

  static const int maxRunning = 6;

  GoatLinkApi? api;
  int _nextId = 1;
  int _running = 0;
  final Map<String, _Load> _loads = {};
  final List<_Load> _queue = [];
  final Map<String, int> _holds = {};

  Future<String> thumbnail(LinkRef ref, int size) {
    return _enqueue(thumbKey(ref, size),
        (id) => api!.thumbnail(id, ref.treeUri, ref.rel, ref.cacheKey, size));
  }

  Future<String> full(LinkRef ref) {
    return _enqueue(fullKey(ref),
        (id) => api!.full(id, ref.treeUri, ref.rel, ref.cacheKey));
  }

  static String thumbKey(LinkRef ref, int size) => 't:${ref.cacheKey}:$size';
  static String fullKey(LinkRef ref) => 'f:${ref.cacheKey}';

  Future<String> _enqueue(String key, Future<String> Function(int id) start) {
    final existing = _loads[key];
    if (existing != null) return existing.done.future;
    if (api == null) return Future.error(const LinkReadError('offline'));
    final load = _Load(key, start);
    _loads[key] = load;
    _queue.add(load);
    _pump();
    return load.done.future;
  }

  void _pump() {
    while (_running < maxRunning && _queue.isNotEmpty) {
      final load = _queue.removeLast(); // последним попросили — виден сейчас
      _running++;
      final id = _nextId++;
      load.nativeId = id;
      load.start(id).then((path) {
        if (!load.done.isCompleted) load.done.complete(path);
      }, onError: (Object e) {
        if (!load.done.isCompleted) load.done.completeError(e);
      }).whenComplete(() {
        _running--;
        if (identical(_loads[load.key], load)) _loads.remove(load.key);
        _pump();
      });
    }
  }

  /// Плитка на экране держит свою загрузку.
  void retain(String key) => _holds[key] = (_holds[key] ?? 0) + 1;

  /// Плитка ушла. Если загрузка больше никому не нужна — отменяем.
  void release(String key) {
    final left = (_holds[key] ?? 1) - 1;
    if (left > 0) {
      _holds[key] = left;
      return;
    }
    _holds.remove(key);
    final load = _loads[key];
    if (load == null) return;
    if (_queue.remove(load)) {
      _loads.remove(key);
      load.done.completeError(const LinkCanceled());
      return;
    }
    final id = load.nativeId;
    if (id != null) unawaited(api?.cancel(id));
  }

  @visibleForTesting
  int get queued => _queue.length;
}

Future<ui.Codec> _decodeFile(String path, ImageDecoderCallback decode) async {
  final buffer = await ui.ImmutableBuffer.fromFilePath(path);
  return decode(buffer);
}

void _forget(Object key) {
  // как у NetworkImage: неудачная загрузка не должна залипнуть в кэше картинок
  scheduleMicrotask(() => PaintingBinding.instance.imageCache.evict(key));
}

/// Миниатюра с ПК (через дисковый кэш приложения).
@immutable
class LinkThumbImage extends ImageProvider<LinkThumbImage> {
  final LinkRef ref;
  final int size;
  const LinkThumbImage(this.ref, this.size);

  @override
  Future<LinkThumbImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<LinkThumbImage>(this);

  @override
  ImageStreamCompleter loadImage(
          LinkThumbImage key, ImageDecoderCallback decode) =>
      MultiFrameImageStreamCompleter(codec: _load(key, decode), scale: 1);

  Future<ui.Codec> _load(
      LinkThumbImage key, ImageDecoderCallback decode) async {
    try {
      final path = await LinkLoads.instance.thumbnail(key.ref, key.size);
      return await _decodeFile(path, decode);
    } catch (_) {
      _forget(key);
      rethrow;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is LinkThumbImage &&
      other.ref.cacheKey == ref.cacheKey &&
      other.size == size;

  @override
  int get hashCode => Object.hash(ref.cacheKey, size);
}

/// Полный файл картинки: читается через Explorer в ограниченный кэш.
@immutable
class LinkFullImage extends ImageProvider<LinkFullImage> {
  final LinkRef ref;
  const LinkFullImage(this.ref);

  @override
  Future<LinkFullImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<LinkFullImage>(this);

  @override
  ImageStreamCompleter loadImage(
          LinkFullImage key, ImageDecoderCallback decode) =>
      MultiFrameImageStreamCompleter(codec: _load(key, decode), scale: 1);

  Future<ui.Codec> _load(LinkFullImage key, ImageDecoderCallback decode) async {
    try {
      final path = await LinkLoads.instance.full(key.ref);
      return await _decodeFile(path, decode);
    } catch (_) {
      _forget(key);
      rethrow;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is LinkFullImage && other.ref.cacheKey == ref.cacheKey;

  @override
  int get hashCode => ref.cacheKey.hashCode;
}

/// Держит загрузку, пока виджет на экране; при уходе с экрана отменяет её.
class LinkLoadLease extends StatefulWidget {
  final String loadKey;
  final Widget child;
  const LinkLoadLease({super.key, required this.loadKey, required this.child});

  @override
  State<LinkLoadLease> createState() => _LinkLoadLeaseState();
}

class _LinkLoadLeaseState extends State<LinkLoadLease> {
  @override
  void initState() {
    super.initState();
    LinkLoads.instance.retain(widget.loadKey);
  }

  @override
  void didUpdateWidget(LinkLoadLease old) {
    super.didUpdateWidget(old);
    if (old.loadKey != widget.loadKey) {
      LinkLoads.instance.retain(widget.loadKey);
      LinkLoads.instance.release(old.loadKey);
    }
  }

  @override
  void dispose() {
    LinkLoads.instance.release(widget.loadKey);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
