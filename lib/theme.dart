import 'package:flutter/material.dart';

/// Палитра одной темы (то, что в итоге видит весь UI).
/// Собирается из [AuroraBase] (нейтральная поверхность) и [AuroraAccent]
/// (цветовая подсветка). Виджеты всё так же читают AuroraColors из
/// [AuroraTheme.of], поэтому остальной код не меняется.
@immutable
class AuroraColors {
  final String id; // композитный: "{baseId}+{accentId}"
  final String name;
  final Brightness brightness;
  final Color bg;
  final Color surface;
  final Color surface2;
  final Color text;
  final Color muted;
  final Color line;
  final Color accent;
  final Color accentSoft; // фон активной плитки/таба
  final Color accentInk; // текст/иконка поверх accentSoft

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

  ThemeData toThemeData() => ThemeData(
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

// ─────────────────────────── базы (поверхности) ───────────────────────────

/// Нейтральная база темы — фон, поверхности, текст. Цвета подобраны
/// с низкой насыщенностью, чтобы не конкурировать с цветами просматриваемых
/// изображений (правило мьюзейного хранения: нейтральный фон вокруг арта).
@immutable
class AuroraBase {
  final String id;
  final String name;
  final Brightness brightness;
  final Color bg;
  final Color surface;
  final Color surface2;
  final Color text;
  final Color muted;
  final Color line;

  const AuroraBase({
    required this.id,
    required this.name,
    required this.brightness,
    required this.bg,
    required this.surface,
    required this.surface2,
    required this.text,
    required this.muted,
    required this.line,
  });
}

/// Светлые базы — для дневного света и ярких комнат.
const List<AuroraBase> kLightBases = [
  // Чистая нейтральная белая бумага — самый точный показ цвета арта.
  AuroraBase(
    id: 'paper',
    name: 'Бумага',
    brightness: Brightness.light,
    bg: Color(0xFFF5F4F2),
    surface: Color(0xFFFFFFFF),
    surface2: Color(0xFFEDECEA),
    text: Color(0xFF1B1B1A),
    muted: Color(0xFF777573),
    line: Color(0xFFE3E1DE),
  ),
  // Тёплая беж/песок — оригинальная Aurora, в духе Claude.
  AuroraBase(
    id: 'sand',
    name: 'Песок',
    brightness: Brightness.light,
    bg: Color(0xFFEFE9E1),
    surface: Color(0xFFFFFDF9),
    surface2: Color(0xFFF4EEE5),
    text: Color(0xFF2B2620),
    muted: Color(0xFF8C8377),
    line: Color(0xFFE6DDD0),
  ),
  // Кремовая — тёплая, но мягче песка, подходит при долгом просмотре.
  AuroraBase(
    id: 'cream',
    name: 'Крем',
    brightness: Brightness.light,
    bg: Color(0xFFF6F1E8),
    surface: Color(0xFFFFFCF6),
    surface2: Color(0xFFEFEAE0),
    text: Color(0xFF272219),
    muted: Color(0xFF8A8275),
    line: Color(0xFFE4DCCD),
  ),
  // Прохладный туман — нейтрально-холодный, не утомляет на крупном мониторе.
  AuroraBase(
    id: 'mist',
    name: 'Туман',
    brightness: Brightness.light,
    bg: Color(0xFFEEF1F4),
    surface: Color(0xFFFAFBFC),
    surface2: Color(0xFFE6EAEE),
    text: Color(0xFF1E2228),
    muted: Color(0xFF707682),
    line: Color(0xFFDADFE5),
  ),
];

/// Тёмные базы — для вечерних сессий и просмотра арта в тёмной комнате.
const List<AuroraBase> kDarkBases = [
  // Тёплый угольный — оригинальная тёмная Aurora.
  AuroraBase(
    id: 'charcoal',
    name: 'Уголь',
    brightness: Brightness.dark,
    bg: Color(0xFF161310),
    surface: Color(0xFF262019),
    surface2: Color(0xFF2F2820),
    text: Color(0xFFF2ECE2),
    muted: Color(0xFFA79C8C),
    line: Color(0xFF352D24),
  ),
  // Холодный графит — нейтрально-серый, не сдвигает оттенки арта.
  AuroraBase(
    id: 'slate',
    name: 'Графит',
    brightness: Brightness.dark,
    bg: Color(0xFF15171A),
    surface: Color(0xFF1F2226),
    surface2: Color(0xFF272B30),
    text: Color(0xFFECEFF3),
    muted: Color(0xFF98A0AB),
    line: Color(0xFF2E3239),
  ),
  // Полуночный — глубокий синеватый чёрный, премиальный.
  AuroraBase(
    id: 'midnight',
    name: 'Полночь',
    brightness: Brightness.dark,
    bg: Color(0xFF0F1320),
    surface: Color(0xFF181D2C),
    surface2: Color(0xFF1F2538),
    text: Color(0xFFE9ECF6),
    muted: Color(0xFF8E97B0),
    line: Color(0xFF252B3F),
  ),
  // Чистый #000 — для OLED-экранов (экономит батарею + идеальный контраст).
  AuroraBase(
    id: 'oled',
    name: 'OLED-чёрный',
    brightness: Brightness.dark,
    bg: Color(0xFF000000),
    surface: Color(0xFF0E0E0E),
    surface2: Color(0xFF161616),
    text: Color(0xFFF0F0F0),
    muted: Color(0xFF8F8F8F),
    line: Color(0xFF1F1F1F),
  ),
  // Сепия-тёмная — тёплый коричневатый, винтажный, мягкий на глаза.
  AuroraBase(
    id: 'sepia',
    name: 'Сепия',
    brightness: Brightness.dark,
    bg: Color(0xFF1A130D),
    surface: Color(0xFF26201A),
    surface2: Color(0xFF2F2820),
    text: Color(0xFFEBDFCB),
    muted: Color(0xFFA89880),
    line: Color(0xFF362C22),
  ),
];

// ─────────────────────────── акценты (подсветка) ───────────────────────────

/// Цвет акцента — кнопки, активные элементы, рамки выбора.
@immutable
class AuroraAccent {
  final String id;
  final String name;
  final Color base; // основной цвет (хорошо смотрится на нейтрале)
  const AuroraAccent({required this.id, required this.name, required this.base});
}

/// Палитра акцентов: тёплые → нейтральные → холодные → пурпурные → красные.
/// Все приглушены до S≈0.55–0.7 и L≈0.45–0.55, чтобы выглядеть «дорого»
/// и не резать глаз поверх миллиона миниатюр.
const List<AuroraAccent> kAccents = [
  AuroraAccent(id: 'coral',   name: 'Коралл',   base: Color(0xFFC96442)),
  AuroraAccent(id: 'amber',   name: 'Янтарь',   base: Color(0xFFD08F3A)),
  AuroraAccent(id: 'olive',   name: 'Олива',    base: Color(0xFF9A9F4A)),
  AuroraAccent(id: 'sage',    name: 'Шалфей',   base: Color(0xFF6E9869)),
  AuroraAccent(id: 'forest',  name: 'Хвоя',     base: Color(0xFF3F7D54)),
  AuroraAccent(id: 'teal',    name: 'Бирюза',   base: Color(0xFF3E8C8C)),
  AuroraAccent(id: 'ocean',   name: 'Океан',    base: Color(0xFF3D7AB8)),
  AuroraAccent(id: 'indigo',  name: 'Индиго',   base: Color(0xFF5C5FB8)),
  AuroraAccent(id: 'violet',  name: 'Фиалка',   base: Color(0xFF8C5FB8)),
  AuroraAccent(id: 'plum',    name: 'Слива',    base: Color(0xFFB46FB0)),
  AuroraAccent(id: 'magenta', name: 'Маджента', base: Color(0xFFC7508B)),
  AuroraAccent(id: 'crimson', name: 'Алый',     base: Color(0xFFB84A57)),
];

// ─────────────────────────── сборка палитры ───────────────────────────

AuroraBase resolveBase(String id, Brightness brightness) {
  final list = brightness == Brightness.light ? kLightBases : kDarkBases;
  return list.firstWhere((b) => b.id == id, orElse: () => list.first);
}

AuroraAccent resolveAccent(String id) =>
    kAccents.firstWhere((a) => a.id == id, orElse: () => kAccents.first);

/// Производные оттенки акцента (мягкий фон и контрастная «тушь»),
/// учитывающие яркость базы. HSL-манипуляция даёт стабильный результат
/// на любом базовом цвете без ручных подборов.
Color _accentSoft(Color accent, Brightness b) {
  final h = HSLColor.fromColor(accent);
  return b == Brightness.light
      ? h.withLightness(0.90).withSaturation((h.saturation * 0.55).clamp(0.0, 1.0)).toColor()
      : h.withLightness(0.20).withSaturation((h.saturation * 0.65).clamp(0.0, 1.0)).toColor();
}

Color _accentInk(Color accent, Brightness b) {
  final h = HSLColor.fromColor(accent);
  return b == Brightness.light
      ? h.withLightness(0.32).toColor()
      : h.withLightness(0.78).withSaturation((h.saturation * 0.7).clamp(0.0, 1.0)).toColor();
}

AuroraColors composeColors(AuroraBase base, AuroraAccent accent) {
  return AuroraColors(
    id: '${base.id}+${accent.id}',
    name: '${base.name} · ${accent.name}',
    brightness: base.brightness,
    bg: base.bg,
    surface: base.surface,
    surface2: base.surface2,
    text: base.text,
    muted: base.muted,
    line: base.line,
    accent: accent.base,
    accentSoft: _accentSoft(accent.base, base.brightness),
    accentInk: _accentInk(accent.base, base.brightness),
  );
}

// ─────────────────────────── InheritedWidget ───────────────────────────

/// Прокидывает активную палитру вниз по дереву. Сменой темы теперь
/// занимается SettingsService — здесь только доставка цветов.
class AuroraTheme extends InheritedWidget {
  final AuroraColors colors;

  const AuroraTheme({
    super.key,
    required this.colors,
    required super.child,
  });

  static AuroraTheme of(BuildContext context) {
    final t = context.dependOnInheritedWidgetOfExactType<AuroraTheme>();
    assert(t != null, 'AuroraTheme не найден в дереве виджетов');
    return t!;
  }

  @override
  bool updateShouldNotify(AuroraTheme oldWidget) =>
      oldWidget.colors.id != colors.id;
}
