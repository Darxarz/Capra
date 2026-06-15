import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'model.dart';
import 'i18n.dart';

/// Результат успешного подключения к хосту.
class LanConnection {
  final String base; // "http://192.168.1.5:8787"
  final String token;
  final String hostId;
  final String hostName;
  final int total;
  const LanConnection({
    required this.base,
    required this.token,
    required this.hostId,
    required this.hostName,
    required this.total,
  });
}

/// Ошибка подключения с понятным пользователю текстом.
/// [needRepair] = true, если хост отверг токен и нужно заново ввести PIN.
class LanError implements Exception {
  final String message;
  final bool needRepair;
  LanError(this.message, {this.needRepair = false});
  @override
  String toString() => message;
}

/// Данные подключения, закодированные в QR-коде.
class LanQrData {
  final String ip;
  final int port;
  final String pin;
  const LanQrData({required this.ip, required this.port, required this.pin});
}

/// Сформировать строку QR: goat://pair?ip=&port=&pin=
String buildLanQr(String ip, int port, String pin) =>
    Uri(scheme: 'goat', host: 'pair', queryParameters: {
      'ip': ip,
      'port': port.toString(),
      'pin': pin,
    }).toString();

/// Разобрать строку QR обратно. null — если это не наш формат.
LanQrData? parseLanQr(String raw) {
  try {
    final u = Uri.parse(raw.trim());
    if (u.scheme != 'goat') return null;
    final ip = u.queryParameters['ip'];
    final pin = u.queryParameters['pin'];
    final port = int.tryParse(u.queryParameters['port'] ?? '') ?? 8787;
    if (ip == null || ip.isEmpty || pin == null || pin.isEmpty) return null;
    return LanQrData(ip: ip, port: port, pin: pin);
  } catch (_) {
    return null;
  }
}

/// Клиент локальной сети: подключается к устройству-хосту и тянет его галерею.
class LanClient {
  /// ПЕРВОЕ сопряжение по адресу [ip]:[port] и PIN. Передаёт хосту свой
  /// [clientId] и [clientName], получает ПОСТОЯННЫЙ токен. Дальше используется
  /// [connectWithToken] — PIN больше не нужен.
  static Future<LanConnection> pair({
    required String ip,
    required int port,
    required String pin,
    required String clientId,
    required String clientName,
  }) async {
    final base = 'http://$ip:$port';
    final ping = await _ping(base);

    try {
      final url = Uri.parse('$base/pair').replace(queryParameters: {
        'pin': pin,
        'client': clientId,
        'name': clientName,
      });
      final r = await http.get(url).timeout(const Duration(seconds: 6));
      if (r.statusCode == 429) {
        throw LanError(tr(
            'Слишком много попыток. Подожди полминуты и снова.',
            'Too many attempts. Wait half a minute and try again.',
            'Demasiados intentos. Espera medio minuto e inténtalo de nuevo.'));
      }
      if (r.statusCode == 403) {
        throw LanError(tr('Неверный PIN.', 'Wrong PIN.', 'PIN incorrecto.'));
      }
      if (r.statusCode != 200) {
        throw LanError(tr(
            'Не удалось сопрячься (${r.statusCode}).',
            'Could not pair (${r.statusCode}).',
            'No se pudo emparejar (${r.statusCode}).'));
      }
      final data = jsonDecode(r.body) as Map<String, dynamic>;
      return LanConnection(
        base: base,
        token: data['token'] as String,
        hostId: (data['hostId'] ?? ping['hostId'] ?? '') as String,
        hostName: (data['name'] ?? ping['name'] ?? 'Устройство') as String,
        total: (ping['count'] ?? 0) as int,
      );
    } on LanError {
      rethrow;
    } catch (_) {
      throw LanError(tr(
          'Сбой при сопряжении. Попробуй ещё раз.',
          'Pairing failed. Try again.',
          'Falló el emparejamiento. Inténtalo de nuevo.'));
    }
  }

  /// Повторное подключение к уже запомненному хосту по постоянному токену
  /// (без PIN). Бросает [LanError]; код различает «нет связи» и «токен
  /// отвергнут» по полю [LanError.needRepair].
  static Future<LanConnection> connectWithToken({
    required String ip,
    required int port,
    required String token,
  }) async {
    final base = 'http://$ip:$port';
    try {
      final r = await http
          .get(Uri.parse('$base/auth?token=$token'))
          .timeout(const Duration(seconds: 6));
      if (r.statusCode == 401) {
        throw LanError(
            tr(
                'Устройство больше не помнит этот ключ — нужен PIN заново.',
                'The device no longer remembers this key — PIN is needed again.',
                'El dispositivo ya no recuerda esta clave: hace falta el PIN otra vez.'),
            needRepair: true);
      }
      if (r.statusCode != 200) {
        throw LanError(tr(
            'Устройство ответило ошибкой (${r.statusCode}).',
            'The device replied with an error (${r.statusCode}).',
            'El dispositivo respondió con un error (${r.statusCode}).'));
      }
      final data = jsonDecode(r.body) as Map<String, dynamic>;
      return LanConnection(
        base: base,
        token: token,
        hostId: (data['hostId'] ?? '') as String,
        hostName: (data['name'] ?? 'Устройство') as String,
        total: (data['count'] ?? 0) as int,
      );
    } on LanError {
      rethrow;
    } catch (_) {
      throw LanError(tr(
          'Не удалось связаться. Устройство включило раздачу? Одна ли у вас Wi-Fi сеть?',
          'Could not connect. Is sharing turned on? Are both devices on the same Wi-Fi?',
          'No se pudo conectar. ¿Está activado compartir? ¿Ambos dispositivos están en la misma Wi-Fi?'));
    }
  }

  /// Проверка связи + что это GOAT.
  static Future<Map<String, dynamic>> _ping(String base) async {
    try {
      final r = await http
          .get(Uri.parse('$base/ping'))
          .timeout(const Duration(seconds: 6));
      if (r.statusCode != 200) {
        throw LanError(tr(
            'Устройство ответило ошибкой (${r.statusCode}).',
            'The device replied with an error (${r.statusCode}).',
            'El dispositivo respondió con un error (${r.statusCode}).'));
      }
      final ping = jsonDecode(r.body) as Map<String, dynamic>;
      if (ping['app'] != 'GOAT') {
        throw LanError(tr('По этому адресу не GOAT.',
            'That address is not GOAT.', 'Esa dirección no es GOAT.'));
      }
      return ping;
    } on LanError {
      rethrow;
    } catch (_) {
      throw LanError(tr(
          'Не удалось связаться. Проверь адрес и одну ли вы Wi-Fi сеть.',
          'Could not connect. Check the address and that both devices are on the same Wi-Fi.',
          'No se pudo conectar. Revisa la dirección y que ambos dispositivos estén en la misma Wi-Fi.'));
    }
  }

  /// Получить весь список фото хоста (страницами) как удалённые [PhotoItem].
  static Future<List<PhotoItem>> fetchAll(LanConnection conn) async {
    final out = <PhotoItem>[];
    const page = 1000;
    var offset = 0;
    var total = conn.total;
    while (offset < total || offset == 0) {
      final r = await http
          .get(Uri.parse(
              '${conn.base}/list?token=${conn.token}&offset=$offset&limit=$page'))
          .timeout(const Duration(seconds: 15));
      if (r.statusCode != 200) {
        throw LanError(tr(
            'Не удалось получить список (${r.statusCode}).',
            'Could not fetch the list (${r.statusCode}).',
            'No se pudo obtener la lista (${r.statusCode}).'));
      }
      final data = jsonDecode(r.body) as Map<String, dynamic>;
      total = (data['total'] ?? 0) as int;
      final items = (data['items'] as List? ?? const []);
      if (items.isEmpty) break;
      for (final raw in items) {
        final m = raw as Map<String, dynamic>;
        out.add(PhotoItem(
          path: (m['name'] ?? '') as String,
          isGif: (m['gif'] ?? false) as bool,
          isVideo: (m['video'] ?? false) as bool,
          folderPath: (m['folder'] ?? '') as String,
          folderName: (m['folder'] ?? '') as String,
          modified:
              DateTime.fromMillisecondsSinceEpoch((m['mtime'] ?? 0) as int),
          sizeBytes: (m['size'] ?? 0) as int,
          remoteBase: conn.base,
          remoteToken: conn.token,
          remoteId: (m['id'] ?? '') as String,
        ));
      }
      offset += items.length;
      if (offset >= total) break;
    }
    return out;
  }
}
