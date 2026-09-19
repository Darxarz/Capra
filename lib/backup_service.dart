import 'dart:convert';
import 'favorites.dart';
import 'settings_service.dart';
import 'collections_service.dart';
import 'library_service.dart';
import 'tag_service.dart';

/// Сколько элементов удалось восстановить по каждому разделу резервной копии.
class BackupImportResult {
  final int favorites;
  final int hiddenFolders;
  final bool settingsRestored;
  final int collections;
  final int collectionItems;
  final int libraryFolders;
  final int tags;
  const BackupImportResult({
    this.favorites = 0,
    this.hiddenFolders = 0,
    this.settingsRestored = false,
    this.collections = 0,
    this.collectionItems = 0,
    this.libraryFolders = 0,
    this.tags = 0,
  });

  /// Хоть что-то восстановилось.
  bool get isEmpty =>
      favorites == 0 &&
      hiddenFolders == 0 &&
      !settingsRestored &&
      collections == 0 &&
      libraryFolders == 0 &&
      tags == 0;
}

/// Полная резервная копия пользовательских данных одним JSON-файлом:
/// избранное, настройки внешнего вида + скрытые папки, свои коллекции,
/// список папок библиотеки и теги. В отличие от «Экспорт тегов» (только теги)
/// собирает вообще всё, что иначе теряется при переустановке/сбросе.
class BackupService {
  BackupService._();

  static const int formatVersion = 1;

  /// Собрать всё текущее состояние в один JSON-документ.
  static Future<String> exportAll() async {
    final s = SettingsService.instance;
    final libraryFolders = await LibraryService.folders();

    final collections = <Map<String, dynamic>>[];
    if (CollectionsService.instance.ready) {
      for (final col in CollectionsService.instance.list()) {
        collections.add({
          'name': col.name,
          'created': col.created.toIso8601String(),
          'paths': CollectionsService.instance.pathsOf(col.id),
        });
      }
    }

    // Теги переиспользуют собственный формат TagService — не изобретаем свой.
    dynamic tagsPayload;
    try {
      tagsPayload = jsonDecode(TagService.instance.exportJson());
    } catch (_) {
      tagsPayload = null;
    }

    final data = <String, dynamic>{
      'version': formatVersion,
      'exported': DateTime.now().toIso8601String(),
      'favorites': Favorites.instance.paths.toList(),
      'settings': {
        'themeMode': s.themeMode.name,
        'lightBaseId': s.lightBaseId,
        'darkBaseId': s.darkBaseId,
        'accentId': s.accentId,
        'cellSize': s.cellSize,
        'gridRadius': s.gridRadius,
        'tileSpacing': s.tileSpacing,
        'gridLayout': s.gridLayout.name,
        'squareThumbs': s.squareThumbs,
        'reduceMotion': s.reduceMotion,
        'startSection': s.startSection.name,
        'showFavBadge': s.showFavBadge,
        'showGifBadge': s.showGifBadge,
        'hiddenFolders': s.hiddenFolders.toList(),
        'showHidden': s.showHidden,
        // защита скрытых папок: переносим соль и ХЕШ (не сам PIN), иначе после
        // восстановления секретные папки остались бы без кода
        'pinHash': s.pinHash,
        'pinSalt': s.pinSalt,
        'gapStyle': s.gapStyle.name,
        'gapColorValue': s.gapColorValue,
        'pcScanMinDim': s.pcScanMinDim,
        'appLang': s.appLang.name,
        'uiDensity': s.uiDensity.name,
        'sectionNavPlacement': s.sectionNavPlacement.name,
        'avoidCloudThumbnailDownloads': s.avoidCloudThumbnailDownloads,
        'sortMode': s.sortMode.name,
        'perfMode': s.perfMode.name,
      },
      'collections': collections,
      'libraryFolders': libraryFolders,
      'tags': tagsPayload,
    };
    return jsonEncode(data);
  }

  /// Восстановить состояние из JSON, сделанного [exportAll]. Каждый раздел
  /// обрабатывается независимо и в своём try/catch — повреждённый или
  /// незнакомый формат одного раздела не мешает восстановить остальные,
  /// а совсем чужой/битый файл просто вернёт пустой результат, без падения.
  static Future<BackupImportResult> importAll(String jsonStr) async {
    Map<String, dynamic> data;
    try {
      final decoded = jsonDecode(jsonStr);
      if (decoded is! Map) return const BackupImportResult();
      data = decoded.cast<String, dynamic>();
    } catch (_) {
      return const BackupImportResult();
    }

    var favCount = 0;
    var hiddenCount = 0;
    var settingsRestored = false;
    var collCount = 0;
    var collItemCount = 0;
    var folderCount = 0;
    var tagCount = 0;

    // ── избранное (полная замена) ──
    try {
      final raw = data['favorites'];
      if (raw is List) {
        final paths = raw.whereType<String>().toSet();
        await Favorites.instance.setAll(paths);
        favCount = paths.length;
      }
    } catch (_) {}

    // ── настройки внешнего вида + скрытые папки (полная замена) ──
    try {
      final raw = data['settings'];
      if (raw is Map) {
        final m = raw.cast<String, dynamic>();
        final s = SettingsService.instance;

        T? enumOf<T extends Enum>(List<T> values, String key) {
          final name = m[key];
          if (name is! String) return null;
          for (final v in values) {
            if (v.name == name) return v;
          }
          return null;
        }

        final themeMode = enumOf(ThemeModeChoice.values, 'themeMode');
        if (themeMode != null) s.setThemeMode(themeMode);
        if (m['lightBaseId'] is String) s.setLightBase(m['lightBaseId']);
        if (m['darkBaseId'] is String) s.setDarkBase(m['darkBaseId']);
        if (m['accentId'] is String) s.setAccent(m['accentId']);
        if (m['cellSize'] is num) s.setCellSize((m['cellSize'] as num).toDouble());
        if (m['gridRadius'] is num) {
          s.setGridRadius((m['gridRadius'] as num).toDouble());
        }
        if (m['tileSpacing'] is num) {
          s.setTileSpacing((m['tileSpacing'] as num).toDouble());
        }
        final gridLayout = enumOf(GridLayout.values, 'gridLayout');
        if (gridLayout != null) s.setGridLayout(gridLayout);
        if (m['squareThumbs'] is bool) s.setSquareThumbs(m['squareThumbs']);
        if (m['reduceMotion'] is bool) s.setReduceMotion(m['reduceMotion']);
        final startSection = enumOf(StartSection.values, 'startSection');
        if (startSection != null) s.setStartSection(startSection);
        if (m['showFavBadge'] is bool) s.setShowFavBadge(m['showFavBadge']);
        if (m['showGifBadge'] is bool) s.setShowGifBadge(m['showGifBadge']);
        // сначала восстанавливаем защиту, потом решаем про показ скрытого
        s.restorePin(
            m['pinHash'] is String ? m['pinHash'] as String : null,
            m['pinSalt'] is String ? m['pinSalt'] as String : null);
        // при заданном PIN скрытое всегда остаётся закрытым — копия не должна
        // открывать секретные папки в обход кода
        if (m['showHidden'] is bool) {
          s.setShowHidden(s.hasPin ? false : m['showHidden'] as bool);
        }
        final gapStyle = enumOf(GapStyle.values, 'gapStyle');
        if (gapStyle != null) s.setGapStyle(gapStyle);
        if (m['gapColorValue'] is int) s.setGapColor(m['gapColorValue']);
        if (m['pcScanMinDim'] is int) s.setPcScanMinDim(m['pcScanMinDim']);
        final appLang = enumOf(AppLang.values, 'appLang');
        if (appLang != null) s.setAppLang(appLang);
        final uiDensity = enumOf(UiDensity.values, 'uiDensity');
        if (uiDensity != null) s.setUiDensity(uiDensity);
        final navPlacement =
            enumOf(SectionNavPlacement.values, 'sectionNavPlacement');
        if (navPlacement != null) s.setSectionNavPlacement(navPlacement);
        if (m['avoidCloudThumbnailDownloads'] is bool) {
          s.setAvoidCloudThumbnailDownloads(m['avoidCloudThumbnailDownloads']);
        }
        final sortMode = enumOf(SortMode.values, 'sortMode');
        if (sortMode != null) s.setSortMode(sortMode);
        final perfMode = enumOf(PerfMode.values, 'perfMode');
        if (perfMode != null) s.setPerfMode(perfMode);

        // скрытые папки — полная замена набора через существующий API
        final hiddenRaw = m['hiddenFolders'];
        if (hiddenRaw is List) {
          final wanted = hiddenRaw.whereType<String>().toSet();
          for (final old in Set<String>.from(s.hiddenFolders)) {
            if (!wanted.contains(old)) s.setFolderHidden(old, false);
          }
          for (final folder in wanted) {
            s.setFolderHidden(folder, true);
          }
          hiddenCount = wanted.length;
        }
        settingsRestored = true;
      }
    } catch (_) {}

    // ── папки библиотеки (полная замена) ──
    try {
      final raw = data['libraryFolders'];
      if (raw is List) {
        final list = raw.whereType<String>().toList();
        await LibraryService.setFolders(list);
        folderCount = list.length;
      }
    } catch (_) {}

    // ── коллекции (полная замена: старые удаляются, затем создаются из копии) ──
    try {
      final raw = data['collections'];
      if (raw is List && CollectionsService.instance.ready) {
        final svc = CollectionsService.instance;
        for (final old in svc.list()) {
          svc.delete(old.id);
        }
        for (final entry in raw) {
          if (entry is! Map) continue;
          final name = entry['name'];
          final paths = entry['paths'];
          if (name is! String || paths is! List) continue;
          final id = svc.create(name);
          if (id < 0) continue;
          final added = svc.addPaths(id, paths.whereType<String>());
          collCount++;
          collItemCount += added;
        }
      }
    } catch (_) {}

    // ── теги: переиспользуем формат и логику TagService (слияние) ──
    try {
      final raw = data['tags'];
      if (raw != null && TagService.instance.ready) {
        tagCount = TagService.instance.importJson(jsonEncode(raw));
      }
    } catch (_) {}

    return BackupImportResult(
      favorites: favCount,
      hiddenFolders: hiddenCount,
      settingsRestored: settingsRestored,
      collections: collCount,
      collectionItems: collItemCount,
      libraryFolders: folderCount,
      tags: tagCount,
    );
  }
}
