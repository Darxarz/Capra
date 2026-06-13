import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:image/image.dart' as img;
import 'model.dart';

/// Хост локальной сети: раздаёт свою галерею другим устройствам в той же
/// Wi-Fi сети. Поднимает встроенный HTTP-сервер (чистый dart:io, без нативных
/// плагинов — работает и на Windows, и на Android). Доступ защищён PIN-кодом:
/// другое устройство вводит PIN, в обмен получает токен сессии.
///
/// Эндпоинты:
///   GET /ping                         — кто это (без токена), для проверки связи
///   GET /pair?pin=XXXXXX              — сверить PIN, выдать токен
///   GET /list?token=&offset=&limit=   — список фото (JSON)
///   GET /thumb?token=&id=&w=          — миниатюра (ужата на стороне хоста)
///   GET /file?token=&id=              — оригинал файла
class LanService extends ChangeNotifier {
  LanService._();
  static final LanService instance = LanService._();

  static const int _basePort = 8787;

  HttpServer? _server;
  List<PhotoItem> _snapshot = const []; // что раздаём (фиксируется на старте)
  String _pin = '';
  String _token = '';
  int _port = _basePort;

  // защита от перебора PIN
  int _failCount = 0;
  DateTime? _lockUntil;

  Directory? _cacheDir; // дисковый кэш ужатых миниатюр

  bool get isRunning => _server != null;
  String get pin => _pin;
  int get port => _port;
  int get sharedCount => _snapshot.length;

  /// Текущая библиотека (обновляется хозяином при каждом сканировании).
  /// Берётся как снимок в момент запуска сервера.
  List<PhotoItem> _live = const [];
  void setLibrary(List<PhotoItem> photos) {
    _live = photos;
    // если уже раздаём — обновим снимок (новые фото станут видны клиенту
    // при следующем запросе списка)
    if (isRunning) _snapshot = List.unmodifiable(_live);
  }

  /// Запустить раздачу. Возвращает список локальных адресов, по которым
  /// устройство доступно (для показа на экране).
  Future<List<String>> start() async {
    if (isRunning) return localAddresses();
    _snapshot = List.unmodifiable(_live);
    _pin = (Random.secure().nextInt(900000) + 100000).toString(); // 6 цифр
    _token = _randomToken();
    _failCount = 0;
    _lockUntil = null;

    // подобрать свободный порт
    HttpServer? srv;
    for (var port = _basePort; port < _basePort + 12; port++) {
      try {
        srv = await HttpServer.bind(InternetAddress.anyIPv4, port);
        _port = port;
        break;
      } on SocketException {
        continue;
      }
    }
    if (srv == null) {
      throw const SocketException('Не удалось открыть сетевой порт');
    }
    _server = srv;
    srv.listen(_onRequest, onError: (_) {});
    notifyListeners();
    return localAddresses();
  }

  Future<void> stop() async {
    final s = _server;
    _server = null;
    _snapshot = const [];
    _pin = '';
    _token = '';
    if (s != null) {
      try {
        await s.close(force: true);
      } catch (_) {}
    }
    notifyListeners();
  }

  // ───────────────────────── обработка запросов ─────────────────────────
  Future<void> _onRequest(HttpRequest req) async {
    final res = req.response;
    try {
      final path = req.uri.path;
      final q = req.uri.queryParameters;

      if (path == '/ping') {
        _json(res, {
          'app': 'GOAT',
          'name': _deviceName(),
          'count': _snapshot.length,
        });
        return;
      }

      if (path == '/pair') {
        _handlePair(res, q['pin']);
        return;
      }

      // дальше — только с действующим токеном
      if (q['token'] != _token || _token.isEmpty) {
        res.statusCode = HttpStatus.unauthorized;
        await res.close();
        return;
      }

      switch (path) {
        case '/list':
          _handleList(res, q);
          return;
        case '/thumb':
          await _handleThumb(res, q);
          return;
        case '/file':
          await _handleFile(res, q);
          return;
        default:
          res.statusCode = HttpStatus.notFound;
          await res.close();
      }
    } catch (_) {
      try {
        res.statusCode = HttpStatus.internalServerError;
        await res.close();
      } catch (_) {}
    }
  }

  void _handlePair(HttpResponse res, String? pin) {
    // блокировка после серии неудачных попыток
    final now = DateTime.now();
    if (_lockUntil != null && now.isBefore(_lockUntil!)) {
      res.statusCode = HttpStatus.tooManyRequests;
      res.close();
      return;
    }
    if (pin != null && pin == _pin && _pin.isNotEmpty) {
      _failCount = 0;
      _json(res, {'token': _token, 'name': _deviceName()});
      return;
    }
    _failCount++;
    if (_failCount >= 5) {
      _lockUntil = now.add(const Duration(seconds: 30));
      _failCount = 0;
    }
    res.statusCode = HttpStatus.forbidden;
    res.close();
  }

  void _handleList(HttpResponse res, Map<String, String> q) {
    final offset = int.tryParse(q['offset'] ?? '0') ?? 0;
    final limit = (int.tryParse(q['limit'] ?? '500') ?? 500).clamp(1, 2000);
    final end = (offset + limit).clamp(0, _snapshot.length);
    final items = <Map<String, dynamic>>[];
    for (var i = offset; i < end; i++) {
      final ph = _snapshot[i];
      items.add({
        'id': i.toString(),
        'name': ph.fileName,
        'folder': ph.folderName,
        'gif': ph.isGif,
        'size': ph.sizeBytes,
        'mtime': ph.modified.millisecondsSinceEpoch,
      });
    }
    _json(res, {'total': _snapshot.length, 'items': items});
  }

  PhotoItem? _byId(String? id) {
    final i = int.tryParse(id ?? '');
    if (i == null || i < 0 || i >= _snapshot.length) return null;
    return _snapshot[i];
  }

  Future<void> _handleThumb(HttpResponse res, Map<String, String> q) async {
    final ph = _byId(q['id']);
    if (ph == null) {
      res.statusCode = HttpStatus.notFound;
      await res.close();
      return;
    }
    final w = (int.tryParse(q['w'] ?? '256') ?? 256).clamp(48, 1024);
    final bytes = await _thumbBytes(q['id']!, ph.path, w);
    if (bytes == null) {
      res.statusCode = HttpStatus.notFound;
      await res.close();
      return;
    }
    res.headers.contentType = ContentType('image', 'jpeg');
    res.add(bytes);
    await res.close();
  }

  Future<void> _handleFile(HttpResponse res, Map<String, String> q) async {
    final ph = _byId(q['id']);
    if (ph == null) {
      res.statusCode = HttpStatus.notFound;
      await res.close();
      return;
    }
    final f = File(ph.path);
    if (!f.existsSync()) {
      res.statusCode = HttpStatus.notFound;
      await res.close();
      return;
    }
    res.headers.contentType = _contentTypeFor(ph.path);
    await res.addStream(f.openRead());
    await res.close();
  }

  // ───────────────────────── миниатюры ─────────────────────────
  Future<Directory> _ensureCache() async {
    if (_cacheDir != null) return _cacheDir!;
    final base = await getTemporaryDirectory();
    final d = Directory(p.join(base.path, 'goat_lan_cache'));
    if (!await d.exists()) await d.create(recursive: true);
    _cacheDir = d;
    return d;
  }

  /// Ужатая миниатюра (JPEG) с диск-кэшем по id+ширине.
  Future<Uint8List?> _thumbBytes(String id, String path, int w) async {
    try {
      final dir = await _ensureCache();
      final cacheFile = File(p.join(dir.path, '${id}_$w.jpg'));
      if (cacheFile.existsSync()) {
        return cacheFile.readAsBytesSync();
      }
      final src = File(path);
      if (!src.existsSync()) return null;
      final raw = await src.readAsBytes();
      final out = await compute(_resizeJpeg, _ResizeReq(raw, w));
      if (out != null) {
        try {
          cacheFile.writeAsBytesSync(out);
        } catch (_) {}
      }
      return out;
    } catch (_) {
      return null;
    }
  }

  // ───────────────────────── вспомогательное ─────────────────────────
  void _json(HttpResponse res, Object data) {
    res.headers.contentType = ContentType.json;
    res.write(jsonEncode(data));
    res.close();
  }

  ContentType _contentTypeFor(String path) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.png')) return ContentType('image', 'png');
    if (lower.endsWith('.gif')) return ContentType('image', 'gif');
    if (lower.endsWith('.webp')) return ContentType('image', 'webp');
    if (lower.endsWith('.bmp')) return ContentType('image', 'bmp');
    return ContentType('image', 'jpeg');
  }

  String _deviceName() {
    try {
      return Platform.localHostname;
    } catch (_) {
      return Platform.isAndroid ? 'Android' : 'Устройство';
    }
  }

  String _randomToken() {
    final r = Random.secure();
    final b = List<int>.generate(16, (_) => r.nextInt(256));
    return b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  }

  /// Локальные IPv4-адреса (для показа на экране хоста). Приватные сети
  /// (192.168.* / 10.* / 172.16-31.*) — в начало списка.
  static Future<List<String>> localAddresses() async {
    final out = <String>[];
    try {
      final ifaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      for (final iface in ifaces) {
        for (final a in iface.addresses) {
          out.add(a.address);
        }
      }
    } catch (_) {}
    out.sort((a, b) {
      final pa = _isPrivate(a) ? 0 : 1;
      final pb = _isPrivate(b) ? 0 : 1;
      return pa.compareTo(pb);
    });
    return out;
  }

  static bool _isPrivate(String ip) =>
      ip.startsWith('192.168.') ||
      ip.startsWith('10.') ||
      RegExp(r'^172\.(1[6-9]|2[0-9]|3[0-1])\.').hasMatch(ip);
}

/// Запрос на ужатие (для compute).
class _ResizeReq {
  final Uint8List bytes;
  final int width;
  _ResizeReq(this.bytes, this.width);
}

/// Декодирует, уменьшает до [width] и кодирует в JPEG. Выполняется в изоляте.
Uint8List? _resizeJpeg(_ResizeReq req) {
  try {
    final decoded = img.decodeImage(req.bytes);
    if (decoded == null) return null;
    final resized = decoded.width > req.width
        ? img.copyResize(decoded, width: req.width)
        : decoded;
    return Uint8List.fromList(img.encodeJpg(resized, quality: 82));
  } catch (_) {
    return null;
  }
}
