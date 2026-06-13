import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'model.dart';

/// Результат успешного подключения к хосту.
class LanConnection {
  final String base; // "http://192.168.1.5:8787"
  final String token;
  final String hostName;
  final int total;
  const LanConnection({
    required this.base,
    required this.token,
    required this.hostName,
    required this.total,
  });
}

/// Ошибка подключения с понятным пользователю текстом.
class LanError implements Exception {
  final String message;
  LanError(this.message);
  @override
  String toString() => message;
}

/// Клиент локальной сети: подключается к устройству-хосту и тянет его галерею.
class LanClient {
  /// Подключиться по адресу [ip]:[port] с PIN-кодом. Возвращает соединение
  /// с токеном сессии. Бросает [LanError] с человекочитаемым текстом.
  static Future<LanConnection> connect({
    required String ip,
    required int port,
    required String pin,
  }) async {
    final base = 'http://$ip:$port';

    // 1) проверка связи — это вообще GOAT?
    Map<String, dynamic> ping;
    try {
      final r = await http
          .get(Uri.parse('$base/ping'))
          .timeout(const Duration(seconds: 6));
      if (r.statusCode != 200) {
        throw LanError('Устройство ответило ошибкой (${r.statusCode}).');
      }
      ping = jsonDecode(r.body) as Map<String, dynamic>;
      if (ping['app'] != 'GOAT') {
        throw LanError('По этому адресу не GOAT.');
      }
    } on LanError {
      rethrow;
    } catch (_) {
      throw LanError('Не удалось связаться. Проверь адрес и одну ли вы Wi-Fi сеть.');
    }

    // 2) сопряжение по PIN
    try {
      final r = await http
          .get(Uri.parse('$base/pair?pin=$pin'))
          .timeout(const Duration(seconds: 6));
      if (r.statusCode == 429) {
        throw LanError('Слишком много попыток. Подожди полминуты и снова.');
      }
      if (r.statusCode == 403) {
        throw LanError('Неверный PIN.');
      }
      if (r.statusCode != 200) {
        throw LanError('Не удалось сопрячься (${r.statusCode}).');
      }
      final data = jsonDecode(r.body) as Map<String, dynamic>;
      return LanConnection(
        base: base,
        token: data['token'] as String,
        hostName: (data['name'] ?? ping['name'] ?? 'Устройство') as String,
        total: (ping['count'] ?? 0) as int,
      );
    } on LanError {
      rethrow;
    } catch (_) {
      throw LanError('Сбой при сопряжении. Попробуй ещё раз.');
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
        throw LanError('Не удалось получить список (${r.statusCode}).');
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
          folderPath: (m['folder'] ?? '') as String,
          folderName: (m['folder'] ?? '') as String,
          modified: DateTime.fromMillisecondsSinceEpoch((m['mtime'] ?? 0) as int),
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
