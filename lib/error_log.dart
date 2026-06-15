import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Простой файловый журнал: пишет ошибки и события в `goat_log.txt` рядом с БД
/// приложения. Нужен для диагностики крашей/зависаний на устройствах, к которым
/// нет прямого доступа (тестер присылает файл через «Поделиться журналом»).
class ErrorLog {
  ErrorLog._();
  static File? _file;
  static final List<String> _recent = [];

  /// Путь к файлу журнала (или null, если не инициализирован).
  static String? get path => _file?.path;

  /// Последние строки из текущего сеанса (для показа в настройках).
  static List<String> get recent => List.unmodifiable(_recent);

  static Future<void> init() async {
    try {
      final dir = await getApplicationSupportDirectory();
      final f = File(p.join(dir.path, 'goat_log.txt'));
      // не даём журналу разрастаться: при >1 МБ начинаем заново
      if (await f.exists() && await f.length() > 1024 * 1024) {
        await f.writeAsString('');
      }
      _file = f;
      record('=== запуск GOAT (${Platform.operatingSystem}) ===');
    } catch (_) {
      // журнал — необязательная штука, без него приложение работает
    }
  }

  static void record(String msg) {
    final line = '[${DateTime.now().toIso8601String()}] $msg';
    _recent.add(line);
    if (_recent.length > 60) _recent.removeAt(0);
    try {
      _file?.writeAsStringSync('$line\n', mode: FileMode.append, flush: true);
    } catch (_) {}
  }

  static void recordError(Object error, StackTrace? stack) {
    record('ОШИБКА: $error${stack != null ? '\n$stack' : ''}');
  }

  /// Всё содержимое журнала (для копирования/отправки).
  static Future<String> readAll() async {
    try {
      final f = _file;
      if (f != null && await f.exists()) return await f.readAsString();
    } catch (_) {}
    return _recent.join('\n');
  }
}
