import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Какой режим яркости использовать.
enum ThemeModeChoice { system, light, dark }

/// Стартовый раздел при запуске.
enum StartSection { all, dates, albums }

/// Раскладка сетки: ровные квадраты или мозаика с разными формами.
enum GridLayout { square, mosaic }

/// Оформление зазоров между плитками.
enum GapStyle { none, color, silver, gold, holographic, polaroid }

/// Язык интерфейса.
enum AppLang { system, ru, en }

/// Плотность основного интерфейса: авто выбирает компактный вид на телефонах.
enum UiDensity { auto, compact, comfortable }

/// Единый сервис настроек пользователя: палитра, плотность сетки, поведение
/// при старте, мелкие визуальные предпочтения. Все значения сохраняются
/// в shared_preferences и рассылаются подписчикам через ChangeNotifier.
class SettingsService extends ChangeNotifier {
  SettingsService._();
  static final SettingsService instance = SettingsService._();

  // ─── ключи в SharedPreferences ───
  static const _kThemeMode = 'goat_theme_mode';
  static const _kLightBase = 'goat_light_base';
  static const _kDarkBase = 'goat_dark_base';
  static const _kAccent = 'goat_accent';
  static const _kCellSize = 'goat_cell_size';
  static const _kGridRadius = 'goat_grid_radius';
  static const _kTileSpacing = 'goat_tile_spacing';
  static const _kGridLayout = 'goat_grid_layout';
  static const _kSquareThumbs = 'goat_square_thumbs';
  static const _kReduceMotion = 'goat_reduce_motion';
  static const _kStartSection = 'goat_start_section';
  static const _kShowFav = 'goat_show_fav_badge';
  static const _kShowGif = 'goat_show_gif_badge';
  static const _kHiddenFolders = 'goat_hidden_folders';
  static const _kShowHidden = 'goat_show_hidden';
  static const _kGapStyle = 'goat_gap_style';
  static const _kGapColor = 'goat_gap_color';
  static const _kPcScanMinDim = 'goat_pc_scan_min_dim';
  static const _kAppLang = 'goat_app_lang';
  static const _kUiDensity = 'goat_ui_density';

  late SharedPreferences _p;
  bool _ready = false;

  // ─── текущие значения (видимые наружу) ───
  ThemeModeChoice themeMode = ThemeModeChoice.system;
  String lightBaseId = 'sand'; // оставляем оригинальную светлую тему
  String darkBaseId = 'charcoal'; // и оригинальную тёмную
  String accentId = 'coral';
  double cellSize = 120;
  double gridRadius = 7; // скругление миниатюр
  double tileSpacing = 4; // зазор между плитками (0 = плотная мозаика)
  GridLayout gridLayout = GridLayout.square; // раскладка сетки
  bool squareThumbs = true; // true: BoxFit.cover; false: contain
  bool reduceMotion = false;
  StartSection startSection = StartSection.all;
  bool showFavBadge = true;
  bool showGifBadge = true;
  Set<String> hiddenFolders = {}; // скрытые папки (секретные альбомы)
  bool showHidden = false; // показывать ли скрытые папки в галерее
  GapStyle gapStyle = GapStyle.none; // оформление зазоров
  int gapColorValue = 0xFFC96442; // цвет для GapStyle.color (ARGB)
  int pcScanMinDim = 256; // мин. размер картинки (px) при поиске по ПК
  AppLang appLang = AppLang.system; // язык интерфейса
  UiDensity uiDensity = UiDensity.auto; // компактность главного экрана

  bool get ready => _ready;

  Future<void> load() async {
    _p = await SharedPreferences.getInstance();
    themeMode = _decodeMode(_p.getString(_kThemeMode));
    lightBaseId = _p.getString(_kLightBase) ?? lightBaseId;
    darkBaseId = _p.getString(_kDarkBase) ?? darkBaseId;
    accentId = _p.getString(_kAccent) ?? accentId;
    cellSize = _p.getDouble(_kCellSize) ?? cellSize;
    gridRadius = _p.getDouble(_kGridRadius) ?? gridRadius;
    tileSpacing = _p.getDouble(_kTileSpacing) ?? tileSpacing;
    gridLayout = (_p.getString(_kGridLayout) == 'mosaic')
        ? GridLayout.mosaic
        : GridLayout.square;
    squareThumbs = _p.getBool(_kSquareThumbs) ?? squareThumbs;
    reduceMotion = _p.getBool(_kReduceMotion) ?? reduceMotion;
    startSection = _decodeStart(_p.getString(_kStartSection));
    showFavBadge = _p.getBool(_kShowFav) ?? showFavBadge;
    showGifBadge = _p.getBool(_kShowGif) ?? showGifBadge;
    hiddenFolders = (_p.getStringList(_kHiddenFolders) ?? const []).toSet();
    showHidden = _p.getBool(_kShowHidden) ?? showHidden;
    gapStyle = GapStyle.values.firstWhere(
        (e) => e.name == _p.getString(_kGapStyle),
        orElse: () => GapStyle.none);
    gapColorValue = _p.getInt(_kGapColor) ?? gapColorValue;
    pcScanMinDim = _p.getInt(_kPcScanMinDim) ?? pcScanMinDim;
    appLang = AppLang.values.firstWhere(
        (e) => e.name == _p.getString(_kAppLang),
        orElse: () => AppLang.system);
    uiDensity = UiDensity.values.firstWhere(
        (e) => e.name == _p.getString(_kUiDensity),
        orElse: () => UiDensity.auto);
    _ready = true;
    notifyListeners();
  }

  // ─── сеттеры с автосохранением ───
  void setThemeMode(ThemeModeChoice v) {
    themeMode = v;
    _p.setString(_kThemeMode, v.name);
    notifyListeners();
  }

  void setLightBase(String id) {
    lightBaseId = id;
    _p.setString(_kLightBase, id);
    notifyListeners();
  }

  void setDarkBase(String id) {
    darkBaseId = id;
    _p.setString(_kDarkBase, id);
    notifyListeners();
  }

  void setAccent(String id) {
    accentId = id;
    _p.setString(_kAccent, id);
    notifyListeners();
  }

  void setCellSize(double v) {
    cellSize = v;
    _p.setDouble(_kCellSize, v);
    notifyListeners();
  }

  void setGridRadius(double v) {
    gridRadius = v;
    _p.setDouble(_kGridRadius, v);
    notifyListeners();
  }

  void setTileSpacing(double v) {
    tileSpacing = v;
    _p.setDouble(_kTileSpacing, v);
    notifyListeners();
  }

  void setGridLayout(GridLayout v) {
    gridLayout = v;
    _p.setString(_kGridLayout, v.name);
    notifyListeners();
  }

  void setSquareThumbs(bool v) {
    squareThumbs = v;
    _p.setBool(_kSquareThumbs, v);
    notifyListeners();
  }

  void setReduceMotion(bool v) {
    reduceMotion = v;
    _p.setBool(_kReduceMotion, v);
    notifyListeners();
  }

  void setStartSection(StartSection v) {
    startSection = v;
    _p.setString(_kStartSection, v.name);
    notifyListeners();
  }

  void setShowFavBadge(bool v) {
    showFavBadge = v;
    _p.setBool(_kShowFav, v);
    notifyListeners();
  }

  void setShowGifBadge(bool v) {
    showGifBadge = v;
    _p.setBool(_kShowGif, v);
    notifyListeners();
  }

  void setShowHidden(bool v) {
    showHidden = v;
    _p.setBool(_kShowHidden, v);
    notifyListeners();
  }

  void setGapStyle(GapStyle v) {
    gapStyle = v;
    _p.setString(_kGapStyle, v.name);
    notifyListeners();
  }

  void setGapColor(int argb) {
    gapColorValue = argb;
    _p.setInt(_kGapColor, argb);
    notifyListeners();
  }

  void setPcScanMinDim(int v) {
    pcScanMinDim = v;
    _p.setInt(_kPcScanMinDim, v);
    notifyListeners();
  }

  void setAppLang(AppLang v) {
    appLang = v;
    _p.setString(_kAppLang, v.name);
    notifyListeners();
  }

  void setUiDensity(UiDensity v) {
    uiDensity = v;
    _p.setString(_kUiDensity, v.name);
    notifyListeners();
  }

  bool isHidden(String folderPath) => hiddenFolders.contains(folderPath);

  void setFolderHidden(String folderPath, bool hidden) {
    if (hidden) {
      hiddenFolders.add(folderPath);
    } else {
      hiddenFolders.remove(folderPath);
    }
    _p.setStringList(_kHiddenFolders, hiddenFolders.toList());
    notifyListeners();
  }

  // ─── вспомогательное ───
  ThemeModeChoice _decodeMode(String? raw) {
    switch (raw) {
      case 'light':
        return ThemeModeChoice.light;
      case 'dark':
        return ThemeModeChoice.dark;
      default:
        return ThemeModeChoice.system;
    }
  }

  StartSection _decodeStart(String? raw) {
    switch (raw) {
      case 'dates':
        return StartSection.dates;
      case 'albums':
        return StartSection.albums;
      default:
        return StartSection.all;
    }
  }
}
