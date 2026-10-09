import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'theme.dart';
import 'gx.dart';
import 'model.dart';
import 'lan_service.dart';
import 'lan_client.dart';
import 'lan_store.dart';
import 'background_service.dart';
import 'viewer_page.dart';
import 'settings_service.dart';
import 'i18n.dart';

// ── свои значки для этого экрана (24×24, линия 1.6) ──
const _gBroadcast = GxGlyph(
    'M12 12.2h.2M8.5 8.5a5 5 0 0 0 0 7M15.5 8.5a5 5 0 0 1 0 7M5.5 5.5a9 9 0 0 0 0 13M18.5 5.5a9 9 0 0 1 0 13');
const _gBroadcastOff =
    GxGlyph('M12 12.2h.2M8.5 8.5a5 5 0 0 0 0 7M15.5 8.5a5 5 0 0 1 0 7M4.5 4.5l15 15');
const _gCast = GxGlyph(
    'M4 7V6a1.5 1.5 0 0 1 1.5-1.5h13A1.5 1.5 0 0 1 20 6v12a1.5 1.5 0 0 1-1.5 1.5H14M4 11a8 8 0 0 1 8 8M4 15a4 4 0 0 1 4 4M4 19h.2');
const _gChip = GxGlyph(
    'M8 8h8v8H8zM10 4v4M14 4v4M10 16v4M14 16v4M4 10h4M4 14h4M16 10h4M16 14h4');
const _gEthernet =
    GxGlyph('M3.5 8.5h17v7h-17zM7 15.5V12M10 15.5V12M14 15.5V12M17 15.5V12');
const _gCellular = GxGlyph('M5 19v-3M10 19v-6M15 19V9M20 19V5');
const _gQr = GxGlyph(
    'M4 4h6v6H4zM14 4h6v6h-6zM4 14h6v6H4zM14 14h2.5v2.5H14zM17.500 17.500H20V20h-2.500z');
const _gScan = GxGlyph(
    'M4 8V5.5A1.5 1.5 0 0 1 5.5 4H8M16 4h2.5A1.5 1.5 0 0 1 20 5.5V8M20 16v2.5a1.5 1.5 0 0 1-1.5 1.5H16M8 20H5.5A1.5 1.5 0 0 1 4 18.5V16M4 12h16');
const _gLock = GxGlyph(
    'M6.5 11h11a1.5 1.5 0 0 1 1.5 1.5v6a1.5 1.5 0 0 1-1.5 1.5h-11A1.5 1.5 0 0 1 5 18.5v-6A1.5 1.5 0 0 1 6.5 11zM8.5 11V8a3.5 3.5 0 0 1 7 0v3');
const _gLink = GxGlyph(
    'M10 14a3.5 3.5 0 0 0 5 0l3-3a3.5 3.5 0 0 0-5-5l-.8.8M14 10a3.5 3.5 0 0 0-5 0l-3 3a3.5 3.5 0 0 0 5 5l.8-.8');
const _gPlay = GxGlyph('M8.500 5.500v13l10.500-6.500z', true);

/// Локализованное название типа сетевого адаптера (ключи приходят из lan_service).
String lanKindLabel(String kind) {
  switch (kind) {
    case 'VPN':
      return 'VPN';
    case 'Виртуальная сеть':
      return tr('Виртуальная сеть', 'Virtual network', 'Red virtual');
    case 'Wi-Fi':
      return 'Wi-Fi';
    case 'Ethernet (кабель)':
      return tr('Ethernet (кабель)', 'Ethernet (cable)', 'Ethernet (cable)');
    case 'Моб. интернет':
      return tr('Моб. интернет', 'Mobile data', 'Datos móviles');
    default:
      return kind;
  }
}

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
          _Switcher(
            tab: _tab,
            onTab: (v) => setState(() => _tab = v),
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
    return Column(mainAxisSize: MainAxisSize.min, children: [
      SizedBox(
        height: 52,
        child: Row(children: [
          const SizedBox(width: 4),
          GxIconBtn(GxGlyph.back, tr('Назад', 'Back', 'Atrás'), onTap: onBack),
          const SizedBox(width: 6),
          Text(tr('Локальная сеть', 'Local network', 'Red local'),
              style: TextStyle(
                  color: c.text, fontSize: 15, fontWeight: FontWeight.w600)),
        ]),
      ),
      const GxHLine(),
    ]);
  }
}

class _Switcher extends StatelessWidget {
  final int tab;
  final ValueChanged<int> onTab;
  const _Switcher({required this.tab, required this.onTab});

  @override
  Widget build(BuildContext context) {
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Align(
        alignment: Alignment.centerLeft,
        child: Padding(
          padding: const EdgeInsets.only(left: 6),
          child: GxTabs<int>(
            value: tab,
            height: 40,
            items: [
              (0, tr('Раздать', 'Share', 'Compartir')),
              (1, tr('Подключиться', 'Connect', 'Conectar')),
            ],
            onChanged: onTab,
          ),
        ),
      ),
      const GxHLine(),
    ]);
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
        await BackgroundService.stop();
        _addresses = const [];
      } else {
        _addresses = await lan.start();
        // держим раздачу живой в фоне (Android foreground-сервис)
        await BackgroundService.start();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('${tr('Не удалось запустить', 'Could not start', 'No se pudo iniciar')}: $e')));
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
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 24),
          children: [
            _Card(
                c: c,
                child: Column(children: [
                  Row(children: [
                    GxIcon(on ? _gBroadcast : _gBroadcastOff,
                        color: on ? c.accent : c.muted, size: 24),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(on ? tr('Раздача включена', 'Sharing on', 'Compartir activado') : tr('Раздача выключена', 'Sharing off', 'Compartir desactivado'),
                                style: TextStyle(
                                    color: c.text,
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600)),
                            const SizedBox(height: 2),
                            Text(
                                on
                                    ? tr('Другое устройство в той же Wi-Fi сети может подключиться', 'Another device on the same Wi-Fi can connect', 'Otro dispositivo en la misma Wi-Fi puede conectarse')
                                    : tr('Включи, чтобы показать свои фото другому устройству', 'Turn on to show your photos to another device', 'Actívalo para mostrar tus fotos a otro dispositivo'),
                                style: TextStyle(color: c.muted, fontSize: 12)),
                          ]),
                    ),
                    Switch(
                      value: on,
                      onChanged: _busy ? null : (_) => _toggle(),
                    ),
                  ]),
                ])),
            if (on) ...[
              const SizedBox(height: 10),
              _Card(
                  c: c,
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(tr('PIN для подключения', 'Connection PIN', 'PIN de conexión'),
                            style: TextStyle(color: c.muted, fontSize: 12)),
                        const SizedBox(height: 4),
                        Text(_spacedPin(lan.pin),
                            style: TextStyle(
                                color: c.strong,
                                fontSize: 32,
                                fontWeight: FontWeight.w600,
                                letterSpacing: 6)),
                        const SizedBox(height: 4),
                        Text(
                            tr('Введи этот PIN на другом устройстве. Он меняется при каждом включении.', 'Enter this PIN on the other device. It changes each time sharing is turned on.', 'Introduce este PIN en el otro dispositivo. Cambia cada vez que activas el modo compartir.'),
                            style: TextStyle(color: c.muted, fontSize: 12)),
                      ])),
              const SizedBox(height: 10),
              _Card(
                  c: c,
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(tr('Адрес устройства', 'Device address', 'Dirección del dispositivo'),
                            style: TextStyle(color: c.muted, fontSize: 12)),
                        const SizedBox(height: 4),
                        if (_addresses.isEmpty)
                          Text(tr('Не нашёл сетевой адрес. Подключён ли Wi-Fi?', 'No network address found. Is Wi-Fi connected?', 'No se encontró dirección de red. ¿Wi-Fi conectado?'),
                              style: TextStyle(color: c.muted, fontSize: 13))
                        else
                          for (var i = 0; i < _addresses.length; i++) ...[
                            if (i > 0) GxHLine(color: c.rowLine),
                            _AddressRow(
                                adapter: _addresses[i],
                                port: lan.port,
                                pin: lan.pin,
                                c: c),
                          ],
                        const SizedBox(height: 8),
                        Text('${tr('Раздаётся фото', 'Photos shared', 'Fotos compartidas')}: ${lan.sharedCount}',
                            style: TextStyle(color: c.muted, fontSize: 12)),
                      ])),
            ],
            const SizedBox(height: 10),
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
        return _Card(
            c: c,
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(tr('Доверенные устройства', 'Trusted devices', 'Dispositivos de confianza'),
                  style: TextStyle(color: c.muted, fontSize: 12)),
              const SizedBox(height: 2),
              Text(tr('Эти устройства подключаются без PIN', 'These devices connect without a PIN', 'Estos dispositivos se conectan sin PIN'),
                  style: TextStyle(color: c.dim, fontSize: 12)),
              const SizedBox(height: 4),
              for (var i = 0; i < list.length; i++) ...[
                if (i > 0) GxHLine(color: c.rowLine),
                SizedBox(
                  height: 48,
                  child: Row(children: [
                    GxIcon(GxGlyph.monitor, size: 20, color: c.accent),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(list[i].name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: c.text, fontSize: 14)),
                    ),
                    GxTextBtn(tr('Забыть', 'Forget', 'Olvidar'),
                        height: 32,
                        onTap: () =>
                            LanStore.instance.forgetTrusted(list[i].token)),
                  ]),
                ),
              ],
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

  GxGlyph get _icon {
    switch (adapter.kind) {
      case 'VPN':
        return GxGlyph.shield;
      case 'Виртуальная сеть':
        return _gChip;
      case 'Wi-Fi':
        return GxGlyph.network;
      case 'Ethernet (кабель)':
        return _gEthernet;
      case 'Моб. интернет':
        return _gCellular;
      default:
        return GxGlyph.tree;
    }
  }

  @override
  Widget build(BuildContext context) {
    final address = '${adapter.ip}:$port';
    return SizedBox(
      height: 52,
      child: Row(children: [
        GxIcon(_icon, size: 20, color: adapter.private ? c.accent : c.muted),
        const SizedBox(width: 10),
        Expanded(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Flexible(
                child: Text(lanKindLabel(adapter.kind),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: c.muted, fontSize: 12)),
              ),
            ]),
            Text(address, style: TextStyle(color: c.text, fontSize: 14)),
          ]),
        ),
        GxIconBtn(
          _gQr,
          tr('QR-код', 'QR code', 'Código QR'),
          onTap: () => _showQr(context, adapter, port, pin, c),
        ),
        GxIconBtn(
          GxGlyph.copy,
          tr('Скопировать', 'Copy', 'Copiar'),
          onTap: () {
            Clipboard.setData(ClipboardData(text: address));
            ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(tr('Адрес скопирован', 'Address copied', 'Dirección copiada'))));
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
      title: Text(tr('Сканируй на другом устройстве', 'Scan on the other device', 'Escanea en el otro dispositivo')),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        // QR всегда тёмный на светлом, с полями — иначе не сканируется
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: gxCorner,
          ),
          child: QrImageView(
            data: data,
            version: QrVersions.auto,
            size: 220,
            backgroundColor: Colors.white,
          ),
        ),
        const SizedBox(height: 12),
        Text('${lanKindLabel(adapter.kind)} · ${adapter.ip}:$port',
            style: TextStyle(color: c.muted, fontSize: 12)),
        const SizedBox(height: 2),
        Text(tr('GOAT → Подключиться → Сканировать QR', 'GOAT → Connect → Scan QR', 'GOAT → Conectar → Escanear QR'),
            textAlign: TextAlign.center,
            style: TextStyle(color: c.dim, fontSize: 12)),
      ]),
      actions: [
        FilledButton(
          onPressed: () => Navigator.pop(ctx),
          child: Text(tr('Готово', 'Done', 'Listo')),
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
      return Platform.isAndroid ? 'Android' : tr('Устройство', 'Device', 'Dispositivo');
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
        content: Text(tr('Подключено к ${conn.hostName}: ${photos.length} фото', 'Connected to ${conn.hostName}: ${photos.length} photos', 'Conectado a ${conn.hostName}: ${photos.length} fotos'))));
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
      if (mounted) setState(() => _error = tr('QR не от GOAT.', 'This QR is not from GOAT.', 'Este QR no es de GOAT.'));
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
      setState(() => _error = tr('Введи адрес и PIN.', 'Enter address and PIN.', 'Introduce dirección y PIN.'));
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
      setState(() => _error = '${tr('Ошибка', 'Error', 'Error')}: $e');
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
        title: Text(tr('Не дозвонился до «${host.name}»', 'Couldn’t reach “${host.name}”', 'No se pudo contactar con «${host.name}»')),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(
              tr('Возможно, сменился адрес устройства. Уточни IP:порт (включена ли раздача на нём?).', 'The device address may have changed. Check IP:port (is sharing on there?).', 'La dirección puede haber cambiado. Revisa IP:puerto (¿está activo el modo compartir?).'),
              style: TextStyle(color: c.muted, fontSize: 13)),
          const SizedBox(height: 12),
          TextField(
            controller: ctl,
            decoration: const InputDecoration(hintText: '192.168.1.5:8787'),
          ),
        ]),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(tr('Отмена', 'Cancel', 'Cancelar')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctl.text.trim()),
            child: Text(tr('Подключиться', 'Connect', 'Conectar')),
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
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 24),
          children: [
            // ── запомненные устройства ──
            if (hosts.isNotEmpty) ...[
              _Card(
                  c: c,
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(tr('Мои устройства', 'My devices', 'Mis dispositivos'),
                            style: TextStyle(color: c.muted, fontSize: 12)),
                        const SizedBox(height: 2),
                        Text(tr('Подключение в один тап, без PIN', 'One-tap connect, no PIN', 'Conexión con un toque, sin PIN'),
                            style: TextStyle(color: c.dim, fontSize: 12)),
                        const SizedBox(height: 4),
                        for (var i = 0; i < hosts.length; i++) ...[
                          if (i > 0) GxHLine(color: c.rowLine),
                          _KnownRow(
                            host: hosts[i],
                            busy: _busyHostId == hosts[i].hostId,
                            c: c,
                            onTap: () => _connectKnown(hosts[i]),
                            onForget: () =>
                                LanStore.instance.forgetHost(hosts[i].hostId),
                          ),
                        ],
                      ])),
              const SizedBox(height: 10),
            ],

            // ── добавить новое устройство ──
            if (!_addOpen)
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(44),
                ),
                onPressed: () => setState(() => _addOpen = true),
                icon: GxIcon(GxGlyph.plus, color: c.onAccent, size: 18),
                label: Text(hosts.isEmpty
                    ? tr('Подключиться к устройству', 'Connect to a device', 'Conectar a un dispositivo')
                    : tr('Добавить новое устройство', 'Add a new device', 'Añadir un dispositivo')),
              )
            else
              _Card(
                  c: c,
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(children: [
                          Expanded(
                            child: Text(tr('Новое устройство', 'New device', 'Nuevo dispositivo'),
                                style: TextStyle(
                                    color: c.text,
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600)),
                          ),
                          GxIconBtn(
                            GxGlyph.close,
                            tr('Закрыть', 'Close', 'Cerrar'),
                            onTap: () => setState(() {
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
                              minimumSize: const Size.fromHeight(44),
                            ),
                            onPressed: _busy ? null : _scanQr,
                            icon: GxIcon(_gScan, color: c.text, size: 18),
                            label: Text(tr('Сканировать QR', 'Scan QR', 'Escanear QR')),
                          ),
                          const SizedBox(height: 12),
                          Row(children: [
                            const Expanded(child: GxHLine()),
                            Padding(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 10),
                              child: Text(tr('или вручную', 'or manually', 'o manualmente'),
                                  style:
                                      TextStyle(color: c.muted, fontSize: 12)),
                            ),
                            const Expanded(child: GxHLine()),
                          ]),
                          const SizedBox(height: 12),
                        ],
                        Text(tr('Адрес устройства', 'Device address', 'Dirección del dispositivo'),
                            style: TextStyle(color: c.muted, fontSize: 12)),
                        const SizedBox(height: 6),
                        _Field(
                          controller: _ipCtl,
                          hint: tr('например 192.168.1.5', 'e.g. 192.168.1.5', 'p. ej. 192.168.1.5'),
                          icon: GxGlyph.tree,
                          keyboard: TextInputType.text,
                          c: c,
                        ),
                        const SizedBox(height: 12),
                        Text('PIN',
                            style: TextStyle(color: c.muted, fontSize: 12)),
                        const SizedBox(height: 6),
                        _Field(
                          controller: _pinCtl,
                          hint: tr('6 цифр', '6 digits', '6 dígitos'),
                          icon: _gLock,
                          keyboard: TextInputType.number,
                          maxLen: 6,
                          c: c,
                        ),
                        if (_error != null) ...[
                          const SizedBox(height: 12),
                          Row(children: [
                            GxIcon(GxGlyph.info, size: 18, color: c.danger),
                            const SizedBox(width: 8),
                            Expanded(
                                child: Text(_error!,
                                    style: TextStyle(
                                        color: c.danger, fontSize: 13))),
                          ]),
                        ],
                        const SizedBox(height: 16),
                        FilledButton.icon(
                          style: FilledButton.styleFrom(
                            minimumSize: const Size.fromHeight(44),
                          ),
                          onPressed: _busy ? null : _pairNew,
                          icon: _busy
                              ? SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2, color: c.onAccent))
                              : GxIcon(_gLink, color: c.onAccent, size: 18),
                          label:
                              Text(_busy ? tr('Сопрягаю…', 'Pairing…', 'Emparejando…') : tr('Сопрячь устройство', 'Pair device', 'Emparejar dispositivo')),
                        ),
                      ])),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text(
                  tr('На втором устройстве открой «Локальная сеть → Раздать», включи раздачу и продиктуй адрес и PIN. PIN нужен только в первый раз — дальше устройства помнят друг друга.', 'On the other device open “Local network → Share”, turn on sharing and read out the address and PIN. The PIN is only needed the first time — after that the devices remember each other.', 'En el otro dispositivo abre «Red local → Compartir», activa el modo compartir y dicta la dirección y el PIN. El PIN solo hace falta la primera vez — después los dispositivos se recuerdan.'),
                  style: TextStyle(color: c.muted, fontSize: 12)),
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
      borderRadius: gxCorner,
      onTap: busy ? null : onTap,
      child: SizedBox(
        height: 52,
        child: Row(children: [
          busy
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : GxIcon(GxGlyph.monitor, size: 20, color: c.accent),
          const SizedBox(width: 12),
          Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(host.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: c.text, fontSize: 14)),
              Text('${host.ip}:${host.port}',
                  style: TextStyle(color: c.muted, fontSize: 12)),
            ]),
          ),
          PopupMenuButton<String>(
            icon: GxIcon(GxGlyph.more, size: 20, color: c.muted),
            onSelected: (v) {
              if (v == 'forget') onForget();
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                  value: 'forget',
                  child: Text(tr('Забыть устройство', 'Forget device',
                      'Olvidar dispositivo'))),
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
  final GxGlyph icon;
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
    return TextField(
      controller: controller,
      keyboardType: keyboard,
      maxLength: maxLen,
      style: const TextStyle(fontSize: 14),
      decoration: InputDecoration(
        counterText: '',
        hintText: hint,
        prefixIcon: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: GxIcon(icon, size: 18, color: c.muted),
        ),
        prefixIconConstraints:
            const BoxConstraints(minWidth: 42, minHeight: 18),
      ),
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
              border: Border.all(color: Colors.white, width: 2),
              borderRadius: gxCorner,
            ),
          ),
        ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Align(
              alignment: Alignment.topLeft,
              child: Material(
                color: Colors.black.withValues(alpha: 0.45),
                borderRadius: gxCorner,
                child: InkWell(
                  borderRadius: gxCorner,
                  onTap: () => Navigator.pop(context),
                  child: const SizedBox(
                    width: 44,
                    height: 40,
                    child: Center(
                        child: GxIcon(GxGlyph.close,
                            color: Colors.white, size: 19)),
                  ),
                ),
              ),
            ),
          ),
        ),
        SafeArea(
          child: Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 30),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.45),
                  borderRadius: gxCorner,
                ),
                child: Text(tr('Наведи на QR с экрана раздачи', 'Point at the QR on the sharing screen', 'Apunta al QR de la pantalla de compartir'),
                    style: const TextStyle(color: Colors.white, fontSize: 14)),
              ),
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
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SizedBox(
            height: 52,
            child: Row(children: [
              const SizedBox(width: 4),
              GxIconBtn(GxGlyph.back, tr('Назад', 'Back', 'Atrás'),
                  onTap: () => Navigator.pop(context)),
              const SizedBox(width: 6),
              Expanded(
                child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        GxIcon(_gCast, size: 16, color: c.accent),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(hostName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600,
                                  color: c.text)),
                        ),
                      ]),
                      Text('${photos.length} ${tr('фото · по сети', 'photos · over network', 'fotos · por red')}',
                          style: TextStyle(fontSize: 12, color: c.muted)),
                    ]),
              ),
              const SizedBox(width: 14),
            ]),
          ),
          const GxHLine(),
          Expanded(
            child: photos.isEmpty
                ? Center(
                    child: Text(tr('У этого устройства нет фото', 'This device has no photos', 'Este dispositivo no tiene fotos'),
                        style: TextStyle(color: c.muted)))
                : GridView.builder(
                    padding: const EdgeInsets.fromLTRB(14, 10, 14, 18),
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
        borderRadius: BorderRadius.circular(s.gridRadius > 7 ? 7.0 : s.gridRadius),
        child: Stack(fit: StackFit.expand, children: [
          Container(color: c.active),
          if (photo.isVideo)
            Center(
              child: Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.45),
                  borderRadius: gxCorner,
                ),
                child: const Center(
                    child: GxIcon(_gPlay, color: Colors.white, size: 24)),
              ),
            )
          else
            Image(
              image: photo.thumb(cacheWidth),
              fit: s.squareThumbs ? BoxFit.cover : BoxFit.contain,
              gaplessPlayback: true,
              filterQuality: FilterQuality.low,
              frameBuilder: (ctx, child, frame, wasSync) {
                if (wasSync || frame != null) return child;
                return Container(
                  color: c.active,
                  child: const Center(
                    child: SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 1.6),
                    ),
                  ),
                );
              },
              errorBuilder: (ctx, e, st) =>
                  Center(child: GxIcon(GxGlyph.gallery, color: c.muted, size: 18)),
            ),
          if (photo.isVideo)
            Positioned(
              right: 5,
              bottom: 5,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(5),
                ),
                child: const Text('VIDEO',
                    style: TextStyle(color: Colors.white, fontSize: 10)),
              ),
            ),
          if (photo.isGif && s.showGifBadge)
            Positioned(
              right: 5,
              bottom: 5,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(5),
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
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: c.panel,
        borderRadius: gxCorner,
        border: Border.all(color: c.line),
      ),
      child: child,
    );
  }
}
