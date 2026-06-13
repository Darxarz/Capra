import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'theme.dart';
import 'model.dart';
import 'lan_service.dart';
import 'lan_client.dart';
import 'lan_store.dart';
import 'viewer_page.dart';
import 'settings_service.dart';

/// Экран локальной сети: «Раздать» свою галерею и «Подключиться» к чужой.
class LanPage extends StatefulWidget {
  const LanPage({super.key});

  @override
  State<LanPage> createState() => _LanPageState();
}

class _LanPageState extends State<LanPage> {
  int _tab = 0; // 0 — раздать, 1 — подключиться

  @override
  Widget build(BuildContext context) {
    final c = AuroraTheme.of(context).colors;
    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        child: Column(children: [
          _Header(c: c, onBack: () => Navigator.of(context).pop()),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 6, 20, 10),
            child: _Switcher(
              tab: _tab,
              onTab: (v) => setState(() => _tab = v),
            ),
          ),
          Expanded(
            child: _tab == 0 ? const _HostView() : const _ClientView(),
          ),
        ]),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final AuroraColors c;
  final VoidCallback onBack;
  const _Header({required this.c, required this.onBack});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 8, 18, 10),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: c.line)),
      ),
      child: Row(children: [
        IconButton(
          onPressed: onBack,
          icon: Icon(Icons.arrow_back, color: c.text),
          tooltip: 'Назад',
        ),
        const SizedBox(width: 4),
        Text('Локальная сеть',
            style: TextStyle(
                color: c.text, fontSize: 18, fontWeight: FontWeight.w800)),
      ]),
    );
  }
}

class _Switcher extends StatelessWidget {
  final int tab;
  final ValueChanged<int> onTab;
  const _Switcher({required this.tab, required this.onTab});

  @override
  Widget build(BuildContext context) {
    final c = AuroraTheme.of(context).colors;
    Widget seg(String label, IconData icon, int v) {
      final on = tab == v;
      return Expanded(
        child: GestureDetector(
          onTap: () => onTab(v),
          child: Container(
            margin: const EdgeInsets.all(3),
            padding: const EdgeInsets.symmetric(vertical: 10),
            decoration: BoxDecoration(
              color: on ? c.surface : Colors.transparent,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              Icon(icon, size: 17, color: on ? c.accentInk : c.muted),
              const SizedBox(width: 7),
              Text(label,
                  style: TextStyle(
                      color: on ? c.text : c.muted,
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600)),
            ]),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: c.surface2,
        borderRadius: BorderRadius.circular(13),
        border: Border.all(color: c.line),
      ),
      child: Row(children: [
        seg('Раздать', Icons.wifi_tethering_rounded, 0),
        seg('Подключиться', Icons.cast_connected_rounded, 1),
      ]),
    );
  }
}

// ───────────────────────── РАЗДАТЬ (хост) ─────────────────────────
class _HostView extends StatefulWidget {
  const _HostView();
  @override
  State<_HostView> createState() => _HostViewState();
}

class _HostViewState extends State<_HostView> {
  List<LanAdapter> _addresses = const [];
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    // если раздача уже идёт (вернулись на экран) — подтянуть адреса
    if (LanService.instance.isRunning) {
      LanService.localAdapters().then((a) {
        if (mounted) setState(() => _addresses = a);
      });
    }
  }

  Future<void> _toggle() async {
    final lan = LanService.instance;
    setState(() => _busy = true);
    try {
      if (lan.isRunning) {
        await lan.stop();
        _addresses = const [];
      } else {
        _addresses = await lan.start();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Не удалось запустить: $e')));
      }
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final c = AuroraTheme.of(context).colors;
    return AnimatedBuilder(
      animation: LanService.instance,
      builder: (ctx, _) {
        final lan = LanService.instance;
        final on = lan.isRunning;
        return ListView(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
          children: [
            _Card(c: c, child: Column(children: [
              Row(children: [
                Icon(on ? Icons.wifi_tethering_rounded
                        : Icons.wifi_tethering_off_rounded,
                    color: on ? c.accent : c.muted, size: 26),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(on ? 'Раздача включена' : 'Раздача выключена',
                          style: TextStyle(
                              color: c.text,
                              fontSize: 15,
                              fontWeight: FontWeight.w700)),
                      const SizedBox(height: 2),
                      Text(on
                          ? 'Другое устройство в той же Wi-Fi сети может подключиться'
                          : 'Включи, чтобы показать свои фото другому устройству',
                          style: TextStyle(color: c.muted, fontSize: 12.5)),
                    ]),
                ),
                Switch(
                  value: on,
                  activeThumbColor: c.accent,
                  onChanged: _busy ? null : (_) => _toggle(),
                ),
              ]),
            ])),
            if (on) ...[
              const SizedBox(height: 16),
              _Card(c: c, child: Column(
                crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('PIN для подключения',
                    style: TextStyle(color: c.muted, fontSize: 12.5,
                        fontWeight: FontWeight.w600)),
                const SizedBox(height: 6),
                Text(_spacedPin(lan.pin),
                    style: TextStyle(
                        color: c.accent,
                        fontSize: 38,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 6)),
                const SizedBox(height: 4),
                Text('Введи этот PIN на другом устройстве. '
                    'Он меняется при каждом включении.',
                    style: TextStyle(color: c.muted, fontSize: 12)),
              ])),
              const SizedBox(height: 16),
              _Card(c: c, child: Column(
                crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Адрес устройства',
                    style: TextStyle(color: c.muted, fontSize: 12.5,
                        fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                if (_addresses.isEmpty)
                  Text('Не нашёл сетевой адрес. Подключён ли Wi-Fi?',
                      style: TextStyle(color: c.muted, fontSize: 13))
                else
                  for (final a in _addresses)
                    _AddressRow(adapter: a, port: lan.port, pin: lan.pin, c: c),
                const SizedBox(height: 6),
                Text('Раздаётся фото: ${lan.sharedCount}',
                    style: TextStyle(color: c.muted, fontSize: 12.5)),
              ])),
            ],
            const SizedBox(height: 16),
            _TrustedList(c: c),
          ],
        );
      },
    );
  }

  String _spacedPin(String pin) {
    if (pin.length == 6) return '${pin.substring(0, 3)} ${pin.substring(3)}';
    return pin;
  }
}

/// Список устройств, которым этот хост уже доверяет (входят без PIN).
class _TrustedList extends StatelessWidget {
  final AuroraColors c;
  const _TrustedList({required this.c});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: LanStore.instance,
      builder: (ctx, _) {
        final list = LanStore.instance.trusted;
        if (list.isEmpty) return const SizedBox.shrink();
        return _Card(c: c, child: Column(
          crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Доверенные устройства',
              style: TextStyle(color: c.muted, fontSize: 12.5,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 2),
          Text('Эти устройства подключаются без PIN',
              style: TextStyle(color: c.muted, fontSize: 11.5)),
          const SizedBox(height: 6),
          for (final t in list)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(children: [
                Icon(Icons.devices_rounded, size: 18, color: c.accent),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(t.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: c.text, fontSize: 14,
                          fontWeight: FontWeight.w600)),
                ),
                TextButton(
                  onPressed: () => LanStore.instance.forgetTrusted(t.token),
                  child: Text('Забыть',
                      style: TextStyle(color: c.muted, fontSize: 12.5)),
                ),
              ]),
            ),
        ]));
      },
    );
  }
}

class _AddressRow extends StatelessWidget {
  final LanAdapter adapter;
  final int port;
  final String pin;
  final AuroraColors c;
  const _AddressRow(
      {required this.adapter,
      required this.port,
      required this.pin,
      required this.c});

  IconData get _icon {
    switch (adapter.kind) {
      case 'VPN':
        return Icons.vpn_lock_rounded;
      case 'Виртуальная сеть':
        return Icons.developer_board_rounded;
      case 'Wi-Fi':
        return Icons.wifi_rounded;
      case 'Ethernet (кабель)':
        return Icons.settings_ethernet_rounded;
      case 'Моб. интернет':
        return Icons.signal_cellular_alt_rounded;
      default:
        return Icons.lan_outlined;
    }
  }

  @override
  Widget build(BuildContext context) {
    final address = '${adapter.ip}:$port';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(children: [
        Icon(_icon, size: 20, color: adapter.private ? c.accent : c.muted),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Flexible(
                child: Text(adapter.kind,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: c.muted, fontSize: 11.5,
                        fontWeight: FontWeight.w600)),
              ),
            ]),
            Text(address,
                style: TextStyle(
                    color: c.text, fontSize: 15, fontWeight: FontWeight.w600)),
          ]),
        ),
        IconButton(
          icon: Icon(Icons.qr_code_rounded, size: 20, color: c.muted),
          tooltip: 'QR-код',
          onPressed: () => _showQr(context, adapter, port, pin, c),
        ),
        IconButton(
          icon: Icon(Icons.copy_rounded, size: 18, color: c.muted),
          tooltip: 'Скопировать',
          onPressed: () {
            Clipboard.setData(ClipboardData(text: address));
            ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Адрес скопирован')));
          },
        ),
      ]),
    );
  }
}

/// Диалог с QR-кодом для быстрого подключения второго устройства.
void _showQr(BuildContext context, LanAdapter adapter, int port, String pin,
    AuroraColors c) {
  final data = buildLanQr(adapter.ip, port, pin);
  showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: c.surface,
      title: Text('Сканируй на другом устройстве',
          style: TextStyle(color: c.text, fontSize: 16)),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
          ),
          child: QrImageView(
            data: data,
            version: QrVersions.auto,
            size: 220,
            backgroundColor: Colors.white,
          ),
        ),
        const SizedBox(height: 12),
        Text('${adapter.kind} · ${adapter.ip}:$port',
            style: TextStyle(color: c.muted, fontSize: 12.5)),
        const SizedBox(height: 2),
        Text('GOAT → Подключиться → Сканировать QR',
            textAlign: TextAlign.center,
            style: TextStyle(color: c.muted, fontSize: 11.5)),
      ]),
      actions: [
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: c.accent),
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Готово'),
        ),
      ],
    ),
  );
}

// ───────────────────────── ПОДКЛЮЧИТЬСЯ (клиент) ─────────────────────────
class _ClientView extends StatefulWidget {
  const _ClientView();
  @override
  State<_ClientView> createState() => _ClientViewState();
}

class _ClientViewState extends State<_ClientView> {
  final _ipCtl = TextEditingController();
  final _pinCtl = TextEditingController();
  bool _busy = false;
  bool _addOpen = false; // раскрыта ли форма добавления нового устройства
  String? _error;
  String? _busyHostId; // какой запомненный хост сейчас подключается

  @override
  void dispose() {
    _ipCtl.dispose();
    _pinCtl.dispose();
    super.dispose();
  }

  String _clientName() {
    try {
      return Platform.localHostname;
    } catch (_) {
      return Platform.isAndroid ? 'Android' : 'Устройство';
    }
  }

  /// Открыть галерею хоста: тянем список и переходим на экран просмотра.
  Future<void> _openGallery(LanConnection conn) async {
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final photos = await LanClient.fetchAll(conn);
    if (!mounted) return;
    navigator.push(MaterialPageRoute(
      builder: (_) =>
          _RemoteGalleryPage(hostName: conn.hostName, photos: photos),
    ));
    messenger.showSnackBar(SnackBar(
        content: Text('Подключено к ${conn.hostName}: ${photos.length} фото')));
  }

  /// Сканировать QR с экрана раздачи: подставить адрес+PIN и сразу сопрячь.
  Future<void> _scanQr() async {
    final navigator = Navigator.of(context);
    final raw = await navigator.push<String>(
      MaterialPageRoute(builder: (_) => const _ScanPage()),
    );
    if (raw == null) return;
    final data = parseLanQr(raw);
    if (data == null) {
      if (mounted) setState(() => _error = 'QR не от GOAT.');
      return;
    }
    _ipCtl.text = '${data.ip}:${data.port}';
    _pinCtl.text = data.pin;
    await _pairNew();
  }

  /// ПЕРВОЕ сопряжение нового устройства (адрес + PIN).
  Future<void> _pairNew() async {
    var ip = _ipCtl.text.trim();
    var port = LanService.instance.port;
    if (ip.contains(':')) {
      final parts = ip.split(':');
      ip = parts[0];
      port = int.tryParse(parts[1]) ?? 8787;
    }
    final pin = _pinCtl.text.trim();
    if (ip.isEmpty || pin.isEmpty) {
      setState(() => _error = 'Введи адрес и PIN.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final conn = await LanClient.pair(
        ip: ip,
        port: port,
        pin: pin,
        clientId: LanStore.instance.clientId,
        clientName: _clientName(),
      );
      // запоминаем устройство — больше PIN не понадобится
      LanStore.instance.rememberHost(KnownHost(
        hostId: conn.hostId,
        name: conn.hostName,
        ip: ip,
        port: port,
        token: conn.token,
      ));
      _pinCtl.clear();
      _ipCtl.clear();
      if (mounted) setState(() => _addOpen = false);
      await _openGallery(conn);
    } on LanError catch (e) {
      setState(() => _error = e.message);
    } catch (e) {
      setState(() => _error = 'Ошибка: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Повторное подключение к запомненному устройству — по токену, без PIN.
  Future<void> _connectKnown(KnownHost host) async {
    setState(() {
      _busyHostId = host.hostId;
      _error = null;
    });
    try {
      final conn = await LanClient.connectWithToken(
          ip: host.ip, port: host.port, token: host.token);
      await _openGallery(conn);
    } on LanError catch (e) {
      if (!mounted) return;
      if (e.needRepair) {
        // хост забыл нас — предложим заново ввести PIN
        setState(() {
          _addOpen = true;
          _ipCtl.text = '${host.ip}:${host.port}';
          _error = e.message;
        });
      } else {
        // скорее всего сменился IP или раздача выключена — дать сменить адрес
        _askNewAddress(host);
      }
    } finally {
      if (mounted) setState(() => _busyHostId = null);
    }
  }

  /// Запросить новый адрес запомненного устройства (IP сменился), затем
  /// повторить вход по сохранённому токену.
  Future<void> _askNewAddress(KnownHost host) async {
    final c = AuroraTheme.of(context).colors;
    final ctl = TextEditingController(text: '${host.ip}:${host.port}');
    final newAddr = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: c.surface,
        title: Text('Не дозвонился до «${host.name}»',
            style: TextStyle(color: c.text, fontSize: 17)),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('Возможно, сменился адрес устройства. Уточни IP:порт '
              '(включена ли раздача на нём?).',
              style: TextStyle(color: c.muted, fontSize: 13)),
          const SizedBox(height: 12),
          TextField(
            controller: ctl,
            cursorColor: c.accent,
            style: TextStyle(color: c.text),
            decoration: const InputDecoration(hintText: '192.168.1.5:8787'),
          ),
        ]),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('Отмена', style: TextStyle(color: c.muted)),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: c.accent),
            onPressed: () => Navigator.pop(ctx, ctl.text.trim()),
            child: const Text('Подключиться'),
          ),
        ],
      ),
    );
    if (newAddr == null || newAddr.isEmpty) return;
    var ip = newAddr;
    var port = host.port;
    if (newAddr.contains(':')) {
      final parts = newAddr.split(':');
      ip = parts[0];
      port = int.tryParse(parts[1]) ?? host.port;
    }
    LanStore.instance.updateHostAddress(host.hostId, ip, port);
    final updated = LanStore.instance.hostById(host.hostId);
    if (updated != null) await _connectKnown(updated);
  }

  @override
  Widget build(BuildContext context) {
    final c = AuroraTheme.of(context).colors;
    return AnimatedBuilder(
      animation: LanStore.instance,
      builder: (ctx, _) {
        final hosts = LanStore.instance.hosts;
        return ListView(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
          children: [
            // ── запомненные устройства ──
            if (hosts.isNotEmpty) ...[
              _Card(c: c, child: Column(
                crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Мои устройства',
                    style: TextStyle(color: c.muted, fontSize: 12.5,
                        fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text('Подключение в один тап, без PIN',
                    style: TextStyle(color: c.muted, fontSize: 11.5)),
                const SizedBox(height: 6),
                for (final h in hosts)
                  _KnownRow(
                    host: h,
                    busy: _busyHostId == h.hostId,
                    c: c,
                    onTap: () => _connectKnown(h),
                    onForget: () => LanStore.instance.forgetHost(h.hostId),
                  ),
              ])),
              const SizedBox(height: 14),
            ],

            // ── добавить новое устройство ──
            if (!_addOpen)
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: c.accent,
                  minimumSize: const Size.fromHeight(48),
                ),
                onPressed: () => setState(() => _addOpen = true),
                icon: const Icon(Icons.add),
                label: Text(hosts.isEmpty
                    ? 'Подключиться к устройству'
                    : 'Добавить новое устройство'),
              )
            else
              _Card(c: c, child: Column(
                crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Expanded(
                    child: Text('Новое устройство',
                        style: TextStyle(color: c.text, fontSize: 15,
                            fontWeight: FontWeight.w700)),
                  ),
                  IconButton(
                    icon: Icon(Icons.close, size: 18, color: c.muted),
                    onPressed: () => setState(() {
                      _addOpen = false;
                      _error = null;
                    }),
                  ),
                ]),
                const SizedBox(height: 4),
                // быстрый путь: сканировать QR с экрана раздачи (моб. устройства)
                if (Platform.isAndroid || Platform.isIOS) ...[
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: c.accent,
                      side: BorderSide(color: c.accent),
                      minimumSize: const Size.fromHeight(46),
                    ),
                    onPressed: _busy ? null : _scanQr,
                    icon: const Icon(Icons.qr_code_scanner_rounded),
                    label: const Text('Сканировать QR'),
                  ),
                  const SizedBox(height: 14),
                  Row(children: [
                    Expanded(child: Divider(color: c.line)),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      child: Text('или вручную',
                          style: TextStyle(color: c.muted, fontSize: 12)),
                    ),
                    Expanded(child: Divider(color: c.line)),
                  ]),
                  const SizedBox(height: 14),
                ],
                Text('Адрес устройства',
                    style: TextStyle(color: c.muted, fontSize: 12.5,
                        fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                _Field(
                  controller: _ipCtl,
                  hint: 'например 192.168.1.5',
                  icon: Icons.lan_outlined,
                  keyboard: TextInputType.text,
                  c: c,
                ),
                const SizedBox(height: 16),
                Text('PIN',
                    style: TextStyle(color: c.muted, fontSize: 12.5,
                        fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                _Field(
                  controller: _pinCtl,
                  hint: '6 цифр',
                  icon: Icons.password_rounded,
                  keyboard: TextInputType.number,
                  maxLen: 6,
                  c: c,
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Row(children: [
                    Icon(Icons.error_outline_rounded, size: 17, color: c.accent),
                    const SizedBox(width: 8),
                    Expanded(child: Text(_error!,
                        style: TextStyle(color: c.accent, fontSize: 13))),
                  ]),
                ],
                const SizedBox(height: 18),
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: c.accent,
                    minimumSize: const Size.fromHeight(48),
                  ),
                  onPressed: _busy ? null : _pairNew,
                  icon: _busy
                      ? const SizedBox(
                          width: 18, height: 18,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white))
                      : const Icon(Icons.link_rounded),
                  label: Text(_busy ? 'Сопрягаю…' : 'Сопрячь устройство'),
                ),
              ])),
            const SizedBox(height: 14),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text(
                  'На втором устройстве открой «Локальная сеть → Раздать», '
                  'включи раздачу и продиктуй адрес и PIN. PIN нужен только '
                  'в первый раз — дальше устройства помнят друг друга.',
                  style: TextStyle(color: c.muted, fontSize: 12.5)),
            ),
          ],
        );
      },
    );
  }
}

/// Строка запомненного устройства в списке клиента.
class _KnownRow extends StatelessWidget {
  final KnownHost host;
  final bool busy;
  final AuroraColors c;
  final VoidCallback onTap;
  final VoidCallback onForget;
  const _KnownRow({
    required this.host,
    required this.busy,
    required this.c,
    required this.onTap,
    required this.onForget,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: busy ? null : onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(children: [
          busy
              ? SizedBox(
                  width: 20, height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2, color: c.accent))
              : Icon(Icons.devices_rounded, size: 20, color: c.accent),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(host.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: c.text, fontSize: 14.5, fontWeight: FontWeight.w600)),
              Text('${host.ip}:${host.port}',
                  style: TextStyle(color: c.muted, fontSize: 12)),
            ]),
          ),
          PopupMenuButton<String>(
            icon: Icon(Icons.more_vert, size: 18, color: c.muted),
            onSelected: (v) {
              if (v == 'forget') onForget();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'forget', child: Text('Забыть устройство')),
            ],
          ),
        ]),
      ),
    );
  }
}

class _Field extends StatelessWidget {
  final TextEditingController controller;
  final String hint;
  final IconData icon;
  final TextInputType keyboard;
  final int? maxLen;
  final AuroraColors c;
  const _Field({
    required this.controller,
    required this.hint,
    required this.icon,
    required this.keyboard,
    required this.c,
    this.maxLen,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      decoration: BoxDecoration(
        color: c.surface2,
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: c.line),
      ),
      child: Row(children: [
        Icon(icon, size: 18, color: c.muted),
        const SizedBox(width: 10),
        Expanded(
          child: TextField(
            controller: controller,
            keyboardType: keyboard,
            maxLength: maxLen,
            cursorColor: c.accent,
            style: TextStyle(color: c.text, fontSize: 15),
            decoration: InputDecoration(
              isDense: true,
              counterText: '',
              border: InputBorder.none,
              hintText: hint,
              hintStyle: TextStyle(color: c.muted, fontSize: 14),
            ),
          ),
        ),
      ]),
    );
  }
}

// ───────────────────────── сканер QR ─────────────────────────
class _ScanPage extends StatefulWidget {
  const _ScanPage();
  @override
  State<_ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<_ScanPage> {
  bool _handled = false; // чтобы не сработать на одном коде дважды

  void _onDetect(BarcodeCapture capture) {
    if (_handled) return;
    for (final b in capture.barcodes) {
      final raw = b.rawValue;
      if (raw != null && parseLanQr(raw) != null) {
        _handled = true;
        Navigator.of(context).pop(raw);
        return;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(children: [
        Positioned.fill(child: MobileScanner(onDetect: _onDetect)),
        // рамка-подсказка в центре
        Center(
          child: Container(
            width: 230,
            height: 230,
            decoration: BoxDecoration(
              border: Border.all(color: Colors.white, width: 3),
              borderRadius: BorderRadius.circular(20),
            ),
          ),
        ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Align(
              alignment: Alignment.topLeft,
              child: Material(
                color: Colors.white24,
                shape: const CircleBorder(),
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: () => Navigator.pop(context),
                  child: const SizedBox(
                    width: 44, height: 44,
                    child: Icon(Icons.close, color: Colors.white),
                  ),
                ),
              ),
            ),
          ),
        ),
        const SafeArea(
          child: Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: EdgeInsets.only(bottom: 30),
              child: Text('Наведи на QR с экрана раздачи',
                  style: TextStyle(color: Colors.white, fontSize: 14)),
            ),
          ),
        ),
      ]),
    );
  }
}

// ───────────────────────── чужая галерея (просмотр) ─────────────────────────
class _RemoteGalleryPage extends StatelessWidget {
  final String hostName;
  final List<PhotoItem> photos;
  const _RemoteGalleryPage({required this.hostName, required this.photos});

  @override
  Widget build(BuildContext context) {
    final c = AuroraTheme.of(context).colors;
    final cell = SettingsService.instance.cellSize;
    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 16, 8),
            child: Row(children: [
              IconButton(
                onPressed: () => Navigator.pop(context),
                icon: Icon(Icons.arrow_back, color: c.text),
                tooltip: 'Назад',
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Icon(Icons.cast_connected_rounded, size: 16, color: c.accent),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(hostName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 17,
                                fontWeight: FontWeight.w800,
                                color: c.text)),
                      ),
                    ]),
                    Text('${photos.length} фото · по сети',
                        style: TextStyle(fontSize: 12, color: c.muted)),
                  ]),
              ),
            ]),
          ),
          Expanded(
            child: photos.isEmpty
                ? Center(child: Text('У этого устройства нет фото',
                    style: TextStyle(color: c.muted)))
                : GridView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 6, 16, 18),
                    gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: cell,
                      mainAxisSpacing: 4,
                      crossAxisSpacing: 4,
                      childAspectRatio: 1,
                    ),
                    itemCount: photos.length,
                    itemBuilder: (ctx, i) => _RemoteTile(
                      photo: photos[i],
                      cell: cell,
                      onTap: () => openViewer(ctx, photos, i),
                    ),
                  ),
          ),
        ]),
      ),
    );
  }
}

class _RemoteTile extends StatelessWidget {
  final PhotoItem photo;
  final double cell;
  final VoidCallback onTap;
  const _RemoteTile(
      {required this.photo, required this.cell, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final c = AuroraTheme.of(context).colors;
    final s = SettingsService.instance;
    final dpr = MediaQuery.of(context).devicePixelRatio;
    final cacheWidth = (cell * dpr).round().clamp(64, 512);
    return GestureDetector(
      onTap: onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(s.gridRadius),
        child: Stack(fit: StackFit.expand, children: [
          Container(color: c.surface2),
          Image(
            image: photo.thumb(cacheWidth),
            fit: s.squareThumbs ? BoxFit.cover : BoxFit.contain,
            gaplessPlayback: true,
            filterQuality: FilterQuality.low,
            frameBuilder: (ctx, child, frame, wasSync) {
              if (wasSync || frame != null) return child;
              return Container(
                color: c.surface2,
                child: Center(
                  child: SizedBox(
                    width: 16, height: 16,
                    child: CircularProgressIndicator(
                        strokeWidth: 1.6, color: c.muted),
                  ),
                ),
              );
            },
            errorBuilder: (ctx, e, st) =>
                Icon(Icons.broken_image_outlined, color: c.muted, size: 18),
          ),
          if (photo.isGif && s.showGifBadge)
            Positioned(
              right: 5, bottom: 5,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: const Text('GIF',
                    style: TextStyle(color: Colors.white, fontSize: 10)),
              ),
            ),
        ]),
      ),
    );
  }
}

// общая карточка-контейнер
class _Card extends StatelessWidget {
  final AuroraColors c;
  final Widget child;
  const _Card({required this.c, required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: c.line),
      ),
      child: child,
    );
  }
}
