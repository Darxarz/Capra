import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

/// Номер текущей сборки. Вшивается при сборке через
/// `--dart-define=BUILD_NUMBER=...` (см. workflow). Локально/в отладке = 0,
/// поэтому обновления в режиме разработки не предлагаются.
const int kBuildNumber = int.fromEnvironment('BUILD_NUMBER', defaultValue: 0);

/// Публичный репозиторий с готовыми сборками — скачивание без ключей.
const String kRepo = 'Darxarz/Capra';

/// Информация о доступном обновлении.
class UpdateInfo {
  final int build; // номер новой сборки
  final String downloadUrl; // прямая ссылка на .zip
  final String notes; // описание релиза
  const UpdateInfo({
    required this.build,
    required this.downloadUrl,
    required this.notes,
  });
}

/// Проверка и установка обновлений из GitHub Releases (только Windows).
class UpdateService {
  /// Проверяет последний релиз. Возвращает [UpdateInfo], если есть сборка
  /// новее текущей, иначе null. Наружу исключения не бросает (нет сети и т.п.).
  static Future<UpdateInfo?> check() async {
    if (!Platform.isWindows) return null;
    try {
      final r = await http
          .get(
            Uri.parse('https://api.github.com/repos/$kRepo/releases/latest'),
            headers: const {
              'User-Agent': 'Capra-Updater',
              'Accept': 'application/vnd.github+json',
            },
          )
          .timeout(const Duration(seconds: 10));
      if (r.statusCode != 200) return null;

      final data = jsonDecode(r.body) as Map<String, dynamic>;
      final tag = (data['tag_name'] ?? '') as String; // ожидаем "build-N"
      final build = int.tryParse(tag.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0;
      if (build <= kBuildNumber) return null;

      // ищем приложенный .zip
      String? url;
      for (final a in (data['assets'] as List? ?? const [])) {
        final name = ((a as Map)['name'] ?? '') as String;
        if (name.toLowerCase().endsWith('.zip')) {
          url = a['browser_download_url'] as String?;
          break;
        }
      }
      if (url == null) return null;

      return UpdateInfo(
        build: build,
        downloadUrl: url,
        notes: (data['body'] ?? '') as String,
      );
    } catch (_) {
      return null;
    }
  }

  /// Скачивает обновление и применяет его: распаковка, замена файлов рядом с
  /// приложением и перезапуск. В конце завершает текущий процесс (`exit(0)`),
  /// чтобы освободить файлы — поэтому метод не возвращает управление при успехе.
  ///
  /// [onProgress] получает долю скачанного 0..1 (или null, если размер неизвестен).
  static Future<void> downloadAndApply(
    UpdateInfo info, {
    void Function(double? progress)? onProgress,
  }) async {
    final exe = Platform.resolvedExecutable; // полный путь к .exe
    final installDir = p.dirname(exe);
    final exeName = p.basename(exe);

    final tmp = Directory.systemTemp.createTempSync('capra_update_');
    final zipPath = p.join(tmp.path, 'update.zip');
    final extractDir = p.join(tmp.path, 'files');

    // — скачивание с прогрессом —
    final client = http.Client();
    try {
      final req = http.Request('GET', Uri.parse(info.downloadUrl))
        ..headers['User-Agent'] = 'Capra-Updater';
      final resp = await client.send(req);
      if (resp.statusCode != 200) {
        throw HttpException('Не удалось скачать (код ${resp.statusCode})');
      }
      final total = resp.contentLength ?? -1;
      var received = 0;
      final sink = File(zipPath).openWrite();
      await for (final chunk in resp.stream) {
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call(total > 0 ? received / total : null);
      }
      await sink.close();
    } finally {
      client.close();
    }

    // — помощник-обновлятор: ждёт выхода приложения, распаковывает zip,
    //   копирует файлы поверх установленных и перезапускает приложение —
    final bat = p.join(tmp.path, 'apply_update.bat');
    final script = '''
@echo off
chcp 65001 >nul
:wait
tasklist /FI "IMAGENAME eq $exeName" 2>nul | find /I "$exeName" >nul
if not errorlevel 1 (
  timeout /t 1 /nobreak >nul
  goto wait
)
powershell -NoProfile -ExecutionPolicy Bypass -Command "Expand-Archive -LiteralPath '$zipPath' -DestinationPath '$extractDir' -Force"
robocopy "$extractDir" "$installDir" /E /IS /IT /R:3 /W:1 /NFL /NDL /NJH /NJS /NC /NS >nul
start "" "$exe"
del "$zipPath" >nul 2>&1
rmdir /S /Q "$extractDir" >nul 2>&1
(goto) 2>nul & del "%~f0"
''';
    await File(bat).writeAsString(script);

    // запускаем помощник отдельным процессом и выходим — иначе файлы заняты
    await Process.start(
      'cmd.exe',
      ['/c', bat],
      mode: ProcessStartMode.detached,
      runInShell: false,
    );
    exit(0);
  }
}
