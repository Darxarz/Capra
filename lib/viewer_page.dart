import 'dart:io';
import 'package:flutter/material.dart';
import 'theme.dart';
import 'model.dart';
import 'editor_service.dart';
import 'i18n.dart';
import 'favorites.dart';
import 'tag_service.dart';
import 'tagger_service.dart';
import 'metadata_service.dart';
import 'settings_service.dart';
import 'media_actions.dart';

/// Открыть просмотрщик на конкретном фото.
void openViewer(BuildContext context, List<PhotoItem> photos, int index) {
  Navigator.of(context).push(MaterialPageRoute(
    builder: (_) => ViewerPage(photos: photos, initialIndex: index),
  ));
}

class ViewerPage extends StatefulWidget {
  final List<PhotoItem> photos;
  final int initialIndex;
  const ViewerPage({super.key, required this.photos, required this.initialIndex});

  @override
  State<ViewerPage> createState() => _ViewerPageState();
}

class _ViewerPageState extends State<ViewerPage> {
  late final PageController _controller;
  late int _index;
  bool _infoOpen = false; // боковая панель свёрнута по умолчанию

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex;
    _controller = PageController(initialPage: _index);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = AuroraTheme.of(context).colors;
    final photo = widget.photos[_index];

    final stage = Stack(
      children: [
        Positioned.fill(
          child: PageView.builder(
            controller: _controller,
            itemCount: widget.photos.length,
            onPageChanged: (i) => setState(() => _index = i),
            itemBuilder: (ctx, i) => InteractiveViewer(
              minScale: 1,
              maxScale: 5,
              child: Center(
                child: Image(
                  image: widget.photos[i].full,
                  fit: BoxFit.contain,
                  errorBuilder: (c2, e, s) =>
                      const Icon(Icons.broken_image_outlined, color: Colors.white54, size: 48),
                ),
              ),
            ),
          ),
        ),
        Positioned(
          top: 14,
          left: 14,
          child: _RoundBtn(icon: Icons.close, onTap: () => Navigator.pop(context)),
        ),
        // кнопка «инфо» — открывает/прячет выезжающую панель
        Positioned(
          top: 14,
          right: 14,
          child: _RoundBtn(
            icon: _infoOpen ? Icons.info : Icons.info_outline,
            onTap: () => setState(() => _infoOpen = !_infoOpen),
          ),
        ),
      ],
    );

    return Scaffold(
      backgroundColor: const Color(0xFF100D0B),
      body: SafeArea(
        child: LayoutBuilder(builder: (ctx, cns) {
          final wide = cns.maxWidth > 720;
          final dur = SettingsService.instance.reduceMotion
              ? Duration.zero
              : const Duration(milliseconds: 220);
          // на ПК панель шириной 360, на телефоне — лист на 78% высоты
          final panelW = wide ? 360.0 : cns.maxWidth;
          final panelH = wide ? cns.maxHeight : cns.maxHeight * 0.78;

          return Stack(children: [
            Positioned.fill(child: stage),

            // затемнение-подложка: тап мимо панели закрывает её
            if (_infoOpen)
              Positioned.fill(
                child: GestureDetector(
                  onTap: () => setState(() => _infoOpen = false),
                  child: Container(color: Colors.black.withValues(alpha: 0.45)),
                ),
              ),

            // сама панель — выезжает справа (ПК) или снизу (телефон)
            if (wide)
              AnimatedPositioned(
                duration: dur,
                curve: Curves.easeOutCubic,
                top: 0,
                bottom: 0,
                right: _infoOpen ? 0 : -panelW,
                width: panelW,
                child: _InfoPanel(photo: photo, colors: c),
              )
            else
              AnimatedPositioned(
                duration: dur,
                curve: Curves.easeOutCubic,
                left: 0,
                right: 0,
                height: panelH,
                bottom: _infoOpen ? 0 : -panelH,
                child: ClipRRect(
                  borderRadius:
                      const BorderRadius.vertical(top: Radius.circular(20)),
                  child: _InfoPanel(
                      photo: photo, colors: c, showHandle: true),
                ),
              ),
          ]);
        }),
      ),
    );
  }
}

class _RoundBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  const _RoundBtn({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white24,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(
          width: 42,
          height: 42,
          child: Icon(icon, color: Colors.white, size: 20),
        ),
      ),
    );
  }
}

class _InfoPanel extends StatelessWidget {
  final PhotoItem photo;
  final AuroraColors colors;
  final bool showHandle; // показывать «ручку» сверху (лист на телефоне)
  const _InfoPanel(
      {required this.photo, required this.colors, this.showHandle = false});

  @override
  Widget build(BuildContext context) {
    final c = colors;
    Widget row(String k, String v) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Text(k, style: TextStyle(color: c.muted, fontSize: 13)),
            const SizedBox(width: 12),
            Flexible(
              child: Text(v,
                  textAlign: TextAlign.right,
                  style: TextStyle(color: c.text, fontSize: 13, fontWeight: FontWeight.w600)),
            ),
          ]),
        );

    Widget action(IconData icon, String label,
            {VoidCallback? onTap, bool active = false}) =>
        Expanded(
          child: GestureDetector(
            onTap: onTap,
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 4),
              padding: const EdgeInsets.symmetric(vertical: 11),
              decoration: BoxDecoration(
                color: active ? c.accentSoft : c.surface2,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: active ? c.accent : c.line),
              ),
              child: Column(children: [
                Icon(icon, size: 19, color: active ? c.accentInk : c.text),
                const SizedBox(height: 4),
                Text(label,
                    style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        color: active ? c.accentInk : c.text)),
              ]),
            ),
          ),
        );

    return Container(
      color: c.surface,
      padding: EdgeInsets.fromLTRB(22, showHandle ? 10 : 24, 22, 24),
      child: ListView(children: [
        if (showHandle)
          Center(
            child: Container(
              width: 40,
              height: 4,
              margin: const EdgeInsets.only(bottom: 14),
              decoration: BoxDecoration(
                color: c.line,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
        Text(photo.fileName,
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: c.text)),
        const SizedBox(height: 4),
        Text(prettyDate(photo.modified), style: TextStyle(fontSize: 13, color: c.muted)),
        if (photo.isProject) ...[
          const SizedBox(height: 14),
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: c.accent,
              minimumSize: const Size.fromHeight(46),
            ),
            onPressed: () => MediaActions.openInEditor(context, photo),
            icon: const Icon(Icons.open_in_new_rounded),
            label: Text('Открыть ${photo.extension.replaceFirst('.', '').toUpperCase()} '
                'в редакторе'),
          ),
        ],
        // «Открыть в…» — найденные в системе редакторы (ПК)
        if (!photo.isRemote && (Platform.isWindows || Platform.isLinux)) ...[
          const SizedBox(height: 16),
          _OpenInRow(photo: photo, colors: c),
        ],
        const SizedBox(height: 18),
        _TagsSection(photo: photo, colors: c),
        const SizedBox(height: 20),
        ValueListenableBuilder<Set<String>>(
          valueListenable: Favorites.instance.notifier,
          builder: (ctx, favs, _) {
            final fav = favs.contains(photo.path);
            return Row(children: [
              action(
                fav ? Icons.favorite : Icons.favorite_border,
                fav ? 'В избранном' : 'В избранное',
                onTap: () => Favorites.instance.toggle(photo.path),
                active: fav,
              ),
              action(Icons.folder_outlined, 'В альбом'),
              action(Icons.ios_share, 'Поделиться'),
            ]);
          },
        ),
        const SizedBox(height: 22),
        Divider(color: c.line, height: 1),
        row('Размер', prettySize(photo.sizeBytes)),
        Divider(color: c.line, height: 1),
        row('Папка', photo.folderName),
        const SizedBox(height: 16),
        Text('Путь', style: TextStyle(color: c.muted, fontSize: 13)),
        const SizedBox(height: 4),
        SelectableText(photo.path,
            style: TextStyle(color: c.text, fontSize: 12)),
        const SizedBox(height: 18),
        _MetaSection(photo: photo, colors: c),
      ]),
    );
  }
}

// ───────────────────────── «Открыть в…» (редакторы) ─────────────────────────
class _OpenInRow extends StatefulWidget {
  final PhotoItem photo;
  final AuroraColors colors;
  const _OpenInRow({required this.photo, required this.colors});

  @override
  State<_OpenInRow> createState() => _OpenInRowState();
}

class _OpenInRowState extends State<_OpenInRow> {
  List<EditorApp> _apps = const [];

  @override
  void initState() {
    super.initState();
    EditorService.available().then((a) {
      if (mounted) setState(() => _apps = a);
    });
  }

  Widget _chip(IconData? icon, String? badge, String label, Color color,
      VoidCallback onTap) {
    final c = widget.colors;
    return GestureDetector(
      onTap: onTap,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: 46,
          height: 46,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(13),
          ),
          alignment: Alignment.center,
          child: icon != null
              ? Icon(icon, color: Colors.white, size: 20)
              : Text(badge ?? '',
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w800)),
        ),
        const SizedBox(height: 4),
        SizedBox(
          width: 56,
          child: Text(label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(color: c.muted, fontSize: 10.5)),
        ),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.colors;
    final path = widget.photo.path;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(tr('Открыть в…', 'Open in…'),
          style: TextStyle(
              color: c.muted, fontSize: 12.5, fontWeight: FontWeight.w600)),
      const SizedBox(height: 10),
      Wrap(spacing: 12, runSpacing: 12, children: [
        for (final app in _apps)
          _chip(null, app.badge, app.name, app.color,
              () => EditorService.openIn(app, path)),
        if (Platform.isWindows)
          _chip(Icons.more_horiz_rounded, null, tr('Другое…', 'Other…'),
              const Color(0xFF6B7280),
              () => EditorService.openWithDialog(path)),
      ]),
      if (_apps.isEmpty && !Platform.isWindows)
        Text('Редакторы не найдены.',
            style: TextStyle(color: c.muted, fontSize: 12)),
    ]);
  }
}

// ───────────────────────── метаданные (EXIF / AI) ─────────────────────────
class _MetaSection extends StatefulWidget {
  final PhotoItem photo;
  final AuroraColors colors;
  const _MetaSection({required this.photo, required this.colors});

  @override
  State<_MetaSection> createState() => _MetaSectionState();
}

class _MetaSectionState extends State<_MetaSection> {
  PhotoMeta? _meta;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(_MetaSection old) {
    super.didUpdateWidget(old);
    if (old.photo.path != widget.photo.path) _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final m = await readMetadata(widget.photo.path);
    if (mounted) {
      setState(() {
        _meta = m;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.colors;
    if (_loading) {
      return Row(children: [
        SizedBox(
            width: 13,
            height: 13,
            child: CircularProgressIndicator(strokeWidth: 2, color: c.muted)),
        const SizedBox(width: 8),
        Text('Читаю метаданные…',
            style: TextStyle(color: c.muted, fontSize: 12)),
      ]);
    }
    final m = _meta;
    if (m == null || !m.hasAnything) {
      return Text('Метаданные не найдены.',
          style: TextStyle(color: c.muted, fontSize: 12));
    }

    Widget kv(String k, String v) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(k, style: TextStyle(color: c.muted, fontSize: 12.5)),
                const SizedBox(width: 12),
                Flexible(
                  child: Text(v,
                      textAlign: TextAlign.right,
                      style: TextStyle(
                          color: c.text,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600)),
                ),
              ]),
        );

    Widget promptBox(String label, String value, Color bg) => Container(
          width: double.infinity,
          margin: const EdgeInsets.only(top: 8),
          padding: const EdgeInsets.fromLTRB(11, 9, 11, 10),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(11),
            border: Border.all(color: c.line),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label,
                style: TextStyle(
                    color: c.muted,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.3)),
            const SizedBox(height: 4),
            SelectableText(value,
                style: TextStyle(color: c.text, fontSize: 12.5, height: 1.35)),
          ]),
        );

    final children = <Widget>[
      Row(children: [
        Icon(m.isAi ? Icons.auto_awesome : Icons.info_outline,
            size: 16, color: c.accent),
        const SizedBox(width: 6),
        Text(m.isAi ? 'Параметры генерации' : 'Метаданные',
            style: TextStyle(
                color: c.text, fontSize: 14, fontWeight: FontWeight.w700)),
        if (m.aiTool != null) ...[
          const Spacer(),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: c.accentSoft,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(m.aiTool!,
                style: TextStyle(
                    color: c.accentInk,
                    fontSize: 11,
                    fontWeight: FontWeight.w700)),
          ),
        ],
      ]),
    ];

    if (m.width != null && m.height != null) {
      children.add(kv('Разрешение', '${m.width}×${m.height}'));
    }
    if (m.prompt != null && m.prompt!.isNotEmpty) {
      children.add(promptBox('PROMPT', m.prompt!, c.surface2));
    }
    if (m.negative != null && m.negative!.isNotEmpty) {
      children.add(promptBox('NEGATIVE', m.negative!, c.surface2));
    }
    if (m.aiParams.isNotEmpty) {
      children.add(const SizedBox(height: 4));
      for (final e in m.aiParams) {
        children.add(kv(e.key, e.value));
      }
    }
    if (m.exif.isNotEmpty) {
      if (m.isAi) children.add(const SizedBox(height: 4));
      for (final e in m.exif) {
        children.add(kv(e.key, e.value));
      }
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: children);
  }
}

// ───────────────────────── теги фото ─────────────────────────
class _TagsSection extends StatefulWidget {
  final PhotoItem photo;
  final AuroraColors colors;
  const _TagsSection({required this.photo, required this.colors});

  @override
  State<_TagsSection> createState() => _TagsSectionState();
}

class _TagsSectionState extends State<_TagsSection> {
  final _ctl = TextEditingController();
  List<String> _tags = const [];
  bool _busy = false;
  String _busyText = '';
  double? _busyProgress;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _autoTag() async {
    if (_busy) return;
    final tagger = Tagger.instance;
    if (!await tagger.isDownloaded()) {
      if (!mounted) return;
      final c = widget.colors;
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: c.surface,
          title: Text('Скачать ИИ-модель?', style: TextStyle(color: c.text)),
          content: Text(
            'Для авто-тегирования нужна модель WD (danbooru/аниме/арт), '
            '~380 МБ. Скачивается один раз, дальше работает офлайн.',
            style: TextStyle(color: c.muted),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text('Отмена', style: TextStyle(color: c.muted))),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: c.accent),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Скачать'),
            ),
          ],
        ),
      );
      if (ok != true) return;
      setState(() {
        _busy = true;
        _busyText = 'Скачивание модели…';
        _busyProgress = 0;
      });
      try {
        await tagger.download(onProgress: (pr) {
          if (mounted) setState(() => _busyProgress = pr);
        });
      } catch (e) {
        if (mounted) setState(() => _busy = false);
        _snack('Не удалось скачать модель: $e');
        return;
      }
    }
    setState(() {
      _busy = true;
      _busyText = 'Распознаю…';
      _busyProgress = null;
    });
    try {
      final n = await tagger.tagAndStore(widget.photo.path);
      _snack('Добавлено тегов: $n');
    } catch (e) {
      _snack('Ошибка тегирования: $e');
    }
    if (mounted) {
      setState(() => _busy = false);
      _load();
    }
  }

  @override
  void didUpdateWidget(_TagsSection old) {
    super.didUpdateWidget(old);
    if (old.photo.path != widget.photo.path) _load();
  }

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  void _load() =>
      setState(() => _tags = TagService.instance.tagsFor(widget.photo.path));

  void _add() {
    final t = _ctl.text.trim();
    if (t.isEmpty) return;
    TagService.instance.addTag(widget.photo.path, t);
    _ctl.clear();
    _load();
  }

  void _remove(String t) {
    TagService.instance.removeTag(widget.photo.path, t);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          Icon(Icons.sell_outlined, size: 16, color: c.muted),
          const SizedBox(width: 6),
          Text('Теги',
              style: TextStyle(
                  color: c.text, fontSize: 14, fontWeight: FontWeight.w700)),
          const Spacer(),
          if (!_busy)
            GestureDetector(
              onTap: _autoTag,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
                decoration: BoxDecoration(
                  color: c.accent,
                  borderRadius: BorderRadius.circular(9),
                ),
                child: const Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.auto_awesome, size: 15, color: Colors.white),
                  SizedBox(width: 6),
                  Text('Тегировать',
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600)),
                ]),
              ),
            ),
        ]),
        if (_busy) ...[
          const SizedBox(height: 10),
          Row(children: [
            SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2, color: c.accent),
            ),
            const SizedBox(width: 8),
            Text(
                _busyProgress != null
                    ? '$_busyText ${((_busyProgress ?? 0) * 100).round()}%'
                    : _busyText,
                style: TextStyle(color: c.muted, fontSize: 12)),
          ]),
          if (_busyProgress != null) ...[
            const SizedBox(height: 6),
            LinearProgressIndicator(
                value: _busyProgress, color: c.accent, backgroundColor: c.surface2),
          ],
        ],
        const SizedBox(height: 10),
        if (_tags.isEmpty)
          Text('Пока нет тегов. Добавь вручную или запусти авто-тегирование.',
              style: TextStyle(color: c.muted, fontSize: 12))
        else
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final t in _tags)
                Container(
                  padding: const EdgeInsets.fromLTRB(10, 5, 6, 5),
                  decoration: BoxDecoration(
                    color: c.accentSoft,
                    borderRadius: BorderRadius.circular(9),
                  ),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Text(t,
                        style: TextStyle(color: c.accentInk, fontSize: 12.5)),
                    const SizedBox(width: 4),
                    GestureDetector(
                      onTap: () => _remove(t),
                      child: Icon(Icons.close, size: 14, color: c.accentInk),
                    ),
                  ]),
                ),
            ],
          ),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
              decoration: BoxDecoration(
                color: c.surface2,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: c.line),
              ),
              child: TextField(
                controller: _ctl,
                onSubmitted: (_) => _add(),
                cursorColor: c.accent,
                style: TextStyle(color: c.text, fontSize: 13),
                decoration: InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  hintText: 'Добавить тег…',
                  hintStyle: TextStyle(color: c.muted, fontSize: 13),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: _add,
            child: Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: c.accent,
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(Icons.add, color: Colors.white, size: 20),
            ),
          ),
        ]),
      ],
    );
  }
}