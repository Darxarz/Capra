import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'i18n.dart';

/// Номер текущей сборки. Вшивается при сборке через
/// `--dart-define=BUILD_NUMBER=...` (см. workflow). Локально/в отладке = 0,
/// поэтому обновления в режиме разработки не предлагаются.
const int kBuildNumber = int.fromEnvironment('BUILD_NUMBER', defaultValue: 0);

/// Публичный репозиторий с готовыми сборками — скачивание без ключей.
const String kRepo = 'Darxarz/Capra';

/// Адрес «последнего релиза» для проверки на тестовом сервере. Действует ТОЛЬКО
/// в debug/profile-сборках: в release `kReleaseMode` — константа true, и ветка
/// с этим адресом выбрасывается компилятором.
const String _testReleaseUrl = String.fromEnvironment('GOAT_UPDATE_TEST_URL');

/// Включена ли тестовая подмена адреса (никогда — в release-сборке).
bool get updateTestOverride => !kReleaseMode && _testReleaseUrl.isNotEmpty;

Uri get releaseApiUrl => updateTestOverride
    ? Uri.parse(_testReleaseUrl)
    : Uri.parse('https://api.github.com/repos/$kRepo/releases/latest');

/// Платформа с точки зрения обновлений: какой файл из релиза ей подходит.
enum UpdatePlatform { windows, android, other }

UpdatePlatform get currentUpdatePlatform {
  if (Platform.isWindows) return UpdatePlatform.windows;
  if (Platform.isAndroid) return UpdatePlatform.android;
  return UpdatePlatform.other;
}

/// Номер сборки из тега релиза: только «build-N», остальное не наше.
int? buildFromTag(String tag) {
  final m = RegExp(r'^build-(\d+)$').firstMatch(tag.trim());
  if (m == null) return null;
  return int.tryParse(m.group(1)!);
}

/// Предлагать ли обновление. Локальная/отладочная сборка (номер 0) не
/// обновляется никогда — так же, как раньше на Windows.
bool offersUpdate({required int current, required int latest}) =>
    current > 0 && latest > current;

/// Файл из релиза.
class ReleaseAsset {
  final String name;
  final String url;
  final int size; // байт; 0 — неизвестно

  /// sha256 в hex, если GitHub его сообщил (поле `digest` = "sha256:…").
  final String? sha256;
  const ReleaseAsset(
      {required this.name, required this.url, this.size = 0, this.sha256});

  static ReleaseAsset? fromJson(Object? a) {
    if (a is! Map) return null;
    final name = '${a['name'] ?? ''}';
    final url = a['browser_download_url'];
    if (name.isEmpty || url is! String || url.isEmpty) return null;
    final digest = '${a['digest'] ?? ''}'.toLowerCase();
    final sha = RegExp(r'^sha256:([0-9a-f]{64})$').firstMatch(digest)?.group(1);
    return ReleaseAsset(
      name: name,
      url: url,
      size: (a['size'] as num?)?.toInt() ?? 0,
      sha256: sha,
    );
  }
}

/// Выбор файла из релиза для платформы: Windows — архив .zip, Android — GOAT.apk.
/// На прочих платформах самообновления нет.
ReleaseAsset? pickAsset(List<Object?> assets, UpdatePlatform platform) {
  final all = assets.map(ReleaseAsset.fromJson).whereType<ReleaseAsset>().toList();
  bool ends(ReleaseAsset a, String ext) => a.name.toLowerCase().endsWith(ext);
  switch (platform) {
    case UpdatePlatform.windows:
      final zips = all.where((a) => ends(a, '.zip')).toList();
      if (zips.isEmpty) return null;
      return zips.firstWhere((a) => a.name.toLowerCase().contains('windows'),
          orElse: () => zips.first);
    case UpdatePlatform.android:
      for (final a in all) {
        if (a.name.toLowerCase() == 'goat.apk') return a;
      }
      final apks = all.where((a) => ends(a, '.apk')).toList();
      return apks.length == 1 ? apks.first : null;
    case UpdatePlatform.other:
      return null;
  }
}

/// Информация о доступном обновлении.
class UpdateInfo {
  final int build; // номер новой сборки
  final String downloadUrl; // прямая ссылка на файл (.zip или .apk)
  final String notes; // описание релиза
  final String assetName;
  final int size; // байт; 0 — неизвестно
  final String? sha256;
  const UpdateInfo({
    required this.build,
    required this.downloadUrl,
    required this.notes,
    this.assetName = '',
    this.size = 0,
    this.sha256,
  });
}

enum UpdateCheckStatus {
  available,
  upToDate,

  /// локальная или отладочная сборка — обновления не предлагаются
  disabled,

  /// на этой платформе самообновления нет
  unsupported,
  offline,

  /// GitHub ограничил число проверок с этого адреса
  rateLimited,
  failed,
}

class UpdateCheck {
  final UpdateCheckStatus status;
  final UpdateInfo? info;

  /// Когда GitHub снова разрешит проверку (для [UpdateCheckStatus.rateLimited]).
  final DateTime? retryAfter;
  const UpdateCheck(this.status, {this.info, this.retryAfter});
}

/// Разбор ответа GitHub `releases/latest` — без сети, чтобы проверять тестами.
UpdateCheck parseRelease(Map<String, dynamic> data,
    {required int current, required UpdatePlatform platform}) {
  final build = buildFromTag('${data['tag_name'] ?? ''}');
  if (build == null || !offersUpdate(current: current, latest: build)) {
    return const UpdateCheck(UpdateCheckStatus.upToDate);
  }
  final asset = pickAsset(data['assets'] as List? ?? const [], platform);
  if (asset == null) return const UpdateCheck(UpdateCheckStatus.upToDate);
  return UpdateCheck(
    UpdateCheckStatus.available,
    info: UpdateInfo(
      build: build,
      downloadUrl: asset.url,
      notes: '${data['body'] ?? ''}',
      assetName: asset.name,
      size: asset.size,
      sha256: asset.sha256,
    ),
  );
}

/// Ответ GitHub об ограничении частоты (403/429 с исчерпанным лимитом).
DateTime? rateLimitedUntil(int status, Map<String, String> headers) {
  if (status != 403 && status != 429) return null;
  final remaining = headers['x-ratelimit-remaining'];
  final retry = int.tryParse(headers['retry-after'] ?? '');
  if (status == 403 && remaining != '0' && retry == null) return null;
  if (retry != null) return DateTime.now().add(Duration(seconds: retry));
  final reset = int.tryParse(headers['x-ratelimit-reset'] ?? '');
  if (reset != null) {
    return DateTime.fromMillisecondsSinceEpoch(reset * 1000);
  }
  return DateTime.now().add(const Duration(hours: 1));
}

/// Проверка и установка обновлений из GitHub Releases (Windows и Android).
class UpdateService {
  /// Проверяет последний релиз. Наружу исключения не бросает (нет сети,
  /// ограничение GitHub и т.п. — это статус, а не ошибка).
  static Future<UpdateCheck> checkDetailed({
    http.Client? client,
    int current = kBuildNumber,
    UpdatePlatform? platform,
    Uri? url,
  }) async {
    final plat = platform ?? currentUpdatePlatform;
    if (plat == UpdatePlatform.other) {
      return const UpdateCheck(UpdateCheckStatus.unsupported);
    }
    if (current <= 0) return const UpdateCheck(UpdateCheckStatus.disabled);
    final c = client ?? http.Client();
    try {
      final r = await c.get(
        url ?? releaseApiUrl,
        headers: const {
          'User-Agent': 'GOAT-Updater',
          'Accept': 'application/vnd.github+json',
        },
      ).timeout(const Duration(seconds: 15));
      final limited = rateLimitedUntil(r.statusCode, r.headers);
      if (limited != null) {
        return UpdateCheck(UpdateCheckStatus.rateLimited, retryAfter: limited);
      }
      if (r.statusCode != 200) return const UpdateCheck(UpdateCheckStatus.failed);
      final data = jsonDecode(r.body);
      if (data is! Map<String, dynamic>) {
        return const UpdateCheck(UpdateCheckStatus.failed);
      }
      return parseRelease(data, current: current, platform: plat);
    } on SocketException {
      return const UpdateCheck(UpdateCheckStatus.offline);
    } on http.ClientException {
      return const UpdateCheck(UpdateCheckStatus.offline);
    } on TimeoutException {
      return const UpdateCheck(UpdateCheckStatus.offline);
    } catch (_) {
      return const UpdateCheck(UpdateCheckStatus.failed);
    } finally {
      if (client == null) c.close();
    }
  }

  /// Есть ли сборка новее текущей; null — нет (или проверить не удалось).
  static Future<UpdateInfo?> check() async => (await checkDetailed()).info;

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

    final tmp = Directory.systemTemp.createTempSync('goat_update_');
    final zipPath = p.join(tmp.path, 'update.zip');
    final extractDir = p.join(tmp.path, 'files');

    // — скачивание с прогрессом —
    final client = http.Client();
    try {
      final req = http.Request('GET', Uri.parse(info.downloadUrl))
        ..headers['User-Agent'] = 'GOAT-Updater';
      final resp = await client.send(req);
      if (resp.statusCode != 200) {
        throw HttpException(
            '${tr('Не удалось скачать', 'Could not download', 'No se pudo descargar')} (${tr('код', 'code', 'código')} ${resp.statusCode})');
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

    // — помощник-обновлятор на PowerShell (скрытое окно): ждёт выхода
    //   приложения, при необходимости закрывает принудительно (чтобы
    //   разблокировать файлы), копирует новые файлы и перезапускает —
    final exeBase = p.basenameWithoutExtension(exe);
    final ps1 = p.join(tmp.path, 'apply_update.ps1');
    final script = '''
\$ErrorActionPreference = 'SilentlyContinue'
# ждём штатного выхода приложения (до ~12 с)
for (\$i = 0; \$i -lt 24; \$i++) {
  if (-not (Get-Process -Name '$exeBase' -ErrorAction SilentlyContinue)) { break }
  Start-Sleep -Milliseconds 500
}
# если всё ещё живо — закрываем принудительно (иначе файлы заняты)
if (Get-Process -Name '$exeBase' -ErrorAction SilentlyContinue) {
  Stop-Process -Name '$exeBase' -Force -ErrorAction SilentlyContinue
  Start-Sleep -Milliseconds 800
}
Expand-Archive -LiteralPath '$zipPath' -DestinationPath '$extractDir' -Force
robocopy '$extractDir' '$installDir' /E /IS /IT /R:2 /W:1 /NFL /NDL /NJH /NJS /NC /NS | Out-Null
Start-Process -FilePath '$exe' -WorkingDirectory '$installDir'
Remove-Item '$zipPath' -Force -ErrorAction SilentlyContinue
Remove-Item '$extractDir' -Recurse -Force -ErrorAction SilentlyContinue
''';
    await File(ps1).writeAsString(script);

    // Запускаем помощник через `cmd /c start` — так он становится полностью
    // независимым процессом и переживает выход приложения. Прямой detached-
    // запуск powershell этого НЕ гарантирует (процесс гибнет вместе с
    // родителем — проверено), поэтому обновление не применялось.
    await Process.start(
      'cmd.exe',
      [
        '/c',
        'start',
        '/min',
        '',
        'powershell',
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-WindowStyle',
        'Hidden',
        '-File',
        ps1,
      ],
      mode: ProcessStartMode.detached,
      runInShell: false,
    );
    exit(0);
  }
}
