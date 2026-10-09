import 'dart:io';
import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';
import 'theme.dart';
import 'gx.dart';
import 'model.dart';
import 'integrity_service.dart';
import 'trash_service.dart';
import 'i18n.dart';

// ── свои значки для этого экрана (24×24, линия 1.6) ──
const _gVerified = GxGlyph(
    'M12 3.5l7 2.5v5.5c0 4.5-3 7.7-7 9-4-1.3-7-4.5-7-9V6zM8.8 12l2.4 2.4 4-4.4',
    true);
const _gWarning = GxGlyph('M12 4l9 16H3zM12 10v4.500M12 17.200v.2', true);
const _gRestore = GxGlyph('M4.500 12a7.500 7.500 0 1 1 2.200 5.300M4.500 4v4h4M12 8v4.500l3 1.500');

/// Экран менеджера дубликатов: поиск точных/похожих дублей, проверка
/// целостности, группировка с разбивкой по папкам и удаление в корзину.
class DupPage extends StatefulWidget {
  final List<PhotoItem> photos;
  final VoidCallback onLibraryChanged;
  const DupPage(
      {super.key, required this.photos, required this.onLibraryChanged});

  @override
  State<DupPage> createState() => _DupPageState();
}

class _DupPageState extends State<DupPage> {
  final _scanner = DupScanner.instance;
  final Set<String> _selected = {};
  DupResult? _lastResult;

  @override
  void initState() {
    super.initState();
    _scanner.addListener(_onScan);
    if (_scanner.result != null) _initSelection(_scanner.result!);
  }

  @override
  void dispose() {
    _scanner.removeListener(_onScan);
    super.dispose();
  }

  void _onScan() {
    if (!mounted) return;
    final r = _scanner.result;
    if (r != null && !identical(r, _lastResult)) _initSelection(r);
    setState(() {});
  }

  // по умолчанию выбираем всё, кроме «лучшего» в каждой группе
  void _initSelection(DupResult r) {
    _lastResult = r;
    _selected.clear();
    for (final g in r.groups) {
      final best = g.best;
      for (final f in g.files) {
        if (f.path != best.path) _selected.add(f.path);
      }
    }
  }

  int get _selectedBytes {
    final r = _scanner.result;
    if (r == null) return 0;
    var s = 0;
    for (final g in r.groups) {
      for (final f in g.files) {
        if (_selected.contains(f.path)) s += f.size;
      }
    }
    for (final f in r.corrupt) {
      if (_selected.contains(f.path)) s += f.size;
    }
    return s;
  }

  /// Удаление: на Android — в системную корзину через MediaStore (scoped
  /// storage не даёт удалять медиа по пути); иначе — в корзину GOAT.
  Future<int> _performDelete(List<String> paths) async {
    if (Platform.isAndroid) {
      final ids = <String>[];
      final noId = <String>[];
      for (final path in paths) {
        final id = _scanner.assetIdFor(path);
        if (id != null) {
          ids.add(id);
        } else {
          noId.add(path);
        }
      }
      var moved = 0;
      if (ids.isNotEmpty) {
        final entities = <AssetEntity>[];
        for (final id in ids) {
          final e = await AssetEntity.fromId(id);
          if (e != null) entities.add(e);
        }
        if (entities.isNotEmpty) {
          final res = await PhotoManager.editor.android.moveToTrash(entities);
          moved += res.length;
        }
      }
      if (noId.isNotEmpty) moved += await TrashService.instance.trash(noId);
      return moved;
    }
    return TrashService.instance.trash(paths);
  }

  Future<void> _trashSelected() async {
    if (_selected.isEmpty) return;
    final n = _selected.length;
    final desc = Platform.isAndroid
        ? '${tr('Файлы уйдут в системную корзину — их можно вернуть из «Недавно удалённых».', 'Files will go to the system trash — you can restore them from Recently Deleted.', 'Los archivos irán a la papelera del sistema; puedes restaurarlos desde Eliminados recientemente.')} '
            '${tr('Освободится', 'Will free', 'Se liberarán')} ${prettySize(_selectedBytes)}.'
        : '${tr('Файлы переедут в корзину GOAT — их можно вернуть.', 'Files will move to the GOAT trash — you can restore them.', 'Los archivos irán a la papelera de GOAT; puedes restaurarlos.')} '
            '${tr('Освободится', 'Will free', 'Se liberarán')} ${prettySize(_selectedBytes)}.';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('Удалить $n файлов?', 'Delete $n files?',
            '¿Eliminar $n archivos?')),
        content: Text(desc),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr('Отмена', 'Cancel', 'Cancelar')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('В корзину', 'To trash', 'A la papelera')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final moved = await _performDelete(_selected.toList());
    // убрать перемещённые из результата
    final r = _scanner.result;
    if (r != null) {
      final gone = _selected;
      final groups = <DupGroup>[];
      for (final g in r.groups) {
        final remain = g.files.where((f) => !gone.contains(f.path)).toList();
        if (remain.length >= 2) {
          groups.add(DupGroup(exact: g.exact, files: remain));
        }
      }
      final corrupt = r.corrupt.where((f) => !gone.contains(f.path)).toList();
      _scanner.result = DupResult(groups: groups, corrupt: corrupt);
    }
    _selected.clear();
    widget.onLibraryChanged();
    if (mounted) {
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(
                '${tr('Перемещено в корзину', 'Moved to trash', 'Movido a la papelera')}: $moved')),
      );
    }
  }


  @override
  Widget build(BuildContext context) {
    final c = AuroraTheme.of(context).colors;
    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _header(c),
            const GxHLine(),
            Expanded(child: _content(c)),
            if (_selected.isNotEmpty) _actionBar(c),
          ],
        ),
      ),
    );
  }

  Widget _header(AuroraColors c) => SizedBox(
        height: 52,
        child: Row(children: [
          const SizedBox(width: 4),
          GxIconBtn(GxGlyph.back, tr('Назад', 'Back', 'Atrás'),
              onTap: () => Navigator.pop(context)),
          const SizedBox(width: 6),
          Text(tr('Дубликаты', 'Duplicates', 'Duplicados'),
              style: TextStyle(
                  fontSize: 15, fontWeight: FontWeight.w600, color: c.text)),
          const Spacer(),
          if (!Platform.isAndroid)
            Material(
              color: Colors.transparent,
              shape: RoundedRectangleBorder(
                borderRadius: gxCorner,
                side: BorderSide(color: c.field),
              ),
              child: InkWell(
                borderRadius: gxCorner,
                onTap: () async {
                  await Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) =>
                        TrashPage(onChanged: widget.onLibraryChanged),
                  ));
                  if (mounted) setState(() {});
                },
                child: Container(
                  height: 36,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    GxIcon(GxGlyph.bin, size: 17, color: c.muted),
                    const SizedBox(width: 6),
                    Text(
                        '${tr('Корзина', 'Trash', 'Papelera')} ${TrashService.instance.count}',
                        style: TextStyle(color: c.text, fontSize: 13)),
                  ]),
                ),
              ),
            ),
          const SizedBox(width: 14),
        ]),
      );

  Widget _content(AuroraColors c) {
    if (_scanner.running) return _progress(c);
    final r = _scanner.result;
    if (r == null) return _intro(c);
    return _results(c, r);
  }

  Widget _intro(AuroraColors c) {
    Widget card(String title, String desc, GxGlyph icon, bool similar) =>
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
          child: Material(
            color: c.panel,
            shape: RoundedRectangleBorder(
              borderRadius: gxCorner,
              side: BorderSide(color: c.line),
            ),
            child: InkWell(
              borderRadius: gxCorner,
              onTap: () => _scanner.scan(widget.photos, similar: similar),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(children: [
                  GxIcon(icon, color: c.accent, size: 22),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(title,
                              style: TextStyle(
                                  color: c.text,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600)),
                          const SizedBox(height: 2),
                          Text(desc,
                              style: TextStyle(color: c.muted, fontSize: 12)),
                        ]),
                  ),
                  const SizedBox(width: 8),
                  GxIcon(GxGlyph.forward, color: c.muted, size: 18),
                ]),
              ),
            ),
          ),
        );

    return ListView(children: [
      const SizedBox(height: 12),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14),
        child: Text(
            tr(
                'Найдём повторы и повреждённые файлы среди ${widget.photos.length} изображений.',
                'We’ll find duplicates and damaged files among ${widget.photos.length} images.',
                'Buscaremos duplicados y archivos dañados entre ${widget.photos.length} imágenes.'),
            style: TextStyle(color: c.muted, fontSize: 13)),
      ),
      const SizedBox(height: 8),
      card(
          tr('Точные дубликаты', 'Exact duplicates', 'Duplicados exactos'),
          tr(
              'Побайтово одинаковые файлы. Быстро.',
              'Byte-for-byte identical files. Fast.',
              'Archivos idénticos byte a byte. Rápido.'),
          GxGlyph.copy,
          false),
      card(
          tr('Похожие изображения', 'Similar images', 'Imágenes similares'),
          tr(
              'Пережатые, уменьшенные, «зашакаленные» копии + проверка целостности. Медленнее.',
              'Recompressed, resized or messy copies + integrity check. Slower.',
              'Copias recomprimidas, reducidas o degradadas + revisión de integridad. Más lento.'),
          GxGlyph.mosaic,
          true),
    ]);
  }

  Widget _progress(AuroraColors c) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(_scanner.phase,
                style: TextStyle(
                    color: c.text, fontSize: 14, fontWeight: FontWeight.w600)),
            const SizedBox(height: 12),
            LinearProgressIndicator(
              value: _scanner.total == 0 ? null : _scanner.progress,
              minHeight: 3,
            ),
            const SizedBox(height: 10),
            Text('${_scanner.done} / ${_scanner.total}',
                style: TextStyle(color: c.muted, fontSize: 13)),
            const SizedBox(height: 16),
            GxTextBtn(tr('Остановить', 'Stop', 'Detener'),
                onTap: () => _scanner.stop()),
          ]),
        ),
      );

  Widget _results(AuroraColors c, DupResult r) {
    if (r.groups.isEmpty && r.corrupt.isEmpty) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          GxIcon(_gVerified, size: 48, color: c.accent),
          const SizedBox(height: 12),
          Text(
              tr('Дубликатов не найдено', 'No duplicates found',
                  'No se encontraron duplicados'),
              style: TextStyle(
                  color: c.text, fontSize: 15, fontWeight: FontWeight.w600)),
          const SizedBox(height: 14),
          GxTextBtn(tr('Новый поиск', 'New scan', 'Nueva búsqueda'),
              onTap: () => setState(() => _scanner.result = null)),
        ]),
      );
    }
    return ListView(
      padding: const EdgeInsets.only(bottom: 20),
      children: [
        _summary(c, r),
        for (final g in r.groups) _groupCard(c, g),
        if (r.corrupt.isNotEmpty) _corruptSection(c, r.corrupt),
      ],
    );
  }

  Widget _summary(AuroraColors c, DupResult r) => Padding(
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 6),
        child: Row(children: [
          Expanded(
            child: Text(
                '${r.groups.length} ${tr('групп', 'groups', 'grupos')} · ${r.totalDuplicates} ${tr('лишних', 'extra', 'sobrantes')} · ${tr('можно освободить', 'can free', 'se pueden liberar')} ${prettySize(r.reclaimableBytes)}'
                '${r.corrupt.isNotEmpty ? ' · ${tr('повреждённых', 'damaged', 'dañados')} ${r.corrupt.length}' : ''}',
                style: TextStyle(color: c.muted, fontSize: 12)),
          ),
          const SizedBox(width: 8),
          GxTextBtn(tr('Заново', 'Again', 'Otra vez'),
              height: 32,
              onTap: () => setState(() => _scanner.result = null)),
        ]),
      );

  Widget _groupCard(AuroraColors c, DupGroup g) {
    // разбивка по папкам
    final byFolder = <String, List<DupFile>>{};
    for (final f in g.files) {
      byFolder.putIfAbsent(f.folderPath, () => []).add(f);
    }
    final best = g.best;
    return Container(
      margin: const EdgeInsets.fromLTRB(14, 5, 14, 5),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      decoration: BoxDecoration(
        color: c.panel,
        borderRadius: gxCorner,
        border: Border.all(color: c.line),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          GxIcon(g.exact ? GxGlyph.copy : GxGlyph.mosaic,
              size: 16, color: c.accent),
          const SizedBox(width: 8),
          Text(
              g.exact
                  ? '${tr('Точные', 'Exact', 'Exactos')} · ${g.files.length}'
                  : '${tr('Похожие', 'Similar', 'Similares')} · ${g.files.length}',
              style: TextStyle(
                  color: c.text, fontSize: 13, fontWeight: FontWeight.w600)),
          const Spacer(),
          Text(
              '${tr('освободить', 'free', 'liberar')} ${prettySize(g.reclaimable)}',
              style: TextStyle(color: c.muted, fontSize: 12)),
        ]),
        for (final entry in byFolder.entries) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(0, 10, 0, 6),
            child: Row(children: [
              GxIcon(GxGlyph.folder, size: 14, color: c.muted),
              const SizedBox(width: 6),
              Expanded(
                child: Text(entry.key,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: c.muted, fontSize: 12)),
              ),
              Text('${entry.value.length}',
                  style: TextStyle(color: c.muted, fontSize: 12)),
            ]),
          ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final f in entry.value)
                _DupThumb(
                  file: f,
                  isBest: f.path == best.path,
                  selected: _selected.contains(f.path),
                  colors: c,
                  onTap: () => setState(() {
                    if (!_selected.add(f.path)) _selected.remove(f.path);
                  }),
                ),
            ],
          ),
        ],
      ]),
    );
  }

  Widget _corruptSection(AuroraColors c, List<DupFile> corrupt) => Container(
        margin: const EdgeInsets.fromLTRB(14, 10, 14, 5),
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
        decoration: BoxDecoration(
          color: c.panel,
          borderRadius: gxCorner,
          border: Border.all(color: c.danger.withValues(alpha: 0.5)),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            GxIcon(_gWarning, size: 16, color: c.danger),
            const SizedBox(width: 8),
            Text(
                '${tr('Повреждённые', 'Damaged', 'Dañados')} · ${corrupt.length}',
                style: TextStyle(
                    color: c.text, fontSize: 13, fontWeight: FontWeight.w600)),
            const Spacer(),
            GestureDetector(
              onTap: () => setState(() {
                final all = corrupt.every((f) => _selected.contains(f.path));
                for (final f in corrupt) {
                  if (all) {
                    _selected.remove(f.path);
                  } else {
                    _selected.add(f.path);
                  }
                }
              }),
              child: Text(tr('Выбрать все', 'Select all', 'Seleccionar todo'),
                  style: TextStyle(color: c.accent, fontSize: 12)),
            ),
          ]),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final f in corrupt)
                _DupThumb(
                  file: f,
                  isBest: false,
                  selected: _selected.contains(f.path),
                  colors: c,
                  onTap: () => setState(() {
                    if (!_selected.add(f.path)) _selected.remove(f.path);
                  }),
                ),
            ],
          ),
        ]),
      );

  Widget _actionBar(AuroraColors c) => Container(
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
        decoration: BoxDecoration(
          color: c.panel,
          border: Border(top: BorderSide(color: c.line)),
        ),
        child: Row(children: [
          Expanded(
            child: Text(
                '${tr('Выбрано', 'Selected', 'Seleccionado')}: ${_selected.length} · ${prettySize(_selectedBytes)}',
                style: TextStyle(color: c.text, fontSize: 13)),
          ),
          GxTextBtn(tr('Снять', 'Clear', 'Quitar'),
              onTap: () => setState(() => _selected.clear())),
          const SizedBox(width: 8),
          FilledButton.icon(
            onPressed: _trashSelected,
            icon: GxIcon(GxGlyph.bin, size: 18, color: c.onAccent),
            label: Text(tr('В корзину', 'To trash', 'A la papelera')),
          ),
        ]),
      );
}

// ───────────────────────── квадратная миниатюра ─────────────────────────
class _DupThumb extends StatelessWidget {
  final DupFile file;
  final bool isBest;
  final bool selected;
  final AuroraColors colors;
  final VoidCallback onTap;
  const _DupThumb({
    required this.file,
    required this.isBest,
    required this.selected,
    required this.colors,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = colors;
    const side = 112.0;
    final dpr = MediaQuery.of(context).devicePixelRatio;
    final cw = (side * dpr).round();
    final corrupt = file.status != kOk;
    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: side,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Stack(children: [
            ClipRRect(
              borderRadius: gxCorner,
              child: Container(
                width: side,
                height: side,
                color: c.active,
                child: file.status == kBroken
                    ? Center(
                        child: GxIcon(GxGlyph.gallery, color: c.muted, size: 26))
                    : Image(
                        image: ResizeImage(FileImage(File(file.path)),
                            width: cw, allowUpscaling: false),
                        fit: BoxFit.cover,
                        width: side,
                        height: side,
                        filterQuality: FilterQuality.low,
                        errorBuilder: (_, __, ___) => Center(
                            child: GxIcon(GxGlyph.gallery,
                                color: c.muted, size: 26)),
                      ),
              ),
            ),
            // рамка выбора
            Positioned.fill(
              child: IgnorePointer(
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius: gxCorner,
                    border: Border.all(
                      color: selected ? c.accent : Colors.transparent,
                      width: 2,
                    ),
                  ),
                ),
              ),
            ),
            // чекбокс
            Positioned(
              right: 4,
              top: 4,
              child: Container(
                width: 20,
                height: 20,
                decoration: BoxDecoration(
                  color: selected ? c.accent : Colors.black45,
                  borderRadius: BorderRadius.circular(5),
                  border: Border.all(
                      color: selected ? c.accent : Colors.white70, width: 1.5),
                ),
                child: selected
                    ? Center(
                        child: GxIcon(GxGlyph.check, size: 14, color: c.onAccent))
                    : null,
              ),
            ),
            // бейдж «лучший»
            if (isBest)
              Positioned(
                left: 4,
                top: 4,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: c.accent,
                    borderRadius: BorderRadius.circular(5),
                  ),
                  child: Text(tr('лучший', 'best', 'mejor'),
                      style: TextStyle(color: c.onAccent, fontSize: 10)),
                ),
              ),
            // бейдж повреждения
            if (corrupt)
              Positioned(
                left: 4,
                bottom: 4,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: c.danger,
                    borderRadius: BorderRadius.circular(5),
                  ),
                  child: Text(
                      file.status == kBroken
                          ? tr('битый', 'broken', 'dañado')
                          : tr('обрезан', 'truncated', 'incompleto'),
                      style: TextStyle(color: c.onAccent, fontSize: 10)),
                ),
              ),
          ]),
          const SizedBox(height: 4),
          Text(
              file.pixels > 0
                  ? '${file.width}×${file.height} · ${prettySize(file.size)}'
                  : prettySize(file.size),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: c.muted, fontSize: 11)),
        ]),
      ),
    );
  }
}

// ───────────────────────── экран корзины ─────────────────────────
class TrashPage extends StatefulWidget {
  final VoidCallback onChanged;
  const TrashPage({super.key, required this.onChanged});

  @override
  State<TrashPage> createState() => _TrashPageState();
}

class _TrashPageState extends State<TrashPage> {
  List<TrashEntry> _entries = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final e = await TrashService.instance.entries();
    if (mounted) {
      setState(() {
        _entries = e;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = AuroraTheme.of(context).colors;
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
              Text(tr('Корзина', 'Trash', 'Papelera'),
                  style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: c.text)),
              const Spacer(),
              if (_entries.isNotEmpty)
                TextButton(
                  style: TextButton.styleFrom(foregroundColor: c.danger),
                  onPressed: () async {
                    final ok = await showDialog<bool>(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        title: Text(tr('Очистить корзину?', 'Empty trash?',
                            '¿Vaciar la papelera?')),
                        content: Text(tr(
                            'Безвозвратно удалит ${_entries.length} файлов (${prettySize(TrashService.instance.totalBytes)}).',
                            'This will permanently delete ${_entries.length} files (${prettySize(TrashService.instance.totalBytes)}).',
                            'Esto eliminará definitivamente ${_entries.length} archivos (${prettySize(TrashService.instance.totalBytes)}).')),
                        actions: [
                          TextButton(
                              onPressed: () => Navigator.pop(ctx, false),
                              child:
                                  Text(tr('Отмена', 'Cancel', 'Cancelar'))),
                          FilledButton(
                            style: FilledButton.styleFrom(
                                backgroundColor: c.danger,
                                foregroundColor: c.onAccent),
                            onPressed: () => Navigator.pop(ctx, true),
                            child: Text(tr('Очистить', 'Empty', 'Vaciar')),
                          ),
                        ],
                      ),
                    );
                    if (ok == true) {
                      await TrashService.instance.empty();
                      await _load();
                    }
                  },
                  child: Text(tr('Очистить всё', 'Empty all', 'Vaciar todo')),
                ),
              const SizedBox(width: 10),
            ]),
          ),
          const GxHLine(),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _entries.isEmpty
                    ? Center(
                        child:
                            Column(mainAxisSize: MainAxisSize.min, children: [
                          GxIcon(GxGlyph.bin, size: 48, color: c.dim),
                          const SizedBox(height: 12),
                          Text(
                              tr('Корзина пуста', 'Trash is empty',
                                  'La papelera está vacía'),
                              style: TextStyle(color: c.muted, fontSize: 14)),
                        ]),
                      )
                    : ListView.separated(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        itemCount: _entries.length,
                        separatorBuilder: (_, __) =>
                            GxHLine(color: c.rowLine),
                        itemBuilder: (ctx, i) {
                          final e = _entries[i];
                          return Padding(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 14, vertical: 4),
                            child: Row(children: [
                              ClipRRect(
                                borderRadius: gxCorner,
                                child: SizedBox(
                                  width: 40,
                                  height: 40,
                                  child: Image(
                                    image: ResizeImage(
                                        FileImage(File(e.stored)),
                                        width: 96),
                                    fit: BoxFit.cover,
                                    errorBuilder: (_, __, ___) => Container(
                                        color: c.active,
                                        child: Center(
                                            child: GxIcon(GxGlyph.gallery,
                                                color: c.muted, size: 18))),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(e.fileName,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                              color: c.text, fontSize: 14)),
                                      Text(
                                          '${prettySize(e.size)} · ${e.original}',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                              color: c.muted, fontSize: 12)),
                                    ]),
                              ),
                              GxIconBtn(
                                _gRestore,
                                tr('Восстановить', 'Restore', 'Restaurar'),
                                tint: c.accent,
                                onTap: () async {
                                  final messenger =
                                      ScaffoldMessenger.of(context);
                                  final ok =
                                      await TrashService.instance.restore(e);
                                  widget.onChanged();
                                  await _load();
                                  if (!ok) {
                                    messenger.showSnackBar(
                                      SnackBar(
                                          content: Text(tr(
                                              'Не удалось восстановить (файл на месте занят?)',
                                              'Could not restore (is the destination busy?)',
                                              'No se pudo restaurar (¿el destino está ocupado?)'))),
                                    );
                                  }
                                },
                              ),
                            ]),
                          );
                        },
                      ),
          ),
        ]),
      ),
    );
  }
}
