import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Какой режим яркости использовать.
enum ThemeModeChoice { system, light, dark }

/// Стартовый раздел при запуске.
enum StartSection { all, dates, albums }

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
  static const _kSquareThumbs = 'goat_square_thumbs';
  static const _kReduceMotion = 'goat_reduce_motion';
  static const _kStartSection = 'goat_start_section';
  static const _kShowFav = 'goat_show_fav_badge';
  static const _kShowGif = 'goat_show_gif_badge';

  late SharedPreferences _p;
  bool _ready = false;

  // ─── текущие значения (видимые наружу) ───
  ThemeModeChoice themeMode = ThemeModeChoice.system;
  String lightBaseId = 'sand'; // оставляем оригинальную светлую тему
  String darkBaseId = 'charcoal'; // и оригинальную тёмную
  String accentId = 'coral';
  double cellSize = 120;
  double gridRadius = 7; // скругление миниатюр
  bool squareThumbs = true; // true: BoxFit.cover; false: contain
  bool reduceMotion = false;
  StartSection startSection = StartSection.all;
  bool showFavBadge = true;
  bool showGifBadge = true;

  bool get ready => _ready;

  Future<void> load() async {
    _p = await SharedPreferences.getInstance();
    themeMode = _decodeMode(_p.getString(_kThemeMode));
    lightBaseId = _p.getString(_kLightBase) ?? lightBaseId;
    darkBaseId = _p.getString(_kDarkBase) ?? darkBaseId;
    accentId = _p.getString(_kAccent) ?? accentId;
    cellSize = _p.getDouble(_kCellSize) ?? cellSize;
    gridRadius = _p.getDouble(_kGridRadius) ?? gridRadius;
    squareThumbs = _p.getBool(_kSquareThumbs) ?? squareThumbs;
    reduceMotion = _p.getBool(_kReduceMotion) ?? reduceMotion;
    startSection = _decodeStart(_p.getString(_kStartSection));
    showFavBadge = _p.getBool(_kShowFav) ?? showFavBadge;
    showGifBadge = _p.getBool(_kShowGif) ?? showGifBadge;
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
