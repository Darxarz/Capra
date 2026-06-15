import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:photo_manager/photo_manager.dart';
import 'theme.dart';
import 'model.dart';
import 'library_service.dart';
import 'viewer_page.dart';
import 'update_service.dart';
import 'favorites.dart';
import 'folder_tree.dart';
import 'tree_view.dart';
import 'tag_service.dart';
import 'tags_page.dart';
import 'batch_tagger.dart';
import 'dedup_page.dart';
import 'settings_service.dart';
import 'settings_page.dart';
import 'lan_service.dart';
import 'lan_page.dart';
import 'dims_service.dart';
import 'selection.dart';
import 'media_actions.dart';
import 'gap_background.dart';
import 'i18n.dart';

enum ViewMode { all, dates, albums }

enum MediaKindFilter { all, images, gifs, videos }

/// Способ показа раздела «Альбомы»: сетка обложек / список / древо.
enum FolderView { grid, list, tree }

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  late ViewMode _mode = _modeFromSettings();
  // плотность сетки берётся из настроек (SettingsService.cellSize)

  List<PhotoItem> _photos = []; // всё, что просканировано
  List<PhotoItem> _shown = []; // с учётом скрытых папок
  List<String> _folders = []; // папки библиотеки (можно несколько)
  bool _loading = false;
  UpdateInfo? _update; // доступное обновление (null = нет)
  String _query = ''; // строка поиска
  Set<String> _tagMatchPaths = const {}; // пути, чьи теги совпали с запросом
  Set<String> _filterTags = {}; // активный фильтр по тегам (И)
  Set<String> _filterPaths = const {}; // пути, подходящие под фильтр тегов
  bool _tagsPanelOpen = false; // открыта боковая панель тегов
  bool _favOnly = false; // показывать только избранное
  bool _projectsOnly = false; // показывать только проекты (KRA/PSD)
  MediaKindFilter _mediaFilter = MediaKindFilter.all;
  FolderView _folderView = FolderView.grid; // вид раздела «Альбомы»
  FolderNode? _treeCache; // построенное древо папок (кэш)
  MediaKindFilter? _treeCacheFilter;
  int _tagsRev = 0; // счётчик для пересоздания панели тегов после импорта
  bool _mediaGranted = false; // на Android: есть доступ к фото устройства
  bool _allFiles =
      false; // на Android: «доступ ко всем файлам» (секретные папки)
  bool get _useDeviceMedia => Platform.isAndroid || Platform.isIOS;

  bool _compactUi(BuildContext context) {
    final pref = SettingsService.instance.uiDensity;
    if (pref == UiDensity.compact) return true;
    if (pref == UiDensity.comfortable) return false;
    final size = MediaQuery.sizeOf(context);
    return size.shortestSide < 600;
  }

  bool get _showTopSections {
    final p = SettingsService.instance.sectionNavPlacement;
    return p == SectionNavPlacement.top || p == SectionNavPlacement.both;
  }

  bool get _showSideSections {
    final p = SettingsService.instance.sectionNavPlacement;
    return p == SectionNavPlacement.side || p == SectionNavPlacement.both;
  }

  bool _matchesMedia(PhotoItem p) {
    return switch (_mediaFilter) {
      MediaKindFilter.all => true,
      MediaKindFilter.images => !p.isVideo && !p.isGif && !p.isProject,
      MediaKindFilter.gifs => p.isGif,
      MediaKindFilter.videos => p.isVideo,
    };
  }

  List<PhotoItem> get _mediaShown =>
      _shown.where(_matchesMedia).toList(growable: false);

  List<AlbumItem> get _mediaAlbums => LibraryService.albums(_mediaShown);

  void _setMediaFilter(MediaKindFilter v) {
    setState(() {
      _mediaFilter = v;
      _treeCache = null;
      _treeCacheFilter = null;
    });
  }

  /// Папка скрыта (сама или её родитель в списке скрытых)?
  bool _isHiddenPath(String folderPath) {
    final hidden = SettingsService.instance.hiddenFolders;
    if (hidden.isEmpty) return false;
    for (final h in hidden) {
      if (folderPath == h ||
          folderPath.startsWith('$h/') ||
          folderPath.startsWith('$h\\')) {
        return true;
      }
    }
    return false;
  }

  /// Пересчитать показываемые фото/альбомы с учётом скрытых папок.
  void _applyHidden() {
    final s = SettingsService.instance;
    if (s.showHidden || s.hiddenFolders.isEmpty) {
      _shown = _photos;
    } else {
      _shown = _photos.where((p) => !_isHiddenPath(p.folderPath)).toList();
    }
    _treeCache = null;
    _treeCacheFilter = null;
    // по сети раздаём только показываемое (секретные папки не уходят)
    LanService.instance.setLibrary(_shown);
  }

  /// Фото с учётом поиска и фильтра «только избранное».
  List<PhotoItem> get _visiblePhotos {
    Iterable<PhotoItem> r = _mediaShown;
    // отдельный режим: только проекты (KRA/PSD) или, наоборот, без них
    if (_projectsOnly) {
      r = r.where((p) => p.isProject);
    } else {
      r = r.where((p) => !p.isProject);
    }
    if (_favOnly) {
      final favs = Favorites.instance.paths;
      r = r.where((p) => favs.contains(p.path));
    }
    if (_filterTags.isNotEmpty) {
      r = r.where((p) => _filterPaths.contains(p.path));
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

  /// Сортирует мастер-список ОДИН раз (а не на каждом кадре): фильтры в
  /// [_visiblePhotos] сохраняют этот порядок. Для 100к это важно по скорости.
  void _applySort(List<PhotoItem> list) {
    switch (SettingsService.instance.sortMode) {
      case SortMode.dateDesc:
        list.sort((a, b) => b.modified.compareTo(a.modified));
        break;
      case SortMode.dateAsc:
        list.sort((a, b) => a.modified.compareTo(b.modified));
        break;
      case SortMode.nameAsc:
        list.sort((a, b) =>
            a.fileName.toLowerCase().compareTo(b.fileName.toLowerCase()));
        break;
      case SortMode.sizeDesc:
        list.sort((a, b) => b.sizeBytes.compareTo(a.sizeBytes));
        break;
      case SortMode.random:
        list.shuffle(math.Random(SettingsService.instance.sortSeed));
        break;
    }
  }

  void _setSort(SortMode m) {
    SettingsService.instance.setSortMode(m);
    setState(() {
      _applySort(_photos);
      _applyHidden(); // пересобрать производные списки в новом порядке
      _treeCache = null;
    });
  }

  FolderNode _folderTreeNode() {
    if (_treeCache == null || _treeCacheFilter != _mediaFilter) {
      _treeCache = buildForest(_mediaShown, _folders);
      _treeCacheFilter = _mediaFilter;
    }
    return _treeCache!;
  }

  Widget _albumsGrid() {
    final q = _query.trim().toLowerCase();
    final base = _mediaAlbums;
    final albums = q.isEmpty
        ? base
        : base.where((a) => a.name.toLowerCase().contains(q)).toList();
    if (albums.isEmpty) return const _NoResults(favOnly: false);
    return _AlbumsView(
      albums: albums,
      photos: _mediaShown,
      cell: SettingsService.instance.cellSize,
      onHideToggle: _toggleHideFolder,
    );
  }

  Widget _albumsList() {
    final q = _query.trim().toLowerCase();
    final base = _mediaAlbums;
    final albums = q.isEmpty
        ? base
        : base.where((a) => a.name.toLowerCase().contains(q)).toList();
    if (albums.isEmpty) return const _NoResults(favOnly: false);
    return _AlbumsList(
      albums: albums,
      photos: _mediaShown,
      onOpen: (a) {
        final inFolder =
            _mediaShown.where((p) => p.folderPath == a.folderPath).toList();
        Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => _FolderPage(
              album: a,
              photos: inFolder,
              cell: SettingsService.instance.cellSize),
        ));
      },
      onHideToggle: _toggleHideFolder,
    );
  }

  /// Скрыть/показать папку: метка в настройках + .nomedia (чтобы другие
  /// галереи её не сканировали). На Android .nomedia убирает папку из системного
  /// индекса — поясняем это пользователю при скрытии.
  Future<void> _toggleHideFolder(AlbumItem album) async {
    final s = SettingsService.instance;
    final nowHidden = !s.isHidden(album.folderPath);
    final messenger = ScaffoldMessenger.of(context);

    // на Android, чтобы записать .nomedia и потом видеть папку только в GOAT,
    // нужен «доступ ко всем файлам». Просим один раз.
    if (_useDeviceMedia && nowHidden && !_allFiles) {
      final ok = await _ensureAllFiles();
      if (!ok) {
        messenger.showSnackBar(SnackBar(
            content: Text(tr(
                'Для секретных папок нужен «доступ ко всем файлам» (Настройки → Приватность).',
                'Secret folders need “all files access” (Settings → Privacy).',
                'Las carpetas secretas necesitan “acceso a todos los archivos” (Ajustes → Privacidad).'))));
        return;
      }
    }

    s.setFolderHidden(album.folderPath, nowHidden);
    // .nomedia — другие галереи перестают сканировать папку
    try {
      final f = File(p.join(album.folderPath, '.nomedia'));
      if (nowHidden) {
        if (!f.existsSync()) f.createSync();
      } else {
        if (f.existsSync()) f.deleteSync();
      }
    } catch (_) {}
    await _rescan(); // пересобрать (на Android — досканировать секретную по пути)
    if (!mounted) return;
    messenger.showSnackBar(SnackBar(
      content: Text(nowHidden
          ? tr(
              'Папка скрыта. Показать — в Настройках → «Показывать скрытые».',
              'Folder hidden. To show it, enable Settings → “Show hidden”.',
              'Carpeta oculta. Para verla, activa Ajustes → “Mostrar ocultas”.')
          : tr('Папка снова видна.', 'Folder is visible again.',
              'La carpeta vuelve a estar visible.')),
    ));
  }

  /// Убедиться, что есть «доступ ко всем файлам» (Android). Запрашивает при нужде.
  Future<bool> _ensureAllFiles() async {
    if (_allFiles) return true;
    final granted = await LibraryService.requestAllFilesAccess();
    if (mounted) setState(() => _allFiles = granted);
    return granted;
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
      builder: (_) => _FolderPage(
          album: album,
          photos: photos,
          cell: SettingsService.instance.cellSize),
    ));
  }

  void _setFilterTags(Set<String> tags) {
    setState(() {
      _filterTags = tags;
      _filterPaths =
          tags.isEmpty ? const {} : TagService.instance.pathsWithAllTags(tags);
    });
  }

  void _toggleFilterTag(String t) {
    final next = {..._filterTags};
    if (!next.add(t)) next.remove(t);
    _setFilterTags(next);
  }

  @override
  void initState() {
    super.initState();
    SettingsService.instance.addListener(_onSettings);
    _restore();
    _checkUpdates();
  }

  @override
  void dispose() {
    SettingsService.instance.removeListener(_onSettings);
    super.dispose();
  }

  void _onSettings() => setState(_applyHidden);

  ViewMode _modeFromSettings() {
    switch (SettingsService.instance.startSection) {
      case StartSection.dates:
        return ViewMode.dates;
      case StartSection.albums:
        return ViewMode.albums;
      case StartSection.all:
        return ViewMode.all;
    }
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
          title: Text(tr('Обновить GOAT?', 'Update GOAT?', '¿Actualizar GOAT?'),
              style: TextStyle(color: c.text)),
          content: Text(
            tr(
                'Доступна сборка №${u.build}. Приложение скачает её, заменит файлы и перезапустится.',
                'Build #${u.build} is available. The app will download it, replace the files and restart.',
                'La compilación n.º ${u.build} está disponible. La app la descargará, reemplazará los archivos y se reiniciará.'),
            style: TextStyle(color: c.muted),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(tr('Позже', 'Later', 'Más tarde'),
                  style: TextStyle(color: c.muted)),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: c.accent),
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(tr('Обновить', 'Update', 'Actualizar')),
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
    final f = await LibraryService.folders();
    _folders = f;
    // на Android/iOS — сразу доступ к фото устройства (как обычные галереи)
    if (_useDeviceMedia) {
      _mediaGranted = await LibraryService.requestMediaAccess();
      _allFiles = await LibraryService.hasAllFilesAccess();
    } else if (_folders.isEmpty) {
      // на ПК по умолчанию открываем системную папку «Изображения»
      final pics = _defaultPicturesDir();
      if (pics != null) {
        _folders = [pics];
        await LibraryService.setFolders(_folders);
      }
    }
    if (mounted) setState(() {});
    if (_mediaGranted || _folders.isNotEmpty) await _rescan();
  }

  String? _defaultPicturesDir() {
    final home =
        Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'];
    if (home == null) return null;
    final dir = p.join(home, 'Pictures');
    return Directory(dir).existsSync() ? dir : null;
  }

  /// Запросить доступ к фото (Android). На отказ — подсказка открыть настройки.
  Future<void> _askMediaAccess() async {
    final granted = await LibraryService.requestMediaAccess();
    if (!mounted) return;
    setState(() => _mediaGranted = granted);
    if (granted) {
      await _rescan();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(tr(
            'Доступ к фото не выдан. Открыть настройки?',
            'Photo access was not granted. Open settings?',
            'No se concedió acceso a las fotos. ¿Abrir ajustes?')),
        action: SnackBarAction(
            label: tr('Настройки', 'Settings', 'Ajustes'),
            onPressed: PhotoManager.openSetting),
      ));
    }
  }

  Future<void> _addFolder() async {
    // на Android папки не выбираем — все фото берём из MediaStore
    if (_useDeviceMedia) {
      await _askMediaAccess();
      return;
    }
    final path = await FilePicker.platform.getDirectoryPath(
      dialogTitle: tr('Выбери папку с фотографиями',
          'Choose a folder with photos', 'Elige una carpeta con fotos'),
    );
    if (path == null || _folders.contains(path)) return;
    final next = [..._folders, path];
    await LibraryService.setFolders(next);
    setState(() => _folders = next);
    await _rescan();
  }

  Future<void> _removeFolder(String path) async {
    final next = _folders.where((f) => f != path).toList();
    await LibraryService.setFolders(next);
    setState(() => _folders = next);
    await _rescan();
  }

  /// Подтверждение очистки всех папок библиотеки.
  Future<bool?> _confirmClear(BuildContext ctx, int n) {
    final c = AuroraTheme.of(ctx).colors;
    return showDialog<bool>(
      context: ctx,
      builder: (d) => AlertDialog(
        backgroundColor: c.surface,
        title: Text(
            tr('Очистить сканирование?', 'Clear scan?', '¿Borrar el escaneo?'),
            style: TextStyle(color: c.text)),
        content: Text(
            tr(
                'Уберём все $n папок из библиотеки. Сами файлы на диске не трогаем — только список просканированных папок. Потом можно добавить заново.',
                'We’ll remove all $n folders from the library. Files on disk stay untouched — only the scanned folder list is cleared. You can add them again later.',
                'Quitaremos las $n carpetas de la biblioteca. Los archivos del disco no se tocan: solo se borra la lista de carpetas escaneadas. Puedes añadirlas de nuevo después.'),
            style: TextStyle(color: c.muted)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(d, false),
            child: Text(tr('Отмена', 'Cancel', 'Cancelar'),
                style: TextStyle(color: c.muted)),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: c.accent),
            onPressed: () => Navigator.pop(d, true),
            child: Text(tr('Очистить', 'Clear', 'Borrar')),
          ),
        ],
      ),
    );
  }

  /// Убрать все папки библиотеки разом (после автоскана по ПК их сотни).
  Future<void> _clearFolders() async {
    await LibraryService.setFolders(const []);
    setState(() => _folders = const []);
    await _rescan();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(tr('Список папок очищен', 'Folder list cleared',
            'Lista de carpetas borrada'))));
  }

  Future<void> _rescan() async {
    setState(() => _loading = true);
    final photos = <PhotoItem>[];
    final seen = <String>{};
    void addAll(List<PhotoItem> list) {
      for (final ph in list) {
        if (seen.add(ph.path)) photos.add(ph);
      }
    }

    if (_useDeviceMedia && _mediaGranted) {
      try {
        addAll(await LibraryService.scanDeviceMedia());
      } catch (_) {}
    }
    if (_folders.isNotEmpty) {
      addAll(await LibraryService.scanAll(_folders));
    }
    // секретные .nomedia-папки: на Android их нет в MediaStore — сканируем
    // по пути напрямую (нужен «доступ ко всем файлам»). На ПК они и так в
    // обычном скане папок. Видны только в GOAT (фильтр скрытых — в _applyHidden).
    final hidden = SettingsService.instance.hiddenFolders.toList();
    if (_useDeviceMedia && _allFiles && hidden.isNotEmpty) {
      try {
        addAll(await LibraryService.scanFolders(hidden));
      } catch (_) {}
    }
    photos.sort((a, b) => b.modified.compareTo(a.modified));
    if (!mounted) return;
    // перепривязать теги к переименованным/перемещённым файлам (по хешу)
    try {
      TagService.instance.relink({for (final p in photos) p.path});
    } catch (_) {}
    setState(() {
      _photos = photos;
      _applySort(_photos);
      _applyHidden(); // считает _shown/_albums и отдаёт раздаче по сети
      _loading = false;
    });
  }

  int _relinkNow() =>
      TagService.instance.relink({for (final ph in _photos) ph.path});

  void _openSettings() {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => SettingsPage(
        onTagsImported: () {
          if (!mounted) return;
          setState(() => _tagsRev++);
        },
        onRelinkRequested: _relinkNow,
      ),
    ));
  }

  Future<void> _openTagsSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        final c = AuroraTheme.of(ctx).colors;
        return FractionallySizedBox(
          heightFactor: 0.92,
          child: ClipRRect(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(18)),
            child: ColoredBox(
              color: c.surface,
              child: SafeArea(
                top: false,
                child: TagsPanel(
                  key: ValueKey('sheet-$_tagsRev'),
                  width: double.infinity,
                  selected: _filterTags,
                  onToggle: _toggleFilterTag,
                  onClear: () => _setFilterTags({}),
                  onClose: () => Navigator.of(ctx).pop(),
                  onStartBatch: () => BatchTagger.instance.start(_photos),
                ),
              ),
            ),
          ),
        );
      },
    );
    if (mounted) setState(() => _tagsRev++);
  }

  void _shiftMode(int delta) {
    if (Selection.instance.active) return;
    final modes = _projectsOnly
        ? const [ViewMode.all]
        : const [ViewMode.all, ViewMode.dates, ViewMode.albums];
    final i = modes.indexOf(_mode);
    if (i < 0) return;
    final next = (i + delta).clamp(0, modes.length - 1);
    if (next != i) setState(() => _mode = modes[next]);
  }

  void _openMobileTools() {
    final c = AuroraTheme.of(context).colors;
    Widget tile(IconData icon, String text, VoidCallback onTap,
        {bool on = false}) {
      return ListTile(
        leading: Icon(icon, color: on ? c.accentInk : c.text),
        title: Text(text,
            style: TextStyle(
                color: on ? c.accentInk : c.text,
                fontWeight: on ? FontWeight.w700 : FontWeight.w500)),
        onTap: () {
          Navigator.pop(context);
          onTap();
        },
      );
    }

    showModalBottomSheet<void>(
      context: context,
      backgroundColor: c.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (_) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          tile(
              Icons.folder_open,
              tr('Папки библиотеки', 'Library folders',
                  'Carpetas de la biblioteca'),
              _manageFolders),
          tile(
              _favOnly ? Icons.favorite_rounded : Icons.favorite_border_rounded,
              tr('Только избранное', 'Favorites only', 'Solo favoritos'),
              () => setState(() => _favOnly = !_favOnly),
              on: _favOnly),
          tile(
              Icons.brush_outlined,
              tr('Проекты KRA/PSD', 'KRA/PSD projects', 'Proyectos KRA/PSD'),
              () => setState(() {
                    _projectsOnly = !_projectsOnly;
                    if (_projectsOnly) _mode = ViewMode.all;
                  }),
              on: _projectsOnly),
          tile(Icons.sell_outlined, tr('Теги', 'Tags', 'Etiquetas'),
              _openTagsSheet,
              on: _filterTags.isNotEmpty),
          tile(Icons.content_copy_outlined,
              tr('Дубликаты', 'Duplicates', 'Duplicados'), _openDedup),
          tile(Icons.wifi_tethering_rounded,
              tr('Локальная сеть', 'Local network', 'Red local'), _openLan,
              on: LanService.instance.isRunning),
          tile(Icons.delete_outline_rounded, tr('Корзина', 'Trash', 'Papelera'),
              _openTrash),
          tile(Icons.settings_outlined, tr('Настройки', 'Settings', 'Ajustes'),
              _openSettings),
        ]),
      ),
    );
  }

  void _openDedup() {
    if (_photos.isEmpty) return;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => DupPage(photos: _photos, onLibraryChanged: _rescan),
    ));
  }

  void _openLan() {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => const LanPage(),
    ));
  }

  void _openTrash() {
    // на Android удаление уходит в системную корзину галереи — своей у нас нет,
    // а открыть «Недавно удалённые» нельзя (у каждого вендора своё). Поясняем.
    if (Platform.isAndroid || Platform.isIOS) {
      final c = AuroraTheme.of(context).colors;
      showModalBottomSheet<void>(
        context: context,
        backgroundColor: c.surface,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
        ),
        builder: (ctx) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(22, 20, 22, 24),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.delete_outline_rounded, color: c.accent, size: 34),
              const SizedBox(height: 12),
              Text(
                  tr(
                      'Корзина — в галерее устройства',
                      'Trash is in the device gallery',
                      'La papelera está en la galería del dispositivo'),
                  style: TextStyle(
                      color: c.text,
                      fontSize: 16,
                      fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              Text(
                  tr(
                      'На Android удалённые фото попадают в системную корзину — «Недавно удалённые» в приложении Галерея/Фото устройства. Там их можно восстановить в течение ~30 дней. Открыть её из стороннего приложения система не позволяет.',
                      'On Android, deleted photos go to the system trash — “Recently deleted” in the device Gallery/Photos app. You can restore them there for about 30 days. Android does not let third-party apps open that screen directly.',
                      'En Android, las fotos eliminadas van a la papelera del sistema: “Eliminados recientemente” en la app Galería/Fotos del dispositivo. Puedes restaurarlas allí durante unos 30 días. Android no permite abrir esa pantalla directamente desde apps de terceros.'),
                  textAlign: TextAlign.center,
                  style: TextStyle(color: c.muted, fontSize: 13)),
              const SizedBox(height: 18),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: c.accent,
                  minimumSize: const Size.fromHeight(46),
                ),
                onPressed: () => Navigator.pop(ctx),
                child: Text(tr('Понятно', 'Got it', 'Entendido')),
              ),
            ]),
          ),
        ),
      );
      return;
    }
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => TrashPage(onChanged: _rescan),
    ));
  }

  void _manageFolders() {
    final c = AuroraTheme.of(context).colors;
    // на Android папки не выбираются — показываем управление доступом к фото
    if (_useDeviceMedia) {
      showModalBottomSheet<void>(
        context: context,
        backgroundColor: c.surface,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
        ),
        builder: (ctx) => SafeArea(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Row(children: [
                Icon(Icons.photo_library_outlined, color: c.accent, size: 20),
                const SizedBox(width: 10),
                Text(tr('Доступ к фото', 'Photo access', 'Acceso a fotos'),
                    style: TextStyle(
                        color: c.text,
                        fontSize: 16,
                        fontWeight: FontWeight.w700)),
              ]),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
              child: Text(
                  _mediaGranted
                      ? tr(
                          'GOAT показывает все фото устройства автоматически.',
                          'GOAT shows all device photos automatically.',
                          'GOAT muestra automáticamente todas las fotos del dispositivo.')
                      : tr(
                          'Дай доступ к фото — GOAT покажет все изображения.',
                          'Grant photo access — GOAT will show all images.',
                          'Da acceso a tus fotos: GOAT mostrará todas las imágenes.'),
                  style: TextStyle(color: c.muted, fontSize: 13)),
            ),
            ListTile(
              leading:
                  Icon(Icons.photo_size_select_actual_outlined, color: c.text),
              title: Text(
                  _mediaGranted
                      ? tr('Выбрать, какие фото видны', 'Choose visible photos',
                          'Elegir fotos visibles')
                      : tr('Дать доступ', 'Grant access', 'Dar acceso'),
                  style: TextStyle(color: c.text)),
              onTap: () async {
                Navigator.pop(ctx);
                if (_mediaGranted) {
                  await PhotoManager.presentLimited();
                  await _rescan();
                } else {
                  await _askMediaAccess();
                }
              },
            ),
            ListTile(
              leading: Icon(Icons.settings_outlined, color: c.text),
              title: Text(
                  tr('Открыть настройки приложения', 'Open app settings',
                      'Abrir ajustes de la app'),
                  style: TextStyle(color: c.text)),
              onTap: () {
                Navigator.pop(ctx);
                PhotoManager.openSetting();
              },
            ),
            const SizedBox(height: 10),
          ]),
        ),
      );
      return;
    }
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: c.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => SafeArea(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Row(children: [
                Icon(Icons.folder_copy_outlined, color: c.accent, size: 20),
                const SizedBox(width: 10),
                Text(
                    tr('Папки библиотеки', 'Library folders',
                        'Carpetas de la biblioteca'),
                    style: TextStyle(
                        color: c.text,
                        fontSize: 16,
                        fontWeight: FontWeight.w700)),
              ]),
            ),
            const Divider(height: 1),
            if (_folders.length > 1)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: c.accent,
                    side: BorderSide(color: c.accent),
                    minimumSize: const Size.fromHeight(46),
                  ),
                  onPressed: () async {
                    final nav = Navigator.of(ctx);
                    final ok = await _confirmClear(ctx, _folders.length);
                    if (ok != true) return;
                    nav.pop();
                    await _clearFolders();
                  },
                  icon: const Icon(Icons.delete_sweep_outlined),
                  label: Text(
                      '${tr('Очистить сканирование', 'Clear scan', 'Borrar escaneo')} (${_folders.length})'),
                ),
              ),
            if (_folders.isEmpty)
              Padding(
                padding: const EdgeInsets.all(20),
                child: Text(
                    tr(
                        'Пока не добавлено ни одной папки.',
                        'No folders added yet.',
                        'Aún no hay carpetas añadidas.'),
                    style: TextStyle(color: c.muted)),
              ),
            for (final f in _folders)
              ListTile(
                leading: Icon(Icons.folder_rounded, color: c.accent, size: 20),
                title: Text(f,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: c.text, fontSize: 13)),
                trailing: IconButton(
                  icon: Icon(Icons.close, color: c.muted, size: 18),
                  tooltip: tr('Убрать', 'Remove', 'Quitar'),
                  onPressed: () async {
                    await _removeFolder(f);
                    setSheet(() {});
                  },
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 6),
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: c.accent,
                  minimumSize: const Size.fromHeight(46),
                ),
                onPressed: () async {
                  Navigator.pop(ctx);
                  await _addFolder();
                },
                icon: const Icon(Icons.add),
                label:
                    Text(tr('Добавить папку', 'Add folder', 'Añadir carpeta')),
              ),
            ),
            if (Platform.isWindows)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: c.accent,
                    side: BorderSide(color: c.accent),
                    minimumSize: const Size.fromHeight(46),
                  ),
                  onPressed: () async {
                    Navigator.pop(ctx);
                    await _scanWholePc();
                  },
                  icon: const Icon(Icons.travel_explore_rounded),
                  label: Text(tr(
                      'Найти все картинки на ПК',
                      'Find all images on PC',
                      'Buscar todas las imágenes en el PC')),
                ),
              ),
          ]),
        ),
      ),
    );
  }

  /// Глубокий поиск всех картинок на компьютере (Windows). Найденные папки
  /// добавляются в библиотеку (минимальный набор верхних), чтобы повторные
  /// сканы были быстрыми.
  Future<void> _scanWholePc() async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _loading = true);
    final photos = await LibraryService.scanWholePc(
        minDim: SettingsService.instance.pcScanMinDim);
    final folders =
        LibraryService.topFolders({for (final ph in photos) ph.folderPath});
    await LibraryService.setFolders(folders);
    if (!mounted) return;
    try {
      TagService.instance.relink({for (final ph in photos) ph.path});
    } catch (_) {}
    setState(() {
      _folders = folders;
      _photos = photos;
      _applySort(_photos);
      _applyHidden();
      _loading = false;
    });
    messenger.showSnackBar(SnackBar(
        content: Text(tr(
            'Найдено картинок: ${photos.length} в ${folders.length} папках',
            'Found images: ${photos.length} in ${folders.length} folders',
            'Imágenes encontradas: ${photos.length} en ${folders.length} carpetas'))));
  }

  @override
  Widget build(BuildContext context) {
    final c = AuroraTheme.of(context).colors;
    final compact = _compactUi(context);
    return _SelPopScope(
      child: Scaffold(
        backgroundColor: c.bg,
        body: SafeArea(
          child: compact ? _compactShell(c) : _wideShell(c),
        ),
      ),
    );
  }

  Widget _mainColumn(AuroraColors c, {required bool compact}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _TopBar(
          mode: _mode,
          cell: SettingsService.instance.cellSize,
          query: _query,
          compact: compact,
          showSections: _showTopSections && !compact,
          onSearch: (q) => setState(() {
            _query = q;
            _tagMatchPaths = q.trim().isEmpty
                ? const {}
                : TagService.instance.pathsMatchingTag(q);
          }),
          onMode: (m) => setState(() => _mode = m),
          onCell: SettingsService.instance.setCellSize,
          onPickFolder: _manageFolders,
          update: _update,
          onUpdate: _startUpdate,
          onMore: _openMobileTools,
        ),
        if (compact && _showTopSections)
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 6, 10, 2),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child:
                  _Tabs(mode: _mode, onMode: (m) => setState(() => _mode = m)),
            ),
          ),
        _CountBar(
          mode: _mode,
          total: _visiblePhotos.length,
          albums: _mediaAlbums.length,
          compact: compact,
          sort: SettingsService.instance.sortMode,
          onSort: _setSort,
          folder: _folders.isNotEmpty
              ? (_folders.length == 1
                  ? _folders.first
                  : '${_folders.length} ${tr('папок', 'folders', 'carpetas')}')
              : (_useDeviceMedia && _mediaGranted
                  ? tr('все фото устройства', 'all device photos',
                      'todas las fotos del dispositivo')
                  : null),
        ),
        _MediaFilterBar(value: _mediaFilter, onChanged: _setMediaFilter),
        if (_filterTags.isNotEmpty)
          _TagFilterBar(
            tags: _filterTags,
            onRemove: (t) => _setFilterTags({..._filterTags}..remove(t)),
            onClear: () => _setFilterTags({}),
            onEdit: compact
                ? _openTagsSheet
                : () => setState(() => _tagsPanelOpen = true),
          ),
        Expanded(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onHorizontalDragEnd: compact
                ? (d) {
                    final v = d.primaryVelocity ?? 0;
                    if (v < -350) _shiftMode(1);
                    if (v > 350) _shiftMode(-1);
                  }
                : null,
            child: Stack(children: [
              ValueListenableBuilder<Set<String>>(
                valueListenable: Favorites.instance.notifier,
                builder: (_, __, ___) => _body(c),
              ),
              AnimatedBuilder(
                animation: Selection.instance,
                builder: (_, __) => Selection.instance.active
                    ? Align(
                        alignment: Alignment.topCenter,
                        child: _SelectionBar(
                          count: Selection.instance.count,
                          onClose: () => Selection.instance.clear(),
                          onSelectAll: () =>
                              Selection.instance.selectAll(_visiblePhotos),
                          onFavorite: _selFavorite,
                          onTags: _selTags,
                          onCopy: () => _selCopyMove(move: false),
                          onMove: () => _selCopyMove(move: true),
                          onShare: _selShare,
                          onDelete: _selDelete,
                        ),
                      )
                    : const SizedBox.shrink(),
              ),
            ]),
          ),
        ),
      ],
    );
  }

  Widget _wideShell(AuroraColors c) {
    return Row(
      children: [
        _Rail(
          mode: _mode,
          showSections: _showSideSections,
          onMode: (m) => setState(() => _mode = m),
          favOnly: _favOnly,
          onFav: () => setState(() => _favOnly = !_favOnly),
          projectsOnly: _projectsOnly,
          onProjects: () => setState(() {
            _projectsOnly = !_projectsOnly;
            if (_projectsOnly) _mode = ViewMode.all;
          }),
          onTags: () => setState(() => _tagsPanelOpen = !_tagsPanelOpen),
          tagsOpen: _tagsPanelOpen,
          onDedup: _openDedup,
          onLan: _openLan,
          onTrash: _openTrash,
          onSettings: _openSettings,
        ),
        if (_tagsPanelOpen)
          TagsPanel(
            key: ValueKey(_tagsRev),
            selected: _filterTags,
            onToggle: _toggleFilterTag,
            onClear: () => _setFilterTags({}),
            onClose: () => setState(() => _tagsPanelOpen = false),
            onStartBatch: () => BatchTagger.instance.start(_photos),
          ),
        Expanded(child: _mainColumn(c, compact: false)),
      ],
    );
  }

  Widget _compactShell(AuroraColors c) {
    if (_tagsPanelOpen) _tagsPanelOpen = false;
    return Column(
      children: [
        Expanded(child: _mainColumn(c, compact: true)),
        _BottomNav(
          mode: _mode,
          showSections: _showSideSections,
          favOnly: _favOnly,
          tagFiltered: _filterTags.isNotEmpty,
          onMode: (m) => setState(() => _mode = m),
          onFav: () => setState(() => _favOnly = !_favOnly),
          onTags: _openTagsSheet,
          onMore: _openMobileTools,
        ),
      ],
    );
  }

  // ───────────────────── массовые действия над выделением ─────────────────────
  List<PhotoItem> _selectedPhotos() {
    final paths = Selection.instance.paths;
    return _photos.where((p) => paths.contains(p.path)).toList();
  }

  Future<void> _selFavorite() async {
    for (final ph in _selectedPhotos()) {
      if (!Favorites.instance.contains(ph.path)) {
        await Favorites.instance.toggle(ph.path);
      }
    }
    Selection.instance.clear();
  }

  Future<void> _selTags() async {
    final photos = _selectedPhotos();
    final n = await MediaActions.addTags(context, photos);
    if (!mounted) return;
    if (n > 0) {
      setState(() => _tagsRev++);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(tr('Теги добавлены к $n фото',
              'Tags added to $n photos', 'Etiquetas añadidas a $n fotos'))));
    }
    Selection.instance.clear();
  }

  Future<void> _selShare() async {
    final n = await MediaActions.share(_selectedPhotos());
    if (n == 0 && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(tr(
              'Нечего отправить', 'Nothing to share', 'Nada para compartir'))));
    }
    Selection.instance.clear();
  }

  Future<void> _selCopyMove({required bool move}) async {
    final res =
        await MediaActions.copyOrMove(context, _selectedPhotos(), move: move);
    if (!mounted || res == null) return;
    final verb = move
        ? tr('Перемещено', 'Moved', 'Movidas')
        : tr('Скопировано', 'Copied', 'Copiadas');
    final failTxt = res.fail > 0
        ? ', ${tr('не удалось', 'failed', 'fallaron')}: ${res.fail}'
        : '';
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('$verb: ${res.ok}$failTxt')));
    Selection.instance.clear();
    if (move && res.ok > 0) await _rescan();
  }

  Future<void> _selDelete() async {
    final n = await MediaActions.delete(context, _selectedPhotos());
    if (n == -1) return; // отмена
    Selection.instance.clear();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(tr('Удалено: $n', 'Deleted: $n', 'Eliminadas: $n'))));
    await _rescan();
  }

  Widget _body(AuroraColors c) {
    if (_loading) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          CircularProgressIndicator(color: c.accent),
          const SizedBox(height: 14),
          Text(tr('Сканирую папку…', 'Scanning folder…', 'Escaneando carpeta…'),
              style: TextStyle(color: c.muted)),
        ]),
      );
    }
    if (_photos.isEmpty) {
      return _EmptyState(
        onPick: _addFolder,
        deviceMedia: _useDeviceMedia,
        granted: _mediaGranted,
      );
    }

    if (_mode == ViewMode.albums) {
      return Column(
        children: [
          _FolderViewToggle(
            view: _folderView,
            onChanged: (v) => setState(() => _folderView = v),
          ),
          Expanded(
            child: switch (_folderView) {
              FolderView.tree => TreeView(
                  root: _folderTreeNode(),
                  onOpenFolder: _openTreeFolder,
                ),
              FolderView.list => _albumsList(),
              FolderView.grid => _albumsGrid(),
            },
          ),
        ],
      );
    }

    final visible = _visiblePhotos;
    if (visible.isEmpty) return _NoResults(favOnly: _favOnly);
    switch (_mode) {
      case ViewMode.all:
        return _AllGrid(
            photos: visible, cell: SettingsService.instance.cellSize);
      case ViewMode.dates:
        return _DatesView(
            photos: visible, cell: SettingsService.instance.cellSize);
      case ViewMode.albums:
        return const SizedBox.shrink(); // обработано выше
    }
  }
}

// ───────────────────────── пустой экран ─────────────────────────
class _EmptyState extends StatelessWidget {
  final VoidCallback onPick;
  final bool deviceMedia;
  final bool granted;
  const _EmptyState({
    required this.onPick,
    required this.deviceMedia,
    required this.granted,
  });

  @override
  Widget build(BuildContext context) {
    final c = AuroraTheme.of(context).colors;
    // на Android без доступа — предлагаем дать доступ к фото
    final needAccess = deviceMedia && !granted;
    final subtitle = deviceMedia
        ? (granted
            ? tr(
                'Фото на устройстве не найдены.',
                'No photos found on the device.',
                'No se encontraron fotos en el dispositivo.')
            : tr(
                'Дай доступ к фото — GOAT покажет все изображения устройства.',
                'Grant photo access — GOAT will show all images on the device.',
                'Da acceso a tus fotos: GOAT mostrará todas las imágenes del dispositivo.'))
        : tr(
            'Выбери папку с фотографиями — GOAT покажет их здесь.',
            'Pick a folder with photos — GOAT will show them here.',
            'Elige una carpeta con fotos: GOAT las mostrará aquí.');
    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.photo_library_outlined, size: 64, color: c.muted),
        const SizedBox(height: 16),
        Text(
            needAccess
                ? tr('Нужен доступ к фото', 'Photo access needed',
                    'Hace falta acceso a fotos')
                : tr('Здесь пока пусто', 'Nothing here yet',
                    'Aquí todavía no hay nada'),
            style: TextStyle(
                fontSize: 18, fontWeight: FontWeight.w700, color: c.text)),
        const SizedBox(height: 6),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Text(subtitle,
              textAlign: TextAlign.center, style: TextStyle(color: c.muted)),
        ),
        const SizedBox(height: 18),
        if (!(deviceMedia && granted))
          FilledButton.icon(
            onPressed: onPick,
            style: FilledButton.styleFrom(backgroundColor: c.accent),
            icon: Icon(deviceMedia ? Icons.photo_library : Icons.folder_open),
            label: Text(deviceMedia
                ? tr('Дать доступ к фото', 'Grant photo access',
                    'Dar acceso a fotos')
                : tr('Выбрать папку', 'Pick a folder', 'Elegir carpeta')),
          ),
      ]),
    );
  }
}

// ───────────────────────── боковая панель ─────────────────────────
class _Rail extends StatelessWidget {
  final ViewMode mode;
  final bool showSections;
  final ValueChanged<ViewMode> onMode;
  final bool favOnly;
  final VoidCallback onFav;
  final bool projectsOnly;
  final VoidCallback onProjects;
  final VoidCallback onTags;
  final bool tagsOpen;
  final VoidCallback onDedup;
  final VoidCallback onLan;
  final VoidCallback onTrash;
  final VoidCallback onSettings;
  const _Rail({
    required this.mode,
    required this.showSections,
    required this.onMode,
    required this.favOnly,
    required this.onFav,
    required this.projectsOnly,
    required this.onProjects,
    required this.onTags,
    required this.tagsOpen,
    required this.onDedup,
    required this.onLan,
    required this.onTrash,
    required this.onSettings,
  });

  @override
  Widget build(BuildContext context) {
    final c = AuroraTheme.of(context).colors;
    Widget item(IconData icon, ViewMode? m,
        {VoidCallback? onTap, bool active = false, String? tip}) {
      final on = active || (m != null && m == mode);
      final btn = Padding(
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
      if (tip == null) return btn;
      return Tooltip(message: tip, child: btn);
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
            child: const Icon(Icons.auto_awesome_mosaic,
                size: 18, color: Colors.white),
          ),
          const SizedBox(height: 14),
          if (showSections) ...[
            item(Icons.grid_view_rounded, ViewMode.all,
                tip: tr('Все', 'All', 'Todo')),
            item(Icons.calendar_today_rounded, ViewMode.dates,
                tip: tr('По датам', 'By date', 'Por fecha')),
            item(Icons.folder_rounded, ViewMode.albums,
                tip: tr('Альбомы', 'Albums', 'Álbumes')),
          ],
          item(favOnly ? Icons.favorite_rounded : Icons.favorite_border_rounded,
              null,
              onTap: onFav,
              active: favOnly,
              tip: tr('Избранное', 'Favorites', 'Favoritos')),
          item(Icons.brush_outlined, null,
              onTap: onProjects,
              active: projectsOnly,
              tip: tr('Проекты (KRA/PSD)', 'Projects (KRA/PSD)',
                  'Proyectos (KRA/PSD)')),
          item(Icons.sell_outlined, null,
              onTap: onTags,
              active: tagsOpen,
              tip: tr('Теги', 'Tags', 'Etiquetas')),
          item(Icons.content_copy_outlined, null,
              onTap: onDedup, tip: tr('Дубликаты', 'Duplicates', 'Duplicados')),
          // активная подсветка, пока раздаём по сети
          AnimatedBuilder(
            animation: LanService.instance,
            builder: (_, __) => item(Icons.wifi_tethering_rounded, null,
                onTap: onLan,
                active: LanService.instance.isRunning,
                tip: tr('Локальная сеть', 'Local network', 'Red local')),
          ),
          item(Icons.delete_outline_rounded, null,
              onTap: onTrash, tip: tr('Корзина', 'Trash', 'Papelera')),
          const Spacer(),
          item(Icons.settings_outlined, null,
              onTap: onSettings, tip: tr('Настройки', 'Settings', 'Ajustes')),
          const SizedBox(height: 10),
        ],
      ),
    );
  }
}

// ───────────────────────── нижняя панель для телефонов ─────────────────────────
class _BottomNav extends StatelessWidget {
  final ViewMode mode;
  final bool showSections;
  final bool favOnly;
  final bool tagFiltered;
  final ValueChanged<ViewMode> onMode;
  final VoidCallback onFav;
  final VoidCallback onTags;
  final VoidCallback onMore;
  const _BottomNav({
    required this.mode,
    required this.showSections,
    required this.favOnly,
    required this.tagFiltered,
    required this.onMode,
    required this.onFav,
    required this.onTags,
    required this.onMore,
  });

  @override
  Widget build(BuildContext context) {
    final c = AuroraTheme.of(context).colors;
    Widget item(IconData icon, String label, bool on, VoidCallback tap) {
      return Expanded(
        child: InkWell(
          onTap: tap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 7),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(icon, size: 21, color: on ? c.accentInk : c.muted),
              const SizedBox(height: 2),
              Text(label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: on ? c.accentInk : c.muted,
                      fontSize: 10.5,
                      fontWeight: on ? FontWeight.w700 : FontWeight.w600)),
            ]),
          ),
        ),
      );
    }

    return DecoratedBox(
      decoration: BoxDecoration(
        color: c.surface,
        border: Border(top: BorderSide(color: c.line)),
      ),
      child: Row(children: [
        if (showSections) ...[
          item(Icons.grid_view_rounded, tr('Все', 'All', 'Todo'),
              mode == ViewMode.all, () => onMode(ViewMode.all)),
          item(Icons.calendar_today_rounded, tr('Даты', 'Dates', 'Fechas'),
              mode == ViewMode.dates, () => onMode(ViewMode.dates)),
          item(Icons.folder_rounded, tr('Альбомы', 'Albums', 'Álbumes'),
              mode == ViewMode.albums, () => onMode(ViewMode.albums)),
        ],
        item(favOnly ? Icons.favorite_rounded : Icons.favorite_border_rounded,
            tr('Избр.', 'Favs', 'Fav.'), favOnly, onFav),
        item(Icons.sell_outlined, tr('Теги', 'Tags', 'Etiquetas'), tagFiltered,
            onTags),
        item(Icons.more_horiz_rounded, tr('Ещё', 'More', 'Más'), false, onMore),
      ]),
    );
  }
}

// ── обёртка PopScope, реагирующая на режим выделения (Назад = снять выбор) ──
class _SelPopScope extends StatefulWidget {
  final Widget child;
  const _SelPopScope({required this.child});
  @override
  State<_SelPopScope> createState() => _SelPopScopeState();
}

class _SelPopScopeState extends State<_SelPopScope> {
  @override
  void initState() {
    super.initState();
    Selection.instance.addListener(_u);
  }

  @override
  void dispose() {
    Selection.instance.removeListener(_u);
    super.dispose();
  }

  void _u() => setState(() {});

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !Selection.instance.active,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Selection.instance.clear();
      },
      child: widget.child, // тот же экземпляр — поддерево не пересобирается
    );
  }
}

// ───────────────────── панель массовых действий ─────────────────────
class _SelectionBar extends StatelessWidget {
  final int count;
  final VoidCallback onClose;
  final VoidCallback onSelectAll;
  final VoidCallback onFavorite;
  final VoidCallback onTags;
  final VoidCallback onCopy;
  final VoidCallback onMove;
  final VoidCallback onShare;
  final VoidCallback onDelete;
  const _SelectionBar({
    required this.count,
    required this.onClose,
    required this.onSelectAll,
    required this.onFavorite,
    required this.onTags,
    required this.onCopy,
    required this.onMove,
    required this.onShare,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final c = AuroraTheme.of(context).colors;
    Widget act(IconData icon, String tip, VoidCallback onTap, {Color? color}) =>
        IconButton(
          icon: Icon(icon, size: 21, color: color ?? c.text),
          tooltip: tip,
          onPressed: count == 0 ? null : onTap,
        );

    return Container(
      margin: const EdgeInsets.fromLTRB(10, 8, 10, 0),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: c.line),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.12),
            blurRadius: 16,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(children: [
        IconButton(
          icon: Icon(Icons.close, color: c.text),
          tooltip: tr('Снять выделение', 'Clear selection', 'Quitar selección'),
          onPressed: onClose,
        ),
        Text('$count',
            style: TextStyle(
                color: c.text, fontSize: 15, fontWeight: FontWeight.w800)),
        const SizedBox(width: 2),
        IconButton(
          icon: Icon(Icons.select_all_rounded, size: 20, color: c.muted),
          tooltip: tr('Выбрать все', 'Select all', 'Seleccionar todo'),
          onPressed: onSelectAll,
        ),
        const Spacer(),
        Flexible(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            reverse: true,
            child: Row(children: [
              act(Icons.favorite_border_rounded,
                  tr('В избранное', 'Favorite', 'A favoritos'), onFavorite),
              act(Icons.sell_outlined,
                  tr('Добавить теги', 'Add tags', 'Añadir etiquetas'), onTags),
              act(
                  Icons.copy_all_rounded,
                  tr('Копировать в папку', 'Copy to folder',
                      'Copiar a carpeta'),
                  onCopy),
              act(
                  Icons.drive_file_move_outline,
                  tr('Переместить в папку', 'Move to folder',
                      'Mover a carpeta'),
                  onMove),
              act(Icons.ios_share_rounded,
                  tr('Отправить', 'Share', 'Compartir'), onShare),
              act(Icons.delete_outline_rounded,
                  tr('Удалить', 'Delete', 'Eliminar'), onDelete,
                  color: c.accent),
            ]),
          ),
        ),
      ]),
    );
  }
}

// ───────────────────────── фильтр типа медиа ─────────────────────────
class _MediaFilterBar extends StatelessWidget {
  final MediaKindFilter value;
  final ValueChanged<MediaKindFilter> onChanged;
  const _MediaFilterBar({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final c = AuroraTheme.of(context).colors;
    Widget chip(String label, IconData icon, MediaKindFilter v) {
      final on = value == v;
      return GestureDetector(
        onTap: () => onChanged(v),
        child: AnimatedContainer(
          duration: SettingsService.instance.reduceMotion
              ? Duration.zero
              : const Duration(milliseconds: 140),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: on ? c.surface : Colors.transparent,
            borderRadius: BorderRadius.circular(9),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 15, color: on ? c.accentInk : c.muted),
            const SizedBox(width: 5),
            Text(label,
                style: TextStyle(
                    color: on ? c.text : c.muted,
                    fontSize: 12,
                    fontWeight: FontWeight.w700)),
          ]),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 5),
      child: Align(
        alignment: Alignment.centerLeft,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: c.surface2,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: c.line),
            ),
            child: Row(children: [
              chip(tr('Всё', 'All', 'Todo'), Icons.all_inclusive_rounded,
                  MediaKindFilter.all),
              chip(tr('Фото', 'Images', 'Imágenes'), Icons.image_rounded,
                  MediaKindFilter.images),
              chip('GIF', Icons.gif_box_rounded, MediaKindFilter.gifs),
              chip(tr('Видео', 'Video', 'Vídeo'),
                  Icons.play_circle_outline_rounded, MediaKindFilter.videos),
            ]),
          ),
        ),
      ),
    );
  }
}

// ───────────────────────── верхняя панель ─────────────────────────
class _TopBar extends StatelessWidget {
  final ViewMode mode;
  final double cell;
  final String query;
  final bool compact;
  final bool showSections;
  final ValueChanged<String> onSearch;
  final ValueChanged<ViewMode> onMode;
  final ValueChanged<double> onCell;
  final VoidCallback onPickFolder;
  final UpdateInfo? update;
  final VoidCallback onUpdate;
  final VoidCallback onMore;
  const _TopBar({
    required this.mode,
    required this.cell,
    required this.query,
    required this.compact,
    required this.showSections,
    required this.onSearch,
    required this.onMode,
    required this.onCell,
    required this.onPickFolder,
    required this.update,
    required this.onUpdate,
    required this.onMore,
  });

  @override
  Widget build(BuildContext context) {
    final c = AuroraTheme.of(context).colors;
    return Container(
      padding: compact
          ? const EdgeInsets.fromLTRB(10, 7, 8, 7)
          : const EdgeInsets.fromLTRB(16, 12, 16, 10),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: c.line)),
      ),
      child: Row(
        children: [
          Expanded(child: _SearchField(initial: query, onSearch: onSearch)),
          SizedBox(width: compact ? 4 : 10),
          IconButton(
            onPressed: onPickFolder,
            icon: Icon(Icons.folder_open, color: c.muted),
            tooltip: tr('Папки библиотеки', 'Library folders',
                'Carpetas de la biblioteca'),
            visualDensity: compact ? VisualDensity.compact : null,
          ),
          if (showSections) ...[
            const SizedBox(width: 4),
            _Tabs(mode: mode, onMode: onMode),
            const SizedBox(width: 8),
          ],
          const _LayoutToggle(),
          if (!compact) ...[
            const SizedBox(width: 4),
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
          ] else
            IconButton(
              onPressed: onMore,
              icon: Icon(Icons.more_horiz_rounded, color: c.muted),
              tooltip: tr('Ещё', 'More', 'Más'),
              visualDensity: VisualDensity.compact,
            ),
          if (update != null) ...[
            SizedBox(width: compact ? 2 : 6),
            _UpdateButton(buildNo: update!.build, onTap: onUpdate),
          ],
        ],
      ),
    );
  }
}

// ───────── переключатель раскладки: квадраты / мозаика ─────────
class _LayoutToggle extends StatelessWidget {
  const _LayoutToggle();

  @override
  Widget build(BuildContext context) {
    final c = AuroraTheme.of(context).colors;
    return AnimatedBuilder(
      animation: SettingsService.instance,
      builder: (ctx, _) {
        final mosaic = SettingsService.instance.gridLayout == GridLayout.mosaic;
        return Tooltip(
          message: mosaic
              ? tr('Мозаика', 'Mosaic', 'Mosaico')
              : tr('Ровные квадраты', 'Even squares', 'Cuadrícula uniforme'),
          child: Material(
            color: mosaic ? c.accentSoft : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
            child: InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: () => SettingsService.instance.setGridLayout(
                  mosaic ? GridLayout.square : GridLayout.mosaic),
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Icon(
                  mosaic ? Icons.dashboard_rounded : Icons.grid_view_rounded,
                  size: 18,
                  color: mosaic ? c.accentInk : c.muted,
                ),
              ),
            ),
          ),
        );
      },
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
                hintText: tr(
                    'Поиск по имени файла или папке…',
                    'Search by file or folder name…',
                    'Buscar por nombre de archivo o carpeta…'),
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
        Text(
            favOnly
                ? tr('В избранном пусто', 'No favorites yet', 'Sin favoritos')
                : tr('Ничего не найдено', 'Nothing found', 'Nada encontrado'),
            style: TextStyle(
                fontSize: 16, fontWeight: FontWeight.w700, color: c.text)),
        const SizedBox(height: 4),
        Text(
            favOnly
                ? tr(
                    'Отмечай фото сердечком — они появятся здесь.',
                    'Tap the heart on photos — they’ll show up here.',
                    'Marca fotos con el corazón — aparecerán aquí.')
                : tr('Попробуй изменить запрос.', 'Try changing your search.',
                    'Prueba a cambiar la búsqueda.'),
            style: TextStyle(color: c.muted, fontSize: 13)),
      ]),
    );
  }
}

// ───────────── переключатель «Сетка / Дерево» в разделе папок ─────────────
class _FolderViewToggle extends StatelessWidget {
  final FolderView view;
  final ValueChanged<FolderView> onChanged;
  const _FolderViewToggle({required this.view, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final c = AuroraTheme.of(context).colors;
    Widget btn(String label, IconData icon, bool on, VoidCallback onTap) {
      return GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: SettingsService.instance.reduceMotion
              ? Duration.zero
              : const Duration(milliseconds: 150),
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
            btn(tr('Сетка', 'Grid', 'Cuadrícula'), Icons.grid_view_rounded,
                view == FolderView.grid, () => onChanged(FolderView.grid)),
            btn(tr('Список', 'List', 'Lista'), Icons.view_list_rounded,
                view == FolderView.list, () => onChanged(FolderView.list)),
            btn(tr('Древо', 'Tree', 'Árbol'), Icons.account_tree_outlined,
                view == FolderView.tree, () => onChanged(FolderView.tree)),
          ]),
        ),
      ]),
    );
  }
}

// ───────────── панель активного фильтра по тегам ─────────────
class _TagFilterBar extends StatelessWidget {
  final Set<String> tags;
  final ValueChanged<String> onRemove;
  final VoidCallback onClear;
  final VoidCallback onEdit;
  const _TagFilterBar({
    required this.tags,
    required this.onRemove,
    required this.onClear,
    required this.onEdit,
  });

  @override
  Widget build(BuildContext context) {
    final c = AuroraTheme.of(context).colors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
      child: Row(children: [
        Icon(Icons.filter_alt_outlined, size: 16, color: c.accent),
        const SizedBox(width: 8),
        Expanded(
          child: Wrap(spacing: 6, runSpacing: 6, children: [
            for (final t in tags)
              GestureDetector(
                onTap: () => onRemove(t),
                child: Container(
                  padding: const EdgeInsets.fromLTRB(10, 5, 6, 5),
                  decoration: BoxDecoration(
                    color: c.accent,
                    borderRadius: BorderRadius.circular(9),
                  ),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Text(t,
                        style: const TextStyle(
                            color: Colors.white, fontSize: 12.5)),
                    const SizedBox(width: 4),
                    const Icon(Icons.close, size: 13, color: Colors.white),
                  ]),
                ),
              ),
          ]),
        ),
        const SizedBox(width: 8),
        GestureDetector(
          onTap: onEdit,
          child: Icon(Icons.edit_outlined, size: 18, color: c.muted),
        ),
        const SizedBox(width: 12),
        GestureDetector(
          onTap: onClear,
          child: Text(tr('Сброс', 'Reset', 'Restablecer'),
              style: TextStyle(color: c.muted, fontSize: 12.5)),
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
      message: tr('Доступна сборка №$buildNo', 'Build #$buildNo is available',
          'Compilación n.º $buildNo disponible'),
      child: Material(
        color: c.accent,
        borderRadius: BorderRadius.circular(11),
        child: InkWell(
          borderRadius: BorderRadius.circular(11),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.system_update_alt_rounded,
                    size: 16, color: Colors.white),
                const SizedBox(width: 6),
                Text(tr('Обновить', 'Update', 'Actualizar'),
                    style: const TextStyle(
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
      title: Text(
          _error == null
              ? tr('Обновление…', 'Updating…', 'Actualizando…')
              : tr('Не удалось обновить', 'Could not update',
                  'No se pudo actualizar'),
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
                      ? tr('Скачивание…', 'Downloading…', 'Descargando…')
                      : '${tr('Скачивание', 'Downloading', 'Descargando')} ${((_progress ?? 0) * 100).round()}%',
                  style: TextStyle(color: c.muted, fontSize: 13),
                ),
                const SizedBox(height: 4),
                Text(
                    tr(
                        'Приложение перезапустится автоматически.',
                        'The app will restart automatically.',
                        'La app se reiniciará automáticamente.'),
                    style: TextStyle(color: c.muted, fontSize: 12)),
              ],
            ),
      actions: _error == null
          ? null
          : [
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: c.accent),
                onPressed: () => Navigator.pop(context),
                child: Text(tr('Закрыть', 'Close', 'Cerrar')),
              ),
            ],
    );
  }
}

class _Tabs extends StatelessWidget {
  final ViewMode mode;
  final ValueChanged<ViewMode> onMode;
  final List<ViewMode>? only; // ограничить набор (например, без «Альбомы»)
  const _Tabs({required this.mode, required this.onMode, this.only});

  @override
  Widget build(BuildContext context) {
    final c = AuroraTheme.of(context).colors;
    Widget tab(String label, ViewMode m) {
      final on = m == mode;
      return GestureDetector(
        onTap: () => onMode(m),
        child: AnimatedContainer(
          duration: SettingsService.instance.reduceMotion
              ? Duration.zero
              : const Duration(milliseconds: 150),
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
        if (only == null || only!.contains(ViewMode.all))
          tab(tr('Все', 'All', 'Todo'), ViewMode.all),
        if (only == null || only!.contains(ViewMode.dates))
          tab(tr('По датам', 'By date', 'Por fecha'), ViewMode.dates),
        if (only == null || only!.contains(ViewMode.albums))
          tab(tr('Альбомы', 'Albums', 'Álbumes'), ViewMode.albums),
      ]),
    );
  }
}

String sortModeLabel(SortMode m) => switch (m) {
      SortMode.dateDesc => tr('Сначала новые', 'Newest first', 'Más recientes'),
      SortMode.dateAsc => tr('Сначала старые', 'Oldest first', 'Más antiguos'),
      SortMode.nameAsc => tr('По имени', 'By name', 'Por nombre'),
      SortMode.sizeDesc => tr('По размеру', 'By size', 'Por tamaño'),
      SortMode.random => tr('Случайно', 'Random', 'Aleatorio'),
    };

IconData _sortModeIcon(SortMode m) => switch (m) {
      SortMode.dateDesc => Icons.arrow_downward_rounded,
      SortMode.dateAsc => Icons.arrow_upward_rounded,
      SortMode.nameAsc => Icons.sort_by_alpha_rounded,
      SortMode.sizeDesc => Icons.data_usage_rounded,
      SortMode.random => Icons.shuffle_rounded,
    };

class _CountBar extends StatelessWidget {
  final ViewMode mode;
  final int total;
  final int albums;
  final String? folder;
  final bool compact;
  final SortMode sort;
  final ValueChanged<SortMode> onSort;
  const _CountBar({
    required this.mode,
    required this.total,
    required this.albums,
    required this.folder,
    required this.sort,
    required this.onSort,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final c = AuroraTheme.of(context).colors;
    return Padding(
      padding: compact
          ? const EdgeInsets.fromLTRB(12, 5, 12, 4)
          : const EdgeInsets.fromLTRB(18, 8, 18, 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: Text.rich(
              TextSpan(children: [
                TextSpan(
                    text: '$total ',
                    style: TextStyle(
                        color: c.text,
                        fontWeight: FontWeight.w600,
                        fontSize: 12)),
                TextSpan(
                    text: folder == null
                        ? tr('изображений', 'images', 'imágenes')
                        : '${tr('изображений', 'images', 'imágenes')} · $folder',
                    style: TextStyle(color: c.muted, fontSize: 12)),
              ]),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
          // сортировка — доступна в режимах с лентой (Все/По датам)
          if (mode != ViewMode.albums)
            PopupMenuButton<SortMode>(
              tooltip: tr('Сортировка', 'Sort', 'Orden'),
              initialValue: sort,
              onSelected: onSort,
              color: c.surface,
              itemBuilder: (ctx) => [
                for (final m in SortMode.values)
                  PopupMenuItem(
                    value: m,
                    child: Row(children: [
                      Icon(_sortModeIcon(m),
                          size: 17, color: m == sort ? c.accent : c.muted),
                      const SizedBox(width: 10),
                      Text(sortModeLabel(m),
                          style: TextStyle(
                              color: c.text,
                              fontWeight: m == sort
                                  ? FontWeight.w700
                                  : FontWeight.w400)),
                    ]),
                  ),
              ],
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(_sortModeIcon(sort), size: 15, color: c.muted),
                const SizedBox(width: 5),
                Text(sortModeLabel(sort),
                    style: TextStyle(color: c.muted, fontSize: 12)),
                Icon(Icons.arrow_drop_down_rounded, size: 18, color: c.muted),
              ]),
            ),
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
  // null — долгий тап обрабатывает сетка (для «паровозика»); иначе тут (даты)
  final VoidCallback? onLongPress;
  // false — выделение здесь отключено (например, внутри отдельной папки)
  final bool selectable;
  // false — ПКМ обрабатывает сетка (Listener для «паровозика»), не плитка
  final bool secondaryTapSelect;
  const PhotoTile({
    super.key,
    required this.photo,
    required this.cell,
    required this.onTap,
    this.onLongPress,
    this.selectable = true,
    this.secondaryTapSelect = true,
  });

  @override
  Widget build(BuildContext context) {
    final c = AuroraTheme.of(context).colors;
    final s = SettingsService.instance;
    final dpr = MediaQuery.of(context).devicePixelRatio;
    final cacheWidth = (cell * dpr).round().clamp(64, 512);
    return AnimatedBuilder(
      animation: Selection.instance,
      builder: (ctx, _) {
        final sel = Selection.instance;
        final selecting = selectable && sel.active;
        final selected = selecting && sel.contains(photo.path);
        return GestureDetector(
          onTap: () {
            if (selecting) {
              sel.toggle(photo.path);
            } else {
              onTap();
            }
          },
          onLongPress: selectable ? onLongPress : null,
          // ПКМ на ПК — войти в выделение / переключить (в _AllGrid отключено,
          // там правую кнопку ведёт Listener для покраски диапазона)
          onSecondaryTapDown: (selectable && secondaryTapSelect)
              ? (_) => sel.toggle(photo.path)
              : null,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(s.gridRadius),
            child: Stack(
              fit: StackFit.expand,
              children: [
                Container(color: c.surface2),
                if (photo.isVideo)
                  _VideoTileFace(colors: c)
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
                    errorBuilder: (ctx, e, st) => Icon(
                        s.avoidCloudThumbnailDownloads
                            ? Icons.cloud_off_outlined
                            : Icons.broken_image_outlined,
                        color: c.muted,
                        size: 18),
                  ),
                if (photo.isVideo)
                  const Positioned(
                    right: 5,
                    bottom: 5,
                    child: _MediaBadge(label: 'VIDEO'),
                  ),
                if (photo.isGif && s.showGifBadge)
                  const Positioned(
                    right: 5,
                    bottom: 5,
                    child: _MediaBadge(label: 'GIF'),
                  ),
                if (s.showFavBadge && !selecting)
                  ValueListenableBuilder<Set<String>>(
                    valueListenable: Favorites.instance.notifier,
                    builder: (ctx, favs, _) {
                      if (!favs.contains(photo.path)) {
                        return const SizedBox.shrink();
                      }
                      return const Positioned(
                        left: 5,
                        top: 5,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                              color: Colors.black54, shape: BoxShape.circle),
                          child: Padding(
                            padding: EdgeInsets.all(3),
                            child: Icon(Icons.favorite,
                                color: Colors.white, size: 12),
                          ),
                        ),
                      );
                    },
                  ),
                // подсветка выбранного + чекбокс в режиме выделения
                if (selecting) ...[
                  if (selected)
                    Positioned.fill(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: c.accent.withValues(alpha: 0.30),
                          border: Border.all(color: c.accent, width: 3),
                          borderRadius: BorderRadius.circular(s.gridRadius),
                        ),
                      ),
                    ),
                  Positioned(
                    left: 5,
                    top: 5,
                    child: Container(
                      decoration: BoxDecoration(
                        color: selected ? c.accent : Colors.black38,
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 1.5),
                      ),
                      padding: const EdgeInsets.all(2),
                      child: Icon(
                        selected ? Icons.check : Icons.circle_outlined,
                        color: Colors.white,
                        size: 14,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

class _VideoTileFace extends StatelessWidget {
  final AuroraColors colors;
  const _VideoTileFace({required this.colors});

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            colors.surface2,
            colors.accentSoft.withValues(alpha: 0.65),
          ],
        ),
      ),
      child: Center(
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
      ),
    );
  }
}

class _MediaBadge extends StatelessWidget {
  final String label;
  const _MediaBadge({required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(label,
          style: const TextStyle(color: Colors.white, fontSize: 10)),
    );
  }
}

// ───────────────────────── сетки ─────────────────────────
class _AllGrid extends StatefulWidget {
  final List<PhotoItem> photos;
  final double cell;
  final bool selectable; // включён ли «паровозик»/выделение
  const _AllGrid(
      {required this.photos, required this.cell, this.selectable = true});

  @override
  State<_AllGrid> createState() => _AllGridState();
}

class _AllGridState extends State<_AllGrid> {
  final _scroll = ScrollController();
  static const _pad = EdgeInsets.fromLTRB(16, 6, 16, 18);

  // состояние «паровозика»
  Timer? _autoScroll;
  Offset _lastLocal = Offset.zero;
  double _viewW = 0;
  double _viewH = 0;
  bool _painting = false; // идёт покраска правой кнопкой мыши (ПК)

  // состояние быстрого бегунка-скролла
  bool _scrubbing = false;
  String _scrubLabel = '';

  @override
  void dispose() {
    _autoScroll?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  /// Геометрия сетки → сколько колонок и каков размер плитки (повторяет
  /// формулу SliverGridDelegateWithMaxCrossAxisExtent).
  ({int cols, double extent, double gap}) _geometry() {
    final gap = SettingsService.instance.tileSpacing;
    final crossExtent = _viewW - _pad.horizontal;
    var cols = (crossExtent / (widget.cell + gap)).ceil();
    if (cols < 1) cols = 1;
    final usable = crossExtent - gap * (cols - 1);
    final extent = usable / cols;
    return (cols: cols, extent: extent, gap: gap);
  }

  /// Индекс плитки под точкой [local] (с учётом прокрутки). null — мимо.
  int? _indexAt(Offset local) {
    if (_viewW <= 0) return null;
    final g = _geometry();
    final dx = local.dx - _pad.left;
    final dy = local.dy + _scroll.offset - _pad.top;
    if (dx < 0 || dy < 0) return null;
    var col = (dx / (g.extent + g.gap)).floor();
    if (col >= g.cols) col = g.cols - 1;
    if (col < 0) col = 0;
    final row = (dy / (g.extent + g.gap)).floor();
    final idx = row * g.cols + col;
    if (idx < 0 || idx >= widget.photos.length) return null;
    return idx;
  }

  void _onLongPressStart(LongPressStartDetails d) {
    final idx = _indexAt(d.localPosition);
    if (idx == null) return;
    _lastLocal = d.localPosition;
    Selection.instance.beginDrag(widget.photos, idx);
    _startAutoScroll();
  }

  void _onLongPressMove(LongPressMoveUpdateDetails d) {
    _lastLocal = d.localPosition;
    final idx = _indexAt(d.localPosition);
    if (idx != null) Selection.instance.updateDrag(widget.photos, idx);
  }

  void _onLongPressEnd(_) {
    _autoScroll?.cancel();
    _autoScroll = null;
    Selection.instance.endDrag();
  }

  // ── ПК: покраска правой кнопкой мыши (не конфликтует с прокруткой ЛКМ) ──
  void _onPointerDown(PointerDownEvent e) {
    if (e.kind != PointerDeviceKind.mouse) return;
    if ((e.buttons & kSecondaryMouseButton) == 0) return;
    final idx = _indexAt(e.localPosition);
    if (idx == null) return;
    _painting = true;
    _lastLocal = e.localPosition;
    Selection.instance.beginDrag(widget.photos, idx);
    _startAutoScroll();
  }

  void _onPointerMove(PointerMoveEvent e) {
    if (!_painting) return;
    _lastLocal = e.localPosition;
    final idx = _indexAt(e.localPosition);
    if (idx != null) Selection.instance.updateDrag(widget.photos, idx);
  }

  void _onPointerUp([PointerEvent? _]) {
    if (!_painting) return;
    _painting = false;
    _autoScroll?.cancel();
    _autoScroll = null;
    Selection.instance.endDrag();
  }

  /// Автопрокрутка, пока палец/курсор у верхнего или нижнего края.
  void _startAutoScroll() {
    _autoScroll?.cancel();
    _autoScroll = Timer.periodic(const Duration(milliseconds: 16), (_) {
      const edge = 70.0;
      double delta = 0;
      if (_lastLocal.dy < edge) {
        delta = -(edge - _lastLocal.dy) / edge * 18;
      } else if (_lastLocal.dy > _viewH - edge) {
        delta = (_lastLocal.dy - (_viewH - edge)) / edge * 18;
      }
      if (delta == 0) return;
      final next =
          (_scroll.offset + delta).clamp(0.0, _scroll.position.maxScrollExtent);
      if (next != _scroll.offset) {
        _scroll.jumpTo(next);
        final idx = _indexAt(_lastLocal);
        if (idx != null) Selection.instance.updateDrag(widget.photos, idx);
      }
    });
  }

  /// Подпись «пузыря» бегунка для данного смещения прокрутки: дата (для
  /// сортировки по дате), первая буква (по имени) или размер (по размеру).
  String _labelAt(double offset) {
    if (widget.photos.isEmpty) return '';
    final g = _geometry();
    final row = ((offset - _pad.top) / (g.extent + g.gap)).floor();
    var idx = row * g.cols;
    if (idx < 0) idx = 0;
    if (idx >= widget.photos.length) idx = widget.photos.length - 1;
    final ph = widget.photos[idx];
    switch (SettingsService.instance.sortMode) {
      case SortMode.nameAsc:
        return ph.fileName.isNotEmpty ? ph.fileName[0].toUpperCase() : '';
      case SortMode.sizeDesc:
        return prettySize(ph.sizeBytes);
      default:
        return dateGroupOf(ph.modified);
    }
  }

  /// Бегунок справа: тянешь — мгновенно прыгаешь по ленте, рядом пузырь с датой.
  /// Появляется только когда листать действительно много.
  Widget _scrubber(double viewH) {
    return AnimatedBuilder(
      animation: _scroll,
      builder: (ctx, _) {
        if (!_scroll.hasClients || !_scroll.position.hasContentDimensions) {
          return const SizedBox.shrink();
        }
        final maxExt = _scroll.position.maxScrollExtent;
        if (maxExt <= 0 || widget.photos.length < 80) {
          return const SizedBox.shrink();
        }
        const margin = 8.0, handleH = 56.0;
        final trackH = viewH - margin * 2 - handleH;
        if (trackH <= 0) return const SizedBox.shrink();
        final frac = (_scroll.offset / maxExt).clamp(0.0, 1.0);
        final c = AuroraTheme.of(ctx).colors;
        return Positioned(
          top: margin + frac * trackH,
          right: 0,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onVerticalDragStart: (_) => setState(() {
              _scrubbing = true;
              _scrubLabel = _labelAt(_scroll.offset);
            }),
            onVerticalDragUpdate: (d) {
              final next =
                  (_scroll.offset + (d.primaryDelta ?? 0) / trackH * maxExt)
                      .clamp(0.0, maxExt);
              _scroll.jumpTo(next);
              setState(() => _scrubLabel = _labelAt(next));
            },
            onVerticalDragEnd: (_) => setState(() => _scrubbing = false),
            onVerticalDragCancel: () => setState(() => _scrubbing = false),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              if (_scrubbing)
                Container(
                  margin: const EdgeInsets.only(right: 6),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                  decoration: BoxDecoration(
                    color: c.accent,
                    borderRadius: BorderRadius.circular(14),
                    boxShadow: const [
                      BoxShadow(
                          color: Colors.black38,
                          blurRadius: 10,
                          offset: Offset(0, 3)),
                    ],
                  ),
                  child: Text(_scrubLabel,
                      style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                          fontSize: 14)),
                ),
              SizedBox(
                width: 34,
                height: handleH,
                child: Center(
                  child: Container(
                    width: _scrubbing ? 8 : 5,
                    height: handleH,
                    decoration: BoxDecoration(
                      color: _scrubbing
                          ? c.accent
                          : c.muted.withValues(alpha: 0.5),
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                ),
              ),
            ]),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = SettingsService.instance;
    if (s.gridLayout == GridLayout.mosaic) {
      return _MosaicGrid(photos: widget.photos, cell: widget.cell);
    }
    final gap = s.tileSpacing;
    return LayoutBuilder(builder: (ctx, cns) {
      _viewW = cns.maxWidth;
      _viewH = cns.maxHeight;
      final grid = GridView.builder(
        controller: _scroll,
        padding: _pad,
        // слабое устройство: меньше плиток рендерим про запас → меньше декодов
        scrollCacheExtent:
            s.lowEndMode ? const ScrollCacheExtent.pixels(120) : null,
        gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: widget.cell,
          mainAxisSpacing: gap,
          crossAxisSpacing: gap,
          childAspectRatio: 1,
        ),
        itemCount: widget.photos.length,
        itemBuilder: (ctx, i) => PhotoTile(
          photo: widget.photos[i],
          cell: widget.cell,
          selectable: widget.selectable,
          secondaryTapSelect: false, // ПКМ ведёт Listener (покраска)
          onTap: () => openViewer(ctx, widget.photos, i),
        ),
      );
      final wrapped = GapBackground(child: grid);
      Widget content;
      if (!widget.selectable) {
        content = wrapped;
      } else {
        // телефон: «паровозик» долгим тапом; ПК: правой кнопкой мыши (Listener)
        content = Listener(
          onPointerDown: _onPointerDown,
          onPointerMove: _onPointerMove,
          onPointerUp: _onPointerUp,
          onPointerCancel: _onPointerUp,
          child: GestureDetector(
            onLongPressStart: _onLongPressStart,
            onLongPressMoveUpdate: _onLongPressMove,
            onLongPressEnd: _onLongPressEnd,
            onLongPressCancel: () => _onLongPressEnd(null),
            child: wrapped,
          ),
        );
      }
      return Stack(children: [
        Positioned.fill(child: content),
        _scrubber(cns.maxHeight),
      ]);
    });
  }
}

/// Мозаичная раскладка: плитки разной формы (широкая / квадрат / высокая)
/// по пропорциям фото. Прямоугольные картинки меньше обрезаются — видно
/// больше. Размеры берутся из [DimsService] (фоновый кэш заголовков).
class _MosaicGrid extends StatefulWidget {
  final List<PhotoItem> photos;
  final double cell;
  const _MosaicGrid({required this.photos, required this.cell});

  @override
  State<_MosaicGrid> createState() => _MosaicGridState();
}

class _MosaicGridState extends State<_MosaicGrid> {
  @override
  void initState() {
    super.initState();
    // запустить фоновое заполнение размеров (если ещё не знаем)
    DimsService.instance.ensureFilled(widget.photos);
  }

  @override
  void didUpdateWidget(_MosaicGrid old) {
    super.didUpdateWidget(old);
    if (old.photos.length != widget.photos.length) {
      DimsService.instance.ensureFilled(widget.photos);
    }
  }

  static const _pad = EdgeInsets.fromLTRB(16, 6, 16, 18);

  // кэш раскладки, чтобы не пересчитывать упаковку каждый кадр
  _QuiltLayout? _layout;
  String _sig = '';

  @override
  Widget build(BuildContext context) {
    final gap = SettingsService.instance.tileSpacing;
    return AnimatedBuilder(
      animation: DimsService.instance,
      builder: (ctx, _) {
        return LayoutBuilder(builder: (ctx2, cns) {
          final crossExtent = cns.maxWidth - _pad.horizontal;
          var cols = (crossExtent / widget.cell).ceil();
          if (cols < 1) cols = 1;
          final cell = (crossExtent - (cols - 1) * gap) / cols; // ширина клетки

          // пересчитываем упаковку только при смене входных данных
          final sig = '$cols|${widget.photos.length}|$gap|'
              '${cell.toStringAsFixed(1)}|${DimsService.instance.rev}';
          if (sig != _sig || _layout == null) {
            _layout = _packQuilt(widget.photos, cols, cell, gap);
            _sig = sig;
          }

          return GapBackground(
            child: GridView.custom(
              padding: _pad,
              gridDelegate: _QuiltDelegate(_layout!),
              childrenDelegate: SliverChildBuilderDelegate(
                (ctx3, i) => PhotoTile(
                  photo: widget.photos[i],
                  cell: widget.cell,
                  onLongPress: () =>
                      Selection.instance.enter(widget.photos[i].path),
                  onTap: () => openViewer(ctx3, widget.photos, i),
                ),
                childCount: widget.photos.length,
              ),
            ),
          );
        });
      },
    );
  }
}

/// Жадная укладка мозаики без дыр. Каждая плитка кладётся в самую нижнюю-левую
/// свободную клетку, поэтому пустых клеток не остаётся. Форма по пропорции
/// фото: портрет → 1×2 (два квадрата по высоте), пейзаж → 2×1 (два по ширине,
/// если рядом свободно), иначе квадрат. Минимум(высот колонок) монотонно
/// растёт ⇒ mainAxisOffset не убывает по индексу ⇒ поиск видимых плиток ленив.
_QuiltLayout _packQuilt(
    List<PhotoItem> photos, int cols, double cell, double gap) {
  final n = photos.length;
  final mainOff = Float64List(n);
  final crossOff = Float64List(n);
  final mainExt = Float64List(n);
  final crossExt = Float64List(n);
  final colRow = List<int>.filled(cols, 0); // до какого ряда занята колонка
  final step = cell + gap;
  double span(int k) => k * cell + (k - 1) * gap; // экстент в k клеток

  var maxScroll = 0.0;
  for (var i = 0; i < n; i++) {
    // самая нижняя клетка = минимальный ряд, самый левый столбец
    var minRow = colRow[0];
    for (var c = 1; c < cols; c++) {
      if (colRow[c] < minRow) minRow = colRow[c];
    }
    var c0 = 0;
    while (colRow[c0] != minRow) {
      c0++;
    }

    final ratio = DimsService.instance.ratioOf(photos[i].path);
    var wSpan = 1, hSpan = 1;
    if (ratio != null && ratio <= 0.8) {
      hSpan = 2; // портрет — два квадрата по высоте
    } else if (ratio != null &&
        ratio >= 1.3 &&
        c0 + 1 < cols &&
        colRow[c0 + 1] == minRow) {
      wSpan = 2; // пейзаж — два квадрата по ширине (если сосед свободен)
    }

    crossOff[i] = c0 * step;
    mainOff[i] = minRow * step;
    crossExt[i] = span(wSpan);
    mainExt[i] = span(hSpan);
    for (var c = c0; c < c0 + wSpan; c++) {
      colRow[c] = minRow + hSpan;
    }
    final bottom = mainOff[i] + mainExt[i];
    if (bottom > maxScroll) maxScroll = bottom;
  }

  return _QuiltLayout(
    mainOff: mainOff,
    crossOff: crossOff,
    mainExt: mainExt,
    crossExt: crossExt,
    maxScroll: maxScroll,
    maxTileExt: 2 * cell + gap, // самая высокая плитка (для ленивого поиска)
  );
}

/// Делегат, отдающий заранее посчитанную раскладку квилта.
class _QuiltDelegate extends SliverGridDelegate {
  final _QuiltLayout layout;
  const _QuiltDelegate(this.layout);

  @override
  SliverGridLayout getLayout(SliverConstraints constraints) => layout;

  @override
  bool shouldRelayout(_QuiltDelegate old) => old.layout != layout;
}

/// Произвольная 2D-раскладка для [SliverGrid]: каждая плитка на своей позиции
/// с произвольным размером. mainOff не убывает по индексу ⇒ бинарный поиск.
class _QuiltLayout extends SliverGridLayout {
  final Float64List mainOff;
  final Float64List crossOff;
  final Float64List mainExt;
  final Float64List crossExt;
  final double maxScroll;
  final double maxTileExt;
  const _QuiltLayout({
    required this.mainOff,
    required this.crossOff,
    required this.mainExt,
    required this.crossExt,
    required this.maxScroll,
    required this.maxTileExt,
  });

  @override
  double computeMaxScrollOffset(int childCount) => maxScroll;

  @override
  SliverGridGeometry getGeometryForChildIndex(int index) => SliverGridGeometry(
        scrollOffset: mainOff[index],
        crossAxisOffset: crossOff[index],
        mainAxisExtent: mainExt[index],
        crossAxisExtent: crossExt[index],
      );

  // первый индекс, чья плитка может попадать в видимую область сверху
  @override
  int getMinChildIndexForScrollOffset(double scrollOffset) =>
      _lowerBound(scrollOffset - maxTileExt);

  // последний индекс, начинающийся до конца видимой области
  @override
  int getMaxChildIndexForScrollOffset(double scrollOffset) {
    final n = mainOff.length;
    if (n == 0) return 0;
    final i = _upperBound(scrollOffset);
    return (i - 1).clamp(0, n - 1);
  }

  // первый индекс с mainOff >= target (mainOff неубывающий)
  int _lowerBound(double target) {
    var lo = 0, hi = mainOff.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (mainOff[mid] < target) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo.clamp(0, mainOff.isEmpty ? 0 : mainOff.length - 1);
  }

  // первый индекс с mainOff > target
  int _upperBound(double target) {
    var lo = 0, hi = mainOff.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (mainOff[mid] <= target) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
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
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: c.text)),
                const SizedBox(width: 10),
                Text('${items.length} ${tr('фото', 'photos', 'fotos')}',
                    style: TextStyle(fontSize: 12, color: c.muted)),
              ]),
        ),
      ));
      final gap = SettingsService.instance.tileSpacing;
      slivers.add(SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        sliver: SliverGrid(
          gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: cell,
            mainAxisSpacing: gap,
            crossAxisSpacing: gap,
            childAspectRatio: 1,
          ),
          delegate: SliverChildBuilderDelegate(
            (ctx, i) => PhotoTile(
              photo: items[i],
              cell: cell,
              onLongPress: () => Selection.instance.enter(items[i].path),
              onTap: () => openViewer(ctx, photos, photos.indexOf(items[i])),
            ),
            childCount: items.length,
          ),
        ),
      ));
    });
    slivers.add(const SliverToBoxAdapter(child: SizedBox(height: 18)));
    return GapBackground(child: CustomScrollView(slivers: slivers));
  }
}

// ───────────────────────── альбомы (папки) ─────────────────────────
class _AlbumsView extends StatelessWidget {
  final List<AlbumItem> albums;
  final List<PhotoItem> photos;
  final double cell;
  final ValueChanged<AlbumItem> onHideToggle;
  const _AlbumsView({
    required this.albums,
    required this.photos,
    required this.cell,
    required this.onHideToggle,
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
          onHideToggle: () => onHideToggle(a),
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
  final VoidCallback onHideToggle;
  const _AlbumCard(
      {required this.album, required this.onTap, required this.onHideToggle});

  @override
  Widget build(BuildContext context) {
    final c = AuroraTheme.of(context).colors;
    final dpr = MediaQuery.of(context).devicePixelRatio;
    final cover = album.cover;
    final hidden = SettingsService.instance.isHidden(album.folderPath);
    return GestureDetector(
      onTap: onTap,
      onLongPress: onHideToggle,
      onSecondaryTapDown: (_) => onHideToggle(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: Stack(fit: StackFit.expand, children: [
                Container(color: c.surface2),
                if (cover != null && cover.isVideo)
                  _VideoTileFace(colors: c)
                else if (cover != null)
                  Image(
                    image: cover.thumb((190 * dpr).round().clamp(64, 512)),
                    fit: BoxFit.cover,
                    filterQuality: FilterQuality.low,
                    errorBuilder: (ctx, e, s) => Icon(
                        Icons.broken_image_outlined,
                        color: c.muted,
                        size: 22),
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
                if (hidden)
                  const Positioned(
                    left: 8,
                    top: 8,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                          color: Colors.black54, shape: BoxShape.circle),
                      child: Padding(
                        padding: EdgeInsets.all(4),
                        child: Icon(Icons.visibility_off_rounded,
                            color: Colors.white, size: 14),
                      ),
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
          Text('${album.count} ${tr('изображений', 'images', 'imágenes')}',
              style: TextStyle(fontSize: 12, color: c.muted)),
        ],
      ),
    );
  }
}

// ───────────── альбомы списком (миниатюра-фон + имя/путь поверх) ─────────────
class _AlbumsList extends StatelessWidget {
  final List<AlbumItem> albums;
  final List<PhotoItem> photos;
  final ValueChanged<AlbumItem> onOpen;
  final ValueChanged<AlbumItem> onHideToggle;
  const _AlbumsList({
    required this.albums,
    required this.photos,
    required this.onOpen,
    required this.onHideToggle,
  });

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 18),
      itemCount: albums.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (ctx, i) => _AlbumRow(
        album: albums[i],
        onTap: () => onOpen(albums[i]),
        onHideToggle: () => onHideToggle(albums[i]),
      ),
    );
  }
}

class _AlbumRow extends StatelessWidget {
  final AlbumItem album;
  final VoidCallback onTap;
  final VoidCallback onHideToggle;
  const _AlbumRow(
      {required this.album, required this.onTap, required this.onHideToggle});

  @override
  Widget build(BuildContext context) {
    final c = AuroraTheme.of(context).colors;
    final dpr = MediaQuery.of(context).devicePixelRatio;
    final cover = album.cover;
    final hidden = SettingsService.instance.isHidden(album.folderPath);
    return GestureDetector(
      onTap: onTap,
      onLongPress: onHideToggle,
      onSecondaryTapDown: (_) => onHideToggle(),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: SizedBox(
          height: 76,
          child: Stack(fit: StackFit.expand, children: [
            Container(color: c.surface2),
            if (cover != null && cover.isVideo)
              _VideoTileFace(colors: c)
            else if (cover != null)
              Image(
                image: cover.thumb((180 * dpr).round().clamp(64, 512)),
                fit: BoxFit.cover,
                filterQuality: FilterQuality.low,
                errorBuilder: (ctx, e, s) => const SizedBox.shrink(),
              ),
            // затемнение, чтобы текст читался поверх миниатюры
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.centerLeft,
                  end: Alignment.centerRight,
                  colors: [Colors.black87, Colors.black38],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Row(children: [
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        if (hidden) ...[
                          const Icon(Icons.visibility_off_rounded,
                              color: Colors.white70, size: 14),
                          const SizedBox(width: 5),
                        ],
                        Flexible(
                          child: Text(album.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 15,
                                  fontWeight: FontWeight.w700)),
                        ),
                      ]),
                      const SizedBox(height: 2),
                      Text(album.folderPath,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: Colors.white70, fontSize: 11.5)),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                  decoration: BoxDecoration(
                    color: Colors.black45,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text('${album.count}',
                      style:
                          const TextStyle(color: Colors.white, fontSize: 12)),
                ),
                Icon(Icons.chevron_right_rounded,
                    color: Colors.white.withValues(alpha: 0.8)),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}

// ───────────────────────── экран содержимого папки ─────────────────────────
class _FolderPage extends StatefulWidget {
  final AlbumItem album;
  final List<PhotoItem> photos;
  final double cell;
  const _FolderPage({
    required this.album,
    required this.photos,
    required this.cell,
  });

  @override
  State<_FolderPage> createState() => _FolderPageState();
}

class _FolderPageState extends State<_FolderPage> {
  String _query = '';
  Set<String> _tagMatch = const {};
  ViewMode _mode = ViewMode.all; // внутри папки: Все / По датам

  /// Фото папки с учётом поиска (имя файла / папка / теги).
  List<PhotoItem> get _visible {
    if (_query.trim().isEmpty) return widget.photos;
    final q = _query.trim().toLowerCase();
    return widget.photos
        .where((p) =>
            p.fileName.toLowerCase().contains(q) ||
            p.folderName.toLowerCase().contains(q) ||
            _tagMatch.contains(p.path))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final c = AuroraTheme.of(context).colors;
    final cell = SettingsService.instance.cellSize;
    final visible = _visible;
    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // заголовок
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 16, 4),
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
                      Text(widget.album.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w800,
                              color: c.text)),
                      Text(
                          '${visible.length} ${tr('из', 'of', 'de')} ${widget.album.count}',
                          style: TextStyle(fontSize: 12, color: c.muted)),
                    ],
                  ),
                ),
              ]),
            ),
            // панель: поиск + режимы + плотность + раскладка (как на главной)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Row(children: [
                Expanded(
                  child: _SearchField(
                    initial: _query,
                    onSearch: (q) => setState(() {
                      _query = q;
                      _tagMatch = q.trim().isEmpty
                          ? const {}
                          : TagService.instance.pathsMatchingTag(q);
                    }),
                  ),
                ),
                const SizedBox(width: 8),
                _Tabs(
                  mode: _mode,
                  onMode: (m) => setState(() => _mode = m),
                  only: const [ViewMode.all, ViewMode.dates],
                ),
                const SizedBox(width: 8),
                const _LayoutToggle(),
                const SizedBox(width: 2),
                Icon(Icons.grid_view, size: 16, color: c.muted),
                SizedBox(
                  width: 100,
                  child: AnimatedBuilder(
                    animation: SettingsService.instance,
                    builder: (_, __) => Slider(
                      value: SettingsService.instance.cellSize,
                      min: 70,
                      max: 220,
                      activeColor: c.accent,
                      onChanged: SettingsService.instance.setCellSize,
                    ),
                  ),
                ),
              ]),
            ),
            Expanded(
              child: visible.isEmpty
                  ? const _NoResults(favOnly: false)
                  : (_mode == ViewMode.dates
                      ? _DatesView(photos: visible, cell: cell)
                      : _AllGrid(
                          photos: visible, cell: cell, selectable: false)),
            ),
          ],
        ),
      ),
    );
  }
}
