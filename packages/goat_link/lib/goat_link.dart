import 'dart:async';

import 'package:flutter/services.dart';

/// A collection handed over by Goat Explorer.
class LinkConnection {
  final String treeUri;
  final String collectionId;
  final String name;
  final String serverName;
  final String indexVersion;
  final bool granted;

  const LinkConnection({
    required this.treeUri,
    required this.collectionId,
    required this.name,
    required this.serverName,
    required this.indexVersion,
    required this.granted,
  });

  static LinkConnection? fromMap(Map<Object?, Object?>? m) {
    if (m == null) return null;
    return LinkConnection(
      treeUri: '${m['treeUri'] ?? ''}',
      collectionId: '${m['collectionId'] ?? ''}',
      name: '${m['name'] ?? ''}',
      serverName: '${m['serverName'] ?? ''}',
      indexVersion: '${m['indexVersion'] ?? ''}',
      granted: m['granted'] == true,
    );
  }
}

enum ProbeState { ok, offline, noCollection, revoked, notInstalled }

class ProbeResult {
  final ProbeState state;
  final String? indexVersion;
  const ProbeResult(this.state, {this.indexVersion});
}

enum ConnectStatus {
  ok,
  canceled,
  noPc,
  offline,
  noCollection,
  notInstalled,
  outdated,
  failed
}

class ConnectResult {
  final ConnectStatus status;
  final LinkConnection? connection;
  const ConnectResult(this.status, {this.connection});
}

/// A read stopped because nobody needs it any more.
class LinkCanceled implements Exception {
  const LinkCanceled();
}

/// The PC or the grant is unavailable for this read.
class LinkReadError implements Exception {
  final String code;
  const LinkReadError(this.code);
  @override
  String toString() => 'LinkReadError($code)';
}

/// What the gallery needs from the Android side. Replaced by a fake in tests.
abstract class GoatLinkApi {
  Future<bool> explorerInstalled();
  Future<bool> openExplorer();
  Future<LinkConnection?> saved();
  Future<bool> takeHandoff();
  Future<void> forget();
  Future<ConnectResult> connect();
  Future<ProbeResult> probe(String treeUri);
  Future<void> copyIndex(String treeUri, String dest,
      {void Function(int done, int total)? onProgress});
  Future<String> thumbnail(
      int id, String treeUri, String rel, String key, int size);
  Future<String> full(int id, String treeUri, String rel, String key);
  Future<void> cancel(int id);
  Future<int> openFd(String treeUri, String rel);
  Future<void> closeFd(int fd);

  /// Fires when Explorer hands over a collection while the app is running.
  Stream<void> get handoffs;
}

class MethodChannelGoatLink implements GoatLinkApi {
  static const MethodChannel _channel = MethodChannel('dev.goat.link');

  final StreamController<void> _handoffs = StreamController<void>.broadcast();
  void Function(int done, int total)? _copyProgress;

  MethodChannelGoatLink() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'handoff') {
        _handoffs.add(null);
      } else if (call.method == 'copyProgress') {
        final a = call.arguments as Map<Object?, Object?>;
        _copyProgress?.call(
            (a['done'] as num).toInt(), (a['total'] as num).toInt());
      }
    });
  }

  Future<T> _read<T>(String method, Map<String, Object?> args) async {
    try {
      return (await _channel.invokeMethod<T>(method, args)) as T;
    } on PlatformException catch (e) {
      if (e.code == 'canceled') throw const LinkCanceled();
      throw LinkReadError(e.code);
    }
  }

  @override
  Stream<void> get handoffs => _handoffs.stream;

  @override
  Future<bool> explorerInstalled() async =>
      await _channel.invokeMethod<bool>('explorerInstalled') ?? false;

  @override
  Future<bool> openExplorer() async =>
      await _channel.invokeMethod<bool>('openExplorer') ?? false;

  @override
  Future<LinkConnection?> saved() async => LinkConnection.fromMap(
      await _channel.invokeMethod<Map<Object?, Object?>>('saved'));

  @override
  Future<bool> takeHandoff() async =>
      await _channel.invokeMethod<bool>('takeHandoff') ?? false;

  @override
  Future<void> forget() => _channel.invokeMethod<void>('forget');

  @override
  Future<ConnectResult> connect() async {
    final Map<Object?, Object?>? m;
    try {
      m = await _channel.invokeMethod<Map<Object?, Object?>>('connect');
    } on PlatformException {
      return const ConnectResult(ConnectStatus.failed);
    }
    switch (m?['status']) {
      case 'ok':
        return ConnectResult(ConnectStatus.ok,
            connection: LinkConnection.fromMap(
                m!['connection'] as Map<Object?, Object?>?));
      case 'canceled':
        return const ConnectResult(ConnectStatus.canceled);
      case 'not_installed':
        return const ConnectResult(ConnectStatus.notInstalled);
      case 'outdated':
        return const ConnectResult(ConnectStatus.outdated);
      case 'error':
        return ConnectResult(switch (m!['error']) {
          'no_pc' => ConnectStatus.noPc,
          'offline' => ConnectStatus.offline,
          'no_collection' => ConnectStatus.noCollection,
          _ => ConnectStatus.failed,
        });
    }
    return const ConnectResult(ConnectStatus.failed);
  }

  @override
  Future<ProbeResult> probe(String treeUri) async {
    final Map<Object?, Object?>? m;
    try {
      m = await _channel
          .invokeMethod<Map<Object?, Object?>>('probe', {'treeUri': treeUri});
    } on PlatformException catch (e) {
      return ProbeResult(
          e.code == 'revoked' ? ProbeState.revoked : ProbeState.offline);
    }
    final state = switch (m?['state']) {
      'ok' => ProbeState.ok,
      'no_collection' => ProbeState.noCollection,
      'revoked' => ProbeState.revoked,
      'not_installed' => ProbeState.notInstalled,
      _ => ProbeState.offline,
    };
    return ProbeResult(state, indexVersion: m?['indexVersion'] as String?);
  }

  @override
  Future<void> copyIndex(String treeUri, String dest,
      {void Function(int done, int total)? onProgress}) async {
    _copyProgress = onProgress;
    try {
      await _read<Object?>('copyIndex', {'treeUri': treeUri, 'dest': dest});
    } finally {
      _copyProgress = null;
    }
  }

  @override
  Future<String> thumbnail(
          int id, String treeUri, String rel, String key, int size) =>
      _read<String>('thumbnail', {
        'id': id,
        'treeUri': treeUri,
        'rel': rel,
        'key': key,
        'size': size,
      });

  @override
  Future<String> full(int id, String treeUri, String rel, String key) =>
      _read<String>(
          'full', {'id': id, 'treeUri': treeUri, 'rel': rel, 'key': key});

  @override
  Future<void> cancel(int id) =>
      _channel.invokeMethod<void>('cancel', {'id': id});

  @override
  Future<int> openFd(String treeUri, String rel) =>
      _read<int>('openFd', {'treeUri': treeUri, 'rel': rel});

  @override
  Future<void> closeFd(int fd) =>
      _channel.invokeMethod<void>('closeFd', {'fd': fd});
}
