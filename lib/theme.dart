import 'package:flutter/material.dart';

/// Палитра одной темы. Все цвета интерфейса берутся отсюда,
/// поэтому добавить новую тему = добавить один объект AuroraColors.
@immutable
class AuroraColors {
  final String id;
  final String name;
  final Brightness brightness;
  final Color bg;
  final Color surface;
  final Color surface2;
  final Color text;
  final Color muted;
  final Color line;
  final Color accent;
  final Color accentSoft;
  final Color accentInk;

  const AuroraColors({
    required this.id,
    required this.name,
    required this.brightness,
    required this.bg,
    required this.surface,
    required this.surface2,
    required this.text,
    required this.muted,
    required this.line,
    required this.accent,
    required this.accentSoft,
    required this.accentInk,
  });

  ThemeData toThemeData() {
    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      scaffoldBackgroundColor: bg,
      colorScheme: ColorScheme.fromSeed(
        seedColor: accent,
        brightness: brightness,
      ).copyWith(surface: surface, primary: accent),
      fontFamily: 'Roboto',
    );
  }
}

/// Все доступные темы. По умолчанию — Sand (тёплая, в духе Claude).
const List<AuroraColors> kThemes = [
  AuroraColors(
    id: 'sand',
    name: 'Sand',
    brightness: Brightness.light,
    bg: Color(0xFFEFE9E1),
    surface: Color(0xFFFFFDF9),
    surface2: Color(0xFFF4EEE5),
    text: Color(0xFF2B2620),
    muted: Color(0xFF8C8377),
    line: Color(0xFFE6DDD0),
    accent: Color(0xFFC96442),
    accentSoft: Color(0xFFF3DDD2),
    accentInk: Color(0xFF7C3A23),
  ),
  AuroraColors(
    id: 'charcoal',
    name: 'Charcoal',
    brightness: Brightness.dark,
    bg: Color(0xFF161310),
    surface: Color(0xFF262019),
    surface2: Color(0xFF2F2820),
    text: Color(0xFFF2ECE2),
    muted: Color(0xFFA79C8C),
    line: Color(0xFF352D24),
    accent: Color(0xFFE08A5F),
    accentSoft: Color(0xFF3A2A20),
    accentInk: Color(0xFFF6D9C7),
  ),
  AuroraColors(
    id: 'forest',
    name: 'Forest',
    brightness: Brightness.light,
    bg: Color(0xFFE7ECE4),
    surface: Color(0xFFFFFFFF),
    surface2: Color(0xFFEEF2E9),
    text: Color(0xFF1F2A22),
    muted: Color(0xFF6F7D70),
    line: Color(0xFFDDE6D8),
    accent: Color(0xFF3F7D54),
    accentSoft: Color(0xFFDCEBDF),
    accentInk: Color(0xFF234835),
  ),
  AuroraColors(
    id: 'ocean',
    name: 'Ocean',
    brightness: Brightness.light,
    bg: Color(0xFFE6ECF1),
    surface: Color(0xFFFFFFFF),
    surface2: Color(0xFFE9EFF3),
    text: Color(0xFF1C2733),
    muted: Color(0xFF6D7A89),
    line: Color(0xFFD9E2EA),
    accent: Color(0xFF2F6F97),
    accentSoft: Color(0xFFD8E7F1),
    accentInk: Color(0xFF1D4763),
  ),
  AuroraColors(
    id: 'plum',
    name: 'Plum',
    brightness: Brightness.dark,
    bg: Color(0xFF1B141B),
    surface: Color(0xFF271E27),
    surface2: Color(0xFF312631),
    text: Color(0xFFF2E7F0),
    muted: Color(0xFFB199AD),
    line: Color(0xFF3A2E39),
    accent: Color(0xFFB46FB0),
    accentSoft: Color(0xFF3A2A38),
    accentInk: Color(0xFFEFD6EC),
  ),
];

/// Прокидывает активную палитру вниз по дереву + даёт сменить тему.
class AuroraTheme extends InheritedWidget {
  final AuroraColors colors;
  final void Function(String id) setTheme;

  const AuroraTheme({
    super.key,
    required this.colors,
    required this.setTheme,
    required super.child,
  });

  static AuroraTheme of(BuildContext context) {
    final t = context.dependOnInheritedWidgetOfExactType<AuroraTheme>();
    assert(t != null, 'AuroraTheme не найден в дереве виджетов');
    return t!;
  }

  @override
  bool updateShouldNotify(AuroraTheme oldWidget) => oldWidget.colors.id != colors.id;
}
