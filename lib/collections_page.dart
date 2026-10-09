import 'package:flutter/material.dart';
import 'theme.dart';
import 'gx.dart';
import 'model.dart';
import 'collections_service.dart';
import 'settings_service.dart';
import 'viewer_page.dart';
import 'i18n.dart';

const _gPlay = GxGlyph('M8 5.5v13l10.5-6.5z', true);

/// Диалог ввода названия (создание/переименование коллекции). Общий стиль —
/// как остальные диалоги приложения (см. media_actions.dart).
Future<String?> _promptName(BuildContext context,
    {required String title, String initial = ''}) {
  final ctl = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: ctl,
        autofocus: true,
        decoration: InputDecoration(
            hintText: tr('Название', 'Name', 'Nombre')),
        onSubmitted: (v) => Navigator.pop(ctx, v),
      ),
      actions: [
        GxTextBtn(tr('Отмена', 'Cancel', 'Cancelar'),
            onTap: () => Navigator.pop(ctx)),
        GxTextBtn(tr('Готово', 'Done', 'Listo'),
            primary: true, onTap: () => Navigator.pop(ctx, ctl.text)),
      ],
    ),
  );
}

/// Нижний лист «В коллекцию»: выбрать существующую или создать новую и сразу
/// добавить туда [paths]. Используется из просмотрщика и из массового
/// выделения на главном экране.
Future<void> showAddToCollectionSheet(
    BuildContext context, List<String> paths) async {
  if (paths.isEmpty) return;
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _AddToCollectionSheet(paths: paths),
  );
}

class _AddToCollectionSheet extends StatefulWidget {
  final List<String> paths;
  const _AddToCollectionSheet({required this.paths});

  @override
  State<_AddToCollectionSheet> createState() => _AddToCollectionSheetState();
}

class _AddToCollectionSheetState extends State<_AddToCollectionSheet> {
  List<CollectionInfo> _items = const [];

  @override
  void initState() {
    super.initState();
    _items = CollectionsService.instance.list();
  }

  Future<void> _createAndAdd() async {
    final name = await _promptName(context,
        title: tr('Новая коллекция', 'New collection', 'Nueva colección'));
    if (name == null || name.trim().isEmpty) return;
    final id = CollectionsService.instance.create(name);
    if (id < 0) return;
    _addTo(id, name.trim());
  }

  void _addTo(int id, String name) {
    final n = CollectionsService.instance.addPaths(id, widget.paths);
    if (!mounted) return;
    Navigator.pop(context);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(tr('Добавлено в «$name»: $n', 'Added to “$name”: $n',
            'Añadido a «$name»: $n'))));
  }

  Widget _row(AuroraColors c, GxGlyph glyph, Color glyphColor, String title,
      Color titleColor, String? trailing, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      child: SizedBox(
        height: 44,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Row(children: [
            GxIcon(glyph, color: glyphColor, size: 18),
            const SizedBox(width: 10),
            Expanded(
              child: Text(title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: titleColor, fontSize: 14)),
            ),
            if (trailing != null)
              Text(trailing, style: TextStyle(color: c.dim, fontSize: 12)),
          ]),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = AuroraTheme.of(context).colors;
    return SafeArea(
      top: false,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        SizedBox(
          height: 48,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Row(children: [
              GxIcon(GxGlyph.library, size: 18, color: c.accent),
              const SizedBox(width: 10),
              Text(tr('В коллекцию', 'To a collection', 'A una colección'),
                  style: TextStyle(
                      color: c.text,
                      fontSize: 15,
                      fontWeight: FontWeight.w600)),
            ]),
          ),
        ),
        const GxHLine(),
        Flexible(
          child: ListView(
            shrinkWrap: true,
            padding: EdgeInsets.zero,
            children: [
              if (_items.isEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                  child: Text(
                      tr('Коллекций пока нет — создай первую.',
                          'No collections yet — create the first one.',
                          'Aún no hay colecciones — crea la primera.'),
                      style: TextStyle(color: c.muted, fontSize: 13)),
                ),
              for (final col in _items)
                _row(
                    c,
                    GxGlyph.library,
                    c.muted,
                    col.name,
                    c.text,
                    '${col.count} ${tr('фото', 'photos', 'fotos')}',
                    () => _addTo(col.id, col.name)),
              const GxHLine(),
              _row(
                  c,
                  GxGlyph.plus,
                  c.accent,
                  tr('Создать новую…', 'Create new…', 'Crear nueva…'),
                  c.accent,
                  null,
                  _createAndAdd),
            ],
          ),
        ),
      ]),
    );
  }
}

/// Экран «Коллекции»: пользовательские альбомы из фото разных папок диска.
/// [library] — весь известный набор фото (для сопоставления путей коллекции
/// с реальными PhotoItem, откуда берутся миниатюры/метаданные).
class CollectionsPage extends StatefulWidget {
  final List<PhotoItem> library;
  const CollectionsPage({super.key, required this.library});

  @override
  State<CollectionsPage> createState() => _CollectionsPageState();
}

class _CollectionsPageState extends State<CollectionsPage> {
  List<CollectionInfo> _items = const [];
  // индекс по пути строим один раз (не на каждый build) — библиотека может
  // быть большой (100к+ фото), а обложки коллекций ищутся часто
  late final Map<String, PhotoItem> _byPath = {
    for (final p in widget.library) p.path: p
  };

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() => setState(() => _items = CollectionsService.instance.list());

  PhotoItem? _findByPath(String path) => _byPath[path];

  Future<void> _createCollection() async {
    final name = await _promptName(context,
        title: tr('Новая коллекция', 'New collection', 'Nueva colección'));
    if (name == null || name.trim().isEmpty) return;
    CollectionsService.instance.create(name);
    _load();
  }

  Future<void> _renameCollection(CollectionInfo col) async {
    final name = await _promptName(context,
        title: tr('Переименовать', 'Rename', 'Renombrar'),
        initial: col.name);
    if (name == null || name.trim().isEmpty) return;
    CollectionsService.instance.rename(col.id, name);
    _load();
  }

  Future<void> _deleteCollection(CollectionInfo col) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('Удалить коллекцию «${col.name}»?',
            'Delete collection “${col.name}”?',
            '¿Eliminar la colección «${col.name}»?')),
        content: Text(tr(
            'Сами фото не удалятся — пропадёт только эта подборка.',
            'The photos themselves stay — only this collection disappears.',
            'Las fotos no se eliminan — solo desaparece esta colección.')),
        actions: [
          GxTextBtn(tr('Отмена', 'Cancel', 'Cancelar'),
              onTap: () => Navigator.pop(ctx, false)),
          GxTextBtn(tr('Удалить', 'Delete', 'Eliminar'),
              primary: true, onTap: () => Navigator.pop(ctx, true)),
        ],
      ),
    );
    if (ok != true) return;
    CollectionsService.instance.delete(col.id);
    _load();
  }

  void _open(CollectionInfo col) {
    Navigator.of(context)
        .push(MaterialPageRoute(
      builder: (_) => _CollectionContentPage(
        collection: col,
        library: widget.library,
        onChanged: _load,
      ),
    ))
        .then((_) => _load()); // счётчик мог измениться (убрали фото)
  }

  @override
  Widget build(BuildContext context) {
    final c = AuroraTheme.of(context).colors;
    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        child: Column(children: [
          SizedBox(
            height: 52,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Row(children: [
                GxIconBtn(GxGlyph.back, tr('Назад', 'Back', 'Atrás'),
                    onTap: () => Navigator.of(context).pop()),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(tr('Коллекции', 'Collections', 'Colecciones'),
                      style: TextStyle(
                          color: c.text,
                          fontSize: 15,
                          fontWeight: FontWeight.w600)),
                ),
                GxIconBtn(
                    GxGlyph.plus,
                    tr('Новая коллекция', 'New collection', 'Nueva colección'),
                    tint: c.accent,
                    onTap: _createCollection),
              ]),
            ),
          ),
          const GxHLine(),
          Expanded(
            child: _items.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                          tr(
                              'Пока нет коллекций.\nСоздай свой альбом кнопкой «+» вверху или добавь фото через «В альбом» в просмотрщике.',
                              'No collections yet.\nCreate an album with the “+” above, or add a photo via “To album” in the viewer.',
                              'Aún no hay colecciones.\nCrea un álbum con «+» arriba, o añade una foto con «A álbum» en el visor.'),
                          textAlign: TextAlign.center,
                          style: TextStyle(color: c.muted, fontSize: 13)),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.only(bottom: 12),
                    itemCount: _items.length,
                    itemBuilder: (ctx, i) {
                      final col = _items[i];
                      final cover =
                          CollectionsService.instance.coverPath(col.id);
                      final coverPhoto =
                          cover == null ? null : _findByPath(cover);
                      return _CollectionCard(
                        info: col,
                        cover: coverPhoto,
                        onTap: () => _open(col),
                        onRename: () => _renameCollection(col),
                        onDelete: () => _deleteCollection(col),
                      );
                    },
                  ),
          ),
        ]),
      ),
    );
  }
}

class _CollectionCard extends StatelessWidget {
  final CollectionInfo info;
  final PhotoItem? cover;
  final VoidCallback onTap;
  final VoidCallback onRename;
  final VoidCallback onDelete;
  const _CollectionCard({
    required this.info,
    required this.cover,
    required this.onTap,
    required this.onRename,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final c = AuroraTheme.of(context).colors;
    final dpr = MediaQuery.of(context).devicePixelRatio;
    const coverSize = 36.0;
    final cacheWidth = (coverSize * dpr).round().clamp(64, 256);
    Widget placeholder(GxGlyph g) => Container(
          color: c.active,
          alignment: Alignment.center,
          child: GxIcon(g, color: c.muted, size: 18),
        );
    return Container(
      decoration:
          BoxDecoration(border: Border(bottom: BorderSide(color: c.rowLine))),
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          height: 48,
          child: Padding(
            padding: const EdgeInsets.only(left: 14),
            child: Row(children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(5),
                child: SizedBox(
                  width: coverSize,
                  height: coverSize,
                  child: cover == null
                      ? placeholder(GxGlyph.library)
                      : Image(
                          image: cover!.thumb(cacheWidth),
                          fit: BoxFit.cover,
                          gaplessPlayback: true,
                          filterQuality: FilterQuality.low,
                          errorBuilder: (ctx, e, st) =>
                              placeholder(GxGlyph.gallery),
                        ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(info.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: c.text, fontSize: 14)),
              ),
              Text('${info.count} ${tr('фото', 'photos', 'fotos')}',
                  style: TextStyle(color: c.muted, fontSize: 12)),
              PopupMenuButton<String>(
                padding: EdgeInsets.zero,
                child: SizedBox(
                  width: 44,
                  height: 40,
                  child: Center(
                      child: GxIcon(GxGlyph.more, size: 19, color: c.muted)),
                ),
                onSelected: (v) {
                  if (v == 'rename') onRename();
                  if (v == 'delete') onDelete();
                },
                itemBuilder: (_) => [
                  PopupMenuItem(
                      value: 'rename',
                      child:
                          Text(tr('Переименовать', 'Rename', 'Renombrar'))),
                  PopupMenuItem(
                      value: 'delete',
                      child: Text(tr('Удалить', 'Delete', 'Eliminar'))),
                ],
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

/// Содержимое одной коллекции — плотная сетка, как на остальных экранах.
class _CollectionContentPage extends StatefulWidget {
  final CollectionInfo collection;
  final List<PhotoItem> library;
  final VoidCallback onChanged;
  const _CollectionContentPage({
    required this.collection,
    required this.library,
    required this.onChanged,
  });

  @override
  State<_CollectionContentPage> createState() =>
      _CollectionContentPageState();
}

class _CollectionContentPageState extends State<_CollectionContentPage> {
  late CollectionInfo _info;
  List<PhotoItem> _photos = const [];

  @override
  void initState() {
    super.initState();
    _info = widget.collection;
    _load();
  }

  void _load() {
    final paths = CollectionsService.instance.pathsOf(_info.id);
    final byPath = {for (final p in widget.library) p.path: p};
    final photos = [
      for (final path in paths)
        if (byPath[path] != null) byPath[path]!
    ];
    setState(() => _photos = photos);
  }

  Future<void> _remove(PhotoItem photo) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('Убрать из коллекции?', 'Remove from collection?',
            '¿Quitar de la colección?')),
        content: Text(photo.fileName,
            maxLines: 2, overflow: TextOverflow.ellipsis),
        actions: [
          GxTextBtn(tr('Отмена', 'Cancel', 'Cancelar'),
              onTap: () => Navigator.pop(ctx, false)),
          GxTextBtn(tr('Убрать', 'Remove', 'Quitar'),
              primary: true, onTap: () => Navigator.pop(ctx, true)),
        ],
      ),
    );
    if (ok != true) return;
    CollectionsService.instance.removePath(_info.id, photo.path);
    _load();
    widget.onChanged();
  }

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
            child: Padding(
              padding: const EdgeInsets.only(left: 4, right: 14),
              child: Row(children: [
                GxIconBtn(GxGlyph.back, tr('Назад', 'Back', 'Atrás'),
                    onTap: () => Navigator.pop(context)),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(_info.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: c.text)),
                ),
                Text('${_photos.length} ${tr('фото', 'photos', 'fotos')}',
                    style: TextStyle(fontSize: 12, color: c.muted)),
              ]),
            ),
          ),
          const GxHLine(),
          Expanded(
            child: _photos.isEmpty
                ? Center(
                    child: Text(
                        tr('В этой коллекции пока пусто',
                            'This collection is empty',
                            'Esta colección está vacía'),
                        style: TextStyle(color: c.muted, fontSize: 13)))
                : GridView.builder(
                    padding: const EdgeInsets.all(8),
                    gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: cell,
                      mainAxisSpacing: 4,
                      crossAxisSpacing: 4,
                      childAspectRatio: 1,
                    ),
                    itemCount: _photos.length,
                    itemBuilder: (ctx, i) => _CollectionTile(
                      photo: _photos[i],
                      cell: cell,
                      onTap: () => openViewer(ctx, _photos, i),
                      onLongPress: () => _remove(_photos[i]),
                    ),
                  ),
          ),
        ]),
      ),
    );
  }
}

class _CollectionTile extends StatelessWidget {
  final PhotoItem photo;
  final double cell;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  const _CollectionTile({
    required this.photo,
    required this.cell,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final c = AuroraTheme.of(context).colors;
    final s = SettingsService.instance;
    final dpr = MediaQuery.of(context).devicePixelRatio;
    final cacheWidth = (cell * dpr).round().clamp(64, 512);
    Widget badge(String text) => Positioned(
          right: 5,
          bottom: 5,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            decoration: BoxDecoration(
              color: Colors.black54,
              borderRadius: BorderRadius.circular(5),
            ),
            child: Text(text,
                style: const TextStyle(color: Colors.white, fontSize: 10)),
          ),
        );
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(s.gridRadius),
        child: Stack(fit: StackFit.expand, children: [
          Container(color: c.active),
          if (photo.isVideo)
            Center(
              child: Container(
                width: 40,
                height: 34,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.45),
                  borderRadius: gxCorner,
                ),
                child: const GxIcon(_gPlay, color: Colors.white, size: 20),
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
                return Container(color: c.active);
              },
              errorBuilder: (ctx, e, st) => Center(
                  child: GxIcon(GxGlyph.gallery, color: c.muted, size: 18)),
            ),
          if (photo.isVideo) badge('VIDEO'),
          if (photo.isGif && s.showGifBadge) badge('GIF'),
        ]),
      ),
    );
  }
}
