import 'dart:async';
import 'dart:io';
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
  List<AlbumItem> _albums = []; // альбомы из _shown
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
  FolderView _folderView = FolderView.grid; // вид раздела «Альбомы»
  FolderNode? _treeCache; // построенное древо папок (кэш)
  int _tagsRev = 0; // счётчик для пересоздания панели тегов после импорта
  bool _mediaGranted = false; // на Android: есть доступ к фото устройства
  bool _allFiles = false; // на Android: «доступ ко всем файлам» (секретные папки)
  bool get _useDeviceMedia => Platform.isAndroid || Platform.isIOS;

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
    _albums = LibraryService.albums(_shown);
    _treeCache = null;
    // по сети раздаём только показываемое (секретные папки не уходят)
    LanService.instance.setLibrary(_shown);
  }

  /// Фото с учётом поиска и фильтра «только избранное».
  List<PhotoItem> get _visiblePhotos {
    Iterable<PhotoItem> r = _shown;
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

  FolderNode _folderTreeNode() =>
      _treeCache ??= buildForest(_shown, _folders);

  Widget _albumsGrid() {
    final q = _query.trim().toLowerCase();
    final albums = q.isEmpty
        ? _albums
        : _albums.where((a) => a.name.toLowerCase().contains(q)).toList();
    if (albums.isEmpty) return const _NoResults(favOnly: false);
    return _AlbumsView(
      albums: albums,
      photos: _shown,
      cell: SettingsService.instance.cellSize,
      onHideToggle: _toggleHideFolder,
    );
  }

  Widget _albumsList() {
    final q = _query.trim().toLowerCase();
    final albums = q.isEmpty
        ? _albums
        : _albums.where((a) => a.name.toLowerCase().contains(q)).toList();
    if (albums.isEmpty) return const _NoResults(favOnly: false);
    return _AlbumsList(
      albums: albums,
      photos: _shown,
      onOpen: (a) {
        final inFolder =
            _shown.where((p) => p.folderPath == a.folderPath).toList();
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
        messenger.showSnackBar(const SnackBar(
            content: Text('Для секретных папок нужен «доступ ко всем файлам» '
                '(Настройки → Приватность).')));
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
          ? 'Папка скрыта. Показать — в Настройках → «Показывать скрытые».'
          : 'Папка снова видна.'),
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
      builder: (_) => _FolderPage(album: album, photos: photos, cell: SettingsService.instance.cellSize),
    ));
  }

  void _setFilterTags(Set<String> tags) {
    setState(() {
      _filterTags = tags;
      _filterPaths = tags.isEmpty
          ? const {}
          : TagService.instance.pathsWithAllTags(tags);
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
          title: Text('Обновить GOAT?', style: TextStyle(color: c.text)),
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
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Доступ к фото не выдан. Открыть настройки?'),
        action: SnackBarAction(
            label: 'Настройки', onPressed: PhotoManager.openSetting),
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
      dialogTitle: 'Выбери папку с фотографиями',
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
        title: Text('Очистить сканирование?', style: TextStyle(color: c.text)),
        content: Text(
            'Уберём все $n папок из библиотеки. Сами файлы на диске не трогаем — '
            'только список просканированных папок. Потом можно добавить заново.',
            style: TextStyle(color: c.muted)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(d, false),
            child: Text('Отмена', style: TextStyle(color: c.muted)),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: c.accent),
            onPressed: () => Navigator.pop(d, true),
            child: const Text('Очистить'),
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
    ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Список папок очищен')));
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
              Text('Корзина — в галерее устройства',
                  style: TextStyle(
                      color: c.text, fontSize: 16, fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              Text(
                  'На Android удалённые фото попадают в системную корзину — '
                  '«Недавно удалённые» в приложении Галерея/Фото устройства. '
                  'Там их можно восстановить в течение ~30 дней. Открыть её '
                  'из стороннего приложения система не позволяет.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: c.muted, fontSize: 13)),
              const SizedBox(height: 18),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: c.accent,
                  minimumSize: const Size.fromHeight(46),
                ),
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Понятно'),
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
                Text('Доступ к фото',
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
                      ? 'GOAT показывает все фото устройства автоматически.'
                      : 'Дай доступ к фото — GOAT покажет все изображения.',
                  style: TextStyle(color: c.muted, fontSize: 13)),
            ),
            ListTile(
              leading: Icon(Icons.photo_size_select_actual_outlined,
                  color: c.text),
              title: Text(_mediaGranted ? 'Выбрать, какие фото видны' : 'Дать доступ',
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
              title: Text('Открыть настройки приложения',
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
                Text(tr('Папки библиотеки', 'Library folders'),
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
                      '${tr('Очистить сканирование', 'Clear scan')} (${_folders.length})'),
                ),
              ),
            if (_folders.isEmpty)
              Padding(
                padding: const EdgeInsets.all(20),
                child: Text('Пока не добавлено ни одной папки.',
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
                  tooltip: 'Убрать',
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
                label: Text(tr('Добавить папку', 'Add folder')),
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
                  label: Text(tr('Найти все картинки на ПК', 'Find all images on PC')),
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
    final folders = LibraryService.topFolders(
        {for (final ph in photos) ph.folderPath});
    await LibraryService.setFolders(folders);
    if (!mounted) return;
    try {
      TagService.instance.relink({for (final ph in photos) ph.path});
    } catch (_) {}
    setState(() {
      _folders = folders;
      _photos = photos;
      _applyHidden();
      _loading = false;
    });
    messenger.showSnackBar(SnackBar(
        content: Text('Найдено картинок: ${photos.length} '
            'в ${folders.length} папках')));
  }

  @override
  Widget build(BuildContext context) {
    final c = AuroraTheme.of(context).colors;
    return _SelPopScope(
      child: Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        child: Row(
          children: [
            _Rail(
              mode: _mode,
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
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _TopBar(
                    mode: _mode,
                    cell: SettingsService.instance.cellSize,
                    query: _query,
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
                  ),
                  _CountBar(
                    mode: _mode,
                    total: _visiblePhotos.length,
                    albums: _albums.length,
                    folder: _folders.isNotEmpty
                        ? (_folders.length == 1
                            ? _folders.first
                            : '${_folders.length} ${tr('папок', 'folders')}')
                        : (_useDeviceMedia && _mediaGranted
                            ? tr('все фото устройства', 'all device photos')
                            : null),
                  ),
                  if (_filterTags.isNotEmpty)
                    _TagFilterBar(
                      tags: _filterTags,
                      onRemove: (t) =>
                          _setFilterTags({..._filterTags}..remove(t)),
                      onClear: () => _setFilterTags({}),
                      onEdit: () => setState(() => _tagsPanelOpen = true),
                    ),
                  Expanded(
                    child: Stack(children: [
                      ValueListenableBuilder<Set<String>>(
                        valueListenable: Favorites.instance.notifier,
                        builder: (_, __, ___) => _body(c),
                      ),
                      // панель массовых действий поверх сетки
                      AnimatedBuilder(
                        animation: Selection.instance,
                        builder: (_, __) => Selection.instance.active
                            ? Align(
                                alignment: Alignment.topCenter,
                                child: _SelectionBar(
                                  count: Selection.instance.count,
                                  onClose: () => Selection.instance.clear(),
                                  onSelectAll: () => Selection.instance
                                      .selectAll(_visiblePhotos),
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
                ],
              ),
            ),
          ],
        ),
      ),
    ),
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
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Теги добавлены к $n фото')));
    }
    Selection.instance.clear();
  }

  Future<void> _selShare() async {
    final n = await MediaActions.share(_selectedPhotos());
    if (n == 0 && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Нечего отправить')));
    }
    Selection.instance.clear();
  }

  Future<void> _selCopyMove({required bool move}) async {
    final res = await MediaActions.copyOrMove(context, _selectedPhotos(),
        move: move);
    if (!mounted || res == null) return;
    final verb = move ? 'Перемещено' : 'Скопировано';
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('$verb: ${res.ok}'
            '${res.fail > 0 ? ', не удалось: ${res.fail}' : ''}')));
    Selection.instance.clear();
    if (move && res.ok > 0) await _rescan();
  }

  Future<void> _selDelete() async {
    final n = await MediaActions.delete(context, _selectedPhotos());
    if (n == -1) return; // отмена
    Selection.instance.clear();
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('Удалено: $n')));
    await _rescan();
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
        return _AllGrid(photos: visible, cell: SettingsService.instance.cellSize);
      case ViewMode.dates:
        return _DatesView(photos: visible, cell: SettingsService.instance.cellSize);
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
            ? tr('Фото на устройстве не найдены.', 'No photos found on the device.')
            : tr('Дай доступ к фото — GOAT покажет все изображения устройства.',
                'Grant photo access — GOAT will show all images on the device.'))
        : tr('Выбери папку с фотографиями — GOAT покажет их здесь.',
            'Pick a folder with photos — GOAT will show them here.');
    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.photo_library_outlined, size: 64, color: c.muted),
        const SizedBox(height: 16),
        Text(
            needAccess
                ? tr('Нужен доступ к фото', 'Photo access needed')
                : tr('Здесь пока пусто', 'Nothing here yet'),
            style: TextStyle(
                fontSize: 18, fontWeight: FontWeight.w700, color: c.text)),
        const SizedBox(height: 6),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Text(subtitle,
              textAlign: TextAlign.center,
              style: TextStyle(color: c.muted)),
        ),
        const SizedBox(height: 18),
        if (!(deviceMedia && granted))
          FilledButton.icon(
            onPressed: onPick,
            style: FilledButton.styleFrom(backgroundColor: c.accent),
            icon: Icon(deviceMedia ? Icons.photo_library : Icons.folder_open),
            label: Text(deviceMedia
                ? tr('Дать доступ к фото', 'Grant photo access')
                : tr('Выбрать папку', 'Pick a folder')),
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
          item(Icons.brush_outlined, null,
              onTap: onProjects, active: projectsOnly),
          item(Icons.sell_outlined, null, onTap: onTags, active: tagsOpen),
          item(Icons.content_copy_outlined, null, onTap: onDedup),
          // активная подсветка, пока раздаём по сети
          AnimatedBuilder(
            animation: LanService.instance,
            builder: (_, __) => item(Icons.wifi_tethering_rounded, null,
                onTap: onLan, active: LanService.instance.isRunning),
          ),
          item(Icons.delete_outline_rounded, null, onTap: onTrash),
          const Spacer(),
          item(Icons.settings_outlined, null, onTap: onSettings),
          const SizedBox(height: 10),
        ],
      ),
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
    Widget act(IconData icon, String tip, VoidCallback onTap,
            {Color? color}) =>
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
          tooltip: 'Снять выделение',
          onPressed: onClose,
        ),
        Text('$count',
            style: TextStyle(
                color: c.text, fontSize: 15, fontWeight: FontWeight.w800)),
        const SizedBox(width: 2),
        IconButton(
          icon: Icon(Icons.select_all_rounded, size: 20, color: c.muted),
          tooltip: 'Выбрать все',
          onPressed: onSelectAll,
        ),
        const Spacer(),
        Flexible(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            reverse: true,
            child: Row(children: [
              act(Icons.favorite_border_rounded, 'В избранное', onFavorite),
              act(Icons.sell_outlined, 'Добавить теги', onTags),
              act(Icons.copy_all_rounded, 'Копировать в папку', onCopy),
              act(Icons.drive_file_move_outline, 'Переместить в папку', onMove),
              act(Icons.ios_share_rounded, 'Отправить', onShare),
              act(Icons.delete_outline_rounded, 'Удалить', onDelete,
                  color: c.accent),
            ]),
          ),
        ),
      ]),
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
            tooltip: 'Папки библиотеки',
          ),
          const SizedBox(width: 4),
          _Tabs(mode: mode, onMode: onMode),
          const SizedBox(width: 8),
          const _LayoutToggle(),
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
          if (update != null) ...[
            const SizedBox(width: 6),
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
          message: mosaic ? tr('Мозаика', 'Mosaic') : tr('Ровные квадраты', 'Even squares'),
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
                hintText: tr('Поиск по имени файла или папке…',
                    'Search by file or folder name…'),
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
            btn(tr('Сетка', 'Grid'), Icons.grid_view_rounded,
                view == FolderView.grid, () => onChanged(FolderView.grid)),
            btn(tr('Список', 'List'), Icons.view_list_rounded,
                view == FolderView.list, () => onChanged(FolderView.list)),
            btn(tr('Древо', 'Tree'), Icons.account_tree_outlined,
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
                        style:
                            const TextStyle(color: Colors.white, fontSize: 12.5)),
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
          child: Text('Сброс', style: TextStyle(color: c.muted, fontSize: 12.5)),
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
          tab(tr('Все', 'All'), ViewMode.all),
        if (only == null || only!.contains(ViewMode.dates))
          tab(tr('По датам', 'By date'), ViewMode.dates),
        if (only == null || only!.contains(ViewMode.albums))
          tab(tr('Альбомы', 'Albums'), ViewMode.albums),
      ]),
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
      ViewMode.all => tr('показаны все', 'all shown'),
      ViewMode.dates => tr('сгруппировано по дате', 'grouped by date'),
      ViewMode.albums => '$albums ${tr('папок', 'folders')}',
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
                    text: folder == null
                        ? tr('изображений', 'images')
                        : '${tr('изображений', 'images')} · $folder',
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
                Image(
                  image: photo.thumb(cacheWidth),
                  fit: s.squareThumbs ? BoxFit.cover : BoxFit.contain,
                  gaplessPlayback: true,
                  filterQuality: FilterQuality.low,
                  frameBuilder: (ctx, child, frame, wasSync) {
                    if (wasSync || frame != null) return child;
                    return Container(color: c.surface2);
                  },
                  errorBuilder: (ctx, e, s) =>
                      Icon(Icons.broken_image_outlined, color: c.muted, size: 18),
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

// ───────────────────────── сетки ─────────────────────────
class _AllGrid extends StatefulWidget {
  final List<PhotoItem> photos;
  final double cell;
  final bool selectable; // включён ли «паровозик»/выделение
  const _AllGrid({required this.photos, required this.cell, this.selectable = true});

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
      final next = (_scroll.offset + delta)
          .clamp(0.0, _scroll.position.maxScrollExtent);
      if (next != _scroll.offset) {
        _scroll.jumpTo(next);
        final idx = _indexAt(_lastLocal);
        if (idx != null) Selection.instance.updateDrag(widget.photos, idx);
      }
    });
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
      if (!widget.selectable) return wrapped;
      // телефон: «паровозик» долгим тапом; ПК: правой кнопкой мыши (Listener)
      return Listener(
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
                        fontSize: 15, fontWeight: FontWeight.w700, color: c.text)),
                const SizedBox(width: 10),
                Text('${items.length} фото',
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
          Text('${album.count} изображений',
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
            if (cover != null)
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
                  tooltip: 'Назад',
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
                      Text('${visible.length} из ${widget.album.count}',
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
