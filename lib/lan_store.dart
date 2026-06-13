import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Клиент, которому этот хост однажды доверился (после сопряжения по PIN).
/// Дальше он входит по постоянному токену без PIN.
class TrustedClient {
  final String clientId;
  final String name;
  final String token;
  final DateTime addedAt;
  TrustedClient({
    required this.clientId,
    required this.name,
    required this.token,
    required this.addedAt,
  });

  Map<String, dynamic> toJson() => {
        'clientId': clientId,
        'name': name,
        'token': token,
        'addedAt': addedAt.millisecondsSinceEpoch,
      };

  factory TrustedClient.fromJson(Map<String, dynamic> j) => TrustedClient(
        clientId: j['clientId'] as String,
        name: (j['name'] ?? 'Устройство') as String,
        token: j['token'] as String,
        addedAt:
            DateTime.fromMillisecondsSinceEpoch((j['addedAt'] ?? 0) as int),
      );
}

/// Хост, с которым этот клиент уже спарен. Хранит выданный токен и последний
/// известный адрес (IP может меняться — адрес правится, токен остаётся).
class KnownHost {
  final String hostId;
  String name;
  String ip;
  int port;
  final String token;
  KnownHost({
    required this.hostId,
    required this.name,
    required this.ip,
    required this.port,
    required this.token,
  });

  Map<String, dynamic> toJson() => {
        'hostId': hostId,
        'name': name,
        'ip': ip,
        'port': port,
        'token': token,
      };

  factory KnownHost.fromJson(Map<String, dynamic> j) => KnownHost(
        hostId: j['hostId'] as String,
        name: (j['name'] ?? 'Устройство') as String,
        ip: (j['ip'] ?? '') as String,
        port: (j['port'] ?? 8787) as int,
        token: j['token'] as String,
      );
}

/// Постоянное хранилище сопряжений локальной сети. Одно устройство может быть
/// одновременно и хостом (хранит доверенных клиентов), и клиентом (хранит
/// известные хосты). Всё лежит в shared_preferences.
class LanStore extends ChangeNotifier {
  LanStore._();
  static final LanStore instance = LanStore._();

  static const _kClientId = 'goat_lan_client_id';
  static const _kHostId = 'goat_lan_host_id';
  static const _kTrusted = 'goat_lan_trusted';
  static const _kHosts = 'goat_lan_hosts';

  late SharedPreferences _p;
  String _clientId = '';
  String _hostId = '';
  final List<TrustedClient> _trusted = [];
  final List<KnownHost> _hosts = [];

  String get clientId => _clientId;
  String get hostId => _hostId;
  List<TrustedClient> get trusted => List.unmodifiable(_trusted);
  List<KnownHost> get hosts => List.unmodifiable(_hosts);

  Future<void> load() async {
    _p = await SharedPreferences.getInstance();
    _clientId = _p.getString(_kClientId) ?? _newId();
    if (!_p.containsKey(_kClientId)) _p.setString(_kClientId, _clientId);
    _hostId = _p.getString(_kHostId) ?? _newId();
    if (!_p.containsKey(_kHostId)) _p.setString(_kHostId, _hostId);

    _trusted
      ..clear()
      ..addAll(_decodeList(_p.getString(_kTrusted))
          .map((e) => TrustedClient.fromJson(e)));
    _hosts
      ..clear()
      ..addAll(
          _decodeList(_p.getString(_kHosts)).map((e) => KnownHost.fromJson(e)));
  }

  // ───────────────────────── сторона хоста ─────────────────────────

  /// Доверенный токен? (проверяется на каждый запрос к раздаче).
  bool isTrustedToken(String? token) =>
      token != null && _trusted.any((t) => t.token == token);

  /// Сопрячь клиента: вернуть существующего доверенного (если этот clientId
  /// уже знаком) или создать нового с постоянным токеном.
  TrustedClient trustClient(String clientId, String name) {
    final existing = _firstOrNull(_trusted, (t) => t.clientId == clientId);
    if (existing != null) return existing;
    final tc = TrustedClient(
      clientId: clientId,
      name: name,
      token: _newToken(),
      addedAt: DateTime.now(),
    );
    _trusted.add(tc);
    _saveTrusted();
    notifyListeners();
    return tc;
  }

  void forgetTrusted(String token) {
    _trusted.removeWhere((t) => t.token == token);
    _saveTrusted();
    notifyListeners();
  }

  // ───────────────────────── сторона клиента ─────────────────────────

  KnownHost? hostById(String hostId) =>
      _firstOrNull(_hosts, (h) => h.hostId == hostId);

  /// Запомнить/обновить хост после успешного сопряжения.
  void rememberHost(KnownHost host) {
    final i = _hosts.indexWhere((h) => h.hostId == host.hostId);
    if (i >= 0) {
      _hosts[i] = host;
    } else {
      _hosts.add(host);
    }
    _saveHosts();
    notifyListeners();
  }

  /// Обновить только адрес запомненного хоста (IP сменился) — токен остаётся.
  void updateHostAddress(String hostId, String ip, int port) {
    final h = hostById(hostId);
    if (h == null) return;
    h.ip = ip;
    h.port = port;
    _saveHosts();
    notifyListeners();
  }

  void forgetHost(String hostId) {
    _hosts.removeWhere((h) => h.hostId == hostId);
    _saveHosts();
    notifyListeners();
  }

  // ───────────────────────── служебное ─────────────────────────
  void _saveTrusted() =>
      _p.setString(_kTrusted, jsonEncode(_trusted.map((e) => e.toJson()).toList()));
  void _saveHosts() =>
      _p.setString(_kHosts, jsonEncode(_hosts.map((e) => e.toJson()).toList()));

  List<Map<String, dynamic>> _decodeList(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    try {
      final list = jsonDecode(raw) as List;
      return list.cast<Map<String, dynamic>>();
    } catch (_) {
      return const [];
    }
  }

  String _newId() {
    final r = Random.secure();
    final b = List<int>.generate(8, (_) => r.nextInt(256));
    return b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  }

  String _newToken() {
    final r = Random.secure();
    final b = List<int>.generate(16, (_) => r.nextInt(256));
    return b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  }

  static T? _firstOrNull<T>(List<T> list, bool Function(T) test) {
    for (final e in list) {
      if (test(e)) return e;
    }
    return null;
  }
}
