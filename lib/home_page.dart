import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'theme.dart';
import 'model.dart';
import 'library_service.dart';
import 'viewer_page.dart';
import 'update_service.dart';
import 'favorites.dart';
import 'folder_tree.dart';
import 'tree_view.dart';
import 'tag_service.dart';

enum ViewMode { all, dates, albums }

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  ViewMode _mode = ViewMode.all;
  double _cell = 120; // плотность сетки: ширина плитки в логических пикселях

  List<PhotoItem> _photos = [];
  List<AlbumItem> _albums = [];
  String? _folder;
  bool _loading = false;
  UpdateInfo? _update; // доступное обновление (null = нет)
  String _query = ''; // строка поиска
  Set<String> _tagMatchPaths = const {}; // пути, чьи теги совпали с запросом
  bool _favOnly = false; // показывать только избранное
  bool _folderTree = false; // в разделе папок: древо вместо сетки
  FolderNode? _treeCache; // построенное древо папок (кэш)

  /// Фото с учётом поиска и фильтра «только избранное».
  List<PhotoItem> get _visiblePhotos {
    Iterable<PhotoItem> r = _photos;
    if (_favOnly) {
      final favs = Favorites.instance.paths;
      r = r.where((p) => favs.contains(p.path));
    }
    if (_query.trim().isNotEmpty) {
      final q = _query.trim().toLowerCase();
      r = r.where((p) =>
          p.fileName.toLowerCase().contains(q) ||
          p.folderName.toLowerCase().contains(q) ||
          _tagMatchPaths.contains(p.path));
    }
    return r.toList();
  }

  FolderNode _folderTreeNode() =>
      _treeCache ??= buildFolderTree(_photos, _folder ?? '');

  Widget _albumsGrid() {
    final q = _query.trim().toLowerCase();
    final albums = q.isEmpty
        ? _albums
        : _albums.where((a) => a.name.toLowerCase().contains(q)).toList();
    if (albums.isEmpty) return const _NoResults(favOnly: false);
    return _AlbumsView(albums: albums, photos: _photos, cell: _cell);
  }

  void _openTreeFolder(FolderNode node) {
    final photos =
        node.directPhotos.isNotEmpty ? node.directPhotos : collectPhotos(node);
    if (photos.isEmpty) return;
    final album = AlbumItem(
      name: node.name,
      folderPath: node.path,
      count: photos.length,
      cover: node.cover,
    );
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => _FolderPage(album: album, photos: photos, cell: _cell),
    ));
  }

  @override
  void initState() {
    super.initState();
    _restore();
    _checkUpdates();
  }

  Future<void> _checkUpdates() async {
    final u = await UpdateService.check();
    if (mounted && u != null) setState(() => _update = u);
  }

  Future<void> _startUpdate() async {
    final u = _update;
    if (u == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final c = AuroraTheme.of(ctx).colors;
        return AlertDialog(
          backgroundColor: c.surface,
          title: Text('Обновить Capra?', style: TextStyle(color: c.text)),
          content: Text(
            'Доступна сборка №${u.build}. Приложение скачает её, '
            'заменит файлы и перезапустится.',
            style: TextStyle(color: c.muted),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text('Позже', style: TextStyle(color: c.muted)),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: c.accent),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Обновить'),
            ),
          ],
        );
      },
    );
    if (ok != true || !mounted) return;
    // диалог прогресса сам запускает скачивание; при успехе приложение выходит
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => _UpdateProgressDialog(info: u),
    );
  }

  Future<void> _restore() async {
    final last = await LibraryService.lastFolder();
    if (last != null) await _scan(last);
  }

  Future<void> _pickFolder() async {
    final path = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Выбери папку с фотографиями',
    );
    if (path == null) return;
    await LibraryService.saveFolder(path);
    await _scan(path);
  }

  Future<void> _scan(String path) async {
    setState(() {
      _loading = true;
      _folder = path;
    });
    final photos = await LibraryService.scan(path);
    if (!mounted) return;
    setState(() {
      _photos = photos;
      _albums = LibraryService.albums(photos);
      _treeCache = null; // папки изменились — пересоберём древо при показе
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = AuroraTheme.of(context).colors;
    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        child: Row(
          children: [
            _Rail(
              mode: _mode,
              onMode: (m) => setState(() => _mode = m),
              favOnly: _favOnly,
              onFav: () => setState(() => _favOnly = !_favOnly),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _TopBar(
                    mode: _mode,
                    cell: _cell,
                    query: _query,
                    onSearch: (q) => setState(() {
                      _query = q;
                      _tagMatchPaths = q.trim().isEmpty
                          ? const {}
                          : TagService.instance.pathsMatchingTag(q);
                    }),
                    onMode: (m) => setState(() => _mode = m),
                    onCell: (v) => setState(() => _cell = v),
                    onPickFolder: _pickFolder,
                    update: _update,
                    onUpdate: _startUpdate,
                  ),
                  _CountBar(
                    mode: _mode,
                    total: _visiblePhotos.length,
                    albums: _albums.length,
                    folder: _folder,
                  ),
                  Expanded(
                    child: ValueListenableBuilder<Set<String>>(
                      valueListenable: Favorites.instance.notifier,
                      builder: (_, __, ___) => _body(c),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _body(AuroraColors c) {
    if (_loading) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          CircularProgressIndicator(color: c.accent),
          const SizedBox(height: 14),
          Text('Сканирую папку…', style: TextStyle(color: c.muted)),
        ]),
      );
    }
    if (_photos.isEmpty) return _EmptyState(onPick: _pickFolder);

    if (_mode == ViewMode.albums) {
      return Column(
        children: [
          _FolderViewToggle(
            tree: _folderTree,
            onChanged: (v) => setState(() => _folderTree = v),
          ),
          Expanded(
            child: _folderTree
                ? TreeView(
                    root: _folderTreeNode(),
                    onOpenFolder: _openTreeFolder,
                  )
                : _albumsGrid(),
          ),
        ],
      );
    }

    final visible = _visiblePhotos;
    if (visible.isEmpty) return _NoResults(favOnly: _favOnly);
    switch (_mode) {
      case ViewMode.all:
        return _AllGrid(photos: visible, cell: _cell);
      case ViewMode.dates:
        return _DatesView(photos: visible, cell: _cell);
      case ViewMode.albums:
        return const SizedBox.shrink(); // обработано выше
    }
  }
}

// ───────────────────────── пустой экран ─────────────────────────
class _EmptyState extends StatelessWidget {
  final VoidCallback onPick;
  const _EmptyState({required this.onPick});

  @override
  Widget build(BuildContext context) {
    final c = AuroraTheme.of(context).colors;
    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.photo_library_outlined, size: 64, color: c.muted),
        const SizedBox(height: 16),
        Text('Здесь пока пусто',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: c.text)),
        const SizedBox(height: 6),
        Text('Выбери папку с фотографиями — Aurora покажет их здесь.',
            style: TextStyle(color: c.muted)),
        const SizedBox(height: 18),
        FilledButton.icon(
          onPressed: onPick,
          style: FilledButton.styleFrom(backgroundColor: c.accent),
          icon: const Icon(Icons.folder_open),
          label: const Text('Выбрать папку'),
        ),
      ]),
    );
  }
}

// ───────────────────────── боковая панель ─────────────────────────
class _Rail extends StatelessWidget {
  final ViewMode mode;
  final ValueChanged<ViewMode> onMode;
  final bool favOnly;
  final VoidCallback onFav;
  const _Rail({
    required this.mode,
    required this.onMode,
    required this.favOnly,
    required this.onFav,
  });

  @override
  Widget build(BuildContext context) {
    final c = AuroraTheme.of(context).colors;
    Widget item(IconData icon, ViewMode? m, {VoidCallback? onTap, bool active = false}) {
      final on = active || (m != null && m == mode);
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Material(
          color: on ? c.accentSoft : Colors.transparent,
          borderRadius: BorderRadius.circular(13),
          child: InkWell(
            borderRadius: BorderRadius.circular(13),
            onTap: onTap ?? (m == null ? null : () => onMode(m)),
            child: SizedBox(
              width: 46,
              height: 46,
              child: Icon(icon, size: 22, color: on ? c.accentInk : c.muted),
            ),
          ),
        ),
      );
    }

    return Container(
      width: 74,
      decoration: BoxDecoration(
        color: c.surface,
        border: Border(right: BorderSide(color: c.line)),
      ),
      child: Column(
        children: [
          const SizedBox(height: 14),
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: c.accent,
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(Icons.auto_awesome_mosaic, size: 18, color: Colors.white),
          ),
          const SizedBox(height: 14),
          item(Icons.grid_view_rounded, ViewMode.all),
          item(Icons.calendar_today_rounded, ViewMode.dates),
          item(Icons.folder_rounded, ViewMode.albums),
          item(favOnly ? Icons.favorite_rounded : Icons.favorite_border_rounded,
              null, onTap: onFav, active: favOnly),
          const Spacer(),
          item(Icons.settings_outlined, null, onTap: () {}),
          const SizedBox(height: 10),
        ],
      ),
    );
  }
}

// ───────────────────────── верхняя панель ─────────────────────────
class _TopBar extends StatelessWidget {
  final ViewMode mode;
  final double cell;
  final String query;
  final ValueChanged<String> onSearch;
  final ValueChanged<ViewMode> onMode;
  final ValueChanged<double> onCell;
  final VoidCallback onPickFolder;
  final UpdateInfo? update;
  final VoidCallback onUpdate;
  const _TopBar({
    required this.mode,
    required this.cell,
    required this.query,
    required this.onSearch,
    required this.onMode,
    required this.onCell,
    required this.onPickFolder,
    required this.update,
    required this.onUpdate,
  });

  @override
  Widget build(BuildContext context) {
    final c = AuroraTheme.of(context).colors;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: c.line)),
      ),
      child: Row(
        children: [
          Expanded(child: _SearchField(initial: query, onSearch: onSearch)),
          const SizedBox(width: 10),
          IconButton(
            onPressed: onPickFolder,
            icon: Icon(Icons.folder_open, color: c.muted),
            tooltip: 'Выбрать папку',
          ),
          const SizedBox(width: 4),
          _Tabs(mode: mode, onMode: onMode),
          const SizedBox(width: 12),
          Icon(Icons.grid_view, size: 16, color: c.muted),
          SizedBox(
            width: 110,
            child: Slider(
              value: cell,
              min: 70,
              max: 220,
              activeColor: c.accent,
              onChanged: onCell,
            ),
          ),
          if (update != null) ...[
            const SizedBox(width: 6),
            _UpdateButton(buildNo: update!.build, onTap: onUpdate),
          ],
          const SizedBox(width: 4),
          const _ThemeDots(),
        ],
      ),
    );
  }
}

// ───────────────────────── строка поиска ─────────────────────────
class _SearchField extends StatefulWidget {
  final String initial;
  final ValueChanged<String> onSearch;
  const _SearchField({required this.initial, required this.onSearch});

  @override
  State<_SearchField> createState() => _SearchFieldState();
}

class _SearchFieldState extends State<_SearchField> {
  late final TextEditingController _ctl =
      TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = AuroraTheme.of(context).colors;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 2),
      decoration: BoxDecoration(
        color: c.surface2,
        borderRadius: BorderRadius.circular(13),
        border: Border.all(color: c.line),
      ),
      child: Row(
        children: [
          Icon(Icons.search, size: 18, color: c.muted),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: _ctl,
              onChanged: (v) {
                widget.onSearch(v);
                setState(() {}); // обновить видимость крестика
              },
              cursorColor: c.accent,
              style: TextStyle(color: c.text, fontSize: 14),
              decoration: InputDecoration(
                isDense: true,
                border: InputBorder.none,
                hintText: 'Поиск по имени файла или папке…',
                hintStyle: TextStyle(color: c.muted, fontSize: 14),
              ),
            ),
          ),
          if (_ctl.text.isNotEmpty)
            GestureDetector(
              onTap: () {
                _ctl.clear();
                widget.onSearch('');
                setState(() {});
              },
              child: Icon(Icons.close, size: 16, color: c.muted),
            ),
        ],
      ),
    );
  }
}

// ─────────────── экран «ничего не найдено» ───────────────
class _NoResults extends StatelessWidget {
  final bool favOnly;
  const _NoResults({required this.favOnly});

  @override
  Widget build(BuildContext context) {
    final c = AuroraTheme.of(context).colors;
    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(favOnly ? Icons.favorite_border_rounded : Icons.search_off_rounded,
            size: 56, color: c.muted),
        const SizedBox(height: 14),
        Text(favOnly ? 'В избранном пусто' : 'Ничего не найдено',
            style: TextStyle(
                fontSize: 16, fontWeight: FontWeight.w700, color: c.text)),
        const SizedBox(height: 4),
        Text(
            favOnly
                ? 'Отмечай фото сердечком — они появятся здесь.'
                : 'Попробуй изменить запрос.',
            style: TextStyle(color: c.muted, fontSize: 13)),
      ]),
    );
  }
}

// ───────────── переключатель «Сетка / Дерево» в разделе папок ─────────────
class _FolderViewToggle extends StatelessWidget {
  final bool tree;
  final ValueChanged<bool> onChanged;
  const _FolderViewToggle({required this.tree, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final c = AuroraTheme.of(context).colors;
    Widget btn(String label, IconData icon, bool on, VoidCallback onTap) {
      return GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            color: on ? c.surface : Colors.transparent,
            borderRadius: BorderRadius.circular(9),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 15, color: on ? c.accentInk : c.muted),
            const SizedBox(width: 6),
            Text(label,
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: on ? c.text : c.muted)),
          ]),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 2),
      child: Row(children: [
        Container(
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: c.surface2,
            borderRadius: BorderRadius.circular(11),
            border: Border.all(color: c.line),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            btn('Сетка', Icons.grid_view_rounded, !tree, () => onChanged(false)),
            btn('Древо', Icons.account_tree_outlined, tree,
                () => onChanged(true)),
          ]),
        ),
      ]),
    );
  }
}

// ───────────────────────── кнопка обновления ─────────────────────────
class _UpdateButton extends StatelessWidget {
  final int buildNo;
  final VoidCallback onTap;
  const _UpdateButton({required this.buildNo, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final c = AuroraTheme.of(context).colors;
    return Tooltip(
      message: 'Доступна сборка №$buildNo',
      child: Material(
        color: c.accent,
        borderRadius: BorderRadius.circular(11),
        child: InkWell(
          borderRadius: BorderRadius.circular(11),
          onTap: onTap,
          child: const Padding(
            padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.system_update_alt_rounded, size: 16, color: Colors.white),
                SizedBox(width: 6),
                Text('Обновить',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.w600)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ───────────────── диалог прогресса скачивания обновления ─────────────────
class _UpdateProgressDialog extends StatefulWidget {
  final UpdateInfo info;
  const _UpdateProgressDialog({required this.info});

  @override
  State<_UpdateProgressDialog> createState() => _UpdateProgressDialogState();
}

class _UpdateProgressDialogState extends State<_UpdateProgressDialog> {
  double? _progress = 0;
  String? _error;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    try {
      // при успехе метод сам завершит приложение (exit), управление не вернётся
      await UpdateService.downloadAndApply(
        widget.info,
        onProgress: (p) {
          if (mounted) setState(() => _progress = p);
        },
      );
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = AuroraTheme.of(context).colors;
    return AlertDialog(
      backgroundColor: c.surface,
      title: Text(_error == null ? 'Обновление…' : 'Не удалось обновить',
          style: TextStyle(color: c.text)),
      content: _error != null
          ? Text(_error!, style: TextStyle(color: c.muted))
          : Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                LinearProgressIndicator(
                  value: _progress,
                  color: c.accent,
                  backgroundColor: c.surface2,
                ),
                const SizedBox(height: 12),
                Text(
                  _progress == null
                      ? 'Скачивание…'
                      : 'Скачивание ${((_progress ?? 0) * 100).round()}%',
                  style: TextStyle(color: c.muted, fontSize: 13),
                ),
                const SizedBox(height: 4),
                Text('Приложение перезапустится автоматически.',
                    style: TextStyle(color: c.muted, fontSize: 12)),
              ],
            ),
      actions: _error == null
          ? null
          : [
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: c.accent),
                onPressed: () => Navigator.pop(context),
                child: const Text('Закрыть'),
              ),
            ],
    );
  }
}

class _Tabs extends StatelessWidget {
  final ViewMode mode;
  final ValueChanged<ViewMode> onMode;
  const _Tabs({required this.mode, required this.onMode});

  @override
  Widget build(BuildContext context) {
    final c = AuroraTheme.of(context).colors;
    Widget tab(String label, ViewMode m) {
      final on = m == mode;
      return GestureDetector(
        onTap: () => onMode(m),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
          decoration: BoxDecoration(
            color: on ? c.surface : Colors.transparent,
            borderRadius: BorderRadius.circular(9),
          ),
          child: Text(label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: on ? c.text : c.muted,
              )),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: c.surface2,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: c.line),
      ),
      child: Row(children: [
        tab('Все', ViewMode.all),
        tab('По датам', ViewMode.dates),
        tab('Альбомы', ViewMode.albums),
      ]),
    );
  }
}

class _ThemeDots extends StatelessWidget {
  const _ThemeDots();

  @override
  Widget build(BuildContext context) {
    final theme = AuroraTheme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final t in kThemes)
          GestureDetector(
            onTap: () => theme.setTheme(t.id),
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 3),
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                color: t.accent,
                shape: BoxShape.circle,
                border: Border.all(
                  color: t.id == theme.colors.id ? theme.colors.text : Colors.transparent,
                  width: 2,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _CountBar extends StatelessWidget {
  final ViewMode mode;
  final int total;
  final int albums;
  final String? folder;
  const _CountBar({
    required this.mode,
    required this.total,
    required this.albums,
    required this.folder,
  });

  @override
  Widget build(BuildContext context) {
    final c = AuroraTheme.of(context).colors;
    final right = switch (mode) {
      ViewMode.all => 'показаны все',
      ViewMode.dates => 'сгруппировано по дате',
      ViewMode.albums => '$albums папок',
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 8, 18, 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: Text.rich(
              TextSpan(children: [
                TextSpan(
                    text: '$total ',
                    style: TextStyle(
                        color: c.text, fontWeight: FontWeight.w600, fontSize: 12)),
                TextSpan(
                    text: folder == null ? 'изображений' : 'изображений · $folder',
                    style: TextStyle(color: c.muted, fontSize: 12)),
              ]),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 12),
          Text(right, style: TextStyle(color: c.muted, fontSize: 12)),
        ],
      ),
    );
  }
}

// ───────────────────────── плитка ─────────────────────────
class PhotoTile extends StatelessWidget {
  final PhotoItem photo;
  final double cell;
  final VoidCallback onTap;
  const PhotoTile({super.key, required this.photo, required this.cell, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final c = AuroraTheme.of(context).colors;
    final dpr = MediaQuery.of(context).devicePixelRatio;
    final cacheWidth = (cell * dpr).round().clamp(64, 512);
    return GestureDetector(
      onTap: onTap,
      onLongPress: () => Favorites.instance.toggle(photo.path),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(7),
        child: Stack(
          fit: StackFit.expand,
          children: [
            Container(color: c.surface2),
            Image(
              image: photo.thumb(cacheWidth),
              fit: BoxFit.cover,
              gaplessPlayback: true,
              filterQuality: FilterQuality.low,
              frameBuilder: (ctx, child, frame, wasSync) {
                if (wasSync || frame != null) return child;
                return Container(color: c.surface2);
              },
              errorBuilder: (ctx, e, s) =>
                  Icon(Icons.broken_image_outlined, color: c.muted, size: 18),
            ),
            if (photo.isGif)
              Positioned(
                right: 5,
                bottom: 5,
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
            ValueListenableBuilder<Set<String>>(
              valueListenable: Favorites.instance.notifier,
              builder: (ctx, favs, _) {
                if (!favs.contains(photo.path)) return const SizedBox.shrink();
                return Positioned(
                  left: 5,
                  top: 5,
                  child: Container(
                    padding: const EdgeInsets.all(3),
                    decoration: const BoxDecoration(
                        color: Colors.black54, shape: BoxShape.circle),
                    child: const Icon(Icons.favorite,
                        color: Colors.white, size: 12),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

// ───────────────────────── сетки ─────────────────────────
class _AllGrid extends StatelessWidget {
  final List<PhotoItem> photos;
  final double cell;
  const _AllGrid({required this.photos, required this.cell});

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 18),
      gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: cell,
        mainAxisSpacing: 4,
        crossAxisSpacing: 4,
        childAspectRatio: 1,
      ),
      itemCount: photos.length,
      itemBuilder: (ctx, i) => PhotoTile(
        photo: photos[i],
        cell: cell,
        onTap: () => openViewer(ctx, photos, i),
      ),
    );
  }
}

class _DatesView extends StatelessWidget {
  final List<PhotoItem> photos;
  final double cell;
  const _DatesView({required this.photos, required this.cell});

  @override
  Widget build(BuildContext context) {
    final c = AuroraTheme.of(context).colors;
    final groups = <String, List<PhotoItem>>{};
    for (final p in photos) {
      groups.putIfAbsent(dateGroupOf(p.modified), () => []).add(p);
    }
    final slivers = <Widget>[];
    groups.forEach((date, items) {
      slivers.add(SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 8),
          child: Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(date,
                    style: TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w700, color: c.text)),
                const SizedBox(width: 10),
                Text('${items.length} фото',
                    style: TextStyle(fontSize: 12, color: c.muted)),
              ]),
        ),
      ));
      slivers.add(SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        sliver: SliverGrid(
          gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: cell,
            mainAxisSpacing: 4,
            crossAxisSpacing: 4,
            childAspectRatio: 1,
          ),
          delegate: SliverChildBuilderDelegate(
            (ctx, i) => PhotoTile(
              photo: items[i],
              cell: cell,
              onTap: () => openViewer(ctx, photos, photos.indexOf(items[i])),
            ),
            childCount: items.length,
          ),
        ),
      ));
    });
    slivers.add(const SliverToBoxAdapter(child: SizedBox(height: 18)));
    return CustomScrollView(slivers: slivers);
  }
}

// ───────────────────────── альбомы (папки) ─────────────────────────
class _AlbumsView extends StatelessWidget {
  final List<AlbumItem> albums;
  final List<PhotoItem> photos;
  final double cell;
  const _AlbumsView({
    required this.albums,
    required this.photos,
    required this.cell,
  });

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(18, 10, 18, 18),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 190,
        mainAxisSpacing: 16,
        crossAxisSpacing: 16,
        childAspectRatio: 0.82,
      ),
      itemCount: albums.length,
      itemBuilder: (ctx, i) {
        final a = albums[i];
        return _AlbumCard(
          album: a,
          onTap: () {
            final inFolder =
                photos.where((p) => p.folderPath == a.folderPath).toList();
            Navigator.of(ctx).push(MaterialPageRoute(
              builder: (_) =>
                  _FolderPage(album: a, photos: inFolder, cell: cell),
            ));
          },
        );
      },
    );
  }
}

class _AlbumCard extends StatelessWidget {
  final AlbumItem album;
  final VoidCallback onTap;
  const _AlbumCard({required this.album, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final c = AuroraTheme.of(context).colors;
    final dpr = MediaQuery.of(context).devicePixelRatio;
    final cover = album.cover;
    return GestureDetector(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: Stack(fit: StackFit.expand, children: [
                Container(color: c.surface2),
                if (cover != null)
                  Image(
                    image: cover.thumb((190 * dpr).round().clamp(64, 512)),
                    fit: BoxFit.cover,
                    filterQuality: FilterQuality.low,
                    errorBuilder: (ctx, e, s) => Icon(
                        Icons.broken_image_outlined, color: c.muted, size: 22),
                  ),
                const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.bottomCenter,
                      end: Alignment.center,
                      colors: [Colors.black54, Colors.transparent],
                    ),
                  ),
                ),
                Positioned(
                  right: 8,
                  top: 8,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text('${album.count}',
                        style:
                            const TextStyle(color: Colors.white, fontSize: 11)),
                  ),
                ),
              ]),
            ),
          ),
          const SizedBox(height: 8),
          Text(album.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 14, fontWeight: FontWeight.w600, color: c.text)),
          Text('${album.count} изображений',
              style: TextStyle(fontSize: 12, color: c.muted)),
        ],
      ),
    );
  }
}

// ───────────────────────── экран содержимого папки ─────────────────────────
class _FolderPage extends StatelessWidget {
  final AlbumItem album;
  final List<PhotoItem> photos;
  final double cell;
  const _FolderPage({
    required this.album,
    required this.photos,
    required this.cell,
  });

  @override
  Widget build(BuildContext context) {
    final c = AuroraTheme.of(context).colors;
    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
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
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(album.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w800,
                              color: c.text)),
                      Text('${album.count} изображений',
                          style: TextStyle(fontSize: 12, color: c.muted)),
                    ],
                  ),
                ),
              ]),
            ),
            Expanded(child: _AllGrid(photos: photos, cell: cell)),
          ],
        ),
      ),
    );
  }
}
