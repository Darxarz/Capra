import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:goat_link/goat_link.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'link_images.dart';
import 'link_index.dart';

// Состояние связи с коллекцией на ПК. Сеть и токены — целиком у Goat Explorer;
// галерея держит только разрешение Android на чтение и свою отдельную базу.

enum LinkPhase {
  off, // не Android
  notInstalled, // нет Goat Explorer
  needsConnect, // Explorer есть, коллекция ещё не подключена
  connecting, // открыт экран Explorer
  checking, // спрашиваем ПК
  importing, // копируем и разбираем индекс
  ready, // можно смотреть
  offline, // ПК выключен или в другой сети
  noPc, // в Explorer нет сопряжённого ПК
  noCollection, // на ПК нет коллекции
  revoked, // разрешение отозвано
  failed,
}

/// Нужно ли заново брать индекс с ПК.
bool linkNeedsImport({required String? stored, required String? live}) {
  if (live == null || live.isEmpty) return false;
  return stored != live;
}

class LinkService extends ChangeNotifier {
  LinkService({GoatLinkApi? api, this.supportDir, this.cacheDir, bool? enabled})
      : _api = api,
        _enabled = enabled ?? Platform.isAndroid;

  static final LinkService instance = LinkService();

  GoatLinkApi? _api;
  final bool _enabled;
  String? supportDir;
  String? cacheDir;

  GoatLinkApi get api => _api ??= MethodChannelGoatLink();

  LinkPhase phase = LinkPhase.off;
  LinkConnection? connection;
  LinkDb? db;
  int dbRevision = 0; // растёт при каждой подмене базы
  int handoffSerial = 0; // растёт, когда Explorer передаёт коллекцию
  bool explorerInstalled = false;
  double? progress; // 0..1 во время копирования/импорта
  bool copying = false;
  String? lastError;

  StreamSubscription<void>? _handoffSub;
  Future<void>? _running;
  bool _started = false;

  /// Открывать экран коллекции сам: есть подключение или только что передано.
  bool get hasConnection => connection != null;

  /// Базу можно показывать (в том числе когда ПК сейчас не в сети).
  bool get canBrowse =>
      db != null &&
      (phase == LinkPhase.ready ||
          phase == LinkPhase.offline ||
          phase == LinkPhase.checking ||
          phase == LinkPhase.importing);

  void _set(LinkPhase next) {
    phase = next;
    notifyListeners();
  }

  Future<String> _support() async {
    final dir = supportDir ??
        p.join((await getApplicationSupportDirectory()).path, 'goat_link');
    supportDir = dir;
    await Directory(dir).create(recursive: true);
    return dir;
  }

  Future<String> _cache() async {
    final dir =
        cacheDir ?? p.join((await getTemporaryDirectory()).path, 'goat_link');
    cacheDir = dir;
    await Directory(dir).create(recursive: true);
    return dir;
  }

  static String _safeName(String id) =>
      id.replaceAll(RegExp(r'[^0-9A-Za-z_-]'), '_');

  Future<String> _dbPath(String collectionId) async =>
      p.join(await _support(), '${_safeName(collectionId)}.sqlite3');

  /// Запуск приложения: подхватить подключение и открыть коллекцию.
  Future<void> start() async {
    if (!_enabled || _started) return;
    _started = true;
    LinkLoads.instance.api = api;
    _handoffSub = api.handoffs.listen((_) => unawaited(onHandoff()));
    try {
      explorerInstalled = await api.explorerInstalled();
      await api.takeHandoff(); // сохранённое ниже уже содержит передачу
      connection = await api.saved();
    } catch (e) {
      lastError = '$e';
    }
    if (connection == null) {
      _set(explorerInstalled ? LinkPhase.needsConnect : LinkPhase.notInstalled);
      return;
    }
    await refresh();
  }

  /// Explorer передал коллекцию, пока приложение работает.
  Future<void> onHandoff() async {
    try {
      await api.takeHandoff();
      explorerInstalled = await api.explorerInstalled();
      connection = await api.saved();
    } catch (e) {
      lastError = '$e';
    }
    handoffSerial++;
    if (connection != null) await refresh();
  }

  /// «Подключить коллекцию»: экран Explorer и его ответ.
  Future<ConnectStatus> connect() async {
    if (phase == LinkPhase.connecting) return ConnectStatus.failed;
    final before = phase;
    _set(LinkPhase.connecting);
    final ConnectResult r;
    try {
      r = await api.connect();
    } catch (_) {
      _set(before);
      return ConnectStatus.failed;
    }
    switch (r.status) {
      case ConnectStatus.ok:
        connection = r.connection ?? await api.saved();
        if (connection == null) {
          _set(LinkPhase.failed);
        } else {
          await refresh();
        }
      case ConnectStatus.canceled:
        _set(before == LinkPhase.connecting ? LinkPhase.needsConnect : before);
      case ConnectStatus.noPc:
        _set(LinkPhase.noPc);
      case ConnectStatus.offline:
        _set(LinkPhase.offline);
      case ConnectStatus.noCollection:
        _set(LinkPhase.noCollection);
      case ConnectStatus.notInstalled:
        explorerInstalled = false;
        _set(LinkPhase.notInstalled);
      case ConnectStatus.outdated:
      case ConnectStatus.failed:
        lastError = r.status.name;
        _set(LinkPhase.failed);
    }
    return r.status;
  }

  /// Проверить ПК и при новом индексе обновить базу. Повторный вызов во время
  /// работы присоединяется к уже идущей проверке.
  Future<void> refresh() => _running ??= _refresh().whenComplete(() {
        _running = null;
      });

  Future<void> _refresh() async {
    final conn = connection;
    if (conn == null) return;
    try {
      explorerInstalled = await api.explorerInstalled();
    } catch (_) {}
    await _openExisting(conn);
    _set(LinkPhase.checking);
    final ProbeResult probe;
    try {
      probe =
          await api.probe(conn.treeUri).timeout(const Duration(seconds: 25));
    } on TimeoutException {
      _set(LinkPhase.offline);
      return;
    } catch (_) {
      _set(LinkPhase.offline);
      return;
    }
    switch (probe.state) {
      case ProbeState.ok:
        break;
      case ProbeState.offline:
        _set(LinkPhase.offline);
        return;
      case ProbeState.noCollection:
        _closeDb();
        _set(LinkPhase.noCollection);
        return;
      case ProbeState.revoked:
        _closeDb();
        _set(LinkPhase.revoked);
        return;
      case ProbeState.notInstalled:
        _closeDb();
        explorerInstalled = false;
        _set(LinkPhase.notInstalled);
        return;
    }

    final live = probe.indexVersion ?? conn.indexVersion;
    final dbPath = await _dbPath(conn.collectionId);
    final stored = await compute(_readVersion, (dbPath, conn.collectionId));
    if (!linkNeedsImport(stored: stored, live: live) && db != null) {
      _set(LinkPhase.ready);
      return;
    }
    await _import(conn, live, dbPath);
  }

  Future<void> _openExisting(LinkConnection conn) async {
    final d = db;
    if (d != null &&
        d.collectionId == conn.collectionId &&
        d.treeUri == conn.treeUri) {
      return;
    }
    _closeDb();
    final path = await _dbPath(conn.collectionId);
    final version = await compute(_readVersion, (path, conn.collectionId));
    if (version == null) return;
    try {
      db = LinkDb.open(path,
          treeUri: conn.treeUri, collectionId: conn.collectionId);
      dbRevision++;
    } catch (e) {
      lastError = '$e';
    }
  }

  void _closeDb() {
    db?.close();
    if (db != null) dbRevision++;
    db = null;
  }

  Future<void> _import(
      LinkConnection conn, String version, String dbPath) async {
    copying = true;
    progress = null;
    _set(LinkPhase.importing);
    final cache = await _cache();
    final copy = p.join(cache, 'library-index-copy.sqlite3');
    try {
      try {
        await api.copyIndex(conn.treeUri, copy, onProgress: (done, total) {
          progress = total > 0 ? done / total : null;
          notifyListeners();
        });
      } on LinkReadError catch (e) {
        if (e.code == 'revoked') _closeDb();
        _finishImport(
            error: switch (e.code) {
          'revoked' => LinkPhase.revoked,
          'offline' => LinkPhase.offline,
          _ => LinkPhase.failed,
        });
        return;
      }
      copying = false;
      progress = 0;
      notifyListeners();

      final port = ReceivePort();
      final sub = port.listen((m) {
        if (m is List && m.length == 2 && (m[1] as int) > 0) {
          progress = (m[0] as int) / (m[1] as int);
          notifyListeners();
        }
      });
      final LinkImportReport report;
      final tmp = '$dbPath.new';
      try {
        report = await compute(
            runLinkImport,
            LinkImportRequest(
              indexCopy: copy,
              outPath: tmp,
              collectionId: conn.collectionId,
              indexVersion: version,
              progress: port.sendPort,
            ));
      } finally {
        await sub.cancel();
        port.close();
      }
      if (!report.ok) {
        lastError = report.error;
        _finishImport(error: LinkPhase.failed);
        return;
      }
      _closeDb();
      await File(tmp).rename(dbPath);
      db = LinkDb.open(dbPath,
          treeUri: conn.treeUri, collectionId: conn.collectionId);
      dbRevision++;
      await _dropOtherCollections(dbPath);
      _finishImport();
    } catch (e) {
      lastError = '$e';
      _finishImport(error: LinkPhase.failed);
    } finally {
      // недокачанный `.part` остаётся: следующая попытка продолжит с того же места
      for (final suffix in const ['', '-wal', '-shm']) {
        try {
          await File('$copy$suffix').delete();
        } catch (_) {}
      }
    }
  }

  void _finishImport({LinkPhase? error}) {
    copying = false;
    progress = null;
    _set(error ?? LinkPhase.ready);
  }

  /// Коллекция переехала (новый id): прежняя база больше не нужна.
  Future<void> _dropOtherCollections(String keep) async {
    final dir = Directory(await _support());
    await for (final e in dir.list()) {
      if (e is File && e.path.endsWith('.sqlite3') && !p.equals(e.path, keep)) {
        try {
          await e.delete();
        } catch (_) {}
      }
    }
  }

  /// Вернулись в приложение (например, из Explorer, где включили связь с ПК):
  /// если коллекция была недоступна, проверить снова.
  void onResumed() {
    const waiting = {
      LinkPhase.offline,
      LinkPhase.noPc,
      LinkPhase.noCollection,
      LinkPhase.notInstalled,
      LinkPhase.revoked,
      LinkPhase.failed,
    };
    if (hasConnection && waiting.contains(phase)) unawaited(refresh());
  }

  /// Забыть подключение. Данные планшета это не затрагивает.
  Future<void> disconnect() async {
    _closeDb();
    try {
      await api.forget();
    } catch (_) {}
    connection = null;
    final cache = p.join(await _cache(), 'library-index-copy.sqlite3');
    for (final suffix in const ['.part', '.part.version']) {
      try {
        await File('$cache$suffix').delete();
      } catch (_) {}
    }
    final dir = Directory(await _support());
    if (await dir.exists()) {
      await for (final e in dir.list()) {
        if (e is File) {
          try {
            await e.delete();
          } catch (_) {}
        }
      }
    }
    _set(explorerInstalled ? LinkPhase.needsConnect : LinkPhase.notInstalled);
  }

  Future<void> openExplorer() async {
    try {
      await api.openExplorer();
    } catch (_) {}
  }

  @override
  void dispose() {
    _handoffSub?.cancel();
    _closeDb();
    super.dispose();
  }
}

String? _readVersion((String, String) a) => readLinkDbVersion(a.$1, a.$2);
