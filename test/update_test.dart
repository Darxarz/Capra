import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goat/android_update.dart';
import 'package:goat/settings_service.dart';
import 'package:goat/theme.dart';
import 'package:goat/update_download.dart';
import 'package:goat/update_service.dart';
import 'package:goat_update/goat_update.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;

Map<String, dynamic> release(int build, List<Map<String, dynamic>> assets) => {
      'tag_name': 'build-$build',
      'body': 'notes',
      'assets': assets,
    };

Map<String, dynamic> asset(String name, {int size = 10, String? digest}) => {
      'name': name,
      'browser_download_url': 'https://github.com/Darxarz/Capra/releases/download/x/$name',
      'size': size,
      if (digest != null) 'digest': digest,
    };

final _allAssets = [
  asset('GOAT-windows.zip'),
  asset('GOAT.apk', size: 146985958),
  asset('GOAT-linux.tar.gz'),
];

/// A tiny raw-socket HTTP server: serves [body] with Range support, and with
/// [cutAfter] drops the first transfer mid-file, as a lost Wi-Fi would.
class _FileServer {
  final List<int> body;
  int? cutAfter;
  bool ignoreRange = false;
  bool redirectFirst = false;
  final List<String?> ranges = [];
  late ServerSocket server;
  late int port;

  _FileServer(this.body);

  Uri get url => Uri.parse('http://127.0.0.1:$port/GOAT.apk');

  Future<void> start() async {
    server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    port = server.port;
    server.listen((socket) {
      final head = <int>[];
      late StreamSubscription<List<int>> sub;
      sub = socket.listen((data) async {
        head.addAll(data);
        final text = latin1.decode(head, allowInvalid: true);
        if (!text.contains('\r\n\r\n')) return;
        await sub.cancel();
        await _answer(socket, text);
      }, onError: (_) {});
    });
  }

  Future<void> _answer(Socket socket, String request) async {
    final path = request.split(' ')[1];
    if (redirectFirst && path == '/GOAT.apk') {
      socket.add(latin1.encode('HTTP/1.1 302 Found\r\nLocation: /objects/GOAT.apk\r\n'
          'Content-Length: 0\r\nConnection: close\r\n\r\n'));
      await socket.flush();
      socket.destroy();
      return;
    }
    final range = RegExp(r'^range: *(.*)$', caseSensitive: false, multiLine: true)
        .firstMatch(request)
        ?.group(1)
        ?.trim();
    ranges.add(range);
    var from = 0;
    final m = RegExp(r'bytes=(\d+)-').firstMatch(range ?? '');
    if (m != null && !ignoreRange) from = int.parse(m.group(1)!);
    if (from >= body.length && from > 0) {
      socket.add(latin1.encode(
          'HTTP/1.1 416 Range Not Satisfiable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n'));
      await socket.flush();
      socket.destroy();
      return;
    }
    final slice = body.sublist(from);
    final status = from > 0 ? '206 Partial Content' : '200 OK';
    final extra =
        from > 0 ? 'Content-Range: bytes $from-${body.length - 1}/${body.length}\r\n' : '';
    socket.add(latin1.encode('HTTP/1.1 $status\r\nContent-Length: ${slice.length}\r\n'
        '${extra}Connection: close\r\n\r\n'));
    final cut = cutAfter;
    cutAfter = null;
    socket.add(cut == null ? slice : slice.sublist(0, cut));
    await socket.flush();
    socket.destroy();
  }

  Future<void> stop() => server.close();
}

class _FakeApi implements GoatUpdateApi {
  final String dir;
  bool allowed;
  bool grantOnSettings = true;
  int settingsOpened = 0;
  final List<String> installed = [];
  InstallOutcome outcome = InstallOutcome.canceled;
  ApkFacts facts = const ApkFacts(
      readable: true,
      package: 'com.example.goat',
      ownPackage: 'com.example.goat',
      versionCode: 2,
      installedVersionCode: 1,
      sameSigner: true);
  _FakeApi(this.dir, {this.allowed = true});

  @override
  Future<bool> canInstall() async => allowed;
  @override
  Future<int> freeSpace() async => 1 << 40;
  @override
  Future<ApkFacts> inspect(String path) async => facts;
  @override
  Future<InstallOutcome> install(String path) async {
    installed.add(path);
    return outcome;
  }

  @override
  Future<bool> openInstallSettings() async {
    settingsOpened++;
    allowed = grantOnSettings;
    return allowed;
  }

  @override
  Future<String> updateDir() async => dir;
}

void main() {
  SettingsService.instance.appLang = AppLang.ru;
  // widget tests swap in a fake HttpClient that answers 400; these talk to a
  // real local server, so use the real client
  setUp(() => HttpOverrides.global = null);

  group('version comparison', () {
    test('only build-N tags count', () {
      expect(buildFromTag('build-97'), 97);
      expect(buildFromTag(' build-5 '), 5);
      expect(buildFromTag('build-'), isNull);
      expect(buildFromTag('build-12a'), isNull);
      expect(buildFromTag('v1.2.3'), isNull);
      expect(buildFromTag(''), isNull);
    });

    test('newer only, and never for local or debug builds (0)', () {
      expect(offersUpdate(current: 96, latest: 97), isTrue);
      expect(offersUpdate(current: 97, latest: 97), isFalse);
      expect(offersUpdate(current: 98, latest: 97), isFalse);
      expect(offersUpdate(current: 0, latest: 97), isFalse);
      expect(offersUpdate(current: 0, latest: 1), isFalse);
    });
  });

  group('asset per platform', () {
    test('Windows takes the zip, Android takes GOAT.apk, others nothing', () {
      expect(pickAsset(_allAssets, UpdatePlatform.windows)?.name, 'GOAT-windows.zip');
      expect(pickAsset(_allAssets, UpdatePlatform.android)?.name, 'GOAT.apk');
      expect(pickAsset(_allAssets, UpdatePlatform.android)?.size, 146985958);
      expect(pickAsset(_allAssets, UpdatePlatform.other), isNull);
    });

    test('Android without an APK has no update; two unknown APKs are ambiguous', () {
      expect(pickAsset([asset('GOAT-windows.zip')], UpdatePlatform.android), isNull);
      expect(pickAsset([asset('a.apk'), asset('b.apk')], UpdatePlatform.android), isNull);
      expect(pickAsset([asset('other.apk')], UpdatePlatform.android)?.name, 'other.apk');
      expect(pickAsset([asset('a.apk'), asset('goat.APK')], UpdatePlatform.android)?.name,
          'goat.APK');
    });

    test('Windows prefers the windows zip when there are several', () {
      expect(
          pickAsset([asset('extra.zip'), asset('GOAT-windows.zip')], UpdatePlatform.windows)
              ?.name,
          'GOAT-windows.zip');
    });

    test('sha256 digest is read when GitHub gives it', () {
      final d = 'a' * 64;
      expect(pickAsset([asset('GOAT.apk', digest: 'sha256:$d')], UpdatePlatform.android)?.sha256,
          d);
      expect(pickAsset([asset('GOAT.apk', digest: 'md5:00')], UpdatePlatform.android)?.sha256,
          isNull);
    });

    test('parseRelease builds the offer for the right file', () {
      final r = parseRelease(release(97, _allAssets), current: 96, platform: UpdatePlatform.android);
      expect(r.status, UpdateCheckStatus.available);
      expect(r.info!.build, 97);
      expect(r.info!.assetName, 'GOAT.apk');
      expect(r.info!.downloadUrl, endsWith('/GOAT.apk'));
      final w = parseRelease(release(97, _allAssets), current: 96, platform: UpdatePlatform.windows);
      expect(w.info!.assetName, 'GOAT-windows.zip');
      expect(
          parseRelease(release(97, _allAssets), current: 97, platform: UpdatePlatform.android)
              .status,
          UpdateCheckStatus.upToDate);
      expect(
          parseRelease(release(97, _allAssets), current: 0, platform: UpdatePlatform.android).info,
          isNull);
    });
  });

  group('check', () {
    test('debug build (0) never asks GitHub and offers nothing', () async {
      var calls = 0;
      final client = MockClient((_) async {
        calls++;
        return http.Response(jsonEncode(release(500, _allAssets)), 200);
      });
      for (final plat in UpdatePlatform.values) {
        final r = await UpdateService.checkDetailed(client: client, current: 0, platform: plat);
        expect(r.info, isNull);
      }
      expect(calls, 0);
      expect(kBuildNumber, 0, reason: 'tests run as a local build');
      expect(await UpdateService.check(), isNull);
    });

    test('newer release with GOAT.apk is offered on Android', () async {
      final client = MockClient(
          (_) async => http.Response(jsonEncode(release(97, _allAssets)), 200));
      final r = await UpdateService.checkDetailed(
          client: client, current: 1, platform: UpdatePlatform.android);
      expect(r.status, UpdateCheckStatus.available);
      expect(r.info!.assetName, 'GOAT.apk');
    });

    test('rate limit, failure and no network are statuses, not crashes', () async {
      final limited = MockClient((_) async => http.Response('{}', 403,
          headers: {'x-ratelimit-remaining': '0', 'x-ratelimit-reset': '2000000000'}));
      final r1 = await UpdateService.checkDetailed(
          client: limited, current: 1, platform: UpdatePlatform.android);
      expect(r1.status, UpdateCheckStatus.rateLimited);
      expect(r1.retryAfter, DateTime.fromMillisecondsSinceEpoch(2000000000 * 1000));

      final broken = MockClient((_) async => http.Response('oops', 500));
      expect(
          (await UpdateService.checkDetailed(
                  client: broken, current: 1, platform: UpdatePlatform.android))
              .status,
          UpdateCheckStatus.failed);

      final notJson = MockClient((_) async => http.Response('<html>', 200));
      expect(
          (await UpdateService.checkDetailed(
                  client: notJson, current: 1, platform: UpdatePlatform.android))
              .status,
          UpdateCheckStatus.failed);

      final offline = MockClient((_) async => throw const SocketException('no route'));
      expect(
          (await UpdateService.checkDetailed(
                  client: offline, current: 1, platform: UpdatePlatform.android))
              .status,
          UpdateCheckStatus.offline);
    });

    test('a plain 403 is a failure, not a rate limit', () {
      expect(rateLimitedUntil(403, {'x-ratelimit-remaining': '12'}), isNull);
      expect(rateLimitedUntil(429, const {}), isNotNull);
      expect(rateLimitedUntil(200, {'x-ratelimit-remaining': '0'}), isNull);
    });

    test('release builds cannot point the check elsewhere', () {
      // tests are not release builds, but no override is defined here either
      expect(updateTestOverride, isFalse);
      expect(releaseApiUrl.toString(),
          'https://api.github.com/repos/Darxarz/Capra/releases/latest');
    });
  });

  group('update files', () {
    test('keep only what is still useful', () {
      expect(keepUpdateFile(97, current: 96, offered: 97, latestKnown: true), isTrue);
      expect(keepUpdateFile(96, current: 96, offered: 97, latestKnown: true), isFalse);
      expect(keepUpdateFile(95, current: 96, offered: null, latestKnown: false), isFalse);
      expect(keepUpdateFile(98, current: 96, offered: 99, latestKnown: true), isFalse);
      expect(keepUpdateFile(98, current: 96, offered: null, latestKnown: false), isTrue);
      expect(keepUpdateFile(null, current: 96, offered: 97, latestKnown: true), isFalse);
    });

    test('names and clean-up', () async {
      expect(updateFileBuild(updateApkName(97)), 97);
      expect(updateFileBuild(updatePartName(97, 123)), 97);
      expect(updateFileBuild('notes.txt'), isNull);
      final dir = await Directory.systemTemp.createTemp('goat_update_test');
      addTearDown(() => dir.delete(recursive: true));
      for (final n in [updateApkName(96), updatePartName(97, 5), 'stray.bin']) {
        await File(p.join(dir.path, n)).writeAsString('x');
      }
      final removed = await cleanUpdateDir(
          dir, (b) => keepUpdateFile(b, current: 96, offered: 97, latestKnown: true));
      expect(removed, 2);
      expect(dir.listSync().map((e) => p.basename(e.path)), [updatePartName(97, 5)]);
    });

    test('space needed covers the rest, the installer copy and a margin', () {
      const mb = 1024 * 1024;
      expect(updateSpaceNeeded(100 * mb, 0), 264 * mb);
      expect(updateSpaceNeeded(100 * mb, 60 * mb), 204 * mb);
      expect(updateSpaceNeeded(0, 0), 0);
    });
  });

  group('resumable download', () {
    late Directory dir;
    late _FileServer srv;
    final rnd = Random(7);
    final body = List<int>.generate(3 * 1024 * 1024 + 17, (i) => rnd.nextInt(256));
    final sha = sha256.convert(body).toString();

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('goat_dl_test');
      srv = _FileServer(body);
      await srv.start();
    });
    tearDown(() async {
      await srv.stop();
      await dir.delete(recursive: true);
    });

    Future<File> fetch({String? hash, DownloadCancel? cancel, bool allowHttp = true}) =>
        ResumableDownload.fetch(
          url: srv.url,
          dir: dir,
          build: 2,
          size: body.length,
          sha256: hash ?? sha,
          allowHttp: allowHttp,
          cancel: cancel,
          stallTimeout: const Duration(seconds: 5),
        );

    test('downloads, verifies and names the file by build', () async {
      srv.redirectFirst = true;
      final f = await fetch();
      expect(p.basename(f.path), updateApkName(2));
      expect(await f.readAsBytes(), body);
      expect(File(p.join(dir.path, updatePartName(2, body.length))).existsSync(), isFalse);
    });

    test('a dropped connection resumes from where it stopped', () async {
      srv.cutAfter = 1024 * 1024;
      await expectLater(
          fetch(),
          throwsA(isA<DownloadFailure>()
              .having((f) => f.kind, 'kind', DownloadFailureKind.offline)));
      final part = File(p.join(dir.path, updatePartName(2, body.length)));
      expect(part.lengthSync(), 1024 * 1024);
      final f = await fetch();
      expect(srv.ranges.last, 'bytes=${1024 * 1024}-');
      expect(await f.readAsBytes(), body);
    });

    test('a server that ignores Range gives a clean restart, not a mixed file', () async {
      srv.cutAfter = 500000;
      await expectLater(fetch(), throwsA(isA<DownloadFailure>()));
      srv.ignoreRange = true;
      final f = await fetch();
      expect(await f.readAsBytes(), body);
    });

    test('a finished file is reused without downloading again', () async {
      await fetch();
      final before = srv.ranges.length;
      final f = await fetch();
      expect(srv.ranges.length, before);
      expect(await f.readAsBytes(), body);
    });

    test('wrong checksum throws the file away', () async {
      await expectLater(
          fetch(hash: 'b' * 64),
          throwsA(isA<DownloadFailure>()
              .having((f) => f.kind, 'kind', DownloadFailureKind.corrupt)));
      expect(dir.listSync(), isEmpty);
    });

    test('plain http is refused outside the test override', () async {
      await expectLater(
          fetch(allowHttp: false),
          throwsA(isA<DownloadFailure>()
              .having((f) => f.kind, 'kind', DownloadFailureKind.insecure)));
      expect(srv.ranges, isEmpty);
    });

    test('cancel stops it and keeps what arrived', () async {
      final cancel = DownloadCancel()..cancel();
      await expectLater(
          fetch(cancel: cancel),
          throwsA(isA<DownloadFailure>()
              .having((f) => f.kind, 'kind', DownloadFailureKind.canceled)));
    });

    test('no network is reported as offline', () async {
      await srv.stop();
      await expectLater(
          fetch(),
          throwsA(isA<DownloadFailure>()
              .having((f) => f.kind, 'kind', DownloadFailureKind.offline)));
    });
  });

  group('downloaded APK checks', () {
    const ok = ApkFacts(
        readable: true,
        package: 'com.example.goat',
        ownPackage: 'com.example.goat',
        versionCode: 97,
        installedVersionCode: 1,
        sameSigner: true);
    test('a proper update passes; strangers, older builds and other keys do not', () {
      expect(apkProblem(ok), isNull);
      expect(
          apkProblem(const ApkFacts(
              readable: true,
              package: 'com.example.goat',
              ownPackage: 'com.example.goat',
              versionCode: 1,
              installedVersionCode: 1)),
          isNull,
          reason: 'same version code and unknown signer: Android decides');
      expect(apkProblem(const ApkFacts(readable: false)), isNotNull);
      expect(
          apkProblem(const ApkFacts(
              readable: true, package: 'evil.app', ownPackage: 'com.example.goat')),
          isNotNull);
      expect(
          apkProblem(const ApkFacts(
              readable: true,
              package: 'com.example.goat',
              ownPackage: 'com.example.goat',
              versionCode: 1,
              installedVersionCode: 97)),
          isNotNull);
      expect(
          apkProblem(const ApkFacts(
              readable: true,
              package: 'com.example.goat',
              ownPackage: 'com.example.goat',
              versionCode: 98,
              installedVersionCode: 97,
              sameSigner: false)),
          contains('другим ключом'));
    });
  });

  group('tablet update dialog', () {
    final body = List<int>.generate(700000, (i) => (i * 31) & 0xff);

    Widget host(Widget dialog) {
      final s = SettingsService.instance;
      final colors =
          composeColors(resolveBase(s.darkBaseId, Brightness.dark), resolveAccent(s.accentId));
      return AuroraTheme(
        colors: colors,
        child: MaterialApp(
          theme: colors.toThemeData(),
          home: Builder(
            builder: (c) => Scaffold(
              body: TextButton(
                onPressed: () => showDialog<void>(
                    context: c, barrierDismissible: false, builder: (_) => dialog),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
    }

    Future<void> until(WidgetTester t, Finder f) async {
      for (var i = 0; i < 200 && f.evaluate().isEmpty; i++) {
        await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await t.pump();
      }
      expect(f, findsOneWidget);
    }

    testWidgets('unknown apps not allowed: explains, opens settings, then installs',
        (t) async {
      final (dir, srv) = (await t.runAsync(() async {
        final d = await Directory.systemTemp.createTemp('goat_dialog_test');
        final s = _FileServer(body);
        await s.start();
        return (d, s);
      }))!;
      addTearDown(() => t.runAsync(() async {
            await srv.stop();
            await dir.delete(recursive: true);
          }));
      final api = _FakeApi(dir.path, allowed: false);
      final info = UpdateInfo(
          build: 2, downloadUrl: srv.url.toString(), notes: '', size: body.length);
      await t.pumpWidget(host(AndroidUpdateDialog(
          info: info, updater: AndroidUpdater(api), allowPlainHttp: true)));
      await t.tap(find.text('open'));
      await until(t, find.textContaining('включите переключатель'));
      expect(api.installed, isEmpty);

      // the owner comes back without turning the switch on
      api.grantOnSettings = false;
      await t.tap(find.text('Открыть настройки'));
      await until(t, find.textContaining('пока выключен'));
      expect(api.installed, isEmpty);

      // second time it is on: download, check, installer
      api.grantOnSettings = true;
      await t.tap(find.text('Открыть настройки'));
      await until(t, find.textContaining('Установка отменена'));
      expect(api.settingsOpened, 2);
      expect(api.installed, hasLength(1));
      expect(p.basename(api.installed.single), updateApkName(2));
      expect(await t.runAsync(() => File(api.installed.single).readAsBytes()), body);
    });

    testWidgets('a key mismatch is explained and the file removed', (t) async {
      final (dir, srv) = (await t.runAsync(() async {
        final d = await Directory.systemTemp.createTemp('goat_dialog_test');
        final s = _FileServer(body);
        await s.start();
        return (d, s);
      }))!;
      addTearDown(() => t.runAsync(() async {
            await srv.stop();
            await dir.delete(recursive: true);
          }));
      final api = _FakeApi(dir.path)
        ..facts = const ApkFacts(
            readable: true,
            package: 'com.example.goat',
            ownPackage: 'com.example.goat',
            versionCode: 2,
            installedVersionCode: 1,
            sameSigner: false);
      final info = UpdateInfo(
          build: 2, downloadUrl: srv.url.toString(), notes: '', size: body.length);
      await t.pumpWidget(host(AndroidUpdateDialog(
          info: info, updater: AndroidUpdater(api), allowPlainHttp: true)));
      await t.tap(find.text('open'));
      await until(t, find.textContaining('другим ключом'));
      expect(api.installed, isEmpty);
      expect(await t.runAsync(() => dir.list().toList()), isEmpty);
    });

    testWidgets('no network: says so, keeps the app usable', (t) async {
      final dir = (await t.runAsync(() => Directory.systemTemp.createTemp('goat_dialog_test')))!;
      addTearDown(() => t.runAsync(() => dir.delete(recursive: true)));
      final api = _FakeApi(dir.path);
      const info = UpdateInfo(
          build: 2, downloadUrl: 'http://127.0.0.1:9/GOAT.apk', notes: '', size: 1000);
      await t.pumpWidget(host(AndroidUpdateDialog(
          info: info, updater: AndroidUpdater(api), allowPlainHttp: true)));
      await t.tap(find.text('open'));
      await until(t, find.textContaining('Нет связи с интернетом'));
      await t.tap(find.text('Закрыть'));
      await t.pump();
      expect(find.byType(AndroidUpdateDialog), findsNothing);
      expect(find.text('open'), findsOneWidget);
    });
  });
}
