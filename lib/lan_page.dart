import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'theme.dart';
import 'model.dart';
import 'lan_service.dart';
import 'lan_client.dart';
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
  List<String> _addresses = const [];
  bool _busy = false;

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
                    _AddressRow(address: '$a:${lan.port}', c: c),
                const SizedBox(height: 6),
                Text('Раздаётся фото: ${lan.sharedCount}',
                    style: TextStyle(color: c.muted, fontSize: 12.5)),
              ])),
            ],
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

class _AddressRow extends StatelessWidget {
  final String address;
  final AuroraColors c;
  const _AddressRow({required this.address, required this.c});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [
        Icon(Icons.lan_outlined, size: 18, color: c.muted),
        const SizedBox(width: 10),
        Expanded(
          child: Text(address,
              style: TextStyle(
                  color: c.text, fontSize: 15, fontWeight: FontWeight.w600)),
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
  String? _error;

  @override
  void dispose() {
    _ipCtl.dispose();
    _pinCtl.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    var ip = _ipCtl.text.trim();
    var port = LanService.instance.port; // по умолчанию 8787
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
      final conn = await LanClient.connect(ip: ip, port: port, pin: pin);
      final photos = await LanClient.fetchAll(conn);
      if (!mounted) return;
      navigator.push(MaterialPageRoute(
        builder: (_) => _RemoteGalleryPage(
            hostName: conn.hostName, photos: photos),
      ));
      messenger.showSnackBar(SnackBar(
          content: Text('Подключено к ${conn.hostName}: ${photos.length} фото')));
    } on LanError catch (e) {
      setState(() => _error = e.message);
    } catch (e) {
      setState(() => _error = 'Ошибка: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = AuroraTheme.of(context).colors;
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
      children: [
        _Card(c: c, child: Column(
          crossAxisAlignment: CrossAxisAlignment.start, children: [
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
            onPressed: _busy ? null : _connect,
            icon: _busy
                ? const SizedBox(
                    width: 18, height: 18,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.cast_connected_rounded),
            label: Text(_busy ? 'Подключаюсь…' : 'Подключиться'),
          ),
        ])),
        const SizedBox(height: 14),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Text(
              'На втором устройстве открой «Локальная сеть → Раздать», '
              'включи раздачу и продиктуй адрес и PIN.',
              style: TextStyle(color: c.muted, fontSize: 12.5)),
        ),
      ],
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
