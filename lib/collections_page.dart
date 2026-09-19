import 'package:flutter/material.dart';
import 'theme.dart';
import 'model.dart';
import 'collections_service.dart';
import 'settings_service.dart';
import 'viewer_page.dart';
import 'i18n.dart';

/// Диалог ввода названия (создание/переименование коллекции). Общий стиль —
/// как остальные диалоги приложения (см. media_actions.dart).
Future<String?> _promptName(BuildContext context,
    {required String title, String initial = ''}) {
  final c = AuroraTheme.of(context).colors;
  final ctl = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: c.surface,
      title: Text(title, style: TextStyle(color: c.text)),
      content: TextField(
        controller: ctl,
        autofocus: true,
        cursorColor: c.accent,
        style: TextStyle(color: c.text),
        decoration: InputDecoration(
            hintText: tr('Название', 'Name', 'Nombre')),
        onSubmitted: (v) => Navigator.pop(ctx, v),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: Text(tr('Отмена', 'Cancel', 'Cancelar'),
              style: TextStyle(color: c.muted)),
        ),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: c.accent),
          onPressed: () => Navigator.pop(ctx, ctl.text),
          child: Text(tr('Готово', 'Done', 'Listo')),
        ),
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
  final c = AuroraTheme.of(context).colors;
  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: c.surface,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
    ),
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

  @override
  Widget build(BuildContext context) {
    final c = AuroraTheme.of(context).colors;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(0, 10, 0, 8),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 40,
            height: 4,
            margin: const EdgeInsets.only(bottom: 12),
            decoration: BoxDecoration(
                color: c.line, borderRadius: BorderRadius.circular(2)),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(children: [
              Icon(Icons.collections_bookmark_outlined,
                  size: 18, color: c.accent),
              const SizedBox(width: 8),
              Text(tr('В коллекцию', 'To a collection', 'A una colección'),
                  style: TextStyle(
                      color: c.text,
                      fontSize: 16,
                      fontWeight: FontWeight.w800)),
            ]),
          ),
          const SizedBox(height: 6),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              children: [
                if (_items.isEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 6, 16, 10),
                    child: Text(
                        tr('Коллекций пока нет — создай первую.',
                            'No collections yet — create the first one.',
                            'Aún no hay colecciones — crea la primera.'),
                        style: TextStyle(color: c.muted, fontSize: 13)),
                  ),
                for (final col in _items)
                  ListTile(
                    leading: Icon(Icons.collections_bookmark_outlined,
                        color: c.muted),
                    title: Text(col.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: c.text, fontWeight: FontWeight.w600)),
                    subtitle: Text(
                        '${col.count} ${tr('фото', 'photos', 'fotos')}',
                        style: TextStyle(color: c.muted, fontSize: 12)),
                    onTap: () => _addTo(col.id, col.name),
                  ),
                ListTile(
                  leading: Icon(Icons.add, color: c.accent),
                  title: Text(
                      tr('Создать новую…', 'Create new…', 'Crear nueva…'),
                      style: TextStyle(
                          color: c.accent, fontWeight: FontWeight.w700)),
                  onTap: _createAndAdd,
                ),
              ],
            ),
          ),
        ]),
      ),
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
    final c = AuroraTheme.of(context).colors;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: c.surface,
        title: Text(
            tr('Удалить коллекцию «${col.name}»?',
                'Delete collection “${col.name}”?',
                '¿Eliminar la colección «${col.name}»?'),
            style: TextStyle(color: c.text)),
        content: Text(
            tr(
                'Сами фото не удалятся — пропадёт только эта подборка.',
                'The photos themselves stay — only this collection disappears.',
                'Las fotos no se eliminan — solo desaparece esta colección.'),
            style: TextStyle(color: c.muted)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr('Отмена', 'Cancel', 'Cancelar'),
                style: TextStyle(color: c.muted)),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: c.accent),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('Удалить', 'Delete', 'Eliminar')),
          ),
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
          Container(
            padding: const EdgeInsets.fromLTRB(8, 8, 18, 10),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: c.line)),
            ),
            child: Row(children: [
              IconButton(
                onPressed: () => Navigator.of(context).pop(),
                icon: Icon(Icons.arrow_back, color: c.text),
                tooltip: tr('Назад', 'Back', 'Atrás'),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Text(tr('Коллекции', 'Collections', 'Colecciones'),
                    style: TextStyle(
                        color: c.text,
                        fontSize: 18,
                        fontWeight: FontWeight.w800)),
              ),
              IconButton(
                onPressed: _createCollection,
                icon: Icon(Icons.add, color: c.accent),
                tooltip:
                    tr('Новая коллекция', 'New collection', 'Nueva colección'),
              ),
            ]),
          ),
          Expanded(
            child: _items.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(30),
                      child: Text(
                          tr(
                              'Пока нет коллекций.\nСоздай свой альбом кнопкой «+» вверху или добавь фото через «В альбом» в просмотрщике.',
                              'No collections yet.\nCreate an album with the “+” above, or add a photo via “To album” in the viewer.',
                              'Aún no hay colecciones.\nCrea un álbum con «+» arriba, o añade una foto con «A álbum» en el visor.'),
                          textAlign: TextAlign.center,
                          style: TextStyle(color: c.muted, fontSize: 13.5)),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 10, 16, 20),
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
    const coverSize = 56.0;
    final cacheWidth = (coverSize * dpr).round().clamp(64, 256);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: c.surface,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: c.line),
            ),
            child: Row(children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(11),
                child: SizedBox(
                  width: coverSize,
                  height: coverSize,
                  child: cover == null
                      ? Container(
                          color: c.surface2,
                          child: Icon(Icons.collections_bookmark_outlined,
                              color: c.muted),
                        )
                      : Image(
                          image: cover!.thumb(cacheWidth),
                          fit: BoxFit.cover,
                          gaplessPlayback: true,
                          filterQuality: FilterQuality.low,
                          errorBuilder: (ctx, e, st) => Container(
                              color: c.surface2,
                              child: Icon(Icons.broken_image_outlined,
                                  color: c.muted, size: 18)),
                        ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(info.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              color: c.text,
                              fontSize: 15,
                              fontWeight: FontWeight.w700)),
                      const SizedBox(height: 2),
                      Text(
                          '${info.count} ${tr('фото', 'photos', 'fotos')}',
                          style: TextStyle(color: c.muted, fontSize: 12.5)),
                    ]),
              ),
              PopupMenuButton<String>(
                icon: Icon(Icons.more_vert, size: 19, color: c.muted),
                onSelected: (v) {
                  if (v == 'rename') onRename();
                  if (v == 'delete') onDelete();
                },
                itemBuilder: (_) => [
                  PopupMenuItem(
                      value: 'rename',
                      child: Text(
                          tr('Переименовать', 'Rename', 'Renombrar'))),
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
    final c = AuroraTheme.of(context).colors;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: c.surface,
        title: Text(
            tr('Убрать из коллекции?', 'Remove from collection?',
                '¿Quitar de la colección?'),
            style: TextStyle(color: c.text)),
        content: Text(photo.fileName,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: c.muted)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr('Отмена', 'Cancel', 'Cancelar'),
                style: TextStyle(color: c.muted)),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: c.accent),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('Убрать', 'Remove', 'Quitar')),
          ),
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
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 16, 8),
            child: Row(children: [
              IconButton(
                onPressed: () => Navigator.pop(context),
                icon: Icon(Icons.arrow_back, color: c.text),
                tooltip: tr('Назад', 'Back', 'Atrás'),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(_info.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w800,
                              color: c.text)),
                      Text('${_photos.length} ${tr('фото', 'photos', 'fotos')}',
                          style: TextStyle(fontSize: 12, color: c.muted)),
                    ]),
              ),
            ]),
          ),
          Expanded(
            child: _photos.isEmpty
                ? Center(
                    child: Text(
                        tr('В этой коллекции пока пусто',
                            'This collection is empty',
                            'Esta colección está vacía'),
                        style: TextStyle(color: c.muted)))
                : GridView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 6, 16, 18),
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
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(s.gridRadius),
        child: Stack(fit: StackFit.expand, children: [
          Container(color: c.surface2),
          if (photo.isVideo)
            Center(
              child: Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.45),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.play_arrow_rounded,
                    color: Colors.white, size: 30),
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
                return Container(color: c.surface2);
              },
              errorBuilder: (ctx, e, st) =>
                  Icon(Icons.broken_image_outlined, color: c.muted, size: 18),
            ),
          if (photo.isVideo)
            Positioned(
              right: 5,
              bottom: 5,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(6),
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
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
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
